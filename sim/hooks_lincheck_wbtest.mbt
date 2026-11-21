// Tests for the invariant hooks and the linearizability checker.
//
// The checker tests follow the same discipline as the checkup battery: a pass on a
// good history proves nothing unless a BAD history is rejected. Both directions are
// asserted, including the case where the violation is only visible if real-time
// order is respected.

///|
fn mk(
  client : Int32,
  invoke : Int32,
  respond : Int32,
  kind : String,
  key : String,
  value : String,
  observed : String
) -> Op {
  { client, invoke, respond, kind, key, value, observed }
}

///|
test "hooks: a clean trace has no violations" {
  let r = run_bounded(fn(_n : Int32, _m : Msg) -> Array[Msg] { [] }, [{ from: 0, to: 1, payload: 1 }], 7, 5, []) catch {
    _ => abort("run failed")
  }
  let vs = check_steps(
    r,
    [accounting_never_negative(), each_step_accounts_one(), no_silent_step()],
  )
  assert_eq(vs.length(), 0)
}

///|
test "hooks: accounting_never_negative fires on a negative counter" {
  let hook = accounting_never_negative()
  let bad : StepView = {
    step: 1,
    delivered: -1,
    dropped: 0,
    deferred: 0,
    line: "send 1: 0->1 #1",
  }
  assert_true(hook(bad) is Some(_))
}

///|
test "hooks: each_step_accounts_one fires when a message vanished" {
  let hook = each_step_accounts_one()
  // step 3 but only two messages accounted for
  let bad : StepView = {
    step: 3,
    delivered: 1,
    dropped: 1,
    deferred: 0,
    line: "send 3: 0->1 #3",
  }
  assert_true(hook(bad) is Some(_))
  // the matching good view
  let good : StepView = {
    step: 3,
    delivered: 2,
    dropped: 1,
    deferred: 0,
    line: "send 3: 0->1 #3",
  }
  assert_true(hook(good) is None)
}

///|
test "hooks: no_silent_step fires on an empty line" {
  let hook = no_silent_step()
  let bad : StepView = { step: 2, delivered: 2, dropped: 0, deferred: 0, line: "" }
  assert_true(hook(bad) is Some(_))
}

///|
test "lincheck: a sequentially consistent history is linearizable" {
  // put k=1 completes, then get k returns 1
  let h = [
    mk(0, 1, 2, "put", "k", "1", ""),
    mk(1, 3, 4, "get", "k", "", "1"),
  ]
  let o = check_history(h, kv_spec, 100)
  assert_true(o is Linearizable)
}

///|
test "lincheck: a stale read that real time forbids is REJECTED" {
  // put k=2 completes at 2, then a read starts at 3 and sees the OLD value
  let h = [
    mk(0, 1, 2, "put", "k", "2", ""),
    mk(1, 3, 4, "get", "k", "", "1"),
  ]
  let o = check_history(h, kv_spec, 100)
  // this is the assertion that proves the checker is not a rubber stamp
  assert_true(o is NotLinearizable(_))
}

///|
test "lincheck: concurrent reads may both see the old value" {
  // two gets overlap the put: reading the old value is legal because they may
  // have been linearized before it.
  // `put k=2` overlaps BOTH reads: each read may be linearized before it, so
  // seeing "1" is legal. (A read that started after the put returned could not
  // see "1", which is the previous test.)
  // k must hold "1" before the concurrent window, otherwise the reads would be
  // observing an empty store.
  let h = [
    mk(0, 1, 2, "put", "k", "1", ""),
    mk(0, 3, 8, "put", "k", "2", ""),
    mk(1, 4, 5, "get", "k", "", "1"),
    mk(2, 4, 5, "get", "k", "", "1"),
  ]
  let o = check_history(h, kv_spec, 100)
  assert_true(o is Linearizable)
}

///|
test "lincheck: write skew that no ordering explains is REJECTED" {
  // A writes k=1 and is acknowledged; B writes k=2 and is acknowledged; both
  // reads then see 1 - the second write cannot have happened before them while
  // the first cannot come after.
  let h = [
    mk(0, 1, 2, "put", "k", "1", ""),
    mk(1, 3, 4, "put", "k", "2", ""),
    mk(2, 5, 6, "get", "k", "", "1"),
  ]
  let o = check_history(h, kv_spec, 100)
  assert_true(o is NotLinearizable(_))
}

///|
test "lincheck: pending operations are not constrained" {
  // a read that never returned cannot make a history illegal
  let h = [
    mk(0, 1, 2, "put", "k", "1", ""),
    mk(1, 3, -1, "get", "k", "", ""),
  ]
  let o = check_history(h, kv_spec, 100)
  assert_true(o is Linearizable)
}

///|
test "lincheck: an exhausted budget reports unknown, never a pass" {
  let h = [
    mk(0, 1, 2, "put", "k", "1", ""),
    mk(1, 3, 4, "get", "k", "", "1"),
  ]
  let o = check_history(h, kv_spec, 0)
  assert_true(o is Unknown(_))
}
