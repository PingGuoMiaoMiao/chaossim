// A brand-new tiny library, written by FOLLOWING docs/adopting.md literally.
// It is not part of chaossim: it stands in for "someone else's protocol".
//
// The protocol is deliberately trivial (REQ/ACK with a request id) so that if
// the guide is wrong, it fails for a documentation reason, not because the toy
// is complicated.

///|
/// The toy library's own state machine: which request ids are in flight.
pub(all) struct Toy {
  mut in_flight : Array[Int32]
  mut sent : Int32
  mut acked : Int32
}

///|
pub fn Toy::new() -> Toy {
  { in_flight: [], sent: 0, acked: 0, }
}

///|
/// Record a request as sent; returns the id to put on the wire.
pub fn Toy::request(self : Toy, id : Int32) -> Int32 {
  self.in_flight.push(id)
  self.sent = self.sent + 1
  id
}

///|
/// Handle an ack; the id must be one we are actually waiting for, otherwise
/// it is an unsolicited ack (a real protocol bug worth reporting).
pub fn Toy::on_ack(self : Toy, id : Int32) -> Bool {
  let keep : Array[Int32] = []
  let mut found = false
  for pending in self.in_flight {
    if pending == id && !found {
      found = true
    } else {
      keep.push(pending)
    }
  }
  self.in_flight = keep
  if found {
    self.acked = self.acked + 1
  }
  found
}
