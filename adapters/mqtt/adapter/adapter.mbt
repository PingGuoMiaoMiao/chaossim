// MQTT scenario adapter: runs REAL moon-mqtt ClientCores under the chaossim
// scheduler against one scripted broker. Node numbering: clients take even
// node ids (0, 2, 4, ...), the broker is node 1. One core per client; all
// handshake replies go through moon-mqtt's own encoders (D7: packet fields
// are read via decode_packet/IncomingPacket, never hand-picked offsets; the
// only hand-written frame is the constant CONNACK accept).
//
// Multi-client design notes (D9):
// - the scripted broker is STATELESS (echo the pid back as ack). That is
//   enough for the acking the library expects, and it keeps the
//   reconciliation invariant honest per client;
// - counters (issued / acks_delivered) are per client, bad_events is global;
// - partition/loss faults address the wire between one client and the
//   broker while the other client keeps flowing - the isolation equivalence
//   class this whole layer exists to observe.

///|
pub struct Frame {
  bytes : Array[Int32]
  /// control packet type from the fixed header's high nibble (spec-pinned
  /// position, not a variable-header offset)
  kind : Int32
}

///|
pub(all) struct World {
  cores : Array[@core.ClientCore]
  bfors : Array[@core.Framer]
  mut frames : Array[Frame]
  /// per-client: client-originated QoS>0 PUBLISH frames
  issued : Array[Int32]
  /// per-client: PUBACK/PUBCOMP frames actually delivered INTO that client
  acks_delivered : Array[Int32]
  /// events the scenario never expected (framer/malformed/unknown),
  /// global: a violation on any client is a finding
  mut bad_events : Int32
  /// the app's on-connack behavior, fixed before the run (never touched by
  /// the scheduler, so replays stay byte-identical)
  mut app_publishes : Int32
  mut app_qos : Int32
  /// per-client CONNECT count: a client's first CONNECT gets
  /// session_present=0, later ones session_present=1 (a resumed session,
  /// which is what the documented replay path expects). Per-client on
  /// purpose: a single global counter made session_present depend on which
  /// client the scheduler happened to deliver first (caught by the
  /// dual-client test).
  connects : Array[Int32]
  /// PUBLISH frames the client re-emitted via `replay_bytes()` (DUP=1)
  mut replays : Int32
  /// replayed frames that actually carried the DUP flag
  mut dups : Int32
  /// replayed PUBREL frames: a QoS2 delivery stuck in WaitPubcomp resumes by
  /// re-sending PUBREL, not by re-sending PUBLISH - a different branch of the
  /// documented replay path, worth its own counter so it cannot be confused
  /// with the QoS1 case
  mut replays_pubrel : Int32
}

///|
/// The broker's node id; clients live on 0, 2, 4, ...
pub let broker_node : Int32 = 1

///|
pub fn register(w : World, bytes : Array[Int32]) -> Int32 {
  let kind = (bytes[0] >> 4) & 0x0F
  w.frames.push({ bytes, kind, })
  w.frames.length() - 1
}

///|
fn client_idx(node : Int32) -> Int32 {
  node / 2
}

///|
/// Count a frame that just arrived at one client, before feeding it.
fn note_inbound(w : World, idx : Int32, kind : Int32) -> Unit {
  if kind == 4 || kind == 7 {
    w.acks_delivered[idx] = w.acks_delivered[idx] + 1
  }
}

///|
fn publish_once(
  w : World,
  idx : Int32,
  out : Array[@sim.Msg],
  tag : Int32,
) -> Unit {
  let qos = match @protocol.qos_from_int(w.app_qos) {
    Some(q) => q
    None => abort("app_qos out of range")
  }
  let pub_bytes = w.cores[idx].publish("device/accel", [0x01, tag], qos)
  if pub_bytes.length() > 0 {
    let slot = register(w, pub_bytes)
    match @protocol.decode_packet(pub_bytes) {
      Ok(@protocol.Publish(p)) =>
        if @protocol.qos_value(p.qos) > 0 {
          w.issued[idx] = w.issued[idx] + 1
        }
      _ => ()
    }
    out.push({ from: 2 * idx, to: broker_node, payload: slot, })
  }
}

///|
fn maybe_publish(w : World, idx : Int32, out : Array[@sim.Msg]) -> Unit {
  for i = 0; i < w.app_publishes; i = i + 1 {
    publish_once(w, idx, out, i)
  }
}

///|
/// The documented recovery move (their README §"持久会话恢复"): after a
/// reconnect that reports `session_present=1`, re-emit the in-flight
/// QoS1/2 frames with DUP set rather than publishing new work. This is the
/// behaviour our fault scenarios exist to check, so it is a first-class
/// mode rather than a comment.
fn replay_inflight(w : World, idx : Int32, out : Array[@sim.Msg]) -> Unit {
  for frame_bytes in w.cores[idx].replay_bytes() {
    let slot = register(w, frame_bytes)
    match @protocol.decode_packet(frame_bytes) {
      Ok(@protocol.Publish(p)) => {
        w.replays = w.replays + 1
        if p.dup {
          w.dups = w.dups + 1
        }
      }
      Ok(@protocol.Pubrel(_)) => w.replays_pubrel = w.replays_pubrel + 1
      _ => ()
    }
    out.push({ from: 2 * idx, to: broker_node, payload: slot, })
  }
}

///|
/// Dispatch a CONNACK: resumed sessions replay, fresh ones publish.
fn on_connack(
  w : World,
  idx : Int32,
  session_present : Bool,
  out : Array[@sim.Msg],
) -> Unit {
  if session_present {
    replay_inflight(w, idx, out)
  } else {
    maybe_publish(w, idx, out)
  }
}

///|
/// Client side of one scheduled delivery for client at `idx`.
fn to_client(w : World, idx : Int32, frame : Frame) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  note_inbound(w, idx, frame.kind)
  let (events, bytes_out) = w.cores[idx].feed(frame.bytes)
  for e in events {
    match e {
      @core.ConnackReceived(connack) =>
        on_connack(w, idx, connack.session_present, out)
      @core.PublishReceived(_) | @core.SubackReceived(_) => ()
      _ => w.bad_events = w.bad_events + 1
    }
  }
  if bytes_out.length() > 0 {
    match w.bfors[idx].feed(bytes_out) {
      Ok(fs) =>
        for f in fs {
          let slot = register(w, f)
          out.push({ from: 2 * idx, to: broker_node, payload: slot, })
        }
      Err(_) => w.bad_events = w.bad_events + 1
    }
  }
  out
}

///|
/// The ack (or nothing) the scripted broker owes for one client frame.
/// Unrecognized/garbage frames earn a bad_events increment and no reply.
fn broker_reply(w : World, from_node : Int32, frame : Frame) -> Array[Int32] {
  match frame.kind {
    1 => {
      // per-client CONNECT count: the first is a fresh session, later ones
      // resume. MQTT 3.1.1 CONNACK = 0x20, remaining length 2, ack flags,
      // return code; bit 0 of the ack flags is session_present.
      let idx = client_idx(from_node)
      if idx >= 0 && idx < w.connects.length() {
        w.connects[idx] = w.connects[idx] + 1
        if w.connects[idx] == 1 {
          [0x20, 0x02, 0x00, 0x00]
        } else {
          [0x20, 0x02, 0x01, 0x00]
        }
      } else {
        [0x20, 0x02, 0x00, 0x00]
      }
    }
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
/// The reply is addressed to the SENDER of the message (not a fixed
/// client) - the single-client tests could not catch that mistake, the
/// dual-client ones can.
fn to_broker(w : World, msg : @sim.Msg, frame : Frame) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  let reply = broker_reply(w, msg.from, frame)
  if reply.length() > 0 {
    let slot = register(w, reply)
    out.push({ from: broker_node, to: msg.from, payload: slot, })
  }
  out
}

///|
/// Build the scenario handler over a world box (array-of-one for mutation).
pub fn make_handler(w : World) -> @sim.Handler {
  let box : Array[World] = [w]
  (node : Int32, msg : @sim.Msg) => {
    if node == broker_node {
      to_broker(box[0], msg, box[0].frames[msg.payload])
    } else if node % 2 == 0 && client_idx(node) < box[0].cores.length() {
      to_client(box[0], client_idx(node), box[0].frames[msg.payload])
    } else {
      box[0].bad_events = box[0].bad_events + 1
      []
    }
  }
}

///|
pub struct Scenario {
  result : @sim.RunResult
  world : World
  /// phase-A transcript for the two-phase recovery runner; for one-phase
  /// runners this is a copy of `result` so callers never special-case it
  phase_a : @sim.RunResult
  /// acks delivered to client 0 at the END of phase A. The World is shared
  /// and mutable, so phase B overwrites the live counter - without this
  /// snapshot the "phase A left the message unsettled" claim would be
  /// unobservable after the fact.
  phase_a_acks : Int32
}

///|
/// Seed a world with `clients` fresh cores; each emits its own CONNECT.
pub fn new_world(clients : Int32) -> (World, Array[@sim.Msg]) {
  let cores : Array[@core.ClientCore] = []
  let bfors : Array[@core.Framer] = []
  let issued : Array[Int32] = []
  let acks : Array[Int32] = []
  let connect_counts : Array[Int32] = []
  let initial : Array[@sim.Msg] = []
  for i = 0; i < clients; i = i + 1 {
    let client_id = "chaossim-mqtt-" + i.to_string()
    cores.push(@core.ClientCore::new(@protocol.ConnectPacket::new(client_id)))
    bfors.push(@core.Framer::new())
    issued.push(0)
    acks.push(0)
    connect_counts.push(0)
  }
  let w = {
    cores,
    bfors,
    frames: [],
    issued,
    acks_delivered: acks,
    bad_events: 0,
    app_publishes: 1,
    app_qos: 1,
    connects: connect_counts,
    replays: 0,
    dups: 0,
    replays_pubrel: 0,
  }
  for i = 0; i < clients; i = i + 1 {
    let connect_slot = register(w, w.cores[i].start())
    initial.push({ from: 2 * i, to: broker_node, payload: connect_slot, })
  }
  (w, initial)
}

///|
/// The full-parameters runner. `qos` selects the app publish level (1 or
/// 2); `count` how many messages each client publishes on its CONNACK;
/// `clients` how many independent ClientCores share the broker lane.
pub fn run_multi(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
  qos : Int32,
  count : Int32,
  clients : Int32,
) -> Scenario raise @sim.SimError {
  let (w, initial) = new_world(clients)
  w.app_qos = qos
  w.app_publishes = count
  let result = @sim.run_bounded(
    make_handler(w),
    initial,
    seed,
    max_steps,
    faults,
  )
  { result, world: w, phase_a: result, phase_a_acks: acks_of(w, 0), }
}

///|
/// Single-client conveniences (the historical default: QoS1, one publish).
pub fn run_scenario(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
) -> Scenario raise @sim.SimError {
  run_scenario_ex(seed, max_steps, faults, 1, 1)
}

///|
pub fn run_scenario_ex(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
  qos : Int32,
  count : Int32,
) -> Scenario raise @sim.SimError {
  run_multi(seed, max_steps, faults, qos, count, 1)
}

///|
/// Phase A -> Phase B recovery scenario (D12).
///
/// A fault is injected in phase A so the client is left with an unsettled
/// in-flight message; phase B then does exactly what their README documents
/// for a dropped connection: `on_transport_close()` + `reconnect_bytes()`,
/// and on the resumed CONNACK (session_present=1) `replay_bytes()`.
///
/// The World persists across the two `run_bounded` calls, which is the
/// point: the fault's aftermath has to survive into the recovery run for
/// this to test anything. Both phases are separately seeded and separately
/// recorded, so a failure tells you which phase broke.
pub fn run_recovery(
  seed : Int32,
  max_steps : Int32,
  phase_a_faults : Array[@sim.Fault],
) -> Scenario raise @sim.SimError {
  run_recovery_ex(seed, max_steps, phase_a_faults, 1)
}

///|
/// Same two-phase recovery, with the app's publish QoS selectable. QoS2 is a
/// genuinely different recovery branch: a delivery stuck in WaitPubcomp
/// resumes by re-sending PUBREL, so the assertion is `replays_pubrel == 1`
/// and `replays == 0` - the opposite of the QoS1 case.
pub fn run_recovery_ex(
  seed : Int32,
  max_steps : Int32,
  phase_a_faults : Array[@sim.Fault],
  qos : Int32,
) -> Scenario raise @sim.SimError {
  let (w, initial_a) = new_world(1)
  w.app_qos = qos
  let phase_a_initial : Array[@sim.Msg] = []
  for m in initial_a {
    phase_a_initial.push(m)
  }
  for m in seed_publish(w, 0, 0) {
    phase_a_initial.push(m)
  }
  let tx_a = @sim.run_bounded(
    make_handler(w),
    phase_a_initial,
    seed,
    max_steps,
    phase_a_faults,
  )
  let acks_after_a = acks_of(w, 0)
  // transport died; the client notices and reconnects
  w.cores[0].on_transport_close()
  let connect_slot = register(w, w.cores[0].reconnect_bytes())
  let initial_b : Array[@sim.Msg] = [
    { from: 0, to: broker_node, payload: connect_slot, },
  ]
  let tx_b = @sim.run_bounded(make_handler(w), initial_b, seed + 1, max_steps, [])
  // report phase B as the scenario trace; phase A is available via
  // `phase_a` for assertions that care about where the fault landed
  { result: tx_b, world: w, phase_a: tx_a, phase_a_acks: acks_after_a, }
}

///|
/// One publish, spilled as scheduled messages (used by the recovery setup).
pub fn seed_publish(w : World, idx : Int32, tag : Int32) -> Array[@sim.Msg] {
  let out : Array[@sim.Msg] = []
  publish_once(w, idx, out, tag)
  out
}

///|
/// CONNECT count seen from one client (1 = fresh, 2+ = resumed).
pub fn connects_of(w : World, node : Int32) -> Int32 {
  w.connects[client_idx(node)]
}

///|
/// Per-client accessors; `node` is the even client id.
pub fn issued_of(w : World, node : Int32) -> Int32 {
  w.issued[client_idx(node)]
}

///|
pub fn acks_of(w : World, node : Int32) -> Int32 {
  w.acks_delivered[client_idx(node)]
}

///|
pub fn inflight(w : World, node : Int32) -> Int32 {
  w.cores[client_idx(node)].session().inflight_count()
}

///|
/// End-to-end consistency per client: what it believes is in flight equals
/// what it issued minus what the network actually delivered to it.
pub fn inflight_matches(w : World, node : Int32) -> Bool {
  inflight(w, node) == issued_of(w, node) - acks_of(w, node)
}

///|
/// Nothing unexpected ever reached any client's event stream.
pub fn no_bad_events(w : World) -> Bool {
  w.bad_events == 0
}

///|
/// Every client's conversation has fully drained (inflight 0).
pub fn all_drained(w : World) -> Bool {
  for i = 0; i < w.cores.length(); i = i + 1 {
    if w.cores[i].session().inflight_count() != 0 {
      return false
    }
  }
  true
}
