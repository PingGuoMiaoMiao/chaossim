// Sharp probes against the real broker: the edges where a young broker breaks.
// Each prints what the broker actually does; assertions mark what SHOULD hold.
// A failure is either a real defect to report upstream or my wrong assumption.

///|
fn new_broker() -> (@broker.Broker, String) {
  let b = @broker.Broker::new()
  let q = match b.declare_queue("audit.q") {
    Ok(q) => q
    Err(_) => "audit.q"
  }
  (b, q)
}

///|
fn pub1(b : @broker.Broker, q : String, body : String) -> Unit {
  ignore(b.publish("", q, @encoding/utf8.encode(body)))
}

///|
fn tag_of(b : @broker.Broker, q : String) -> UInt64? {
  match b.get(q) {
    Ok(Some(d)) => Some(d.tag())
    _ => None
  }
}

///|
fn ready(b : @broker.Broker, q : String) -> Int32 {
  match b.queue_stats(q) {
    Ok(s) => s.message_count()
    _ => -1
  }
}

///|
test "acking the same tag twice" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  let tag = match tag_of(b, q) {
    Some(t) => t
    None => abort("expected a delivery")
  }
  println("first ack ok?  \{b.ack(tag) is Ok(_)}")
  println("second ack ok? \{b.ack(tag) is Ok(_)}   (expected: false)")
}

///|
test "ack after reject(requeue=true)" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  let tag = match tag_of(b, q) {
    Some(t) => t
    None => abort("expected a delivery")
  }
  println("reject(requeue) ok? \{b.reject(tag, true) is Ok(_)}")
  println("ack of that tag ok? \{b.ack(tag) is Ok(_)}   (expected: false)")
  println("ready after requeue: \{ready(b, q)}   (expected: 1)")
}

///|
test "reject(requeue=false) discards" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  let tag = match tag_of(b, q) {
    Some(t) => t
    None => abort("expected a delivery")
  }
  println("reject(discard) ok? \{b.reject(tag, false) is Ok(_)}")
  println("ready after discard: \{ready(b, q)}   (expected: 0)")
  println(
    "get after discard has delivery? \{tag_of(b, q) is Some(_)}   (expected: false)",
  )
}

///|
test "prefetch 1 blocks the second poll" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  pub1(b, q, "b")
  let h = match b.consume(q, "ctag", 1) {
    Ok(h) => h
    Err(_) => abort("consume failed")
  }
  let first = b.poll(h)
  let second = b.poll(h)
  println("poll #1 delivered? \{first is Ok(Some(_))}")
  println("poll #2 delivered? \{second is Ok(Some(_))}   (expected: false)")
}

///|
test "cancel a consumer that holds an unacked delivery" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  let h = match b.consume(q, "ctag", 1) {
    Ok(h) => h
    Err(_) => abort("consume failed")
  }
  let tag = match b.poll(h) {
    Ok(Some(d)) => d.tag()
    _ => abort("expected a delivery")
  }
  println("cancel ok? \{b.cancel_consumer(h) is Ok(_)}")
  println("ready after cancel: \{ready(b, q)}   (a requeue would make this 1)")
  println("ack after cancel ok? \{b.ack(tag) is Ok(_)}")
  println("get after cancel has delivery? \{tag_of(b, q) is Some(_)}")
}

///|
test "delete_queue(if_empty=true) around ack" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  let ready_before = ready(b, q)
  let deleted_while_ready = b.delete_queue(q, false, true)
  println(
    "ready=\{ready_before}; delete if_empty while ready ok? \{deleted_while_ready is Ok(_)}   (expected: false)",
  )
  let tag = match tag_of(b, q) {
    Some(t) => t
    None => abort("expected a delivery")
  }
  let deleted_while_unacked = b.delete_queue(q, false, true)
  println(
    "delete if_empty while unacked ok? \{deleted_while_unacked is Ok(_)}   (expected: false)",
  )
  ignore(b.ack(tag))
  let deleted_after = b.delete_queue(q, false, true)
  println(
    "delete if_empty after ack ok? \{deleted_after is Ok(_)}   (expected: true)",
  )
}

///|
test "ack_many with one bogus tag" {
  let (b, q) = new_broker()
  pub1(b, q, "a")
  pub1(b, q, "b")
  let t1 = match tag_of(b, q) {
    Some(t) => t
    None => abort("expected a delivery")
  }
  let t2 = match tag_of(b, q) {
    Some(t) => t
    None => abort("expected a delivery")
  }
  let bogus = t2 + 99UL
  println(
    "ack_many [valid, bogus] ok? \{b.ack_many_with_owner("", [t1, bogus]) is Ok(_)}",
  )
  println(
    "  -> if Ok, was the valid tag still applied? ack(t2) ok? \{b.ack(t2) is Ok(_)}",
  )
  println(
    "  (a partial ack reported as Ok is an atomicity question worth knowing)",
  )
}
