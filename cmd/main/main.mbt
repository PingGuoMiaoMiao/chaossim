// 90-second demo: run a two-node request/reply protocol twice under the same
// seed (replay equality), then crash the responder mid-protocol and watch a
// reply get dropped — the same scenario `world_wbtest` pins with assertions.

///|
fn reply(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
  // production behavior: always acknowledge, incrementing payload
  [{ from: node, to: msg.from, payload: msg.payload + 1, }]
}

///|
fn print_result(label : String, r : @sim.RunResult) -> Unit {
  println(
    "== \{label}: steps=\{r.steps} delivered=\{r.delivered} dropped=\{r.dropped}",
  )
  for line in r.trace {
    println("   " + line)
  }
}

///|
fn main {
  let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: 1, }]

  // healthy run: node0 asks, node1 acks, node0 acks the ack... bounded by
  // max_steps here so both runs stay tiny and replay-comparable.
  let a = @sim.run_bounded(reply, initial, 42, 4, None)
  let b = @sim.run_bounded(reply, initial, 42, 4, None)
  print_result("run seed=42 max_steps=4", a)
  println("replay equal: \{a.trace == b.trace}")

  // same protocol, but node 1 is down from step 2: its reply still goes out,
  // the ack aimed back at it is dropped, queue drains.
  let crashed = @sim.run_bounded(
    reply,
    initial,
    42,
    100,
    Some({ node: 1, from_step: 2, }),
  )
  print_result("crash plan node=1 from_step=2", crashed)
}
