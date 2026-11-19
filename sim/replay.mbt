// Replay artifacts (v0.2 deliverable: trace persistence + byte-identical
// re-run). A Replay embeds BOTH sides: the scenario (seed, initial, faults)
// and the result it produced. `replay_verify` recomputes with the caller's
// handler and diffs against the recorded trace — so a saved artifact is an
// executable claim about a code path, not just a log (decisions.md D4).
//
// v0 keeps artifacts as JSON strings (the caller writes/reads files); this
// keeps the sim pure and makes unit-testing the verifier trivial.

///|
#derive(ToJson, FromJson)
pub(all) struct Replay {
  /// free-form name so issue threads can carry several artifacts
  label : String
  seed : Int32
  max_steps : Int32
  initial : Array[Msg]
  faults : Array[Fault]
  result : RunResult
}

///|
pub extend Replay with ToJson::{to_json}

///|
pub extend Replay with FromJson::{from_json}

///|
pub fn render_replay(
  label : String,
  seed : Int32,
  max_steps : Int32,
  initial : Array[Msg],
  faults : Array[Fault],
  result : RunResult,
) -> String {
  let sc : Replay = { label, seed, max_steps, initial, faults, result, }
  @json.to_json(sc).stringify()
}

///|
fn diff_lines(want : Array[String], got : Array[String]) -> String {
  if want.length() != got.length() {
    return "trace length \{want.length()} != \{got.length()}"
  }
  for i = 0; i < want.length(); i = i + 1 {
    if want[i] != got[i] {
      return "first diff at line \{i}: recorded `\{want[i]}` != replayed `\{got[i]}`"
    }
  }
  ""
}

///|
/// Re-run the recorded scenario with `handler` and compare against the
/// recorded result. Raises `ParseError` on malformed artifacts and
/// `ReplayMismatch` when the replay diverges (the handler changed, or the
/// sim did — either way, that is exactly the information you file an issue
/// with).
pub fn replay_verify(
  text : String,
  handler : Handler,
) -> RunResult raise SimError {
  let parsed = @json.parse(text) catch {
    e => raise ParseError("not JSON: \{e.to_string()}")
  }
  let sc : Replay = @json.from_json(parsed) catch {
    e => raise ParseError("not a Replay: \{e.to_string()}")
  }
  let again = run_bounded(handler, sc.initial, sc.seed, sc.max_steps, sc.faults)
  let line_diff = diff_lines(sc.result.trace, again.trace)
  if line_diff != "" {
    raise ReplayMismatch("\{sc.label}: \{line_diff}")
  }
  // counters must agree too; identical traces with different tallies would
  // mean the runner miscounts, which is a kernel bug worth surfacing
  if sc.result.steps != again.steps {
    raise ReplayMismatch(
      "\{sc.label}: steps \{sc.result.steps} != \{again.steps}",
    )
  }
  if sc.result.delivered != again.delivered {
    raise ReplayMismatch(
      "\{sc.label}: delivered \{sc.result.delivered} != \{again.delivered}",
    )
  }
  if sc.result.dropped != again.dropped {
    raise ReplayMismatch(
      "\{sc.label}: dropped \{sc.result.dropped} != \{again.dropped}",
    )
  }
  if sc.result.deferred != again.deferred {
    raise ReplayMismatch(
      "\{sc.label}: deferred \{sc.result.deferred} != \{again.deferred}",
    )
  }
  again
}
