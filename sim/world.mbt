// v0.2 kernel: bounded deterministic message-delivery runner with a fault
// list. The subject is a `Handler` — `(node, msg) -> outgoing messages` —
// the real protocol function, not a model rewrite. The runner owns delivery
// order (seeded `pick`), time (monotonic step ticks), and liveness (faults:
// crash / loss / partition drop, delay holds). The handler stays pure with
// respect to the simulation.

///|
#derive(ToJson, FromJson)
pub(all) struct Msg {
  from : Int32
  to : Int32
  payload : Int32
}

///|
pub extend Msg with ToJson::{to_json}

///|
pub extend Msg with FromJson::{from_json}

///|
pub type Handler = (Int32, Msg) -> Array[Msg]

///|
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct RunResult {
  steps : Int32
  delivered : Int32
  dropped : Int32
  /// messages held by a delay fault (counted once per hold scheduling)
  deferred : Int32
  /// One line per event; replaying with the same scenario must produce an
  /// element-wise identical vector (see sim/replay.mbt).
  trace : Array[String]
}

///|
pub extend RunResult with Eq::{not_equal, equal}

///|
pub extend RunResult with Debug::{to_repr}

///|
pub extend RunResult with ToJson::{to_json}

///|
pub extend RunResult with FromJson::{from_json}

///|
fn step_tag(steps : Int32, msg : Msg) -> String {
  "\{steps}: \{msg.from}->\{msg.to} #\{msg.payload}"
}

///|
/// Drop the picked message by rebuild: v0.2 trades O(queue) per step for a
/// dead-simple, backend-stable data structure. The measured swap to an
/// order-preserving vector rides along with the v0.3 timer work.
fn without_index(queue : Array[Msg], idx : Int32) -> Array[Msg] {
  let rest : Array[Msg] = []
  for i, m in queue {
    if i != idx {
      rest.push(m)
    }
  }
  rest
}

///|
/// Run until the queue and the hold set drain, or `max_steps` is hit.
/// Determinism contract: equal (handler behavior, initial, seed, faults)
/// implies equal `RunResult` — pinned by sim/world_wbtest.mbt and enforced
/// on demand by `replay_verify`.
/// Raises `SimError::InvalidFault` before stepping if any fault cannot mean
/// anything (decisions.md D1).
pub fn run_bounded(
  handler : Handler,
  initial : Array[Msg],
  seed : Int32,
  max_steps : Int32,
  faults : Array[Fault],
) -> RunResult raise SimError {
  for f in faults {
    check(f)
  }
  let mut seed = seed
  let mut queue : Array[Msg] = initial
  // (release_step, msg) pairs held by delay faults
  let mut held : Array[(Int32, Msg)] = []
  let trace : Array[String] = []
  let mut steps = 0
  let mut delivered = 0
  let mut dropped = 0
  let mut deferred = 0
  while (queue.length() > 0 || held.length() > 0) && steps < max_steps {
    steps = steps + 1
    // release due holds first, then pick; pure ticks are allowed (a step
    // with no event) so delay cannot stall the clock
    let keep : Array[(Int32, Msg)] = []
    for _i, rm in held {
      let (r, m) = rm
      if r <= steps {
        queue.push(m)
      } else {
        keep.push(rm)
      }
    }
    held = keep
    if queue.length() == 0 {
      continue
    }
    let (idx, seed_next) = pick(seed, queue.length())
    seed = seed_next
    let msg = queue[idx]
    queue = without_index(queue, idx)
    match first_biting(faults, steps, msg) {
      Some(f) =>
        if f.kind == "delay" {
          deferred = deferred + 1
          let release = steps + f.b
          held.push((release, msg))
          trace.push("delay " + step_tag(steps, msg) + " ->@\{release}")
        } else {
          dropped = dropped + 1
          let why = match f.kind {
            "loss" => " (loss)"
            "partition" => " (partition)"
            _ => ""
          }
          trace.push("drop " + step_tag(steps, msg) + why)
        }
      None => {
        delivered = delivered + 1
        trace.push("send " + step_tag(steps, msg))
        for out in handler(msg.to, msg) {
          queue.push(out)
        }
      }
    }
  }
  { steps, delivered, dropped, deferred, trace, }
}
