// Ordering sweep: two concurrent clients against one real broker.
//
// The probes in audit_wbtest/audit2_wbtest are deterministic: they call the API in
// a fixed order. Ordering effects need interleavings, which is what chaossim is
// for. Both clients pull from the same queue and ack what they get; the seed
// decides whose operation reaches the broker first, and faults decide what gets
// lost on the way back.
//
// Invariants checked on every edge:
//   V1 a tag handed to one client is never handed to the other (no duplicate
//      delivery of the same message)
//   V2 a client never acks a tag it was not given (no cross-client ack)
//   V3 acked + outstanding <= published
//
// A violation here is a genuine concurrency defect: the API's own tests cannot
// reach these interleavings.

///|
pub(all) struct SweepWorld {
  broker : @broker.Broker
  queue : String
  /// per client: tags it currently holds
  mut held : Array[Array[UInt64]]
  /// per client: how many ops it has completed
  mut done : Array[Int32]
  mut script : Array[Int32]
  mut violations : Array[String]
  mut delivered : Int32
  mut acked : Int32
  mut published : Int32
}

///|
fn vnote(w : SweepWorld, msg : String) -> Unit {
  if w.violations.length() < 8 {
    w.violations.push(msg)
  }
}

///|
fn has(tags : Array[UInt64], tag : UInt64) -> Bool {
  for t in tags {
    if t == tag {
      return true
    }
  }
  false
}

///|
fn drop_tag(tags : Array[UInt64], tag : UInt64) -> Array[UInt64] {
  let out : Array[UInt64] = []
  for t in tags {
    if t != tag {
      out.push(t)
    }
  }
  out
}

///|
/// client index for a node id: 0 -> 0, 2 -> 1
fn client_of(node : Int32) -> Int32 {
  node / 2
}

///|
fn node_of(client : Int32) -> Int32 {
  client * 2
}

///|
pub fn sweep(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
  count : Int32,
  rounds : Int32,
  kind : Int32,
) -> SweepWorld raise @sim.SimError {
  let b = @broker.Broker::new()
  let q = match b.declare_queue("sweep.q") {
    Ok(q) => q
    Err(_) => "sweep.q"
  }
  let w : SweepWorld = {
    broker: b,
    queue: q,
    held: [[], []],
    done: [0, 0],
    script: [],
    violations: [],
    delivered: 0,
    acked: 0,
    published: 0,
  }
  // get/ack pairs per round
  let s : Array[Int32] = []
  for _i = 0; _i < rounds; _i = _i + 1 {
    s.push(op_get)
    if kind == 1 {
      s.push(op_reject)
    }
    s.push(op_ack)
  }
  w.script = s
  for i = 0; i < count; i = i + 1 {
    let n = match b.publish("", q, @encoding/utf8.encode("m\{i}")) {
      Ok(n) => n
      Err(_) => 0
    }
    w.published = w.published + n
  }
  // Both clients start immediately: whose get reaches the broker first is the
  // seed's decision.
  let initial : Array[@sim.Msg] = [
    { from: 0, to: 1, payload: op_get, },
    { from: 2, to: 1, payload: op_get, },
  ]
  let handler = fn(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
    if node != 1 {
      // a client: a reply advances its own script
      let c = client_of(node)
      w.done[c] = w.done[c] + 1
      let next = w.done[c]
      if next < w.script.length() {
        return [{ from: node, to: 1, payload: w.script[next] }]
      }
      return []
    }
    let c = client_of(msg.from)
    if msg.payload == op_get {
      match w.broker.get(w.queue) {
        Ok(Some(d)) => {
          let tag = d.tag()
          w.delivered = w.delivered + 1
          // V1: the same tag must not already be held by the other client
          let other = 1 - c
          if has(w.held[other], tag) {
            vnote(
              w,
              "V1: tag \{tag} handed to client \{c} while client \{other} holds it",
            )
          }
          if has(w.held[c], tag) {
            vnote(w, "V1: client \{c} was handed tag \{tag} twice")
          }
          w.held[c].push(tag)
          [{ from: 1, to: node_of(c), payload: reply_ok, }]
        }
        _ => [{ from: 1, to: node_of(c), payload: reply_none, }]
      }
    } else if msg.payload == op_reject {
      let mine = w.held[c]
      if mine.length() == 0 {
        [{ from: 1, to: node_of(c), payload: reply_error, }]
      } else {
        let tag = mine[0]
        match w.broker.reject(tag, true) {
          Ok(_) => {
            w.held[c] = drop_tag(w.held[c], tag)
            [{ from: 1, to: node_of(c), payload: reply_ok, }]
          }
          Err(_) => [{ from: 1, to: node_of(c), payload: reply_error, }]
        }
      }
    } else if msg.payload == op_ack {
      let mine = w.held[c]
      if mine.length() == 0 {
        [{ from: 1, to: node_of(c), payload: reply_error, }]
      } else {
        let tag = mine[0]
        // V2: only a tag this client holds may be acked
        if !has(mine, tag) {
          vnote(w, "V2: client \{c} acked tag \{tag} it does not hold")
        }
        match w.broker.ack(tag) {
          Ok(_) => {
            w.held[c] = drop_tag(w.held[c], tag)
            w.acked = w.acked + 1
            [{ from: 1, to: node_of(c), payload: reply_ok, }]
          }
          Err(_) => [{ from: 1, to: node_of(c), payload: reply_error, }]
        }
      }
    } else {
      [{ from: 1, to: node_of(c), payload: reply_error, }]
    }
  }
  let _res = @sim.run_bounded(handler, initial, seed, max_steps, faults)
  // V3
  if w.acked + w.held[0].length() + w.held[1].length() > w.published {
    vnote(
      w,
      "V3: acked \{w.acked} + outstanding \{w.held[0].length() + w.held[1].length()} > published \{w.published}",
    )
  }
  w
}

///|
pub fn violations_of(w : SweepWorld) -> Array[String] {
  w.violations
}
