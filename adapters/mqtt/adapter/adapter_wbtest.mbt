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
/// The recovery promise, checked under an injected fault (D12).
///
/// Phase A loses the PUBACK, so the client is left holding an unsettled
/// in-flight message - the exact state their README says `replay_bytes()`
/// exists for. Phase B then does the documented reconnect: `on_transport_
/// close()`, `reconnect_bytes()`, and because the broker reports
/// session_present=1, the client re-emits the unsettled PUBLISH with DUP=1
/// instead of publishing new work.
///
/// Asserted from the first real run, not from hope: phase A ends with the
/// ack dropped, phase B ends with inflight back to 0 and exactly one DUP
/// frame replayed.
test "ack loss is recovered by reconnect + replay with DUP set" {
  let s = run_recovery(7, 30, faults1(@sim.loss(1, 0, 3)))
  // phase A: the ack was the fault victim
  assert_eq(s.phase_a.dropped, 1)
  assert_eq(s.phase_a_acks, 0)
  // phase B: one reconnect, one session-resumed CONNACK, one DUP replay
  assert_eq(connects_of(s.world, 0), 2)
  assert_eq(s.world.replays, 1)
  assert_eq(s.world.dups, 1) // the replayed frame really carried DUP=1
  // and the client is consistent again
  assert_eq(acks_of(s.world, 0), 1)
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "recovery works for every seed 1..6" {
  // The reconnect handshake frames are scheduled too, so this also proves
  // the recovery does not depend on which frame the scheduler picks first.
  for seed = 1; seed <= 6; seed = seed + 1 {
    let s = run_recovery(seed, 30, faults1(@sim.loss(1, 0, 3)))
    assert_eq(connects_of(s.world, 0), 2)
    assert_eq(s.world.replays, 1)
    assert_eq(s.world.dups, 1)
    assert_eq(inflight(s.world, 0), 0)
    assert_eq(inflight_matches(s.world, 0), true)
    assert_eq(no_bad_events(s.world), true)
  }
}

///|
test "without the fault no replay happens (the control case)" {
  // Same two-phase shape, clean phase A: nothing is left unsettled, so the
  // resumed session has nothing to replay. This is the control that stops
  // the recovery test from passing for a trivial reason.
  let s = run_recovery(7, 30, [])
  assert_eq(s.phase_a.dropped, 0)
  assert_eq(s.phase_a_acks, 1) // already acked in phase A
  assert_eq(s.world.replays, 0) // nothing in flight -> nothing to replay
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(no_bad_events(s.world), true)
}

///|
/// Partition from step 1 is seed-independent BY CONSTRUCTION: every A<->1
/// frame bites immediately, so A never opens a conversation while B runs
/// the full handshake - the lane-cut equivalence class without racing
/// against when A's publish might get picked.
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

///|
/// QoS2 has a DIFFERENT recovery branch, and this is the test that pins the
/// difference: a delivery stuck in WaitPubcomp resumes by re-sending PUBREL
/// (kind 6, which carries no DUP flag in MQTT 3.1.1), NOT by re-sending
/// PUBLISH. So the expected counters are replays=0 / replays_pubrel=1 /
/// dups=0 - the mirror image of the QoS1 recovery test above.
test "qos2 pubcomp loss recovers by replaying PUBREL, not PUBLISH" {
  let s = run_recovery_ex(7, 40, faults1(@sim.loss(1, 0, 6)), 2)
  // phase A: the PUBCOMP was the victim (step 6, broker -> client)
  assert_eq(s.phase_a.dropped, 1)
  assert_eq(s.phase_a_acks, 0)
  // phase B: resumed session replays PUBREL, and the peer completes it
  assert_eq(connects_of(s.world, 0), 2)
  assert_eq(s.world.replays, 0) // no PUBLISH re-sent
  assert_eq(s.world.replays_pubrel, 1) // exactly one PUBREL re-sent
  assert_eq(s.world.dups, 0) // PUBREL has no DUP flag to set
  // and the client is settled again
  assert_eq(acks_of(s.world, 0), 1)
  assert_eq(inflight(s.world, 0), 0)
  assert_eq(inflight_matches(s.world, 0), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "qos2 recovery holds across seeds 1..6" {
  for seed = 1; seed <= 6; seed = seed + 1 {
    let s = run_recovery_ex(seed, 40, faults1(@sim.loss(1, 0, 6)), 2)
    assert_eq(s.world.replays, 0)
    assert_eq(s.world.replays_pubrel, 1)
    assert_eq(inflight(s.world, 0), 0)
    assert_eq(inflight_matches(s.world, 0), true)
    assert_eq(no_bad_events(s.world), true)
  }
}
