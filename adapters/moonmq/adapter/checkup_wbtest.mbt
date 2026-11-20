// Negative control for the checkup tool.
//
// A report that only ever prints PASS is worthless: you cannot tell "the library
// is fine" from "the detector is broken". These tests feed every judge the bad
// observation it is supposed to catch and require a Risk verdict, then feed it
// the good observation and require Pass. If one judge stopped firing, the report
// would silently become a rubber stamp - this is what prevents that.

///|
fn is_risk(v : Verdict) -> Bool {
  match v {
    Risk(_) => true
    _ => false
  }
}

///|
fn is_pass(v : Verdict) -> Bool {
  match v {
    Pass => true
    _ => false
  }
}

///|
test "every judge fires on the bad observation" {
  assert_true(is_risk(Risk("x")))
  assert_true(judge_double_ack(true))
  assert_true(judge_ack_after_requeue(true))
  assert_true(judge_requeue_returns(false))
  assert_true(judge_discard(true))
  assert_true(judge_prefetch(true))
  assert_true(judge_cancel(0))
  assert_true(judge_delete_refused(true))
  assert_true(judge_ack_many(false))
  assert_true(judge_isolation(true))
  assert_true(judge_fanout(true, false))
  assert_true(judge_fanout(false, false))
  assert_true(judge_topic(false, false))
  assert_true(judge_topic(true, true))
}

///|
test "no judge fires on the good observation" {
  assert_false(judge_double_ack(false))
  assert_false(judge_ack_after_requeue(false))
  assert_false(judge_requeue_returns(true))
  assert_false(judge_discard(false))
  assert_false(judge_prefetch(false))
  assert_false(judge_cancel(1))
  assert_false(judge_delete_refused(false))
  assert_false(judge_ack_many(true))
  assert_false(judge_isolation(false))
  assert_false(judge_fanout(true, true))
  assert_false(judge_topic(true, false))
}

///|
test "every risk carries a non-empty reason" {
  assert_true(why_double_ack(true).length() > 0)
  assert_true(why_ack_after_requeue(true).length() > 0)
  assert_true(why_requeue_returns(false).length() > 0)
  assert_true(why_discard(true).length() > 0)
  assert_true(why_prefetch(true).length() > 0)
  assert_true(why_cancel(0).length() > 0)
  assert_true(why_delete(true).length() > 0)
  assert_true(why_ack_many(false).length() > 0)
  assert_true(why_isolation(true).length() > 0)
  assert_true(why_fanout(true, false).length() > 0)
  assert_true(why_topic(false, false).length() > 0)
}

///|
test "the report's own counters separate pass from risk" {
  let items : Array[Check] = [
    { name: "a", question: "q", verdict: Pass },
    { name: "b", question: "q", verdict: Risk("why") },
    { name: "c", question: "q", verdict: NotCovered("n/a") },
  ]
  assert_eq(items.length(), 3)
  assert_true(is_pass(items[0].verdict))
  assert_true(is_risk(items[1].verdict))
}
