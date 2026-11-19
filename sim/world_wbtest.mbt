// v0 contract tests. These are the tests the README cites; keep them honest.

///|
fn echo_handler(node : Int32, msg : Msg) -> Array[Msg] {
  if msg.payload == 1 {
    [{ from: node, to: msg.from, payload: 2, }]
  } else {
    []
  }
}

///|
test "same seed and plan imply identical trace" {
  let initial = [
    { from: 0, to: 1, payload: 1, },
    { from: 1, to: 0, payload: 1, },
  ]
  let a = run_bounded(echo_handler, initial, 42, 100, None)
  let b = run_bounded(echo_handler, initial, 42, 100, None)
  assert_eq(a.trace.length(), b.trace.length())
  for i = 0; i < a.trace.length(); i = i + 1 {
    assert_eq(a.trace[i], b.trace[i])
  }
  assert_eq(a, b)
}

///|
test "any seed delivers every message of a quiescing protocol" {
  let stop : Handler = (_node, _msg) => []
  let initial = [
    { from: 0, to: 1, payload: 7, },
    { from: 1, to: 0, payload: 8, },
    { from: 2, to: 0, payload: 9, },
  ]
  let a = run_bounded(stop, initial, 1, 10, None)
  let b = run_bounded(stop, initial, 2, 10, None)
  assert_eq(a.steps, 3)
  assert_eq(b.steps, 3)
  assert_eq(a.delivered + b.delivered, 6)
}

///|
test "crash plan silences the target node" {
  let reply : Handler = (node, msg) => {
    [{ from: node, to: msg.from, payload: msg.payload + 1, }]
  }
  let initial = [{ from: 0, to: 1, payload: 1, }]
  let plan = { node: 1, from_step: 2, }
  // step1: 0->1 #1 delivered, node1 replies 1->0 #2.
  // step2: 1->0 #2 delivered (node 0 is alive), node0 replies 0->1 #3.
  // step3: 0->1 #3 targets the down node => dropped, queue drains.
  let r = run_bounded(reply, initial, 3, 50, Some(plan))
  assert_eq(r.delivered, 2)
  assert_eq(r.dropped, 1)
  assert_eq(r.trace, ["send 1: 0->1 #1", "send 2: 1->0 #2", "drop 3: 0->1 #3"])
}

///|
test "max_steps bounds a livelocked handler" {
  let loop_handler : Handler = (node, msg) => {
    [{ from: node, to: (msg.to + 1) % 2, payload: msg.payload, }]
  }
  let r = run_bounded(
    loop_handler,
    [{ from: 0, to: 1, payload: 1, }],
    5,
    7,
    None,
  )
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
