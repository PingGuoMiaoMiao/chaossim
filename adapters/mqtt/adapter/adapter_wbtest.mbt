// Adapter contract tests. Round one established the QoS1/QoS2 single-client
// equivalence classes; this file adds the dual-client ones (D9). Every
// assertion is a joint claim about moon-mqtt AND chaossim.

///|
fn faults1(f : @sim.Fault) -> Array[@sim.Fault] {
  [f]
}

///|
test "same seed and faults imply identical result" {
  let a = run_scenario(1, 20, [])
  let b = run_scenario(1, 20, [])
  assert_eq(a.result, b.result)
}

///|
test "clean scenario: publish acked, counters reconcile" {
  let s = run_scenario(7, 20, [])
  assert_eq(s.result.dropped, 0)
  assert_eq(s.result.steps, 4)
  assert_eq(issued_of(s.world, 0), 1)
  assert_eq(acks_of(s.world, 0), 1)
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "ack loss pins inflight at 1 and the drop is counted" {
  let s = run_scenario(7, 20, faults1(@sim.loss(1, 0, 3)))
  assert_eq(s.result.dropped, 1)
  assert_eq(acks_of(s.world, 0), 0)
  assert_eq(inflight(s.world, 0), 1)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "broker crash after ack leaves the same end state as plain loss" {
  let s = run_scenario(7, 20, faults1(@sim.crash(1, 3)))
  assert_eq(acks_of(s.world, 0), 0)
  assert_eq(inflight(s.world, 0), 1)
  assert_eq(inflight_matches(s.world, 0), true)
}

///|
test "delay window restores delivery after the window closes" {
  let s = run_scenario(7, 20, faults1(@sim.delay_window(0, 3, 2, 5)))
  assert_eq(issued_of(s.world, 0), 1)
  assert_eq(acks_of(s.world, 0), 1)
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(s.result.deferred >= 1, true)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "forever-slow ack starves but counters stay reconciled" {
  let s = run_scenario(7, 20, faults1(@sim.delay(0, 3, 2)))
  assert_eq(acks_of(s.world, 0), 0)
  assert_eq(inflight(s.world, 0), 1)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(s.result.deferred, 9)
}

///|
test "qos2 full handshake converges and reconciles" {
  let s = run_scenario_ex(7, 30, [], 2, 1)
  assert_eq(s.result.steps, 6)
  assert_eq(s.result.dropped, 0)
  assert_eq(issued_of(s.world, 0), 1)
  assert_eq(acks_of(s.world, 0), 1)
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "qos2 pubcomp loss pins WaitPubcomp and stays reconciled" {
  let s = run_scenario_ex(7, 30, faults1(@sim.loss(1, 0, 6)), 2, 1)
  assert_eq(s.result.dropped, 1)
  assert_eq(acks_of(s.world, 0), 0)
  assert_eq(inflight(s.world, 0), 1)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "two qos2 handshakes interleave and drain for every seed 1..8" {
  let mut drained = 0
  for seed = 1; seed <= 8; seed = seed + 1 {
    let s = run_scenario_ex(seed, 60, [], 2, 2)
    assert_eq(inflight_matches(s.world, 0), true)
    assert_eq(no_bad_events(s.world), true)
    assert_eq(issued_of(s.world, 0), 2)
    assert_eq(acks_of(s.world, 0), 2)
    assert_eq(inflight(s.world, 0), 0)
    if s.result.dropped == 0 {
      drained = drained + 1
    }
  }
  assert_eq(drained, 8)
}

///|
test "dual clients complete independently on a clean wire" {
  let s = run_multi(7, 60, [], 1, 1, 2)
  assert_eq(s.result.dropped, 0)
  assert_eq(issued_of(s.world, 0), 1)
  assert_eq(issued_of(s.world, 2), 1)
  assert_eq(acks_of(s.world, 0), 1)
  assert_eq(acks_of(s.world, 2), 1)
  assert_eq(all_drained(s.world), true)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(inflight_matches(s.world, 2), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
/// Partition from step 1 is seed-independent BY CONSTRUCTION: every A<->1
/// frame bites immediately, so A never opens a conversation while B runs
/// the full handshake - the lane-cut equivalence class without any racing
/// against when A's publish might get picked. (The mid-session isolation
/// case is shown in the bin transcript with its ACTUAL counters instead
/// of a brittle assertion - D8 discipline.)

///|
test "partition from step 1 silences one client, peer converges" {
  let s = run_multi(7, 60, faults1(@sim.partition([0], [1], 1, -1)), 1, 1, 2)
  assert_eq(s.result.dropped >= 1, true)
  // isolated client: never got past CONNECT
  assert_eq(issued_of(s.world, 0), 0)
  assert_eq(acks_of(s.world, 0), 0)
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(inflight_matches(s.world, 0), true)
  // peer client: everything still completes
  assert_eq(issued_of(s.world, 2), 1)
  assert_eq(acks_of(s.world, 2), 1)
  assert_eq(inflight(s.world, 2), 0)
  assert_eq(inflight_matches(s.world, 2), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "partition lane-cut holds across seeds 1..6" {
  for seed = 1; seed <= 6; seed = seed + 1 {
    let s = run_multi(
      seed,
      60,
      faults1(@sim.partition([0], [1], 1, -1)),
      1,
      1,
      2,
    )
    assert_eq(issued_of(s.world, 0), 0)
    assert_eq(acks_of(s.world, 0), 0)
    assert_eq(inflight(s.world, 0), 0)
    assert_eq(issued_of(s.world, 2), 1)
    assert_eq(acks_of(s.world, 2), 1)
    assert_eq(inflight(s.world, 2), 0)
    assert_eq(inflight_matches(s.world, 0), true)
    assert_eq(inflight_matches(s.world, 2), true)
    assert_eq(no_bad_events(s.world), true)
  }
}
