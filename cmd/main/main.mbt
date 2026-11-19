// 90-second demo: a two-node request/reply protocol under three fault
// regimes (clean / crash / slow), then the saved replay artifact is
// re-verified against the recorded claim.

///|
fn reply(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
  // production behavior: always acknowledge, incrementing payload
  [{ from: node, to: msg.from, payload: msg.payload + 1, }]
}

///|
fn print_result(label : String, r : @sim.RunResult) -> Unit {
  println(
    "== \{label}: steps=\{r.steps} delivered=\{r.delivered} dropped=\{r.dropped} deferred=\{r.deferred}",
  )
  for line in r.trace {
    println("   " + line)
  }
}

///|
fn demos() -> Unit raise @sim.SimError {
  let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: 1, }]

  let clean = @sim.run_bounded(reply, initial, 42, 4, [])
  print_result("clean max_steps=4", clean)

  // node 1 goes down from step 2: the ack aimed back at it is dropped
  let crashed = @sim.run_bounded(reply, initial, 42, 100, [@sim.crash(1, 2)])
  print_result("crash node=1 from_step=2", crashed)

  // node 1 becomes slow from step 3: same ack keeps getting re-held ->
  // a visible slow-node livelock
  let slow = @sim.run_bounded(reply, initial, 42, 8, [@sim.delay(1, 3, 2)])
  print_result("delay node=1 from_step=3 hold=2", slow)

  // persist the crash scenario as a replay artifact and verify it
  let artifact = @sim.render_replay(
    "crash node=1 from_step=2",
    42,
    100,
    initial,
    [@sim.crash(1, 2)],
    crashed,
  )
  println("-- replay artifact (JSON) --")
  println(artifact)
  let verified = @sim.replay_verify(artifact, reply)
  println(
    "replay verified: steps=\{verified.steps} dropped=\{verified.dropped}",
  )
}

///|
fn main {
  let _ = demos() catch { e => println("demo failed: \{e.message()}") }
}
