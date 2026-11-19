// Transcript demo: QoS1/QoS2 fault regimes for one client, then the
// dual-client lane cut. Counters are printed as they actually ended; the
// mid-session isolation row exists to SHOW the interleaving, its exact
// outcome per seed is asserted nowhere - the suite in adapter_wbtest only
// pins the seed-independent classes (D8 discipline).

///|
fn counters(node : Int32, s : @adapter.Scenario) -> String {
  "node\{node}: issued=\{@adapter.issued_of(s.world, node)}" +
  " acks=\{@adapter.acks_of(s.world, node)}" +
  " inflight=\{@adapter.inflight(s.world, node)}" +
  " matches=\{@adapter.inflight_matches(s.world, node)}"
}

///|
fn show(label : String, s : @adapter.Scenario) -> Unit {
  let r = s.result
  println("== \{label}")
  for line in r.trace {
    println("   " + line)
  }
  println(
    "   dropped=\{r.dropped} deferred=\{r.deferred}" +
    " bad_events=\{s.world.bad_events}",
  )
  println("   " + counters(0, s))
}

///|
fn show_two(label : String, s : @adapter.Scenario) -> Unit {
  let r = s.result
  println("== \{label}")
  for line in r.trace {
    println("   " + line)
  }
  println(
    "   dropped=\{r.dropped} bad_events=\{s.world.bad_events}" +
    " all_drained=\{@adapter.all_drained(s.world)}",
  )
  println("   " + counters(0, s))
  println("   " + counters(2, s))
}

///|
fn demos() -> Unit raise @sim.SimError {
  show("qos1 clean", @adapter.run_scenario(7, 20, []))
  show(
    "qos1 ack loss from step 3",
    @adapter.run_scenario(7, 20, [@sim.loss(1, 0, 3)]),
  )
  show("qos2 full handshake", @adapter.run_scenario_ex(7, 30, [], 2, 1))
  show(
    "qos2 pubcomp loss (stalls in WaitPubcomp)",
    @adapter.run_scenario_ex(7, 30, [@sim.loss(1, 0, 6)], 2, 1),
  )

  show_two("dual clients, clean wire", @adapter.run_multi(7, 60, [], 1, 1, 2))
  show_two(
    "partition([0]|[1]) from step 1: lane cut",
    @adapter.run_multi(7, 60, [@sim.partition([0], [1], 1, -1)], 1, 1, 2),
  )
  show_two(
    "partition([0]|[1]) from step 5: isolation lands mid-session (illustrative)",
    @adapter.run_multi(7, 60, [@sim.partition([0], [1], 5, -1)], 2, 1, 2),
  )

  let rec = @adapter.run_recovery(7, 30, [@sim.loss(1, 0, 3)])
  println("== recovery: phase A (ack lost) then reconnect + replay")
  println("   phase A:")
  for line in rec.phase_a.trace {
    println("     " + line)
  }
  println("   phase B:")
  for line in rec.result.trace {
    println("     " + line)
  }
  println(
    "   connects=\{@adapter.connects_of(rec.world, 0)} replays=\{rec.world.replays}" +
    " dups=\{rec.world.dups} inflight=\{@adapter.inflight(rec.world, 0)}" +
    " reconciled=\{@adapter.inflight_matches(rec.world, 0)}",
  )

  let r2 = @adapter.run_recovery_ex(7, 40, [@sim.loss(1, 0, 6)], 2)
  println("== recovery QoS2: PUBCOMP lost -> PUBREL replayed (not PUBLISH)")
  println("   phase A:")
  for line in r2.phase_a.trace {
    println("     " + line)
  }
  println("   phase B:")
  for line in r2.result.trace {
    println("     " + line)
  }
  println(
    "   connects=\{@adapter.connects_of(r2.world, 0)} replays=\{r2.world.replays}" +
    " replays_pubrel=\{r2.world.replays_pubrel} dups=\{r2.world.dups}" +
    " inflight=\{@adapter.inflight(r2.world, 0)}" +
    " reconciled=\{@adapter.inflight_matches(r2.world, 0)}",
  )

  let mut ok_seeds = 0
  for seed = 1; seed <= 6; seed = seed + 1 {
    let s = @adapter.run_multi(
      seed,
      60,
      [@sim.partition([0], [1], 1, -1)],
      1,
      1,
      2,
    )
    let a_ok = @adapter.inflight_matches(s.world, 0) &&
      @adapter.acks_of(s.world, 0) == 0
    let b_ok = @adapter.inflight_matches(s.world, 2) &&
      @adapter.acks_of(s.world, 2) == 1
    if a_ok && b_ok && @adapter.no_bad_events(s.world) {
      ok_seeds = ok_seeds + 1
    }
  }
  println(
    "lane-cut class across seeds 1..6: reconciled " +
    ok_seeds.to_string() +
    "/6",
  )
}

///|
fn main {
  let _ = demos() catch { e => println("demo failed: \{e.message()}") }
}
