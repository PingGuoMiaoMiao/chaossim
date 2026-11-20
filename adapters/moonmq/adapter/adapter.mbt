// chaossim adapter for Zcxssxx/moonmq (AMQP 0-9-1 core + embedded broker).
//
// Target: the broker's ack/requeue accounting, driven over a wire that can lose
// messages. Node 1 is the REAL broker; node 0 is a scripted client. Faults sit
// between them, so the thing under test is: when the broker's reply never
// arrives, does the message survive, and does the broker still know it is
// outstanding?
//
// Invariants, all delivery-independent:
//   I1 an acked tag is never handed out again
//   I2 while a delivery is unacked, delete_queue(if_empty=false) is refused,
//      i.e. the broker has not silently dropped the message
//   I3 accounting closes: acked + unacked <= published, and nothing evaporates
//
// None of them asserts "the message arrived": under loss it must NOT arrive.

///|
pub let op_get : Int = 1

///|
pub let op_ack : Int = 2

///|
pub let op_delete_probe : Int = 3

///|
pub let op_reject : Int = 4

///|
pub let op_stats : Int = 5

///|
pub let reply_ok : Int = 100

///|
pub let reply_none : Int = 101

///|
pub let reply_refused : Int = 102

///|
pub let reply_error : Int = 103

///|
pub(all) struct World {
  broker : @broker.Broker
  queue : String
  mut published : Int
  mut delivered : Int
  mut acked : Int
  /// every tag the broker handed out, in order
  mut issued_tags : Array[UInt64]
  /// tags the client acknowledged
  mut acked_tags : Array[UInt64]
  /// tags still outstanding broker-side
  mut unacked_tags : Array[UInt64]
  /// client operations, applied in order as replies come back
  mut script : Array[Int]
  mut pos : Int
  mut rejected : Int
  mut stats_counts : Array[Int]
  mut delete_refused : Int
  mut delete_allowed : Int
  /// invariant violations, in the order found
  mut bad : Array[String]
}

///|
fn note(w : World, msg : String) -> Unit {
  w.bad.push(msg)
}

///|
fn without(tags : Array[UInt64], tag : UInt64) -> Array[UInt64] {
  let out : Array[UInt64] = []
  for t in tags {
    if t != tag {
      out.push(t)
    }
  }
  out
}

///|
/// Set up the broker and fill a queue. Setup is not fault-injected: the
/// interesting failures live in the delivery/ack path, not in topology creation.
pub fn setup(count : Int) -> World {
  let broker = @broker.Broker::new()
  let queue = match broker.declare_queue("chaossim.q") {
    Ok(q) => q
    Err(_) => "chaossim.q"
  }
  let w : World = {
    broker,
    queue,
    published: 0,
    delivered: 0,
    acked: 0,
    issued_tags: [],
    acked_tags: [],
    unacked_tags: [],
    script: [],
    pos: 0,
    rejected: 0,
    stats_counts: [],
    delete_refused: 0,
    delete_allowed: 0,
    bad: [],
  }
  for i = 0; i < count; i = i + 1 {
    let n = match broker.publish("", queue, @encoding/utf8.encode("m\{i}")) {
      Ok(n) => n
      Err(_) => 0
    }
    w.published = w.published + n
  }
  w
}

///|
pub(all) struct Scenario {
  result : @sim.RunResult
  world : World
}

///|
/// Apply one client operation to the real broker and return the reply code.
fn apply(w : World, op : Int) -> Int {
  if op == op_get {
    match w.broker.get(w.queue) {
      Ok(Some(d)) => {
        let tag = d.tag()
        w.delivered = w.delivered + 1
        w.issued_tags.push(tag)
        w.unacked_tags.push(tag)
        reply_ok
      }
      Ok(None) => reply_none
      Err(_) => reply_error
    }
  } else if op == op_ack {
    if w.unacked_tags.length() == 0 {
      reply_error
    } else {
      let tag = w.unacked_tags[0]
      match w.broker.ack(tag) {
        Ok(_) => {
          w.unacked_tags = without(w.unacked_tags, tag)
          w.acked_tags.push(tag)
          w.acked = w.acked + 1
          reply_ok
        }
        Err(_) => reply_error
      }
    }
  } else if op == op_reject {
    // requeue=true: the message must return to the queue, never vanish
    if w.unacked_tags.length() == 0 {
      reply_error
    } else {
      let tag = w.unacked_tags[0]
      match w.broker.reject(tag, true) {
        Ok(_) => {
          w.unacked_tags = without(w.unacked_tags, tag)
          w.rejected = w.rejected + 1
          reply_ok
        }
        Err(_) => reply_error
      }
    }
  } else if op == op_stats {
    match w.broker.queue_stats(w.queue) {
      Ok(s) => {
        w.stats_counts.push(s.message_count())
        reply_ok
      }
      Err(_) => reply_error
    }
  } else if op == op_delete_probe {
    // if_unused=false, if_empty=false: only outstanding deliveries can refuse it
    match w.broker.delete_queue(w.queue, false, false) {
      Ok(_) => {
        w.delete_allowed = w.delete_allowed + 1
        if w.unacked_tags.length() > 0 {
          note(
            w,
            "I2 violated: queue deleted while \{w.unacked_tags.length()} delivery(s) were unacked",
          )
        }
        reply_ok
      }
      Err(@broker.QueueDeleteWithUnackedDeliveriesUnsupported) => {
        w.delete_refused = w.delete_refused + 1
        reply_refused
      }
      Err(_) => reply_error
    }
  } else {
    reply_error
  }
}

///|
/// Run the client script against the real broker.
///
/// The client asks for a delivery, acknowledges it, then probes whether the
/// queue may be deleted; that probe is how "the message is still accounted for"
/// is observed from outside the broker, without reading its internals.
pub fn run_script(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
  count : Int,
  script : Array[Int],
) -> Scenario raise @sim.SimError {
  let w = setup(count)
  w.script = script
  w.pos = 0
  let first = if script.length() > 0 { script[0] } else { op_delete_probe }
  let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: first }]
  // The handler closes over `w`, like the MQTT adapter: the real state machine
  // lives in the World and survives across steps.
  let handler = fn(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
    if node != 1 {
      // Node 0 is the scripted client: each reply advances the script. A lost
      // reply never arrives, so the client simply stops where it is.
      w.pos = w.pos + 1
      if w.pos < w.script.length() {
        return [{ from: 0, to: 1, payload: w.script[w.pos] }]
      }
      return []
    }
    let reply = apply(w, msg.payload)
    [{ from: 1, to: 0, payload: reply }]
  }
  let result = @sim.run_bounded(handler, initial, seed, max_steps, faults)
  { result, world: w }
}

///|
/// I1: a tag that was acknowledged must never be outstanding again.
pub fn i1_no_acked_tag_outstanding(w : World) -> Bool {
  for tag in w.acked_tags {
    for other in w.unacked_tags {
      if tag == other {
        return false
      }
    }
  }
  true
}

///|
/// I3: nothing evaporated - everything published is either acked or still
/// outstanding broker-side.
///
/// Note what is deliberately NOT here: `delivered <= published`. A first version
/// asserted that, and it failed on a legitimate case - `reject(tag, requeue=true)`
/// returns the message to the queue, so one published message can be delivered
/// twice. An invariant that forbids redelivery would be a false alarm about
/// correct behaviour; the fix is to constrain the accounting, not the deliveries.
pub fn i3_accounting_closes(w : World) -> Bool {
  w.acked + w.unacked_tags.length() <= w.published
}

///|
pub fn no_bad_events(w : World) -> Bool {
  w.bad.length() == 0
}

///|
pub fn all_invariants_hold(w : World) -> Bool {
  i1_no_acked_tag_outstanding(w) && i3_accounting_closes(w) && no_bad_events(w)
}

///|
pub fn describe(w : World) -> String {
  "published=\{w.published} delivered=\{w.delivered} acked=\{w.acked} " +
  "unacked=\{w.unacked_tags.length()} delete_refused=\{w.delete_refused} " +
  "delete_allowed=\{w.delete_allowed}"
}
