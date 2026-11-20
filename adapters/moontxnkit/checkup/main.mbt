// Report generator for the transactional target.
// `moon run adapters/moontxnkit/checkup --target native`

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
fn main {
  let items = @adapter.battery()
  println("# 协议库体检报告：black-duck666/moontxnkit")
  println("")
  println("> 第二个域：不是消息中间件，而是 MVCC 事务引擎。问题是隔离、冲突检测、历史与回滚。")
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
  println("## 这一份与 broker 那份的关系")
  println("")
  println("检查项完全重写（域不同），但形状相同：准备状态 → 触发一次操作 → 把事实交给纯判定函数。")
  println("判定函数与观测分开，所以每一条都能用故意给错的输入验证会报 RISK（`moon test`）。")
}
