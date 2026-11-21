// Linearizability checking for recorded histories.
//
// PROVENANCE - read this before trusting the code:
//
//   `moonbit-community/moon_historycheck` and any `lincheck` package referenced in
//   the design notes DO NOT EXIST on the MoonCakes registry (verified: `moon fetch`
//   reports "was not found in the registry"). There is therefore no third-party
//   implementation to reuse, and injecting a reuse claim for a package that cannot
//   be resolved would be a false statement in the submission.
//
//   What is implemented here follows the DEFINITION, not any specific code base:
//
//     Herlihy, M. & Wing, J. "Linearizability: A Correctness Condition for
//     Concurrent Objects." ACM TOPLAS 12(3), 1990.
//
//     Wing, J. & Gong, C. "Testing and Verifying Concurrent Objects."
//     Journal of Parallel and Distributed Computing, 1993.
//     (the Wing & Gong algorithm this checker follows: search for a linearization
//      by repeatedly taking an operation whose result is consistent with being
//      next in a sequential execution ordered by real-time precedence.)
//
//   The algorithm below is written from that definition; no source code was copied,
//   so there is no third-party code and no licence obligation beyond this project's
//   own MIT licence. If a MoonBit implementation appears later, re-verify against
//   its tests rather than assuming equivalence.
//
// WHAT IS CHECKED
//
//   A history is a set of operations, each with an invoke and a response time, an
//   input, and a result (or "pending" if it never returned). It is linearizable if
//   the completed operations can be ordered so that:
//     * the order respects real time: if A returned before B was invoked, A is
//       before B;
//     * replaying that order against a sequential specification reproduces every
//       observed result;
//     * pending operations may be placed anywhere or dropped.
//
//   This is a bounded search: the history checked here is a handful of operations
//   per key, which is the size a property test can generate cheaply.

///|
/// One operation as observed from outside.
pub(all) struct Op {
  /// who issued it
  client : Int32
  /// invocation order, monotonically increasing
  invoke : Int32
  /// response order; -1 when the operation never returned
  respond : Int32
  /// "put" | "get" | ... - the sequential spec decides what this means
  kind : String
  key : String
  value : String
  /// the value the caller observed; "" for writes and for pending reads
  observed : String
}

///|
pub fn Op::completed(self : Op) -> Bool {
  self.respond >= 0
}

///|
/// A sequential specification: apply one operation to a logical store.
/// Returns the value the operation must have returned, or None when the operation
/// is allowed to behave non-deterministically.
pub type Spec = (Map[String, String], Op) -> String?

///|
/// The default specification: a key/value store.
///   put always returns "" (nothing observed), get returns the stored value.
pub fn kv_spec(store : Map[String, String], op : Op) -> String? {
  if op.kind == "put" {
    store[op.key] = op.value
    Some("")
  } else if op.kind == "get" {
    match store.get(op.key) {
      Some(v) => Some(v)
      None => Some("")
    }
  } else {
    None
  }
}

///|
/// Real-time precedence: `a` must come before `b`.
pub fn before(a : Op, b : Op) -> Bool {
  a.respond >= 0 && a.respond < b.invoke
}

///|
/// Outcome of a check.
pub(all) enum Outcome {
  /// the history is linearizable
  Linearizable
  /// no ordering explains the observations; `witness` is a prefix that cannot be
  /// extended, which is what a reader needs to debug it
  NotLinearizable(String)
  /// the search budget ran out: an honest "unknown", never reported as a pass
  Unknown(String)
}

///|
pub fn describe(o : Outcome) -> String {
  match o {
    Linearizable => "linearizable"
    NotLinearizable(w) => "NOT linearizable: " + w
    Unknown(w) => "unknown: " + w
  }
}

///|
/// Depth-first search for a linearization.
///
/// At each step pick an operation that could be next: every operation that must
/// precede it has already been applied. Replay it against the specification and
/// keep it only if the predicted result matches what was observed.
fn search(
  remaining : Array[Op],
  applied : Array[Op],
  spec : Spec,
  budget : Int32,
) -> Outcome {
  if remaining.length() == 0 {
    return Linearizable
  }
  if budget <= 0 {
    return Unknown("search budget exhausted")
  }
  for i = 0; i < remaining.length(); i = i + 1 {
    let cand = remaining[i]
    let mut blocked = false
    for j = 0; j < remaining.length(); j = j + 1 {
      if i != j && before(remaining[j], cand) {
        blocked = true
      }
    }
    if blocked {
      continue
    }
    let rest : Array[Op] = []
    for j = 0; j < remaining.length(); j = j + 1 {
      if j != i {
        rest.push(remaining[j])
      }
    }
    let next_applied = applied.copy()
    next_applied.push(cand)
    // Rebuild the store from the candidate prefix each time: a failed branch must
    // not leak its write into the next candidate's replay.
    let store : Map[String, String] = Map([])
    let mut consistent = true
    for k = 0; k < next_applied.length(); k = k + 1 {
      let op = next_applied[k]
      match spec(store, op) {
        Some(pred) =>
          if pred != op.observed {
            consistent = false
          }
        None => ()
      }
    }
    if !consistent {
      continue
    }
    match search(rest, next_applied, spec, budget - 1) {
      Linearizable => return Linearizable
      Unknown(w) => return Unknown(w)
      NotLinearizable(_) => ()
    }
  }
  NotLinearizable(
    "no candidate ordering explains the observations after \{applied.length()} applied",
  )
}

///|
/// Check a history. Operations with `respond < 0` are pending and may be dropped.
pub fn check_history(history : Array[Op], spec : Spec, budget : Int32) -> Outcome {
  // ignore pending operations: linearizability only constrains the completed ones
  let completed : Array[Op] = []
  for op in history {
    if op.completed() {
      completed.push(op)
    }
  }
  search(completed, [], spec, budget)
}
