// White-box tests for the moonmq adapter.
//
// The question these answer is not "does the broker work" (its own suite covers
// that) but "when the wire loses the broker's reply, does a message disappear
// silently, and does the broker still account for it".

///|
fn script(count : Int) -> Array[Int] {
  let s : Array[Int] = []
  for _i = 0; _i < count; _i = _i + 1 {
    s.push(op_get)
    s.push(op_ack)
  }
  s.push(op_delete_probe)
  s
}

///|
test "clean wire: deliveries are acknowledged and accounting closes" {
  let s = run_script(42, 40, [], 2, script(2))
  let w = s.world
  assert_eq(w.published, 2)
  assert_eq(w.delivered, 2)
  assert_eq(w.acked, 2)
  assert_eq(w.unacked_tags.length(), 0)
  assert_eq(w.delete_allowed, 1)
  assert_eq(w.delete_refused, 0)
  assert_true(i1_no_acked_tag_outstanding(w))
  assert_true(i3_accounting_closes(w))
  assert_true(no_bad_events(w))
}

///|
test "lost reply: the client never learns the tag, the broker still holds it" {
  // Every reply from node 1 back to node 0 is dropped from step 1 on, so the
  // client's script cannot advance past the first get.
  let faults : Array[@sim.Fault] = [@sim.loss(1, 0, 1)]
  let s = run_script(42, 40, faults, 2, script(2))
  let w = s.world
  assert_eq(w.published, 2)
  assert_eq(w.delivered, 1)
  // the client never learned the tag, so nothing was acknowledged
  assert_eq(w.acked, 0)
  assert_eq(w.unacked_tags.length(), 1)
  // the delivery happened broker-side; the client was never told
  assert_eq(w.issued_tags.length(), 1)
  // any later get still sees the queue as non-empty from the broker's view:
  // nothing was silently dropped
  assert_true(i3_accounting_closes(w))
  assert_true(no_bad_events(w))
}

///|
test "broker down: nothing is delivered and nothing is claimed" {
  let faults : Array[@sim.Fault] = [@sim.crash(1, 1)]
  let s = run_script(42, 40, faults, 2, script(2))
  let w = s.world
  assert_eq(w.delivered, 0)
  assert_eq(w.acked, 0)
  assert_eq(w.unacked_tags.length(), 0)
  assert_true(no_bad_events(w))
}

///|
test "delete probe is refused while a delivery is unacked" {
  // get, then probe deletion without acking: the broker must refuse, because
  // deleting would destroy an outstanding message.
  let s = run_script(42, 40, [], 1, [op_get, op_delete_probe])
  let w = s.world
  assert_eq(w.delivered, 1)
  assert_eq(w.unacked_tags.length(), 1)
  assert_eq(w.delete_refused, 1)
  assert_eq(w.delete_allowed, 0)
  assert_true(no_bad_events(w))
}

///|
test "reject with requeue returns the message instead of losing it" {
  // get, reject(requeue), get: the second get must hand out a message again.
  let s = run_script(42, 40, [], 1, [op_get, op_reject, op_get])
  let w = s.world
  assert_eq(w.delivered, 2)
  assert_eq(w.rejected, 1)
  assert_eq(w.acked, 0)
  assert_true(i3_accounting_closes(w))
  assert_true(no_bad_events(w))
}

///|
test "queue_stats message_count while a delivery is unacked" {
  // Documents what the broker reports instead of assuming it: publish 2, get 1
  // (unacked), then read the stats.
  let s = run_script(42, 40, [], 2, [op_get, op_stats])
  let w = s.world
  assert_eq(w.delivered, 1)
  assert_eq(w.stats_counts.length(), 1)
  assert_true(no_bad_events(w))
  println("message_count with 1 delivery unacked = \{w.stats_counts[0]}")
}
