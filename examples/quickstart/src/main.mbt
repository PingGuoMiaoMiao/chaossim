// Minimal, runnable chaossim example: `moon run app/src`
//
// The handler below stands in for "your real code". It is called once per
// delivered message and returns whatever that node wants to send next.
// Note it is a plain function: no model, no re-implementation of your protocol.

///|
/// The system under test.
/// `node` is the id of the node that received `msg` (same as `msg.to`).
fn handler(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
  // A two-node handshake: node 0 sends REQ, node 1 answers ACK, node 0 stops.
  if node == 0 && msg.payload == 1 {
    // got the request; reply once and stop
    []
  } else if node == 0 {
    []
  } else {
    // node 1: acknowledge and bump the counter
    [{ from: node, to: msg.from, payload: msg.payload + 1, }]
  }
}

///|
fn show(label : String, r : @sim.RunResult) -> Unit {
  println(
    "== \{label}: steps=\{r.steps} delivered=\{r.delivered} dropped=\{r.dropped}",
  )
  for line in r.trace {
    println("   " + line)
  }
}

///|
fn main {
  let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: 1, }]

  // 1) one clean run
  let clean = @sim.run_bounded(handler, initial, 42, 20, []) catch {
    e => {
      println("failed: \{e.message()}")
      return
    }
  }
  show("clean", clean)

  // 2) same run with a fault: node 1 is down from step 2
  // from step 1, so the very first delivery to node 1 is dropped
  let faults : Array[@sim.Fault] = [@sim.crash(1, 1)]
  let crashed = @sim.run_bounded(handler, initial, 42, 20, faults) catch {
    e => {
      println("failed: \{e.message()}")
      return
    }
  }
  show("crash node=1 from step 1", crashed)

  // 3) seed sweep: the same code under many delivery orders.
  //    Anything that only breaks under some interleaving shows up here.
  let mut clean_runs = 0
  for seed = 1; seed <= 50; seed = seed + 1 {
    let r = @sim.run_bounded(handler, initial, seed, 20, []) catch {
      _ => continue
    }
    if r.dropped == 0 {
      clean_runs = clean_runs + 1
    }
  }
  println("seed sweep 1..50: \{clean_runs} runs with zero drops")

  // 4) save a replay artifact and prove it re-runs identically
  let art = @sim.render_replay("crash demo", 42, 20, initial, faults, crashed)
  println("replay bytes=\{art.length()}")
  let again = @sim.replay_verify(art, handler) catch {
    e => {
      println("replay failed: \{e.message()}")
      return
    }
  }
  println("replay verified: steps=\{again.steps} dropped=\{again.dropped}")
}
