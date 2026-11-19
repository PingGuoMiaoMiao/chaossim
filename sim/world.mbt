// v0 kernel: a bounded, deterministic message-delivery runner with a crash
// plan. The subject is a `Handler` — `(node, msg) -> outgoing messages` —
// the real protocol function, not a model rewrite. The runner owns delivery
// order (seeded `pick`) and liveness (crash plan); the handler stays pure
// with respect to the simulation.

///|
#derive(Eq, Debug)
pub(all) struct Msg {
  from : Int32
  to : Int32
  payload : Int32
}

///|
pub type Handler = (Int32, Msg) -> Array[Msg]

///|
/// From `from_step` onward, messages addressed to `node` are silently
/// dropped (the node is "down"). v0.2 adds drop/partition plans of this shape.
#derive(Eq, Debug)
pub(all) struct CrashPlan {
  node : Int32
  from_step : Int32
}

///|
#derive(Eq, Debug)
pub(all) struct RunResult {
  steps : Int32
  delivered : Int32
  dropped : Int32
  /// One line per step; replaying with the same seed must produce an
  /// element-wise identical vector.
  trace : Array[String]
}

///|
pub extend Msg with Eq::{not_equal, equal}

///|
pub extend Msg with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend CrashPlan with Eq::{not_equal, equal}

///|
pub extend CrashPlan with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RunResult with Eq::{not_equal, equal}

///|
pub extend RunResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Summarize one step for the trace, shared by both delivery outcomes.
fn step_tag(steps : Int32, msg : Msg) -> String {
  "\{steps}: \{msg.from}->\{msg.to} #\{msg.payload}"
}

///|
/// Run until the in-flight queue drains or `max_steps` is hit.
/// Determinism contract: equal (handler behavior, initial, seed, plan)
/// implies equal `RunResult.trace` — asserted by sim/world_test.mbt and
/// relied on for issue-reproducing replays.
pub fn run_bounded(
  handler : Handler,
  initial : Array[Msg],
  seed : Int32,
  max_steps : Int32,
  plan : CrashPlan?,
) -> RunResult {
  let mut seed = seed
  let mut queue : Array[Msg] = initial
  let trace : Array[String] = []
  let mut steps = 0
  let mut delivered = 0
  let mut dropped = 0
  while queue.length() > 0 && steps < max_steps {
    let (idx, seed_next) = pick(seed, queue.length())
    seed = seed_next
    let msg = queue[idx]
    // remove the picked message by rebuild: v0 trades O(queue) per step for
    // a dead-simple, backend-stable data structure. Measured swap to an
    // order-preserving vector comes with the v0.2 timer work.
    let rest : Array[Msg] = []
    for i, m in queue {
      if i != idx {
        rest.push(m)
      }
    }
    queue = rest
    steps = steps + 1
    let crashed = match plan {
      Some(p) => p.node == msg.to && steps >= p.from_step
      None => false
    }
    if crashed {
      dropped = dropped + 1
      trace.push("drop " + step_tag(steps, msg))
    } else {
      delivered = delivered + 1
      trace.push("send " + step_tag(steps, msg))
      for out in handler(msg.to, msg) {
        queue.push(out)
      }
    }
  }
  { steps, delivered, dropped, trace, }
}
