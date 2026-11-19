// AMQP 1.0 adapter contract tests (second target, D11).
//
// The invariant under test is deliberately delivery-independent: AMQP
// spends link credit at `send()` time, so a wire fault must leave the
// endpoint ACCOUNTED FOR rather than corrupted. These tests therefore check
// credit arithmetic and pending state, not "the message arrived".

///|
test "clean wire: message delivered, settled, credit spent" {
  let s = run_message_cycle(7, 40, [])
  assert_eq(s.world.sends, 1)
  assert_eq(s.world.received, 1)
  assert_eq(s.world.settled, 1)
  assert_eq(s.world.app.pending(), (0, 0))
  assert_eq(credit_accounted(s.world, 1), true)
  assert_eq(no_bad_events(s.world), true)
  assert_eq(s.result.dropped, 0)
}

///|
test "transfer lost: nothing delivered, credit still accounted" {
  // the app spent its credit at send() and the transfer never arrived:
  // received/settled stay 0, one delivery stays unsettled, and the credit
  // arithmetic - the part that is independent of delivery - still holds.
  let s = run_message_cycle(7, 40, [@sim.loss(0, 1, 1)])
  assert_eq(s.result.dropped, 1)
  assert_eq(s.world.sends, 1)
  assert_eq(s.world.received, 0)
  assert_eq(s.world.settled, 0)
  assert_eq(s.world.app.pending(), (1, 0))
  assert_eq(credit_accounted(s.world, 1), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "settlement lost: delivered but the app never learns" {
  // the service received and acknowledged; the acknowledgement died on the
  // wire. The app must keep the delivery unsettled rather than pretend it
  // was accepted - that is exactly the state a retry decision needs.
  let s = run_message_cycle(7, 40, [@sim.loss(1, 0, 2)])
  assert_eq(s.world.received, 1)
  assert_eq(s.world.settled, 0)
  assert_eq(s.world.app.pending(), (1, 0))
  assert_eq(credit_accounted(s.world, 1), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "delayed service still converges, accounting unchanged" {
  let s = run_message_cycle(7, 40, [@sim.delay_window(1, 2, 3, 6)])
  assert_eq(s.world.received, 1)
  assert_eq(s.world.settled, 1)
  assert_eq(s.world.app.pending(), (0, 0))
  assert_eq(credit_accounted(s.world, 1), true)
  assert_eq(no_bad_events(s.world), true)
}

///|
test "same seed and faults reproduce the same run" {
  let a = run_message_cycle(1, 40, [@sim.loss(0, 1, 1)])
  let b = run_message_cycle(1, 40, [@sim.loss(0, 1, 1)])
  assert_eq(a.result, b.result)
  assert_eq(a.world.received, b.world.received)
  assert_eq(a.world.settled, b.world.settled)
}

///|
test "credit arithmetic holds across seeds and fault kinds" {
  // The whole point of a delivery-independent invariant: it must hold no
  // matter which frame the scheduler happens to pick or cut. Sweeping seeds
  // is cheap and catches arithmetic that accidentally depends on order.
  for seed = 1; seed <= 6; seed = seed + 1 {
    let clean = run_message_cycle(seed, 40, [])
    assert_eq(credit_accounted(clean.world, 1), true)
    assert_eq(no_bad_events(clean.world), true)
    let lost = run_message_cycle(seed, 40, [@sim.loss(0, 1, 1)])
    assert_eq(credit_accounted(lost.world, 1), true)
    assert_eq(no_bad_events(lost.world), true)
    let settled_lost = run_message_cycle(seed, 40, [@sim.loss(1, 0, 2)])
    assert_eq(credit_accounted(settled_lost.world, 1), true)
    assert_eq(no_bad_events(settled_lost.world), true)
  }
}
