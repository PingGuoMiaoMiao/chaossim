// The tool is only worth something if its RISK branches actually fire. This file
// separates "observe" (call the library) from "judge" (turn an observation into a
// verdict), so every judgment can be exercised with a deliberately bad input.
//
// Each judge is total: given the good observation it returns Pass, given the bad
// one it returns Risk. checkup_wbtest.mbt asserts both directions for all of them,
// which is what proves the report can flag a broken library rather than only ever
// printing PASS.

///|
/// True if the observation indicates a defect.
pub fn judge_double_ack(second_ok : Bool) -> Bool {
  // the second ack of an already-acked tag must be refused
  second_ok
}

///|
pub fn judge_ack_after_requeue(old_tag_ok : Bool) -> Bool {
  // a tag whose delivery was requeued must no longer be ackable
  old_tag_ok
}

///|
pub fn judge_requeue_returns(got_again : Bool) -> Bool {
  // requeue must put the message back; failing to do so loses it
  !got_again
}

///|
pub fn judge_discard(got_after_discard : Bool) -> Bool {
  // a discarded message must not come back
  got_after_discard
}

///|
pub fn judge_prefetch(second_delivered : Bool) -> Bool {
  // with prefetch=1 and one unacked delivery, a second poll must yield nothing
  second_delivered
}

///|
pub fn judge_cancel(ready_after_cancel : Int32) -> Bool {
  // cancelling a consumer holding an unacked delivery must return it to the queue
  ready_after_cancel < 1
}

///|
pub fn judge_delete_refused(deleted : Bool) -> Bool {
  // deleting a queue with an outstanding delivery destroys it silently
  deleted
}

///|
pub fn judge_ack_many(second_ack_ok : Bool) -> Bool {
  // a failed batch must not consume any of its tags
  !second_ack_ok
}

///|
pub fn judge_isolation(foreign_ack_ok : Bool) -> Bool {
  // another session must not be able to ack someone else's delivery
  foreign_ack_ok
}

///|
pub fn judge_fanout(q1 : Bool, q2 : Bool) -> Bool {
  // fanout must reach every bound queue
  !(q1 && q2)
}

///|
pub fn judge_topic(matched : Bool, leaked : Bool) -> Bool {
  // the wildcard must match what it should, and only that
  !matched || leaked
}

///|
/// Human-readable reason for the failure, given the same observation.
pub fn why_double_ack(second_ok : Bool) -> String {
  if second_ok {
    "第二次确认返回成功：重复确认会被静默接受"
  } else {
    ""
  }
}

///|
pub fn why_ack_after_requeue(old_tag_ok : Bool) -> String {
  if old_tag_ok {
    "旧 tag 仍可确认：未确认计数可能被重复扣减"
  } else {
    ""
  }
}

///|
pub fn why_requeue_returns(got_again : Bool) -> String {
  if got_again {
    ""
  } else {
    "reject(requeue) 之后取不到消息：消息丢失"
  }
}

///|
pub fn why_discard(got_after : Bool) -> String {
  if got_after {
    "已丢弃的消息又被取出：丢弃无效"
  } else {
    ""
  }
}

///|
pub fn why_prefetch(second_delivered : Bool) -> String {
  if second_delivered {
    "第二次 poll 仍投递：预取上限失效，客户端内存可能被撑爆"
  } else {
    ""
  }
}

///|
pub fn why_cancel(ready_after : Int32) -> String {
  if ready_after < 1 {
    "取消后队列为空：未确认消息既没重投也没人能确认，消息悬空"
  } else {
    ""
  }
}

///|
pub fn why_delete(deleted : Bool) -> String {
  if deleted {
    "队列被删掉了，未确认消息随之消失：静默丢数据"
  } else {
    ""
  }
}

///|
pub fn why_ack_many(second_ok : Bool) -> String {
  if second_ok {
    ""
  } else {
    "批量确认部分生效：调用方无法判断哪些被确认"
  }
}

///|
pub fn why_isolation(foreign_ok : Bool) -> String {
  if foreign_ok {
    "另一个会话能确认别人的投递：隔离失效"
  } else {
    ""
  }
}

///|
pub fn why_fanout(q1 : Bool, q2 : Bool) -> String {
  if q1 && q2 {
    ""
  } else {
    "扇出未送达全部队列（q1=\{q1} q2=\{q2}）"
  }
}

///|
pub fn why_topic(matched : Bool, leaked : Bool) -> String {
  if !matched {
    "通配符没匹配到应匹配的 key：消息会路由丢失"
  } else if leaked {
    "不匹配的 key 也被投递：消息会被错误路由"
  } else {
    ""
  }
}
