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

///|
test "qos2 full handshake converges and reconciles" {
  // CONNECT, CONNACK, PUBLISH, PUBREC, PUBREL, PUBCOMP - six scheduled
  // deliveries, and PUBCOMP (kind 7) is the only one that clears inflight.
  let s = run_scenario_ex(7, 30, [], 2, 1)
  assert_eq(s.result.steps, 6)
  assert_eq(s.result.dropped, 0)
  assert_eq(s.world.issued, 1)
  assert_eq(s.world.acks_delivered, 1)
  assert_eq(s.world.core.session().inflight_count(), 0)
  assert_eq(inflight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "qos2 pubcomp loss pins WaitPubcomp and stays reconciled" {
  // loss(1, 0, 6): CONNACK (step 2) and PUBREC (step 4) still land; the
  // PUBCOMP aimed at the client at step 6 is dropped, so the handshake
  // stalls in WaitPubcomp - inflight pinned, accounting exact.
  let s = run_scenario_ex(7, 30, [@sim.loss(1, 0, 6)], 2, 1)
  assert_eq(s.result.dropped, 1)
  assert_eq(s.world.acks_delivered, 0)
  assert_eq(s.world.core.session().inflight_count(), 1)
  assert_eq(inflight_matches(s.world), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "two qos2 handshakes interleave and drain for every seed 1..8" {
  // The scheduler's seeded pick order IS the reorder test: two PUBLISH
  // frames, their PUBREC/PUBREL/PUBCOMP chains, interleaved arbitrarily.
  // For every seed: both conversations drain, PUBCOMP count equals
  // issued count, and the invariant never drifts at the end of the run.
  let mut drained = 0
  for seed = 1; seed <= 8; seed = seed + 1 {
    let s = run_scenario_ex(seed, 60, [], 2, 2)
    assert_eq(inflight_matches(s.world), true)
    assert_eq(no_bad_events(s.world), true)
    assert_eq(s.world.issued, 2)
    assert_eq(s.world.acks_delivered, 2)
    assert_eq(s.world.core.session().inflight_count(), 0)
    if s.result.dropped == 0 {
      drained = drained + 1
    }
  }
  assert_eq(drained, 8)
}
