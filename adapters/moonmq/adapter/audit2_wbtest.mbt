// Second audit batch: the paths a young broker is most likely to get wrong.
//   1. cross-session isolation: can owner A acknowledge owner B's delivery?
//   2. exchange routing: fanout / direct / topic, including a wildcard case
//   3. delete_queue(if_unused=true) while a consumer is attached
//
// These are the classic defect farms, and unlike the first batch they are about
// isolation and routing rather than about one session's own accounting.

///|
fn broker_with_queue(name : String) -> (@broker.Broker, String) {
  let b = @broker.Broker::new()
  let q = match b.declare_queue(name) {
    Ok(q) => q
    Err(_) => name
  }
  (b, q)
}

///|
test "cross-session: another owner must not ack my delivery" {
  let (b, q) = broker_with_queue("iso.q")
  ignore(b.publish("", q, @encoding/utf8.encode("secret")))
  // owner A takes the delivery
  let tag = match b.get_with_owner(q, "ownerA") {
    Ok(Some(d)) => d.tag()
    _ => abort("expected a delivery for ownerA")
  }
  // owner B tries to acknowledge it
  let stolen = b.ack_with_owner("ownerB", tag)
  println(
    "ownerB acking ownerA's tag ok? \{stolen is Ok(_)}   (expected: false)",
  )
  // and the rightful owner can still ack it
  println(
    "ownerA ack ok? \{b.ack_with_owner("ownerA", tag) is Ok(_)}   (expected: true)",
  )
}

///|
test "fanout exchange delivers to every bound queue" {
  let b = @broker.Broker::new()
  let q1 = match b.declare_queue("fan.q1") {
    Ok(q) => q
    Err(_) => "fan.q1"
  }
  let q2 = match b.declare_queue("fan.q2") {
    Ok(q) => q
    Err(_) => "fan.q2"
  }
  ignore(b.declare_exchange("fan.x", @broker.ExchangeFanout))
  ignore(b.bind_queue("fan.x", q1, ""))
  ignore(b.bind_queue("fan.x", q2, ""))
  ignore(b.publish("fan.x", "", @encoding/utf8.encode("broadcast")))
  let got1 = b.get(q1) is Ok(Some(_))
  let got2 = b.get(q2) is Ok(Some(_))
  println("fanout reached q1=\{got1} q2=\{got2}   (expected: both true)")
}

///|
test "topic routing with a wildcard key" {
  let b = @broker.Broker::new()
  let q = match b.declare_queue("topic.q") {
    Ok(q) => q
    Err(_) => "topic.q"
  }
  ignore(b.declare_exchange("topic.x", @broker.ExchangeTopic))
  ignore(b.bind_queue("topic.x", q, "job.*"))
  ignore(b.publish("topic.x", "job.high", @encoding/utf8.encode("m1")))
  let matched = b.get(q) is Ok(Some(_))
  ignore(b.publish("topic.x", "other.low", @encoding/utf8.encode("m2")))
  let second = b.get(q) is Ok(Some(_))
  println("topic job.* got job.high=\{matched}   (expected: true)")
  println("topic job.* got other.low=\{second}    (expected: false)")
}

///|
test "delete_queue(if_unused=true) with a consumer attached" {
  let (b, q) = broker_with_queue("inuse.q")
  let h = match b.consume(q, "ctag", 1) {
    Ok(h) => h
    Err(_) => abort("consume failed")
  }
  let deleted = b.delete_queue(q, true, false)
  println(
    "delete if_unused with a consumer ok? \{deleted is Ok(_)}   (expected: false)",
  )
  ignore(b.cancel_consumer(h))
  let after = b.delete_queue(q, true, false)
  println(
    "delete if_unused after cancel ok? \{after is Ok(_)}   (expected: true)",
  )
}
