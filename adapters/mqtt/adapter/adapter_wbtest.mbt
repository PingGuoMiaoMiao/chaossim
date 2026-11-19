// Adapter contract tests. These are the scenarios docs/w2-targets.md
// promises; every assertion is a joint claim about moon-mqtt AND chaossim:
// if the scheduler is right, the library's inflight bookkeeping must track
// issued-minus-delivered exactly, with or without faults on the wire.

///|
test "clean scenario: publish acked, counters reconcile" {
  let s = run_scenario(7, 20, [])
  assert_eq(s.result.dropped, 0)
  assert_eq(s.result.steps, 4) // CONNECT, CONNACK(+PUBLISH), PUBACK
  assert_eq(s.world.issued, 1)
  assert_eq(s.world.acks_delivered, 1)
  assert_eq(s.world.core.session().inflight_count(), 0)
  assert_eq(inflight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "ack loss pins inflight at 1 and the drop is counted" {
  // loss(1, 0, 3): the PUBACK (scheduled 1->0) bites from step 3 onward
  let s = run_scenario(7, 20, [@sim.loss(1, 0, 3)])
  assert_eq(s.result.dropped, 1)
  assert_eq(s.world.acks_delivered, 0)
  assert_eq(s.world.core.session().inflight_count(), 1)
  assert_eq(inflight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "broker crash after ack leaves the same end state as plain loss" {
  // crash(1, 3): from step 3 the broker answers nothing — PUBACK never
  // arrives either way; the scenario must not distinguish how it starved
  let s = run_scenario(7, 20, [@sim.crash(1, 3)])
  assert_eq(s.world.acks_delivered, 0)
  assert_eq(s.world.core.session().inflight_count(), 1)
  assert_eq(inflight_matches(s.world), true)
}

///|
test "same seed replays identically through the slot indirection" {
  let a = run_scenario(1, 20, [])
  let b = run_scenario(1, 20, [])
  assert_eq(a.result, b.result)
  let c = run_scenario(1, 20, [@sim.loss(1, 0, 3)])
  assert_eq(a.result == c.result, false) // the fault must be observable
}

///|
test "delay window of the ack holds inflight then clears it" {
  // PUBACK held 2 steps, slow window only through step 5 — then it lands.
  let s = run_scenario(7, 20, [@sim.delay_window(0, 3, 2, 5)])
  assert_eq(s.world.issued, 1)
  assert_eq(s.world.acks_delivered, 1)
  assert_eq(s.world.core.session().inflight_count(), 0)
  assert_eq(s.result.deferred >= 1, true)
  assert_eq(inflight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "forever-slow ack starves but counters stay reconciled" {
  // The bin transcript keeps this starvation run as evidence: the ack
  // never lands, yet issued-minus-delivered still equals the store.
  let s = run_scenario(7, 20, [@sim.delay(0, 3, 2)])
  assert_eq(s.world.acks_delivered, 0)
  assert_eq(s.world.core.session().inflight_count(), 1)
  assert_eq(inflight_matches(s.world), true)
  assert_eq(s.result.deferred, 9)
}
