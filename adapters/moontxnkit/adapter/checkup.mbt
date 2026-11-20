// Checkup battery for a transactional engine (black-duck666/moontxnkit).
//
// Same shape as the broker battery - observe with the real library, judge with a
// pure rule - but different questions: isolation, conflict detection, history,
// compaction and abort. This is the second domain, and the reason it exists is to
// show the tool is not a broker-specific script.

///|
pub(all) enum Verdict {
  Pass
  Risk(String)
  NotCovered(String)
}

///|
pub(all) struct Check {
  name : String
  question : String
  verdict : Verdict
}

///|
fn judge(
  name : String,
  question : String,
  bad : Bool,
  why : String
) -> Check {
  if bad {
    { name, question, verdict: Risk(why) }
  } else {
    { name, question, verdict: Pass }
  }
}

///|
pub fn verdict_mark(v : Verdict) -> String {
  match v {
    Pass => "PASS"
    Risk(_) => "RISK"
    NotCovered(_) => "N/A"
  }
}

///|
pub fn verdict_detail(v : Verdict) -> String {
  match v {
    Pass => ""
    Risk(why) => why
    NotCovered(why) => why
  }
}

///|
pub fn battery() -> Array[Check] {
  let out : Array[Check] = []
  out.push(check_dirty_read())
  out.push(check_read_your_writes())
  out.push(check_write_conflict())
  out.push(check_version_per_commit())
  out.push(check_abort_leaves_nothing())
  out.push(check_snapshot_isolation())
  out.push(check_validate_clean())
  out.push(check_savepoint_rollback())
  out.push(check_delete_invisible())
  out.push(check_compact_keeps_current())
  out
}

///|
fn check_dirty_read() -> Check {
  let name = "脏读"
  let question = "未提交的写，外部能否读到"
  let e = @moontxnkit.Engine::new()
  let t = e.begin()
  let _ = t.put("k", "uncommitted")
  let visible = match e.get("k") {
    Some(_) => true
    None => false
  }
  judge(name, question, judge_dirty_read(visible), why_dirty_read(visible))
}

///|
fn check_read_your_writes() -> Check {
  let name = "读自己的写"
  let question = "同一事务内能否读到自己刚写的值"
  let e = @moontxnkit.Engine::new()
  let t = e.begin()
  let _ = t.put("k", "mine")
  let seen = match t.get("k") {
    Some(v) => v == "mine"
    None => false
  }
  judge(name, question, judge_read_your_writes(seen), why_read_your_writes(seen))
}

///|
fn check_write_conflict() -> Check {
  let name = "写写冲突"
  let question = "两个事务写同一 key，后提交者是否被拒绝"
  let e = @moontxnkit.Engine::new()
  let first = e.begin()
  let second = e.begin()
  let _ = first.put("k", "first")
  let _ = second.put("k", "second")
  let _ = first.commit()
  let second_committed = match second.commit() {
    @moontxnkit.CommitResult::CommittedAt(_) => true
    @moontxnkit.CommitResult::Rejected(_) => false
  }
  judge(
    name, question, judge_write_conflict(second_committed),
    why_write_conflict(second_committed),
  )
}

///|
fn check_version_per_commit() -> Check {
  let name = "每次提交推进一个版本"
  let question = "一次成功提交让版本号增加多少"
  let e = @moontxnkit.Engine::new()
  let before = e.version()
  let t = e.begin()
  let _ = t.put("k", "v")
  let _ = t.commit()
  let delta = e.version() - before
  judge(
    name, question, judge_version_per_commit(delta), why_version_per_commit(delta),
  )
}

///|
fn check_abort_leaves_nothing() -> Check {
  let name = "回滚无痕"
  let question = "回滚后还能读到值吗、history 里还有东西吗"
  let e = @moontxnkit.Engine::new()
  let t = e.begin()
  let _ = t.put("k", "gone")
  let _ = t.abort()
  let visible = match e.get("k") {
    Some(_) => true
    None => false
  }
  let entries = e.history("k").length()
  judge(
    name, question, judge_abort_leaves_nothing(visible, entries),
    why_abort_leaves_nothing(visible, entries),
  )
}

///|
fn check_snapshot_isolation() -> Check {
  let name = "快照隔离"
  let question = "在提交之前打开的事务，是否看得到之后提交的值"
  let e = @moontxnkit.Engine::new()
  let seed = e.begin()
  let _ = seed.put("k", "v1")
  let _ = seed.commit()
  let old = e.begin()
  let newer = e.begin()
  let _ = newer.put("k", "v2")
  let _ = newer.commit()
  let seen_newer = match old.get("k") {
    Some(v) => v == "v2"
    None => false
  }
  judge(
    name, question, judge_snapshot_isolation(seen_newer),
    why_snapshot_isolation(seen_newer),
  )
}

///|
fn check_validate_clean() -> Check {
  let name = "自检"
  let question = "正常负载跑完，引擎自检是否报告问题"
  let e = @moontxnkit.Engine::new()
  for i = 0; i < 5; i = i + 1 {
    let t = e.begin()
    let _ = t.put("k\{i}", "v\{i}")
    let _ = t.commit()
  }
  let issues = e.validate().length()
  judge(name, question, judge_validate_clean(issues), why_validate_clean(issues))
}

///|
fn check_savepoint_rollback() -> Check {
  let name = "保存点回滚"
  let question = "回滚到保存点之后，之后的写消失、之前的写还在吗"
  let e = @moontxnkit.Engine::new()
  let t = e.begin()
  let _ = t.put("keep", "before")
  let _ = t.savepoint("sp")
  let _ = t.put("drop", "after")
  let _ = t.rollback_to("sp")
  let kept = match t.get("keep") {
    Some(v) => v == "before"
    None => false
  }
  let dropped = match t.get("drop") {
    Some(_) => true
    None => false
  }
  judge(name, question, judge_savepoint(kept, dropped), why_savepoint(kept, dropped))
}

///|
fn check_delete_invisible() -> Check {
  let name = "删除语义"
  let question = "提交删除之后，读还能取到值吗"
  let e = @moontxnkit.Engine::new()
  let t = e.begin()
  let _ = t.put("k", "v")
  let _ = t.commit()
  let d = e.begin()
  let _ = d.delete("k")
  let _ = d.commit()
  let still = match e.get("k") {
    Some(_) => true
    None => false
  }
  judge(name, question, judge_delete_visible(still), why_delete_visible(still))
}

///|
fn check_compact_keeps_current() -> Check {
  let name = "压缩保留当前值"
  let question = "compact 之后，当前值是否还在"
  let e = @moontxnkit.Engine::new()
  for i = 0; i < 3; i = i + 1 {
    let t = e.begin()
    let _ = t.put("k", "v\{i}")
    let _ = t.commit()
  }
  let _ = e.compact()
  let current = e.get("k")
  judge(
    name, question, judge_compact_keeps_current(current),
    why_compact_keeps_current(current),
  )
}
