// Transcript of the moonmq adapter: the same client script under three wires.
//
// `moon run adapters/moonmq/bin --target native`

///|
fn show(label : String, s : @adapter.Scenario) -> Unit {
  let w = s.world
  println("== \{label}")
  println("   " + @adapter.describe(w))
  println(
    "   invariants: I1=\{@adapter.i1_no_acked_tag_outstanding(w)} I3=\{@adapter.i3_accounting_closes(w)} bad_events=\{w.bad.length()}",
  )
  for line in s.result.trace {
    println("   " + line)
  }
}

///|
fn main {
  let two : Array[Int32] = [
    @adapter.op_get, @adapter.op_ack, @adapter.op_get, @adapter.op_ack, @adapter.op_delete_probe,
  ]
  // 1) clean wire
  let clean = @adapter.run_script(42, 40, [], 2, two) catch {
    e => {
      println("failed: \{e.message()}")
      return
    }
  }
  show("clean wire, 2 messages", clean)

  // 2) the broker's replies are lost: the client never learns a tag
  let lost = @adapter.run_script(42, 40, [@sim.loss(1, 0, 1)], 2, two) catch {
    e => {
      println("failed: \{e.message()}")
      return
    }
  }
  show("broker replies lost from step 1", lost)

  // 3) the broker itself is down
  let down = @adapter.run_script(42, 40, [@sim.crash(1, 1)], 2, two) catch {
    e => {
      println("failed: \{e.message()}")
      return
    }
  }
  show("broker down from step 1", down)

  // 4) reject-with-requeue: the message must come back, not vanish
  let requeue : Array[Int32] = [
    @adapter.op_get, @adapter.op_reject, @adapter.op_get,
  ]
  let back = @adapter.run_script(42, 40, [], 1, requeue) catch {
    e => {
      println("failed: \{e.message()}")
      return
    }
  }
  show("reject(requeue=true) then get again", back)
  println(
    "== note: message_count reports ready messages only (measured, not assumed)",
  )
}
