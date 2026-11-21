// Audit of the RESP2/RESP3 codec in moonbitstack/moonredis.
//
// A different kind of target from the earlier ones: not a state machine driven by
// messages, but a PURE CODEC. A codec has properties that must hold for every input,
// which is exactly what a generator plus a property check can attack:
//
//     decode(encode(v)) == v                       (round-trip)
//     decode(garbage) errors, never panics, never hangs
//
// PROVENANCE: target is moonbitstack/moonredis (Apache-2.0); no code copied, only
// the public API is called.

///|
pub(all) struct Case {
  name : String
  ok : Bool
  detail : String
}

///|
fn ok(name : String, detail : String) -> Case {
  { name, ok: true, detail }
}

///|
fn risk(name : String, detail : String) -> Case {
  { name, ok: false, detail }
}

///|
pub fn describe(c : Case) -> String {
  let mark = if c.ok {
    "PASS"
  } else {
    "RISK"
  }
  "\{mark}  \{c.name}: \{c.detail}"
}

///|
/// Deterministic byte noise. Local on purpose: the audit must not reach into the
/// library, and a fixed seed makes every finding reproducible.
fn noise(seed : Int32, len : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut state = seed * 265443576 + 1
  let mut i = 0
  while i < len {
    state = state ^ (state << 13)
    state = state ^ (state >> 17)
    state = state ^ (state << 5)
    out.push(((state >> 24) & 0xFF).to_byte())
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
/// encode then decode must reproduce the value.
pub fn check_round_trip() -> Case {
  let samples : Array[@resp.RespValue] = [
    @resp.RespValue::SimpleString("OK"),
    @resp.RespValue::Error("ERR bad"),
    @resp.RespValue::Integer(42L),
    @resp.RespValue::BulkString(b"hello"),
    @resp.RespValue::Null,
    @resp.RespValue::Boolean(true),
    @resp.RespValue::Double(1.5),
    @resp.RespValue::Array([@resp.RespValue::Integer(1L), @resp.RespValue::Null]),
    @resp.RespValue::RespMap([
      (@resp.RespValue::SimpleString("k"), @resp.RespValue::Integer(7L)),
    ]),
  ]
  let bad : Array[String] = []
  let mut count = 0
  for v in samples {
    count = count + 1
    let encoded = v.encode()
    let back = @resp.RespValue::decode(encoded) catch {
      _ => {
        bad.push("failed to decode its own encoding")
        continue
      }
    }
    if !back.equal(v) {
      bad.push("round-trip mismatch")
    }
  }
  if bad.length() > 0 {
    risk("round-trip", bad[0])
  } else {
    ok("round-trip", "\{count} shapes encode and decode back identically")
  }
}

///|
/// Truncation: every proper prefix of a valid frame must be rejected.
pub fn check_truncation_rejected() -> Case {
  let frame = @resp.RespValue::Array([
    @resp.RespValue::BulkString(b"a"),
    @resp.RespValue::BulkString(b"bc"),
  ])
  let bytes = frame.encode()
  let accepted : Array[String] = []
  let mut cut = 0
  while cut < bytes.length() {
    let prefix : Bytes = Bytes::from_array(bytes[:cut].to_array())
    let _ = @resp.RespValue::decode(prefix) catch {
      _ => {
        cut = cut + 1
        continue
      }
    }
    accepted.push(cut.to_string())
    cut = cut + 1
  }
  if accepted.length() > 0 {
    risk(
      "truncation rejected",
      "some prefixes of a short frame decoded as complete",
    )
  } else {
    ok("truncation rejected", "all \{bytes.length()} prefixes rejected")
  }
}

///|
/// Garbage must be rejected, not crash. Accepting random noise is legal only if the
/// bytes form a valid frame, so the acceptance count is reported as a fact.
pub fn check_garbage() -> Case {
  let mut accepted = 0
  let mut i = 1
  while i <= 200 {
    let junk = noise(i, 1 + (i % 24))
    let _ = @resp.RespValue::decode(junk) catch {
      _ => {
        i = i + 1
        continue
      }
    }
    accepted = accepted + 1
    i = i + 1
  }
  ok(
    "garbage",
    "200 random inputs: \{accepted} parsed as a valid frame, none crashed",
  )
}

///|
/// Garbage appended to a complete frame. A strict reader rejects; a lenient one
/// ignores it. Both are defensible, so this records which behaviour this library has.
pub fn check_trailing() -> Case {
  let frame = @resp.RespValue::SimpleString("OK")
  let bytes = frame.encode()
  let padded : Array[Byte] = []
  for b in bytes {
    padded.push(b)
  }
  padded.push(88)
  let v = @resp.RespValue::decode(Bytes::from_array(padded)) catch {
    _ => return ok("trailing bytes", "rejected")
  }
  if v.equal(frame) {
    ok("trailing bytes", "ignored, frame decodes to the same value")
  } else {
    risk("trailing bytes", "trailing garbage changed the decoded value")
  }
}

///|
/// Deep nesting must not blow the stack.
pub fn check_deep_nesting() -> Case {
  let depth = 200
  let payload : Array[Byte] = []
  let mut i = 0
  while i < depth {
    payload.push(42)
    payload.push(49)
    payload.push(13)
    payload.push(10)
    i = i + 1
  }
  payload.push(36)
  payload.push(49)
  payload.push(13)
  payload.push(10)
  payload.push(120)
  payload.push(13)
  payload.push(10)
  let _ = @resp.RespValue::decode(Bytes::from_array(payload)) catch {
    _ => return ok("deep nesting", "depth \{depth} rejected cleanly")
  }
  ok("deep nesting", "depth \{depth} decoded without crashing")
}

///|
pub fn battery() -> Array[Case] {
  let out : Array[Case] = []
  out.push(check_round_trip())
  out.push(check_truncation_rejected())
  out.push(check_garbage())
  out.push(check_trailing())
  out.push(check_deep_nesting())
  out
}
