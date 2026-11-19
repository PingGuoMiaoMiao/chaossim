// Virtual clock: an immutable counter advanced explicitly by the runner.
// Real time is never read, so a run's shape depends only on
// (seed, initial messages, fault plan). Timers keyed to this clock land in
// v0.2 (README roadmap).

///|
pub(all) struct VirtualClock {
  now : Int32
}

///|
pub fn VirtualClock::new(start : Int32) -> VirtualClock {
  { now: start, }
}

///|
/// Advance by a non-negative delta; negative deltas are ignored rather than
/// trapping, because shrunk fault plans may produce empty intervals.
pub fn VirtualClock::advance(
  self : VirtualClock,
  delta : Int32,
) -> VirtualClock {
  if delta > 0 {
    { now: self.now + delta, }
  } else {
    self
  }
}
