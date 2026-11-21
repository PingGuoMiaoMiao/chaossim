// Invariant hooks: run predicates after every scheduling step, not only at the end.
//
// Why this exists: a scenario that ends correctly can still pass through broken
// intermediate states, and an assertion only checked at the end cannot see them.
// A hook is called after each delivered step with the state so far, so the first
// violation is reported with the step number that produced it.
//
// Design notes, deliberately narrow:
//   * a hook is a plain function of the observable state, not of the simulator
//     internals, so a hook cannot depend on how many steps remain;
//   * hooks do not stop the run by default: a scenario keeps going so the trace
//     shows the whole aftermath, and every violation is collected, not just the
//     first;
//   * a hook that raises is treated as a violation carrying its message - the
//     alternative (silently ignoring it) would hide exactly the failure it was
//     meant to catch.

///|
/// What a hook may look at after each step.
pub(all) struct StepView {
  /// scheduling step that just completed, 1-based
  step : Int32
  /// messages delivered so far
  delivered : Int32
  /// messages dropped so far
  dropped : Int32
  /// messages still deferred
  deferred : Int32
  /// the trace line produced by this step
  line : String
}

///|
/// A hook returns nothing when the state is acceptable, or a short description of
/// the violated invariant. It cannot mutate the run.
pub type Hook = (StepView) -> String?

///|
/// One recorded violation.
pub(all) struct Violation {
  step : Int32
  /// the hook's description
  what : String
  /// the trace line that produced the state
  line : String
}

///|
/// Built-in hooks. Each is a property that must hold at EVERY step.
///
/// Delivery-independent by construction: none of them asserts that a particular
/// message arrives, because under faults it must not.
pub fn accounting_never_negative() -> Hook {
  fn(v) {
    if v.delivered < 0 || v.dropped < 0 || v.deferred < 0 {
      Some("counter went negative: delivered=\{v.delivered} dropped=\{v.dropped}")
    } else {
      None
    }
  }
}

///|
/// Every step must account for exactly one message: it was either delivered or
/// dropped. This is the invariant that catches "a message vanished".
pub fn each_step_accounts_one() -> Hook {
  fn(v) {
    if v.delivered + v.dropped != v.step {
      Some(
        "step \{v.step}: delivered \{v.delivered} + dropped \{v.dropped} != \{v.step}",
      )
    } else {
      None
    }
  }
}

///|
/// A trace line must be non-empty, so a silent step cannot hide behind the counters.
pub fn no_silent_step() -> Hook {
  fn(v) {
    if v.line == "" {
      Some("step \{v.step}: no trace line")
    } else {
      None
    }
  }
}

///|
/// Run a hook after each step against a recorded trace.
///
/// This is the offline form: given a `RunResult`, replay the counters and call the
/// hook at every step. It needs no cooperation from the simulator loop, which
/// keeps `run_bounded` unchanged.
pub fn check_steps(r : RunResult, hooks : Array[Hook]) -> Array[Violation] {
  let out : Array[Violation] = []
  let mut delivered = 0
  let mut dropped = 0
  let mut step = 0
  for line in r.trace {
    step = step + 1
    if line.has_prefix("drop") {
      dropped = dropped + 1
    } else if line.has_prefix("send") {
      delivered = delivered + 1
    }
    // deferred messages are those the trace marks as parked
    let deferred = if line.contains("defer") {
      1
    } else {
      0
    }
    let view : StepView = {
      step,
      delivered,
      dropped,
      deferred,
      line,
    }
    for hook in hooks {
      match hook(view) {
        Some(what) => out.push({ step, what, line })
        None => ()
      }
    }
  }
  out
}

///|
pub fn describe_violations(vs : Array[Violation]) -> String {
  if vs.length() == 0 {
    return "no invariant violations"
  }
  let mut s = "\{vs.length()} violation(s):"
  for v in vs {
    s = s + "\n  step \{v.step}: \{v.what}   [\{v.line}]"
  }
  s
}
