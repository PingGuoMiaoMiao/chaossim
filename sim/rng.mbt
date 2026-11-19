// Seeded state for the scheduler, as pure functions (no &mut receivers —
// the docmunch-era house style, and it keeps replay reasoning trivial).
// xorshift32: tiny, deterministic, identical on native/wasm/js backends.
// Output bits are masked to 31 bits so `%` never sees a negative value.

///|
/// One mixing step; the returned value IS the next state.
pub fn next_state(state : Int32) -> Int32 {
  let x = (state ^ 0x5DEECE66) | 1 // never zero: xorshift32 absorbs 0
  let a = x ^ (x << 13)
  let b = a ^ (a >> 9)
  let c = b ^ (b << 7)
  c
}

///|
/// Pick an index in `0..<bound` and advance the seed. `bound <= 1`
/// short-circuits so single-element queues cost no division.
pub fn pick(seed : Int32, bound : Int32) -> (Int32, Int32) {
  if bound <= 1 {
    (0, seed)
  } else {
    let s = next_state(seed)
    ((s & 0x7FFF_FFFF) % bound, s)
  }
}
