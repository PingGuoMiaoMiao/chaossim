// MQTT scenario adapter: runs moon-mqtt's REAL ClientCore as node 0 under
// the chaossim scheduler, against a scripted broker (node 1) that only ever
// replies through moon-mqtt's own encoders. D7 is the ground rule: packet
// fields are read via `decode_packet`/`IncomingPacket`, never hand-picked
// offsets; the only hand-written frame is the constant CONNACK accept (the
// client library ships no server-side CONNACK encoder, and that 4-byte form
// carries no variable header to mis-parse).
//
// Node model
//   0 = client (ClientCore; `feed` in, events+bytes out; app behavior:
//       publish one QoS1 message on CONNACK, mirroring their on_connack usage)
//   1 = scripted broker (frames in via its own Framer, ack frames out)
// A wire message's `payload` field is a slot id into the scenario's frame
// registry; slots are append-only and registered in deterministic order,
// so replay equality holds transitively through the indirection.

///|
pub struct Frame {
  bytes : Array[Int32]
  /// control packet type from the fixed header's high nibble (spec-pinned
  /// position, not a variable-header offset)
  kind : Int32
}

///|
pub(all) struct World {
  core : @core.ClientCore
  bfr : @core.Framer
  mut frames : Array[Frame]
  /// client-originated QoS>0 PUBLISH frames
  mut issued : Int32
  /// PUBACK/PUBCOMP frames actually delivered INTO the client
  mut acks_delivered : Int32
  /// events the scenario never expected (framer/malformed/unknown) —
  /// the library should never produce these in a scripted flow
  mut bad_events : Int32
  /// the app's on-connack behavior: how many publishes at which QoS level.
  /// Fixed before the run (never touched by the scheduler), so replays
  /// stay byte-identical.
  mut app_publishes : Int32
  mut app_qos : Int32
}

///|
pub fn register(w : World, bytes : Array[Int32]) -> Int32 {
  let kind = (bytes[0] >> 4) & 0x0F
  w.frames.push({ bytes, kind, })
  w.frames.length() - 1
}

///|
/// Count a frame that just arrived at the client, before feeding it.
fn note_inbound(w : World, kind : Int32) -> Unit {
  if kind == 4 || kind == 7 {
    w.acks_delivered = w.acks_delivered + 1
  }
}

///|
/// The app-on-connack move: when the client just got CONNACK, publish
/// `app_publishes` frames at `app_qos` — what their browser glue does in
/// `on_connack` demos, just parameterized. More than one publish means the
/// handshake frames of several QoS2 conversations interleave in the queue
/// and the scheduler's pick order becomes the reorder test.
fn publish_once(w : World, out : Array[@sim.Msg], tag : Int32) -> Unit {
  let qos = match @protocol.qos_from_int(w.app_qos) {
    Some(q) => q
    None => abort("app_qos out of range")
  }
  let pub_bytes = w.core.publish("device/accel", [0x01, tag], qos)
  if pub_bytes.length() > 0 {
    let slot = register(w, pub_bytes)
    match @protocol.decode_packet(pub_bytes) {
      Ok(@protocol.Publish(p)) =>
        if @protocol.qos_value(p.qos) > 0 {
          w.issued = w.issued + 1
        }
      _ => ()
    }
    out.push({ from: 0, to: 1, payload: slot, })
  }
}

///|
fn maybe_publish(w : World, out : Array[@sim.Msg]) -> Unit {
  for i = 0; i < w.app_publishes; i = i + 1 {
    publish_once(w, out, i)
  }
}

///|
/// Client side of one scheduled delivery: feed, split the reply stream with
/// the broker's own Framer, schedule every produced frame toward node 1.
fn to_client(w : World, frame : Frame) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  note_inbound(w, frame.kind)
  let (events, bytes_out) = w.core.feed(frame.bytes)
  for e in events {
    match e {
      @core.ConnackReceived(_) => maybe_publish(w, out)
      @core.PublishReceived(_) | @core.SubackReceived(_) => ()
      _ => w.bad_events = w.bad_events + 1
    }
  }
  if bytes_out.length() > 0 {
    match w.bfr.feed(bytes_out) {
      Ok(fs) =>
        for f in fs {
          let slot = register(w, f)
          out.push({ from: 0, to: 1, payload: slot, })
        }
      Err(_) => w.bad_events = w.bad_events + 1
    }
  }
  out
}

///|
/// The ack (or nothing) the scripted broker owes for one client frame.
/// Everything is built with moon-mqtt's own encoders; only the constant
/// CONNACK is hand-written (no server-side encoder exists, no pid to mis-
/// parse). Unrecognized/garbage frames earn a bad_events increment and no
/// reply — that is the "broker never answers garbage" invariant.
fn broker_reply(w : World, frame : Frame) -> Array[Int32] {
  match frame.kind {
    1 => [0x20, 0x02, 0x00, 0x00]
    3 =>
      match @protocol.decode_packet(frame.bytes) {
        Ok(@protocol.Publish(p)) =>
          match p.qos {
            @protocol.QoS::AtLeastOnce => @protocol.encode_puback(p.packet_id)
            @protocol.QoS::ExactlyOnce => @protocol.encode_pubrec(p.packet_id)
            @protocol.QoS::AtMostOnce => []
          }
        Ok(_) => {
          w.bad_events = w.bad_events + 1
          []
        }
        Err(_) => {
          w.bad_events = w.bad_events + 1
          []
        }
      }
    6 =>
      match @protocol.decode_packet(frame.bytes) {
        Ok(@protocol.Pubrel(pid)) => @protocol.encode_pubcomp(pid)
        Ok(_) => {
          w.bad_events = w.bad_events + 1
          []
        }
        Err(_) => {
          w.bad_events = w.bad_events + 1
          []
        }
      }
    12 => @protocol.encode_pingresp()
    14 => []
    _ => {
      w.bad_events = w.bad_events + 1
      []
    }
  }
}

///|
/// Broker side: one scheduled delivery in, at most one reply frame out.
fn to_broker(w : World, frame : Frame) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  let reply = broker_reply(w, frame)
  if reply.length() > 0 {
    let slot = register(w, reply)
    out.push({ from: 1, to: 0, payload: slot, })
  }
  out
}

///|
/// Build the scenario handler over a world box (array-of-one for mutation).
pub fn make_handler(w : World) -> @sim.Handler {
  let box : Array[World] = [w]
  (node : Int32, msg : @sim.Msg) => {
    if node == 0 {
      to_client(box[0], box[0].frames[msg.payload])
    } else {
      to_broker(box[0], box[0].frames[msg.payload])
    }
  }
}

///|
pub struct Scenario {
  result : @sim.RunResult
  world : World
}

///|
/// Seed the world: fresh core, CONNECT already emitted from start().
pub fn new_world() -> (World, Array[@sim.Msg]) {
  let w = {
    core: @core.ClientCore::new(@protocol.ConnectPacket::new("chaossim-mqtt")),
    bfr: @core.Framer::new(),
    frames: [],
    issued: 0,
    acks_delivered: 0,
    bad_events: 0,
    app_publishes: 1,
    app_qos: 1,
  }
  let connect_slot = register(w, w.core.start())
  (w, [{ from: 0, to: 1, payload: connect_slot, }])
}

///|
/// Run one scenario under the scheduler with the given faults (QoS1, one
/// publish — the historical default).
pub fn run_scenario(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
) -> Scenario raise @sim.SimError {
  run_scenario_ex(seed, max_steps, faults, 1, 1)
}

///|
/// The QoS2 / multi-publish variant. `qos` selects the app publish level
/// (1 or 2); `count > 1` puts several handshakes in flight at once so
/// delivery interleaving is tested by the seeded scheduler order.
pub fn run_scenario_ex(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
  qos : Int32,
  count : Int32,
) -> Scenario raise @sim.SimError {
  let (w, initial) = new_world()
  w.app_qos = qos
  w.app_publishes = count
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
/// End-to-end consistency: what the client believes is in flight equals
/// what it issued minus what the network actually delivered to it.
/// Any drift is either a scheduler accounting bug or a library bug, and
/// either way this predicate localizes it.
pub fn inflight_matches(w : World) -> Bool {
  w.core.session().inflight_count() == w.issued - w.acks_delivered
}

///|
/// Nothing unexpected ever reached the event stream.
pub fn no_bad_events(w : World) -> Bool {
  w.bad_events == 0
}
