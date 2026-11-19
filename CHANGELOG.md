# Changelog

按**能力**组织，不是 `git log` 的搬运。每条给出可复跑命令与相关 commit，
被否决的方向也记（避免重复试错，也便于评审判断取舍）。

版本号对应 `moon.mod`。`0.3.0` 已可打包验证但**尚未发布到 MoonCakes**
（需要维护者执行 `moon login`，见文末）。

---

## [0.3.0] — 2026-11-19

首个完整形态：内核 + 两个真实靶子 + 恢复验证 + 自检体系。

### 内核

- **种子化投递调度**：xorshift32 纯函数式选路，`(handler, initial, seed, faults)`
  决定唯一 trace（`sim/rng.mbt`、`sim/world.mbt`）— `9aba4a1`
- **四类故障**：`crash` / `loss`（定向链路）/ `partition`（分组、可愈合）/
  `delay` 与 `delay_window`（永久慢 vs 窗口慢）；无效计划在第一步前
  `InvalidFault` 快速失败 — `db28a82`、`6930dc9`
- **Replay 工件**：场景 + 结果自包含 JSON；`replay_verify` 用调用方的 handler
  重跑并逐行比对，分歧即 `ReplayMismatch` — `db28a82`
- **`SimError`**：`code()` / `message()`，与错误处理惯例对齐 — `db28a82`

复跑：`moon test --target native`（39 项）

### 真实靶子（本项目存在的理由）

- **MQTT 3.1.1 客户端**（`Duckweed/moon-mqtt` 的 `ClientCore`）：QoS1 五种场景、
  QoS2 四段握手、双消息并发交错（seeds 1..8）、多客户端 partition 隔离
  （seeds 1..6）— `edc065b`、`25020a3`、`d1c2479`
- **AMQP 1.0**（`binhongcha/moonamqp1` 的 `Endpoint` 对）：同一套内核**零改动**，
  credit / settlement 记账在丢传输、丢结算、慢服务下全部成立 — `017f262`
- **恢复路径按靶子文档核对**：丢 PUBACK → 重连 → `replay_bytes()` → 重放帧
  **DUP=1**（DUP 位解码读回确认）；有"无故障则无重放"的控制组 — `374889f`
- **QoS2 是另一条恢复分支**：卡在 WaitPubcomp 时重放 **PUBREL** 而非 PUBLISH，
  两个独立计数器防止互相冒充 — `2f38d1b`

复跑：`moon run adapters/mqtt/bin --target native`、`moon run adapters/amqp1/bin --target native`

### 工程与验证

- **打包隔离**：`.moonignore` 排除工作区成员（`adapters/` `spikes/` `examples/`），
  实测发布包 0 条泄漏；`moon.mod` 的 `exclude` 键被工具链拒绝，记录在案 —
  `a8eba83`、`b81a463`
- **CI**：库（`check --deny-warn` + `test` + `fmt` 门禁）、工作区（两个适配器
  transcript）、接入演练、验收自检、文档一致性 — `a8eba83` 起逐步补齐
- **吞吐**：约 460–500 ns/调度步，1000 种子 × 20 步扫描 ≈ 9–10 ms；含"故障评估
  约 +9%"的对照 — `63fd3d2`
- **可执行文档**：`examples/adopting-drill/` 是完全照 `docs/adopting.md` 写的
  第三方小库，随 `moon test` 跑，指南失效即红 — `0a97091`
- **上游可用的验证报告**：`docs/reports/independent-verification.md`，逐场景 +
  明确的未覆盖范围 — `24200dd`
- **自检体系**：验收六条（8 PASS）与文档一致性（4 项，含"贴出的输出必须逐字为
  真"）都进 CI — `28aadd1`、`1203a57`、`b6553b0`、`64a0b29`

### 被否决的方向（同样重要）

- **以 `moonbitstack/moonraft` 为靶**：它自带确定性模拟簇（丢包/延迟/乱序/分区
  + etcd 语料逐字节回放），在它身上注入故障等于复述它自己的测试 — `4d422d0`
- **以 `Zcxssxx/moonmq` 为靶**：最后推送 2026-09-27（停更两个月）且自带内嵌
  broker，会把"测协议实现"变成"测我写的仿真 broker" — `017f262`（D11）
- **运行时级确定性调度**：`now()` 是固定 C FFI 导入、协程 `Scheduler` 私有、
  外部事件循环仅 native 且 JS 为空实现。范围因此收敛为 sans-I/O，且不把"事件
  注入"包装成"可重放" — `fd48d5e`，行号证据见 `docs/v0.3-async-verdict.md`
- **`moon bench` / `@bench.Bench`**：前者发现不了这些 bench；后者自动校准迭代，
  在这么便宜的工作负载上烧了 131 s CPU 还在跑 — `63fd3d2`（D15）

### 已知限制

- **未发现靶子的行为 bug**。主张的是故障下可复核的等价类与对账不变量，不是
  bug 标题党
- **transport / 浏览器胶水层未覆盖**：只覆盖靶子的纯计算核心
- **AMQP 握手是同步驱动的**，握手期间的故障未注入
- **每步拼 trace 字符串**可能是主要成本，未优化（先有数字再谈优化）
- **0.3.0 未发布**：`moon package` 通过且包干净，只差 `moon login` → `moon publish`
