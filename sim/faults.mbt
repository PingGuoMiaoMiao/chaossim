// Fault vocabulary. A Fault is a struct with a string `kind` (not an enum)
// so the whole scenario round-trips through JSON unchanged — see
// docs/decisions.md D2. Construct via `crash`/`loss`/`delay`/`partition`;
// raw field combinations are validated by `check` at run time.

///|
pub suberror SimError {
  InvalidFault(String)
  ParseError(String)
  ReplayMismatch(String)
}

///|
/// Stable machine-readable tag (same shape as docmunch's FetchError::code).
pub fn SimError::code(self : SimError) -> String {
  match self {
    InvalidFault(_) => "invalid_fault"
    ParseError(_) => "parse_error"
    ReplayMismatch(_) => "replay_mismatch"
  }
}

///|
pub fn SimError::message(self : SimError) -> String {
  match self {
    InvalidFault(m) => "invalid fault plan: \{m}"
    ParseError(m) => "replay artifact unreadable: \{m}"
    ReplayMismatch(m) => "replay diverged: \{m}"
  }
}

///|
#derive(ToJson, FromJson)
pub(all) struct Fault {
  /// "crash" | "loss" | "delay" | "partition"
  kind : String
  /// crash/delay: victim node. loss: sender. otherwise: -1.
  a : Int32
  /// loss: receiver. delay: hold length (steps). otherwise: -1.
  b : Int32
  group_a : Array[Int32]
  group_b : Array[Int32]
  /// First step at which this fault bites (1-based, must be >= 1).
  from_step : Int32
  /// Partition end step, inclusive; -1 means "until the run ends".
  /// Crash/loss/delay ignore this field.
  until : Int32
}

///|
pub extend Fault with ToJson::{to_json}

///|
pub extend Fault with FromJson::{from_json}

///|
/// Node `node` silently drops every message addressed to it from `from_step`.
pub fn crash(node : Int32, from_step : Int32) -> Fault {
  {
    kind: "crash",
    a: node,
    b: -1,
    group_a: [],
    group_b: [],
    from_step,
    until: -1,
  }
}

///|
/// The link `from` -> `to` goes dark from `from_step` onward.
pub fn loss(from : Int32, to : Int32, from_step : Int32) -> Fault {
  {
    kind: "loss",
    a: from,
    b: to,
    group_a: [],
    group_b: [],
    from_step,
    until: -1,
  }
}

///|
/// Messages to `node` are held `steps` scheduling steps before delivery.
/// The scheduler keeps ticking while a hold is pending (decisions.md D3).
pub fn delay(node : Int32, from_step : Int32, steps : Int32) -> Fault {
  {
    kind: "delay",
    a: node,
    b: steps,
    group_a: [],
    group_b: [],
    from_step,
    until: -1,
  }
}

///|
/// Cross-group messages are dropped from `from_step` to `until`
/// (`until < 0` means forever). Groups must be non-empty and disjoint.
pub fn partition(
  group_a : Array[Int32],
  group_b : Array[Int32],
  from_step : Int32,
  until : Int32,
) -> Fault {
  { kind: "partition", a: -1, b: -1, group_a, group_b, from_step, until, }
}

///|
fn in_group(group : Array[Int32], id : Int32) -> Bool {
  for g in group {
    if g == id {
      return true
    }
  }
  false
}

///|
fn groups_disjoint(x : Array[Int32], y : Array[Int32]) -> Bool {
  for a in x {
    if in_group(y, a) {
      return false
    }
  }
  true
}

///|
/// Rejects faults that cannot mean anything. Called by `run_bounded` before
/// the first step, so a bad scenario fails fast instead of silently doing
/// nothing for 10k steps.
pub fn check(f : Fault) -> Unit raise SimError {
  if f.from_step < 1 {
    raise InvalidFault(
      "from_step must be >= 1, got \{f.from_step} (kind=\{f.kind})",
    )
  }
  match f.kind {
    "crash" => if f.a < 0 { raise InvalidFault("crash needs a node id >= 0") }
    "loss" =>
      if f.a < 0 || f.b < 0 || f.a == f.b {
        raise InvalidFault("loss needs distinct from/to node ids >= 0")
      }
    "delay" =>
      if f.a < 0 || f.b < 1 {
        raise InvalidFault("delay needs node id >= 0 and hold length >= 1")
      }
    "partition" => {
      if f.group_a.length() == 0 || f.group_b.length() == 0 {
        raise InvalidFault("partition needs two non-empty groups")
      }
      if !groups_disjoint(f.group_a, f.group_b) {
        raise InvalidFault("partition groups must be disjoint")
      }
    }
    k => raise InvalidFault("unknown fault kind: \{k}")
  }
}

///|
/// True when this fault currently bites the message `msg` at `steps`.
fn bites(f : Fault, steps : Int32, msg : Msg) -> Bool {
  if steps < f.from_step {
    return false
  }
  match f.kind {
    "crash" => f.a == msg.to
    "loss" => f.a == msg.from && f.b == msg.to
    "delay" => f.a == msg.to
    "partition" => {
      let cross = (in_group(f.group_a, msg.from) && in_group(f.group_b, msg.to)) ||
        (in_group(f.group_b, msg.from) && in_group(f.group_a, msg.to))
      cross && (f.until < 0 || steps <= f.until)
    }
    _ => false
  }
}

///|
/// First fault that bites, in list order (explicit precedence for callers).
fn first_biting(faults : Array[Fault], steps : Int32, msg : Msg) -> Fault? {
  for f in faults {
    if bites(f, steps, msg) {
      return Some(f)
    }
  }
  None
}
