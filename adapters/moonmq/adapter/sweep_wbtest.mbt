// Ordering sweep: two concurrent clients against one real broker, many seeds.
//
// The audit probes call the API in a fixed order; ordering effects need
// interleavings, which is what chaossim is for. Both clients pull from the same
// queue; the seed decides whose operation reaches the broker first, and faults
// decide which replies are lost.

///|
test "ordering sweep: no duplicate delivery, no cross-client ack, accounting closes" {
  let fault_sets : Array[Array[@sim.Fault]] = [
    [],
    [@sim.loss(1, 0, 2)],
    [@sim.loss(1, 2, 2)],
    [@sim.delay(1, 1, 2)],
  ]
  let mut runs = 0
  let mut bad = 0
  let mut first = ""
  // kind 0: get/ack rounds. kind 1: get/reject(requeue)/ack rounds - a requeue
  // while the other client is pulling is the sharpest duplicate-delivery probe.
  for kind = 0; kind <= 1; kind = kind + 1 {
    for f in fault_sets {
      for seed = 1; seed <= 40; seed = seed + 1 {
        let w = sweep(seed, 60, f, 3, 4, kind)
        runs = runs + 1
        if w.violations.length() > 0 {
          bad = bad + 1
          if first == "" {
            first = w.violations[0]
          }
        }
      }
    }
  }
  println(
    "sweep: \{runs} runs (2 script kinds x 4 fault sets x 40 seeds), \{bad} with violations",
  )
  if first != "" {
    println("  first violation: " + first)
  }
  assert_eq(bad, 0)
}
