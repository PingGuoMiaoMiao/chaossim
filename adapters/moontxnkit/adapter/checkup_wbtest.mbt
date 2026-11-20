// Negative control for the transaction-engine battery.
//
// Same discipline as the broker battery: every judging rule must fire on a
// deliberately bad observation, and stay quiet on a good one. Without this, a
// report of "10/10 PASS" could equally mean the detector is broken.

///|
test "every transaction judge fires on the bad observation" {
  assert_true(judge_dirty_read(true))
  assert_true(judge_read_your_writes(false))
  assert_true(judge_write_conflict(true))
  assert_true(judge_loser_left_no_trace(false))
  assert_true(judge_version_per_commit(0))
  assert_true(judge_version_per_commit(2))
  assert_true(judge_history_committed_only(3, 2))
  assert_true(judge_abort_leaves_nothing(true, 0))
  assert_true(judge_abort_leaves_nothing(false, 1))
  assert_true(judge_snapshot_isolation(true))
  assert_true(judge_validate_clean(1))
  assert_true(judge_compact_keeps_current(None))
  assert_true(judge_savepoint(false, false))
  assert_true(judge_savepoint(true, true))
  assert_true(judge_delete_visible(true))
}

///|
test "no transaction judge fires on the good observation" {
  assert_false(judge_dirty_read(false))
  assert_false(judge_read_your_writes(true))
  assert_false(judge_write_conflict(false))
  assert_false(judge_loser_left_no_trace(true))
  assert_false(judge_version_per_commit(1))
  assert_false(judge_history_committed_only(2, 2))
  assert_false(judge_abort_leaves_nothing(false, 0))
  assert_false(judge_snapshot_isolation(false))
  assert_false(judge_validate_clean(0))
  assert_false(judge_compact_keeps_current(Some("v")))
  assert_false(judge_savepoint(true, false))
  assert_false(judge_delete_visible(false))
}

///|
test "the battery runs and every item produces a verdict" {
  let items = battery()
  assert_eq(items.length(), 10)
  for c in items {
    let marked = match c.verdict {
      Pass => 1
      Risk(_) => 1
      NotCovered(_) => 1
    }
    assert_eq(marked, 1)
  }
}
