// AMQP 1.0 scenario adapter (second target, D11).
//
// The subject is MoonAMQP1's real `Endpoint` pair: node 0 = application
// sender, node 1 = service receiver. Both are driven ONLY through their
// public bytes-in / bytes-out surface (`drain()` / `receive(bytes)` /
// `events()`), exactly how their own examples drive them - so this adapter
// adds no model, only a scheduler and fault injection.
//
// What makes this target worth the work (and different from the MQTT one):
// AMQP 1.0 carries NUMERIC state that must survive a network fault. Link
// credit is consumed by `send()` whether or not the transfer ever arrives,
// so a lost frame must leave the endpoint *accounted for*, not corrupted:
//
//     credit_before - sends == link_credit(now)
//
// That invariant is independent of delivery, which is precisely what makes
// it usable when the wire is broken. Their own examples already split bytes
// one at a time ("a host transport may split any byte boundary"), so
// fragmentation is covered by them; loss, delay, reorder and partition of
// the wire are not, which is this layer.

///|
pub struct Frame {
  bytes : Bytes
}

///|
pub(all) struct World {
  /// application side (acts as sender)
  app : @moonamqp1.Endpoint
  /// service side (acts as receiver)
  svc : @moonamqp1.Endpoint
  mut frames : Array[Frame]
  /// local handle of the sender link on `app`
  sender : UInt32
  /// every successful `send()` call = one credit consumed, delivered or not
  mut sends : Int32
  /// Accepted settlements observed back at the app
  mut settled : Int32
  /// messages the service actually received (delivered)
  mut received : Int32
  /// anything the endpoints rejected that a fault scenario should not
  /// provoke: a wire-protocol error is a finding, not a pass
  mut bad_events : Int32
}

///|
fn register(w : World, bytes : Bytes) -> Int32 {
  w.frames.push({ bytes, })
  w.frames.length() - 1
}

///|
/// Drain the app's event queue, counting settlements.
fn note_app_events(w : World) -> Unit {
  for e in w.app.events() {
    if e is @moonamqp1.Settled(_, _) {
      w.settled = w.settled + 1
    }
  }
}

///|
/// Service side: accept the bytes, acknowledge every delivery as Accepted
/// (the outcome their example uses), and return whatever it wants to say.
fn step_service(w : World, frame : Frame) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  let _ = try {
    w.svc.receive(frame.bytes)
    for e in w.svc.events() {
      if e is @moonamqp1.Received(delivery) {
        w.received = w.received + 1
        w.svc.acknowledge(delivery.id, @moonamqp1.Accepted)
      }
    }
    ()
  } catch {
    _ => w.bad_events = w.bad_events + 1
  }
  // drain() does not raise in this API
  let reply = w.svc.drain()
  if reply.length() > 0 {
    let slot = register(w, reply)
    out.push({ from: 1, to: 0, payload: slot, })
  }
  out
}

///|
/// Application side: receive service bytes, surface settlements.
fn step_app(w : World, frame : Frame) -> Array[@sim.Msg] {
  let _ = try {
    w.app.receive(frame.bytes)
    note_app_events(w)
  } catch {
    _ => w.bad_events = w.bad_events + 1
  }
  []
}

///|
pub fn make_handler(w : World) -> @sim.Handler {
  let box : Array[World] = [w]
  (node : Int32, msg : @sim.Msg) => {
    if node == 0 {
      step_app(box[0], box[0].frames[msg.payload])
    } else {
      step_service(box[0], box[0].frames[msg.payload])
    }
  }
}

///|
pub struct Scenario {
  result : @sim.RunResult
  world : World
}

///|
/// Fresh pair with the handshake completed SYNCHRONOUSLY (start / begin /
/// attach / grant), mirroring their examples/support. The handshake is a
/// fixed exchange - scheduling it would add flakiness without testing
/// anything new. The scheduled part is the message cycle, which is where
/// faults matter.
pub fn new_world(credit : UInt32) -> (World, Array[@sim.Msg]) raise {
  let limits : @moonamqp1.Limits = {
    ..@moonamqp1.Limits::default(),
    max_frame_bytes: 512,
  }
  let app = @moonamqp1.Endpoint::new(
    "application",
    channel=3,
    window=256U,
    limits~,
  )
  let svc = @moonamqp1.Endpoint::new(
    "service",
    channel=17,
    window=256U,
    limits~,
  )
  app.start()
  svc.receive(app.drain())
  app.receive(svc.drain())
  app.begin()
  svc.receive(app.drain())
  app.receive(svc.drain())
  ignore(app.events())
  ignore(svc.events())
  let sender = app.attach("jobs", true, "jobs/assets", handle=41U)
  svc.receive(app.drain())
  app.receive(svc.drain())
  let mut receiver : UInt32 = 0U
  for e in svc.events() {
    if e is @moonamqp1.LinkReady(handle, _, false) {
      receiver = handle
    }
  }
  svc.grant(receiver, credit)
  app.receive(svc.drain())
  ignore(app.events())
  let w = {
    app,
    svc,
    frames: [],
    sender,
    sends: 0,
    settled: 0,
    received: 0,
    bad_events: 0,
  }
  (w, [])
}

///|
/// Send one message from the app and spill its frames into the scheduler.
/// Called between runs (never from inside the handler), so the payload/tag
/// choice cannot drift a replay.
pub fn seed_send(w : World, payload : Bytes, tag : Bytes) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  let _ = try {
    let message = @moonamqp1.Message::data(payload)
    ignore(w.app.send(w.sender, message, tag))
    w.sends = w.sends + 1
    ()
  } catch {
    _ => w.bad_events = w.bad_events + 1
  }
  // drain() does not raise in this API
  let frames = w.app.drain()
  if frames.length() > 0 {
    let slot = register(w, frames)
    out.push({ from: 0, to: 1, payload: slot, })
  }
  out
}

///|
/// Run one message cycle under the given faults.
pub fn run_message_cycle(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
) -> Scenario raise {
  let (w, _empty) = new_world(1U)
  let initial = seed_send(w, b"payload-for-the-fault-run", b"tag-1")
  let result = @sim.run_bounded(
    make_handler(w),
    initial,
    seed,
    max_steps,
    faults,
  )
  { result, world: w, }
}

///|
/// Credit accounting is independent of delivery: every send spent one
/// credit whether or not the frame reached the peer.
pub fn credit_accounted(w : World, granted : Int32) -> Bool {
  let left = w.app.link_credit(w.sender).reinterpret_as_int() catch { _ => -1 }
  left == granted - w.sends
}

///|
pub fn no_bad_events(w : World) -> Bool {
  w.bad_events == 0
}
