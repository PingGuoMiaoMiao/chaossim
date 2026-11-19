// W2 seam spike (decisions D6/D7 in docs/decisions.md).
//
// Question this spike answers: can an EXTERNAL harness drive moon-mqtt's
// pure ClientCore — CONNECT/CONNACK, outbound QoS1 publish + PUBACK
// clearing, inbound QoS1 publish + auto-ack — using nothing but bytes in /
// events+bytes out? If yes, those in-flight packets are chaossim messages,
// and loss/delay/reorder become schedulable faults instead of luck.
//
// This spike does NOT inject faults yet; it establishes the seam and maps
// every wire packet through the sim.Msg codec as a fitness probe.

///|
fn packet_kind(frame_start : Int32) -> Int32 {
  (frame_start >> 4) & 0x0F
}

///|
fn pid_of(frame : Array[Int32]) -> Int32 {
  // PUBLISH: variable header is topic-first (2-byte topic length, topic
  // bytes), then the packet id when QoS > 0. Other kinds (PUBACK/...) carry
  // the pid immediately after the 1-byte remaining-length. Small frames only,
  // so the remaining-length varint is one byte here.
  let k = packet_kind(frame[0])
  if k == 3 {
    let topic_len = frame[2] * 256 + frame[3]
    frame[4 + topic_len] * 256 + frame[5 + topic_len]
  } else {
    frame[2] * 256 + frame[3]
  }
}

///|
fn expect(desc : String, ok : Bool) -> Unit {
  if ok {
    println("[ok]   " + desc)
  } else {
    println("[FAIL] " + desc)
    abort(desc)
  }
}

///|
fn main {
  let qos1 = match @protocol.qos_from_int(1) {
    Some(q) => q
    _ => abort("qos_from_int(1)")
  }

  let core = @core.ClientCore::new(
    @protocol.ConnectPacket::new("chaossim-seam"),
  )

  // 1) CONNECT must come out of start()
  let connect_bytes = core.start()
  expect(
    "start() emits CONNECT (kind 1)",
    connect_bytes.length() > 0 && packet_kind(connect_bytes[0]) == 1,
  )

  // 2) broker accepts: CONNACK in, ConnackReceived out
  let connack : Array[Int32] = [0x20, 0x02, 0x00, 0x00]
  let (events, _out0) = core.feed(connack)
  let accepted = match events.length() {
    0 => false
    _ =>
      match events[0] {
        @core.ConnackReceived(_) => true
        _ => false
      }
  }
  expect("CONNACK surfaces as ConnackReceived", accepted)

  // 3) outbound QoS1 publish only flows after CONNACK (§3.1.4 gate), then
  //    PUBACK must clear the in-flight slot
  let pub_bytes = core.publish("device/accel", [0x01, 0x02], qos1)
  expect(
    "publish() after CONNACK emits PUBLISH (kind 3)",
    pub_bytes.length() > 0 && packet_kind(pub_bytes[0]) == 3,
  )
  let pid = pid_of(pub_bytes)
  let puback : Array[Int32] = [0x40, 0x02, pid / 256, pid % 256]
  println(
    "[probe] inflight before PUBACK = " +
    core.session().inflight_count().to_string(),
  )
  println("[probe] sending PUBACK for pid=" + pid.to_string())
  let (ev3, _o3) = core.feed(puback)
  // CoreEvent deliberately derives neither Show nor Eq (their source comment),
  // so name the events through an exhaustive match instead of to_string.
  let ev_names : Array[String] = []
  for e in ev3 {
    ev_names.push(
      match e {
        @core.ConnackReceived(_) => "Connack"
        @core.PublishReceived(_) => "Publish"
        @core.SubackReceived(_) => "Suback"
        @core.PingRespReceived => "PingResp"
        @core.UnknownPacketType(t) => "Unknown(" + t.to_string() + ")"
        @core.MalformedFrame(t, _) => "Malformed(" + t.to_string() + ")"
        @core.FramerError(_) => "Framer"
      },
    )
  }
  let mut joined = ""
  for s in ev_names {
    joined = joined + s + " "
  }
  println("[probe] events after PUBACK: [" + joined + "]")
  expect(
    "PUBACK (pid " + pid.to_string() + ") clears the in-flight slot",
    core.session().inflight_count() == 0,
  )

  // 4) inbound QoS1 publish surfaces as PublishReceived and auto-acks
  let pkt = @protocol.PublishPacket::new(
    "sensors/t",
    [0x61],
    qos1,
    false,
    false,
    5,
  )
  let inbound = @protocol.encode_publish(pkt)
  let (ev2, out2) = core.feed(inbound)
  let saw_publish = match ev2[0] {
    @core.PublishReceived(_) => true
    _ => false
  }
  expect("inbound PUBLISH surfaces as PublishReceived", saw_publish)
  expect(
    "core auto-acks inbound QoS1 with PUBACK (kind 4)",
    out2.length() == 4 && packet_kind(out2[0]) == 4,
  )

  // 5) fitness probe: every exchanged packet maps into chaossim's Msg codec
  //    (kind * 100000 + pid as the payload code — the real adapter will use
  //    structured payloads; this only proves the encode is injective enough
  //    for scheduling decisions)
  let wire : Array[@sim.Msg] = []
  for frame in [connect_bytes, connack, pub_bytes, puback, inbound] {
    let k = packet_kind(frame[0])
    let id = if k == 3 || k == 4 { pid_of(frame) } else { 0 }
    wire.push({ from: 0, to: 1, payload: k * 100000 + id, })
  }
  expect("5 wire packets map into sim.Msg slots", wire.length() == 5)
  expect(
    "codes stay distinct per kind+pid",
    wire[2].payload != wire[3].payload && wire[0].payload == 100000,
  )

  println("SEAM HOLDS: ClientCore drivable externally; wire fits sim.Msg.")
}
