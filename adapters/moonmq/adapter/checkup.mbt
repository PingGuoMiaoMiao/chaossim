// Checkup battery: each item drives one recovery/accounting path of a target
// broker and returns a verdict plus the observation that produced it.
//
// This is the "tool" half of the project: a fixed battery you can run against a
// library and get a report from, instead of a framework you have to assemble.

///|
/// Verdict for one item.
pub(all) enum Verdict {
  Pass
  Risk(String)
  NotCovered(String)
}

///|
pub(all) struct Check {
  name : String
  /// what the item is trying to prove, in one line
  question : String
  verdict : Verdict
}

///|
fn pass(name : String, question : String) -> Check {
  { name, question, verdict: Pass }
}

///|
fn risk(name : String, question : String, why : String) -> Check {
  { name, question, verdict: Risk(why) }
}

///|
fn uncovered(name : String, question : String, why : String) -> Check {
  { name, question, verdict: NotCovered(why) }
}

///|
pub fn verdict_mark(v : Verdict) -> String {
  match v {
    Pass => "PASS"
    Risk(_) => "RISK"
    NotCovered(_) => "N/A"
  }
}

///|
pub fn verdict_detail(v : Verdict) -> String {
  match v {
    Pass => ""
    Risk(why) => why
    NotCovered(why) => why
  }
}

///|
/// Run the whole battery against a fresh broker.
pub fn battery() -> Array[Check] {
  let out : Array[Check] = []
  out.push(check_double_ack())
  out.push(check_ack_after_requeue())
  out.push(check_requeue_returns_message())
  out.push(check_discard_drops_message())
  out.push(check_prefetch_blocks())
  out.push(check_cancel_requeues())
  out.push(check_delete_refused_while_unacked())
  out.push(check_ack_many_atomic())
  out.push(check_cross_session_isolation())
  out.push(check_fanout())
  out.push(check_topic_wildcard())
  out
}

///|
fn fresh(queue : String) -> (@broker.Broker, String) {
  let b = @broker.Broker::new()
  let q = match b.declare_queue(queue) {
    Ok(q) => q
    Err(_) => queue
  }
  (b, q)
}

///|
fn put(b : @broker.Broker, q : String, body : String) -> Unit {
  ignore(b.publish("", q, @encoding/utf8.encode(body)))
}

///|
fn take(b : @broker.Broker, q : String) -> UInt64? {
  match b.get(q) {
    Ok(Some(d)) => Some(d.tag())
    _ => None
  }
}

///|
fn check_double_ack() -> Check {
  let name = "重复确认同一投递"
  let question = "同一个 tag 确认两次，第二次是否被拒绝"
  let (b, q) = fresh("chk.ack")
  put(b, q, "a")
  let tag = match take(b, q) {
    Some(t) => t
    None => return uncovered(name, question, "拿不到投递")
  }
  let _ = b.ack(tag)
  let second = b.ack(tag)
  if second is Ok(_) {
    risk(name, question, "第二次确认返回成功；重复确认会被静默接受")
  } else {
    pass(name, question)
  }
}

///|
fn check_ack_after_requeue() -> Check {
  let name = "重投后确认旧 tag"
  let question = "reject(requeue) 之后，旧的 tag 是否还能被确认"
  let (b, q) = fresh("chk.requeue")
  put(b, q, "a")
  let tag = match take(b, q) {
    Some(t) => t
    None => return uncovered(name, question, "拿不到投递")
  }
  let _ = b.reject(tag, true)
  if b.ack(tag) is Ok(_) {
    risk(name, question, "旧 tag 仍可确认；可能重复扣减未确认计数")
  } else {
    pass(name, question)
  }
}

///|
fn check_requeue_returns_message() -> Check {
  let name = "reject 后消息可再取"
  let question = "reject(requeue=true) 之后消息是否真的回到队列"
  let (b, q) = fresh("chk.back")
  put(b, q, "a")
  let tag = match take(b, q) {
    Some(t) => t
    None => return uncovered(name, question, "拿不到投递")
  }
  let _ = b.reject(tag, true)
  match b.get(q) {
    Ok(Some(_)) => pass(name, question)
    _ => risk(name, question, "reject(requeue) 之后队列里取不到消息：消息丢失")
  }
}

///|
fn check_discard_drops_message() -> Check {
  let name = "reject 不重投即丢弃"
  let question = "reject(requeue=false) 之后消息是否真的消失"
  let (b, q) = fresh("chk.drop")
  put(b, q, "a")
  let tag = match take(b, q) {
    Some(t) => t
    None => return uncovered(name, question, "拿不到投递")
  }
  let _ = b.reject(tag, false)
  match b.get(q) {
    Ok(Some(_)) => risk(name, question, "已丢弃的消息又被取出：丢弃无效")
    _ => pass(name, question)
  }
}

///|
fn check_prefetch_blocks() -> Check {
  let name = "预取上限"
  let question = "prefetch=1 且未确认时，第二次 poll 是否被拦住"
  let (b, q) = fresh("chk.prefetch")
  put(b, q, "a")
  put(b, q, "b")
  let h = match b.consume(q, "ctag", 1) {
    Ok(h) => h
    Err(_) => return uncovered(name, question, "consume 失败")
  }
  let _ = b.poll(h)
  match b.poll(h) {
    Ok(Some(_)) => risk(name, question, "第二次 poll 仍投递：预取上限失效（可能撑爆客户端内存）")
    _ => pass(name, question)
  }
}

///|
fn check_cancel_requeues() -> Check {
  let name = "取消消费者时重投"
  let question = "取消持有未确认投递的消费者，消息是否回到队列"
  let (b, q) = fresh("chk.cancel")
  put(b, q, "a")
  let h = match b.consume(q, "ctag", 1) {
    Ok(h) => h
    Err(_) => return uncovered(name, question, "consume 失败")
  }
  let _ = b.poll(h)
  let _ = b.cancel_consumer(h)
  match b.queue_stats(q) {
    Ok(s) =>
      if s.message_count() >= 1 {
        pass(name, question)
      } else {
        risk(name, question, "取消后队列为空：未确认消息既没重投也没人能确认，消息悬空")
      }
    _ => uncovered(name, question, "拿不到队列统计")
  }
}

///|
fn check_delete_refused_while_unacked() -> Check {
  let name = "未确认时禁止删队列"
  let question = "有未确认投递时 delete_queue(if_empty=false) 是否被拒绝"
  let (b, q) = fresh("chk.delete")
  put(b, q, "a")
  let _tag = take(b, q)
  match b.delete_queue(q, false, false) {
    Ok(_) => risk(name, question, "队列被删掉了，未确认消息随之消失：静默丢数据")
    _ => pass(name, question)
  }
}

///|
fn check_ack_many_atomic() -> Check {
  let name = "批量确认的原子性"
  let question = "批量确认里有一个无效 tag 时，有效的那些是否被误消费"
  let (b, q) = fresh("chk.many")
  put(b, q, "a")
  put(b, q, "b")
  let t1 = match take(b, q) {
    Some(t) => t
    None => return uncovered(name, question, "拿不到投递")
  }
  let t2 = match take(b, q) {
    Some(t) => t
    None => return uncovered(name, question, "拿不到第二条投递")
  }
  let _ = b.ack_many_with_owner("", [t1, t2 + 99UL])
  // if the batch failed atomically, t1 is still confirmable
  if b.ack(t2) is Ok(_) {
    pass(name, question)
  } else {
    risk(name, question, "批量确认部分生效，调用方无法判断哪些被确认")
  }
}

///|
fn check_cross_session_isolation() -> Check {
  let name = "跨会话隔离"
  let question = "ownerB 能否确认 ownerA 的投递"
  let (b, q) = fresh("chk.iso")
  put(b, q, "secret")
  let tag = match b.get_with_owner(q, "ownerA") {
    Ok(Some(d)) => d.tag()
    _ => return uncovered(name, question, "拿不到投递")
  }
  if b.ack_with_owner("ownerB", tag) is Ok(_) {
    risk(name, question, "另一个会话能确认别人的投递：隔离失效")
  } else {
    pass(name, question)
  }
}

///|
fn check_fanout() -> Check {
  let name = "扇出交换机"
  let question = "fanout 绑定的两个队列是否都收到"
  let b = @broker.Broker::new()
  let q1 = match b.declare_queue("chk.f1") {
    Ok(q) => q
    Err(_) => "chk.f1"
  }
  let q2 = match b.declare_queue("chk.f2") {
    Ok(q) => q
    Err(_) => "chk.f2"
  }
  let _ = b.declare_exchange("chk.fx", @broker.ExchangeFanout)
  let _ = b.bind_queue("chk.fx", q1, "")
  let _ = b.bind_queue("chk.fx", q2, "")
  ignore(b.publish("chk.fx", "", @encoding/utf8.encode("broadcast")))
  let got1 = b.get(q1) is Ok(Some(_))
  let got2 = b.get(q2) is Ok(Some(_))
  if got1 && got2 {
    pass(name, question)
  } else {
    risk(
      name,
      question,
      "扇出未送达全部队列（q1=\{got1} q2=\{got2}）",
    )
  }
}

///|
fn check_topic_wildcard() -> Check {
  let name = "主题通配路由"
  let question = "绑定 job.* 时，job.high 是否匹配、other.low 是否不匹配"
  let b = @broker.Broker::new()
  let q = match b.declare_queue("chk.topic") {
    Ok(q) => q
    Err(_) => "chk.topic"
  }
  let _ = b.declare_exchange("chk.tx", @broker.ExchangeTopic)
  let _ = b.bind_queue("chk.tx", q, "job.*")
  ignore(b.publish("chk.tx", "job.high", @encoding/utf8.encode("m1")))
  let matched = b.get(q) is Ok(Some(_))
  ignore(b.publish("chk.tx", "other.low", @encoding/utf8.encode("m2")))
  let leaked = b.get(q) is Ok(Some(_))
  if matched && !leaked {
    pass(name, question)
  } else if !matched {
    risk(name, question, "通配符没匹配到应匹配的 key：消息会路由丢失")
  } else {
    risk(name, question, "不匹配的 key 也被投递：消息会被错误路由")
  }
}
