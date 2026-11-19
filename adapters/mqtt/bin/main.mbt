// Transcript demo: the same scripted MQTT conversation under three fault
// regimes, with the reconciliation invariant printed after each run.

///|
fn show(label : String, s : @adapter.Scenario) -> Unit {
  let r = s.result
  println("== \{label}")
  for line in r.trace {
    println("   " + line)
  }
  println(
    "   counters: issued=\{s.world.issued} acks_delivered=\{s.world.acks_delivered}" +
    " inflight=\{s.world.core.session().inflight_count()}" +
    " dropped=\{r.dropped} deferred=\{r.deferred}",
  )
  println(
    "   inflight_matches=\{@adapter.inflight_matches(s.world)}" +
    " no_bad_events=\{@adapter.no_bad_events(s.world)}",
  )
}

///|
fn demos() -> Unit raise @sim.SimError {
  show("clean", @adapter.run_scenario(7, 20, []))
  show(
    "ack loss from step 3",
    @adapter.run_scenario(7, 20, [@sim.loss(1, 0, 3)]),
  )
  show(
    "ack delayed within window (slow to step 5, then healed)",
    @adapter.run_scenario(7, 20, [@sim.delay_window(0, 3, 2, 5)]),
  )
  show(
    "ack delayed forever (starvation)",
    @adapter.run_scenario(7, 20, [@sim.delay(0, 3, 2)]),
  )
}

///|
fn main {
  let _ = demos() catch { e => println("demo failed: \{e.message()}") }
}
