// v0.2 contract tests. These are the tests the README cites; keep them honest.

///|
fn echo_handler(node : Int32, msg : Msg) -> Array[Msg] {
  if msg.payload == 1 {
    [{ from: node, to: msg.from, payload: 2, }]
  } else {
    []
  }
}

///|
fn stop_handler(_node : Int32, _msg : Msg) -> Array[Msg] {
  []
}

///|
fn reply_handler(node : Int32, msg : Msg) -> Array[Msg] {
  [{ from: node, to: msg.from, payload: msg.payload + 1, }]
}

///|
test "same seed and faults imply identical result" {
  let initial = [
    { from: 0, to: 1, payload: 1, },
    { from: 1, to: 0, payload: 1, },
  ]
  let a = run_bounded(echo_handler, initial, 42, 100, [])
  let b = run_bounded(echo_handler, initial, 42, 100, [])
  assert_eq(a, b)
}

///|
test "any seed delivers every message of a quiescing protocol" {
  let initial = [
    { from: 0, to: 1, payload: 7, },
    { from: 1, to: 0, payload: 8, },
    { from: 2, to: 0, payload: 9, },
  ]
  let a = run_bounded(stop_handler, initial, 1, 10, [])
  let b = run_bounded(stop_handler, initial, 2, 10, [])
  assert_eq(a.steps, 3)
  assert_eq(b.steps, 3)
  assert_eq(a.delivered + b.delivered, 6)
}

///|
test "crash fault silences the target node" {
  let initial = [{ from: 0, to: 1, payload: 1, }]
  // step1: 0->1 #1 delivered, node1 replies 1->0 #2.
  // step2: 1->0 #2 delivered (node 0 is alive), node0 replies 0->1 #3.
  // step3: 0->1 #3 targets the down node => dropped, queue drains.
  let r = run_bounded(reply_handler, initial, 3, 50, [crash(1, 2)])
  assert_eq(r.delivered, 2)
  assert_eq(r.dropped, 1)
  assert_eq(r.deferred, 0)
  assert_eq(r.trace, ["send 1: 0->1 #1", "send 2: 1->0 #2", "drop 3: 0->1 #3"])
}

///|
test "loss fault only silences one directed link" {
  let initial = [{ from: 0, to: 1, payload: 1, }]
  // link 1->0 dark from step 2: node1's reply is lost, nothing else was in
  // flight, so the run ends with exactly one drop.
  let r = run_bounded(reply_handler, initial, 3, 50, [loss(1, 0, 2)])
  assert_eq(r.delivered, 1)
  assert_eq(r.dropped, 1)
  assert_eq(r.trace, ["send 1: 0->1 #1", "drop 2: 1->0 #2 (loss)"])
}

///|
test "partition drops cross-group traffic until healed" {
  let initial = [{ from: 0, to: 1, payload: 1, }]
  // partition {0} | {1} from step 1 forever: nothing crosses, end immediately
  let r = run_bounded(reply_handler, initial, 3, 50, [
    partition([0], [1], 1, -1),
  ])
  assert_eq(r.delivered, 0)
  assert_eq(r.dropped, 1)
  assert_eq(r.trace, ["drop 1: 0->1 #1 (partition)"])
}

///|
test "delay re-holds under retry pressure: the slow-node livelock is visible" {
  let initial = [{ from: 0, to: 1, payload: 1, }]
  // node 1 becomes slow (hold 2 steps) from step 3. Under an always-retry
  // handler the SAME message keeps getting re-held — the trace is the
  // evidence (decisions.md D3: delay is per-scheduling, not once-per-message).
  let r = run_bounded(reply_handler, initial, 42, 8, [delay(1, 3, 2)])
  assert_eq(r.delivered, 2)
  assert_eq(r.dropped, 0)
  assert_eq(r.deferred, 3)
  assert_eq(r.trace, [
    "send 1: 0->1 #1", "send 2: 1->0 #2", "delay 3: 0->1 #3 ->@5", "delay 5: 0->1 #3 ->@7",
    "delay 7: 0->1 #3 ->@9",
  ])
  assert_eq(r.steps, 8)
}

///|
test "delay window restores delivery after the window closes" {
  let initial = [{ from: 0, to: 1, payload: 1, }]
  // slow node 1 from step 3 for 2-step holds, only through step 5. Actual
  // trace below (asserted from the first real run, not wishful): two
  // bounded delays, then both directions flow - the ping-pong keeps
  // producing until max_steps, which is fine: the point is the delay is
  // BOUNDED where the forever variant starves forever.
  let r = run_bounded(reply_handler, initial, 42, 10, [delay_window(1, 3, 2, 5)])
  assert_eq(r.deferred, 2)
  assert_eq(r.dropped, 0)
  assert_eq(r.steps, 10)
  assert_eq(r.trace, [
    "send 1: 0->1 #1", "send 2: 1->0 #2", "delay 3: 0->1 #3 ->@5", "delay 5: 0->1 #3 ->@7",
    "send 7: 0->1 #3", "send 8: 1->0 #4", "send 9: 0->1 #5", "send 10: 1->0 #6",
  ])
}

///|
test "max_steps bounds a livelocked handler" {
  let loop_handler : Handler = (node, msg) => {
    [{ from: node, to: (msg.to + 1) % 2, payload: msg.payload, }]
  }
  let r = run_bounded(loop_handler, [{ from: 0, to: 1, payload: 1, }], 5, 7, [])
  assert_eq(r.steps, 7)
  assert_eq(r.delivered, 7)
}

///|
test "pick stays in range for negative and zero seeds" {
  let mut seed = -12345
  for _i = 0; _i < 2000; _i = _i + 1 {
    let (v, s) = pick(seed, 7)
    assert_eq(v >= 0 && v < 7, true)
    seed = s
  }
  let (v1, s1) = pick(99, 1)
  assert_eq(v1, 0)
  assert_eq(s1, 99) // bound <= 1 must not consume entropy
}

///|
test "virtual clock never goes backwards" {
  let c = VirtualClock::new(10)
  assert_eq(c.advance(-5).now, 10)
  assert_eq(c.advance(3).now, 13)
}

///|
fn bad_kind_fault() -> Fault {
  {
    kind: "earthquake",
    a: 0,
    b: 0,
    group_a: [],
    group_b: [],
    from_step: 1,
    until: -1,
  }
}

///|
fn expect_invalid(faults : Array[Fault]) -> Bool {
  let _ = run_bounded(
    stop_handler,
    [{ from: 0, to: 1, payload: 1, }],
    1,
    5,
    faults,
  ) catch {
    SimError::InvalidFault(_) => return false
    e => abort(e.message())
  }
  true
}

///|
test "invalid faults fail fast" {
  assert_eq(expect_invalid([crash(1, 0)]), false) // from_step < 1
  assert_eq(expect_invalid([delay(1, 1, 0)]), false) // hold length < 1
  assert_eq(expect_invalid([loss(2, 2, 1)]), false) // self-loop link
  assert_eq(expect_invalid([partition([0], [0, 1], 1, -1)]), false) // overlap
  assert_eq(expect_invalid([bad_kind_fault()]), false)
  assert_eq(expect_invalid([crash(1, 1)]), true)
}

///|
fn verify_raises(text : String, handler : Handler) -> Bool {
  let _ = replay_verify(text, handler) catch {
    SimError::ReplayMismatch(_) | SimError::ParseError(_) => return true
    e => abort(e.message())
  }
  false
}

///|
test "replay round-trip verifies, divergent handler fails" {
  let initial = [{ from: 0, to: 1, payload: 1, }]
  let faults = [crash(1, 2)]
  let r = run_bounded(reply_handler, initial, 3, 50, faults)
  let text = render_replay("crash-demo", 3, 50, initial, faults, r)
  // same handler: verifies and returns the recomputed result
  let again = replay_verify(text, reply_handler)
  assert_eq(again, r)
  // different handler: the recorded claim no longer holds -> mismatch
  assert_eq(verify_raises(text, stop_handler), true)
}

///|
test "replay rejects garbage" {
  assert_eq(verify_raises("not json at all", stop_handler), true)
}
