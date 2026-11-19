// The drill's acceptance test: what a new adopter should end up with after
// following docs/adopting.md - one clean run and one fault run that still
// reconciles.

///|
test "clean run: the request is acked" {
  let s = run(7, 20, [])
  assert_eq(s.world.issued, 1)
  assert_eq(s.world.acks, 1)
  assert_eq(s.world.core.in_flight.length(), 0)
  assert_eq(in_flight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "ack lost: the request stays in flight and accounting still ties" {
  let s = run(7, 20, [@sim.loss(1, 0, 1)])
  assert_eq(s.world.issued, 1)
  assert_eq(s.world.acks, 0)
  assert_eq(s.world.core.in_flight.length(), 1)
  assert_eq(in_flight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
  assert_eq(s.result.dropped, 1)
}

///|
test "replay: same seed reproduces the same run" {
  let a = run(3, 20, [@sim.loss(1, 0, 1)])
  let b = run(3, 20, [@sim.loss(1, 0, 1)])
  assert_eq(a.result, b.result)
}
