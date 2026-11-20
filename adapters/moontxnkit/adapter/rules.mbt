// Judging rules for a transactional store. Deliberately a different domain from
// the broker battery: the questions are about isolation and durability, not about
// acknowledgements and redelivery. Each rule takes an OBSERVED fact and returns
// true when that fact means the library is wrong.

///|
/// A write that has not been committed must not be visible to anyone else.
pub fn judge_dirty_read(outsider_sees : Bool) -> Bool {
  outsider_sees
}

///|
/// A transaction must see its own uncommitted writes.
pub fn judge_read_your_writes(owner_sees : Bool) -> Bool {
  !owner_sees
}

///|
/// Two transactions writing the same key: the second commit must be rejected.
pub fn judge_write_conflict(second_committed : Bool) -> Bool {
  second_committed
}

///|
/// A rejected commit must leave no trace: the winner's value stays.
pub fn judge_loser_left_no_trace(winner_value_kept : Bool) -> Bool {
  !winner_value_kept
}

///|
/// One successful commit increments the version exactly once.
pub fn judge_version_per_commit(delta : Int32) -> Bool {
  delta != 1
}

///|
/// The version history of a key must hold only committed versions.
pub fn judge_history_committed_only(entries : Int32, commits : Int32) -> Bool {
  entries != commits
}

///|
/// An aborted transaction must leave no trace at all.
pub fn judge_abort_leaves_nothing(visible : Bool, history_entries : Int32) -> Bool {
  visible || history_entries != 0
}

///|
/// Snapshot isolation: a transaction opened before a commit must not see it.
pub fn judge_snapshot_isolation(sees_newer : Bool) -> Bool {
  sees_newer
}

///|
/// Self-validation must report nothing after a normal, non-conflicting workload.
pub fn judge_validate_clean(issues : Int32) -> Bool {
  issues != 0
}

///|
/// Compaction may drop old versions but must keep the current value.
pub fn judge_compact_keeps_current(value : String?) -> Bool {
  match value {
    Some(_) => false
    None => true
  }
}

///|
/// Reasons, one per rule.
pub fn why_dirty_read(bad : Bool) -> String {
  if bad {
    "未提交的写被外部读到了：脏读"
  } else {
    ""
  }
}

///|
pub fn why_read_your_writes(bad : Bool) -> String {
  if bad {
    "事务读不到自己刚写的值"
  } else {
    ""
  }
}

///|
pub fn why_write_conflict(bad : Bool) -> String {
  if bad {
    "两个事务写同一个 key，第二个提交没有报冲突"
  } else {
    ""
  }
}

///|
pub fn why_loser_left_no_trace(bad : Bool) -> String {
  if bad {
    "失败方的事务留下了痕迹：赢家的值被覆盖或丢失"
  } else {
    ""
  }
}

///|
pub fn why_version_per_commit(delta : Int32) -> String {
  if delta != 1 {
    "一次提交让版本号变化不等于 1：版本推进不可预测"
  } else {
    ""
  }
}

///|
pub fn why_history_committed_only(entries : Int32, commits : Int32) -> String {
  if entries != commits {
    "history 条数与提交次数不一致：未提交或被回滚的版本混进了历史"
  } else {
    ""
  }
}

///|
pub fn why_abort_leaves_nothing(visible : Bool, entries : Int32) -> String {
  if visible || entries != 0 {
    "回滚后仍能读到值或存在历史版本：回滚不彻底"
  } else {
    ""
  }
}

///|
pub fn why_snapshot_isolation(bad : Bool) -> String {
  if bad {
    "旧快照读到了之后提交的值：快照隔离失效"
  } else {
    ""
  }
}

///|
pub fn why_validate_clean(issues : Int32) -> String {
  if issues != 0 {
    "自检报告了问题：正常负载下引擎状态不一致"
  } else {
    ""
  }
}

///|
pub fn why_compact_keeps_current(value : String?) -> String {
  let lost = match value {
    Some(_) => false
    None => true
  }
  if lost {
    "压缩后当前值丢失：压缩把还活着的值删了"
  } else {
    ""
  }
}

pub fn judge_savepoint(kept : Bool, dropped : Bool) -> Bool {
  !kept || dropped
}

///|
pub fn why_savepoint(kept : Bool, dropped : Bool) -> String {
  if !kept {
    "回滚到保存点后，保存点之前的写也消失了"
  } else if dropped {
    "回滚到保存点后，之后的写仍然可见"
  } else {
    ""
  }
}

///|
pub fn judge_delete_visible(still : Bool) -> Bool {
  still
}

///|
pub fn why_delete_visible(still : Bool) -> String {
  if still {
    "删除提交后仍能读到值：删除无效"
  } else {
    ""
  }
}
