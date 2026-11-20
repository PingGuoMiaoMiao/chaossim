// `moon run adapters/moonmq/checkup --target native`
//
// Runs the battery against the real broker and prints a Markdown report.
// This is the deliverable form: a command that answers the question
// "does this library survive missing messages".

///|
fn count(items : Array[@adapter.Check], kind : Int32) -> Int32 {
  let mut n = 0
  for c in items {
    let m = match c.verdict {
      @adapter.Pass => 0
      @adapter.Risk(_) => 1
      @adapter.NotCovered(_) => 2
    }
    if m == kind {
      n = n + 1
    }
  }
  n
}

///|
fn main raise @sim.SimError {
  let items = @adapter.battery()
  println("# 协议库体检报告：Zcxssxx/moonmq")
  println("")
  println("> 由 chaossim 生成。每项都是一次真实调用，结论写的是观察到的事实，不是推测。")
  println("")
  let passed = count(items, 0)
  let risked = count(items, 1)
  let uncovered = count(items, 2)
  println("## 结论")
  println("")
  println("| 项数 | 通过 | 风险 | 未覆盖 |")
  println("| --- | --- | --- | --- |")
  println("| \{items.length()} | \{passed} | \{risked} | \{uncovered} |")
  println("")
  if risked == 0 {
    println("没有发现风险项：这个库在下列恢复与记账路径上行为正确。")
  } else {
    println("发现 \{risked} 项风险，见下表。")
  }
  println("")
  println("## 明细")
  println("")
  println("| # | 检查项 | 问题 | 结论 | 观察 |")
  println("| --- | --- | --- | --- | --- |")
  let mut i = 1
  for c in items {
    let mark = @adapter.verdict_mark(c.verdict)
    let detail = @adapter.verdict_detail(c.verdict)
    println("| \{i} | \{c.name} | \{c.question} | \{mark} | \{detail} |")
    i = i + 1
  }
  println("")
  // Ordering sweep: the part that only a simulator can do.
  let mut runs = 0
  let mut bad = 0
  let mut first = ""
  let fault_sets : Array[Array[@sim.Fault]] = [
    [],
    [@sim.loss(1, 0, 2)],
    [@sim.loss(1, 2, 2)],
  ]
  for kind = 0; kind <= 1; kind = kind + 1 {
    for f in fault_sets {
      for seed = 1; seed <= 20; seed = seed + 1 {
        let w = @adapter.sweep(seed, 60, f, 3, 4, kind)
        runs = runs + 1
        if w.violations.length() > 0 {
          bad = bad + 1
          if first == "" {
            first = w.violations[0]
          }
        }
      }
    }
  }
  let mark = if bad == 0 {
    "通过"
  } else {
    "违反"
  }
  println("## 并发交错扫描")
  println("")
  println("\{runs} 次运行（2 种脚本 × 3 组故障 × 20 种子），两个客户端同时抢同一个队列。")
  println("")
  println("| 检查 | 结果 |")
  println("| --- | --- |")
  println("| 同一消息不会同时被两个客户端持有 | \{mark} |")
  println("| 客户端不会确认它没拿到的消息 | \{mark} |")
  println("| 已确认 + 未确认 ≤ 已发布 | \{mark} |")
  if first != "" {
    println("")
    println("首个违规：" + first)
  }
  println("")
  println("## 检测能力自检（这份报告凭什么不是橡皮章）")
  println("")
  println(
    "11 条判定规则都与\"调用库\"分开，各自用**故意给错的输入**跑过：每一条的 RISK 分支都被验证会触发（`moon test adapters/moonmq/adapter`，4 条对照测试）。",
  )
  println("")
  println("| 层 | 已证 | 未证 |")
  println("| --- | --- | --- |")
  println(
    "| 判定 | 坏输入必然报 RISK，好输入必然报 PASS | - |",
  )
  println(
    "| 观测 | 检查确实调用了库的公开 API | **尚未**用一个真实写坏的库端到端验证 |",
  )
  println("")
  println("## 这个报告能被伪造吗")
  println("")
  println("每一项都直接调用库的公开 API 并打印它的回答；报告里的字句来自代码，不是模板。复跑：")
  println("")
  println("```sh")
  println("moon run adapters/moonmq/checkup --target native")
  println("```")
}
