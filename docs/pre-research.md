# 立项前调研与占位核对（2026-11-19）

> 目的：把“chaossim 到底和生态里哪些东西重合、差异站不站得住”写在提交之前，
> 供评审和未来的自己逐条核对。所有包名/版本/日期取自本机 MoonCakes registry
> 索引（moon 0.1.20261104 代际，约 2026-11-10 生成）+ GitHub 实时抓取。

## 1. 直接相邻的现有方案（实测证据）

| 方案 | 证据 | 与本项目关系 |
| --- | --- | --- |
| `oyjh0381/moonlab` "Deterministic distributed-system simulation and fault injection for MoonBit" | registry 首发 2026-08-12；GitHub `oyjh0381/MoonLab` 最近一次推送 **2026-11-12**（提交信息："maintain compatibility with current MoonBit toolchain"）；README 明确：协议作者把系统写成 **typed 纯迁移模型（boot/step/observe）**，由 MoonLab 控制调度/虚拟时间/消息/定时器/稳定存储/崩溃/重启/分区；自带 replay/trace/report JSON 工件与 CLI；examples 是 Raft-style 选举等**模型** | **最接近的重合，必须正面处理。** 差异：moonlab 仿真的是"你重写的模型"，chaossim 仿真的是"你的真实 handler 代码"。模型 bug 与实现 bug 是两类 bug；本项目只做后者 |
| `NekoYume517/lincheck` (2026-10-29) | "Wing-Gong-Lowe search over concurrent histories with minimal counterexample witnesses" | 线性一致性 **oracle**，不产生受控执行。本项目计划作为依赖接入（v0.4），不自研 |
| `123123213weqw/moon_historycheck` (2026-11-03 v0.7.0) | "Bounded concurrent-history checking with verified witnesses and counterexample reduction" | 同上：检查器，不是故障注入器；接入候选 |
| `zhangbowen2006/moonbit-target-parity` (v0.5.1) | 跨后端行为契约比较 | 维度不同（后端 × 调度交错），互补 |
| `zkc-long/faultcanvas` | 可编程 HTTP 故障代理（真网络面） | 面向 HTTP 集成测试；本项目是进程内秒级 CI 反馈 |
| `wcx789ll/moonsim` / `mizchi/machinations` | 离散事件仿真 / 游戏经济确定性仿真 | 目标是仿真业务而非协议正确性 |
| `Han-Wentao/moonbench`、`sa2360/moonbench` | 基准统计工具 | 无调度控制；不构成重合 |
| Jepsen（外部生态） | Clojure，真集群 + 真分区 | 方法同源（生成执行+不变量+缩小），但依赖真实部署；"进程内确定性版 Jepsen" 在 MoonBit 生态无人做 |

结论：**"在真实代码上做调度级故障注入"这一层无人占用**；"仿真模型"（moonlab）
与"历史判定"（lincheck/historycheck）两层有人做，且做得不错——本项目把这两层
分别作为**互补基线与可复用组件**写进 README，而不是假装看不见。

## 2. 范围决定（v0 刻意小）

1. **v0 只承诺**：消息投递顺序的确定性调度（种子化）+ crash/静默丢弃故障 +
   有界步数 + trace/计数 + 重放相等测试。
2. **不承诺运行时级 async 截停**：对任意 `moonbitlang/async` 程序做虚拟时间/
   续作调度是真正的深水区（官方 runtime 未暴露可控调度器接口），列入 v0.3
   spike，失败预案是把适配面收窄到"纯迁移函数 + 显式效果列表"，并在
   README 明示边界。——docmunch 初审的教训：**不能测的主张不写**。
3. 不变量判定不自研 oracle；接入 moon_historycheck/lincheck 时在
   README/依赖处写明来源与许可证（OSI 兼容，MIT/Apache-2.0 均可）。

## 3. 验收六条自检口径

- MoonBit 为主：仓库只有 `.mbt`，无第三方语言实现。
- 公开+连续：2026-11-19 首 commit（GitHub 建仓当日即公开）。
- 可运行：`moon build --target native` / `moon test` / `moon run cmd/main`。
- 本期实质新增：新项目，非拆分——与 docmunch（文档检索）无共享代码、无共享依赖目的，
  选题动机不同（一个服务 LLM 上下文成本，一个服务并发正确性）。
- 开源合规：MIT（LICENSE 已随仓库初始提交）。
- AI 可解释：本文件 + docs/decisions.md（随进度追加）记录每个取舍与验证方式。

## 4. 四周计划（12 月赛口径）

| 周 | 交付 | 可测证据 |
| --- | --- | --- |
| W1 | drop/partition 故障计划；trace 落盘与逐字节重放；`SimError` 化错误 | 重放哈希相等测试；故障矩阵 golden 测试 |
| W2 | 适配两个真实生态项目（候选 moonbitstack/moonraft、Duckweed/moon-mqtt） | 每个目标 ≥1 个可控失败场景的 trace 文件入库 |
| W3 | 不变量钩子 + 接入 historycheck/lincheck 的线性一致性示例 | 示例测试全绿 + 复用声明页 |
| W4 | 真实 bug 记录（issue/PR 链接）；90 秒演示录屏；README 数字回填 | 验收脚本化：moon test 输出即清单 |
