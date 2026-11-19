// Kernel throughput report: `moon run cmd/perf --target native --release`
//
// Approaches tried and rejected, recorded so nobody repeats them:
//   1. `moon bench` did not discover these tests ("no test entry") and its
//      Summary type is package-private.
//   2. `@bench.Bench::bench` auto-calibrates iteration counts; on a cheap
//      workload it kept raising batches and ran for minutes. A CI-facing
//      report must have a bounded, predictable cost.
// So: explicit timing on core/env's clock over a fixed iteration count, with
// counts chosen so each window is >= ~0.3 s (the clock is 1 ms, so that keeps
// quantisation under ~0.3%).
//
// What is measured: the SIM KERNEL only - seeded scheduling, fault evaluation
// and trace building. That is what every adapter pays per scheduled message;
// adapter cost (real protocol encode/decode) belongs to the target library.
//
// Measurement pitfalls hit while writing this, both fixed:
//   - the first workload (a ping-pong that drained after 4 steps) made all
//     three labels measure identical work, producing self-contradictory
//     numbers;
//   - a loss fault then truncated the message chain, so runs ended after 3
//     steps regardless of max_steps. Hence: baseline runs use no faults, and
//     fault-checking cost is measured separately as a delta.

///|
fn saturate(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
  // every delivery produces exactly one new message: a run for max_steps
  // really does max_steps scheduling steps
  [{ from: node, to: (msg.from + 1) % 2, payload: (msg.payload + 1) % 1000, }]
}

///|
fn one_run(
  seed : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
) -> Int32 {
  let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: 0, }]
  let r = @sim.run_bounded(saturate, initial, seed, max_steps, faults) catch {
    _ => return -1
  }
  // derive a value from the result so the work cannot be optimised away
  r.steps * 1000 + r.dropped
}

///|
fn measure(
  label : String,
  iterations : Int32,
  max_steps : Int32,
  faults : Array[@sim.Fault],
) -> Unit {
  for i = 0; i < 50; i = i + 1 {
    ignore(one_run(i, max_steps, faults))
  }
  let mut checksum : Int64 = 0
  let start = @env.now()
  for i = 0; i < iterations; i = i + 1 {
    checksum = checksum + one_run(i % 1000, max_steps, faults).to_int64()
  }
  let elapsed : UInt64 = @env.now() - start
  let runs : UInt64 = iterations.to_uint64()
  let per_run_us : Double = if elapsed > 0UL {
    elapsed.to_double() * 1000.0 / runs.to_double()
  } else {
    0.0
  }
  let per_step_ns : Double = if elapsed > 0UL {
    elapsed.to_double() *
    1_000_000.0 /
    (runs.to_double() * max_steps.to_double())
  } else {
    0.0
  }
  println(
    "\{label}: \{iterations} runs x \{max_steps} steps in \{elapsed} ms" +
    " -> \{per_run_us} us/run, \{per_step_ns} ns/step  [checksum \{checksum}]",
  )
}

///|
fn main {
  println(
    "chaossim kernel throughput (build with --release; each window >= 0.3 s)",
  )
  measure("short      ", 200_000, 4, [])
  measure("medium     ", 50_000, 20, [])
  measure("long       ", 5_000, 200, [])
  // four faults, none of which truncate the chain: cost of fault evaluation
  let faults : Array[@sim.Fault] = [
    @sim.crash(9, 1),
    @sim.loss(7, 8, 1),
    @sim.delay(9, 1, 2),
    @sim.partition([9], [8], 1, -1),
  ]
  measure("medium+4f  ", 50_000, 20, faults)
  println(
    "budget: a 1000-seed sweep at the medium shape costs 1000 x the medium" +
    " us/run above - that is the number to put in a CI budget",
  )
}
