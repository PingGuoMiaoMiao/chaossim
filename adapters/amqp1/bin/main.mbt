// Transcript: one AMQP 1.0 message cycle, clean and under wire faults.
// Prints the accounting invariants after each run so a reader can check
// them by hand: credit is spent by send() regardless of delivery, and a
// lost frame must leave the endpoints accounted for rather than broken.

///|
fn show(label : String, s : @src.Scenario, granted : Int32) -> Unit {
  let w = s.world
  println("== \{label}")
  for line in s.result.trace {
    println("   " + line)
  }
  let (out_pending, in_pending) = w.app.pending()
  println(
    "   sends=\{w.sends} received=\{w.received} settled=\{w.settled}" +
    " pending=(\{out_pending}, \{in_pending})",
  )
  println(
    "   credit_accounted=\{@src.credit_accounted(w, granted)}" +
    " bad_events=\{w.bad_events}",
  )
}

///|
fn demos() -> Unit raise {
  let clean = @src.run_message_cycle(7, 40, [])
  show("clean wire", clean, 1)

  let lost = @src.run_message_cycle(7, 40, [@sim.loss(0, 1, 1)])
  show("transfer lost (0->1 from step 1)", lost, 1)

  let settled_lost = @src.run_message_cycle(7, 40, [@sim.loss(1, 0, 2)])
  show("settlement lost (1->0 from step 2)", settled_lost, 1)

  let slow = @src.run_message_cycle(7, 40, [@sim.delay_window(1, 2, 3, 6)])
  show("service slow by 3 steps until step 6", slow, 1)
}

///|
fn main {
  let _ = demos() catch { e => println("demo failed: \{e.to_string()}") }
}
