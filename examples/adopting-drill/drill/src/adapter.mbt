// Step 1 + 2 + 3 of docs/adopting.md, applied to the toy library above.
// This file is the whole of the integration: no change to toy.mbt.

///|
pub(all) struct World {
  core : Toy
  mut frames : Array[Int32]
  mut issued : Int32
  mut acks : Int32
  mut bad_events : Int32
}

///|
fn register(w : World, id : Int32) -> Int32 {
  w.frames.push(id)
  w.frames.length() - 1
}

///|
/// The app's move: send one request (the id is the frame's payload slot).
fn seed_request(w : World, id : Int32) -> Array[@sim.Msg] {
  let rid = w.core.request(id)
  w.issued = w.issued + 1
  let slot = register(w, rid)
  [{ from: 0, to: 1, payload: slot, }]
}

///|
/// Node 1 = a STATELESS peer: echo an ACK for whatever id it just received.
/// (Guide's rule: no session table, otherwise you are testing your own peer.)
fn step_peer(w : World, frame : Int32) -> Array[@sim.Msg] {
  let slot = register(w, frame)
  [{ from: 1, to: 0, payload: slot, }]
}

///|
/// Wiring: an inbound frame reaches the client and the library consumes it.
fn deliver_to_client(w : World, msg : @sim.Msg) -> Unit {
  let id = w.frames[msg.payload]
  if w.core.on_ack(id) {
    w.acks = w.acks + 1
  } else {
    w.bad_events = w.bad_events + 1
  }
}

///|
pub fn make_handler(w : World) -> @sim.Handler {
  let box : Array[World] = [w]
  (node, msg) => {
    if node == 0 {
      deliver_to_client(box[0], msg)
      []
    } else {
      step_peer(box[0], box[0].frames[msg.payload])
    }
  }
}

///|
pub struct Scenario {
  result : @sim.RunResult
  world : World
}

///|
pub fn new_world() -> World {
  { core: Toy::new(), frames: [], issued: 0, acks: 0, bad_events: 0, }
}

///|
pub fn run(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
) -> Scenario raise @sim.SimError {
  let w = new_world()
  let initial = seed_request(w, 7)
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
/// The delivery-independent invariant from the guide.
pub fn in_flight_matches(w : World) -> Bool {
  w.core.in_flight.length() == w.issued - w.acks
}

///|
pub fn no_bad_events(w : World) -> Bool {
  w.bad_events == 0
}
