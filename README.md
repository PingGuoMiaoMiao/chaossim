# chaossim (MoonBit)

Deterministic fault-injection simulation **for your real MoonBit state
machine** — no model rewrite. You keep your handler/protocol code as it is;
chaossim controls *which message is delivered next* (seeded RNG), *what time
it is* (virtual clock), and *which node is down* (crash plan). Every run is
replayable byte-for-byte from its seed and produces a trace you can diff,
shrink and attach to an issue.

这是为 2026 MoonBit 年度黑客松（Q2 赛季，12 月赛申报）新建的项目。立项调研与
占位核对见 [docs/pre-research.md](docs/pre-research.md)。

## 它是什么 / 不是什么

| | chaossim | 说明 |
| --- | --- | --- |
| 被测对象 | **生产代码本体**（你的 `(node, msg) -> outgoing` 处理函数就是真实现） | 不需要把协议重写成另一套“仿真模型” |
| 调度 | 种子化确定性投递顺序 + 虚拟时钟 + 有界步数 | 同一 `(handler, initial, seed, plan)` ⇒ 同一 trace |
| 故障 | crash / loss（定向链路）/ partition（分组，可愈合）/ delay 与 delay_window（永久慢 vs 窗口慢，D8）| 故障类型封顶 4 种，超出宁缺毋滥；无效计划在第一步前 `InvalidFault` 快速失败 |
| 不变量 | 交付/丢弃/延迟计数、trace 逐行相等、有界收敛；`Replay` 工件 = 场景+结果自包含，换 handler 重放必报差异 | 线性一致性**不自研**，计划对接 `moon_historycheck` / `lincheck` |

**明确不做**：真多进程、真网络包注入、任意 `moonbitlang/async` 程序的运行时
级截停。v0.3 spike 已给出裁决与行号证据
（[docs/v0.3-async-verdict.md](docs/v0.3-async-verdict.md)）：运行时不提供可注入的
时钟，协程调度器私有，外部事件循环仅 native。因此本项目只宣称
"sans-I/O 状态机可逐字节重放"；"事件注入"即便将来实现也只是半确定性。

## 外部基线（评审准则第 03 条要求，先摆在这里）

| 现有方案 | 它做到哪 | chaossim 的差异 |
| --- | --- | --- |
| [`oyjh0381/moonlab`](https://github.com/oyjh0381/MoonLab)（Q1 项目，11-12 仍在维护） | 把协议**重写成** typed 纯迁移模型（boot/step/observe），仿真模型本身；含 replay/trace/shrink CLI | 被测对象是**真实代码**而非模型；发现的是实现的 bug，不是模型的 bug。两者互补：moonlab 验证设计，chaossim 验证代码 |
| [`NekoYume517/lincheck`](https://github.com/NekoYume517/lincheck)、`123123213weqw/moon_historycheck` | 并发历史的线性一致性判定（oracle） | 不重造 oracle，作为检查器接入；chaossim 负责产生可控执行 |
| `zhangbowen2006/moonbit-target-parity` | 跨后端行为一致性 | 维度不同（后端 vs 调度交错），可同场使用 |
| `wcx789ll/moonsim` / `mizchi/machinations` | 离散事件仿真（游戏经济/DES） | 目标是协议正确性测试，不是仿真业务 |
| Jepsen/faultcanvas | 真集群/真 HTTP 故障代理 | 进程内、零部署、CI 秒级反馈 |

一句话基线主张（README 第一屏承诺，验收时逐条对数）：**生态里有“仿真你的模型”
（moonlab）和“检查你的历史”（lincheck/historycheck），但没有“在你自己的代码上
注入调度与故障”的那一层。chaossim 补这层，并给出可复跑证据。**

## Quick start

```sh
moon build --target native
moon test                          # determinism / echo / crash-plan 用例
moon run cmd/main --target native  # 90 秒演示：带种子重放 + crash 注入
```

## Library sketch（v0.2 真实 API，见 sim/*.mbt）

```moonbit
let reply : @sim.Handler = (node, msg) =>
  [{ from: node, to: msg.from, payload: msg.payload + 1 }]

let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: 1 }]
let faults = [@sim.crash(1, 2)]
let result = @sim.run_bounded(reply, initial, 42, 100, faults)

// 自包含 replay 工件（场景 + 结果）；换 handler 重放会 raise ReplayMismatch
let text = @sim.render_replay("crash demo", 42, 100, initial, faults, result)
let again = @sim.replay_verify(text, reply)
```

`run_bounded` 以 `raise SimError` 报告无效计划 / 坏工件 / 重放分歧
（`e.code()`、`e.message()`），取舍理由见 [docs/decisions.md](docs/decisions.md)。

## Roadmap（与验收对齐，只承诺能测的东西）

- [x] v0.1：种子化投递调度器 + crash 计划 + trace/计数；确定性测试
- [x] v0.2：loss / partition（可愈合）/ delay 与 delay_window 故障；`Replay` JSON 工件与
      `replay_verify` 对账；`SimError`（code/message）；12 项契约测试
- [x] W2 首轮：`adapters/mqtt` 在调度器下跑**真实** moon-mqtt ClientCore，
      5 种故障场景的记账不变量全绿（docs/w2-targets.md 有逐条 transcript；
      首轮未发现库行为 bug——价值主张是可复核的等价类，不标题党）
- [x] W2b：QoS2 四段握手（6 步收敛）、PUBCOMP 丢失钉死 WaitPubcomp、
      双 QoS2 并发交错 seeds 1..8 全部对账归零（调度顺序即乱序测试）
- [x] W2c：多客户端模型（客户端占偶数节点、broker=1）+ partition；
      链路切断类 seeds 1..6 全对账，途中暴露并修掉"应答硬编码回 node0"
      这个只有双客户端才会现形的真 bug（D9）
- [x] W3：第二靶子 **MoonAMQP1**（AMQP 1.0，sans-I/O、无内置 broker、11-16 活跃）。
      同一套内核零改动驱动两种协议：MQTT 3.1.1 客户端 + AMQP 1.0 端点对，
      31/31 测试。AMQP 给出"投递无关不变量"的范例：`credit_before - sends ==
      link_credit(now)` 在丢传输/丢结算/慢服务下全部成立（D11）
- [x] W4：**恢复路径验证**——丢 PUBACK → 重连（`session_present=1`）→ `replay_bytes()`
      重放 DUP=1 → 恢复归零，seeds 1..6 全绿；含"不注入故障则无重放"的控制组。
      把"文档说能恢复"变成"注入故障后确实恢复了"（D12）
- [x] W5：**QoS2 是另一条恢复分支**——卡在 WaitPubcomp 时重放的是 PUBREL 而非
      PUBLISH（`replays=0 / replays_pubrel=1 / dups=0`，因 DUP 位只属于 PUBLISH）。
      用两个独立计数器让两条分支不能互相冒充，seeds 1..6 全绿（D14）
- [x] v0.3 spike：**运行时级确定性调度判定不可行**，附行号证据
      （`now()` 是固定 C FFI、`Scheduler` 私有、外部事件循环仅 native 且 JS 空实现）。
      范围维持 sans-I/O；同时明确"事件注入"最多半确定性，不冒充可重放
      （[docs/v0.3-async-verdict.md](docs/v0.3-async-verdict.md)，D13）
- [ ] v0.4：不变量钩子 + 对接 `moon_historycheck`/`lincheck` 的线性一致性示例（复用声明写明出处与许可证）
- [ ] v1.0（12 月验收包）：发布 mooncakes 0.3.0 —— 包已打好且干净
      （`moon package` 通过、zip 内 0 条工作区成员泄漏），只差维护者执行
      `moon login`（当前 `moon whoami` 报 username unavailable）；
      申报材料见 docs/registration-dec.md

## 性能（可复跑）

```sh
moon run cmd/perf --target native --release
```

单机 release 实测（内核：种子调度 + 故障评估 + trace 构建，不含靶子库的编解码）：

| 形状 | 每次运行 | 每调度步 |
| --- | --- | --- |
| 4 步 | 1.94 us | 485 ns |
| 20 步 | 9.16 us | 458 ns |
| 200 步 | 95.4 us | 477 ns |
| 20 步 + 4 个故障 | 10.02 us | 501 ns |

结论：**约 460–500 ns / 调度步**，叠加 4 个故障只多约 9%。所以
**1000 种子 × 20 步的扫描约 9–10 ms** —— 放在 CI 里跑全量种子扫描是可行的，
不必为性能做取舍。方法学（以及测量时踩的两个坑）见 docs/decisions.md D15。

## 证据索引

[docs/evidence.md](docs/evidence.md) 把每一条对外主张映射到**一条复跑命令**和
仓库里的文件——不想相信文档的人可以直接跑。它自己也有过期风险，所以接入演练与
验收自检都挂在 CI 上：主张失效时构建先红。

## 给别人的库用 / 独立验证

- [docs/adopting.md](docs/adopting.md) —— 30 行接上 chaossim：前提自查、三步胶水、
  不变量怎么挑、四个常见坑（含我们自己踩过的：全局计数器会随种子漂移）。
  **该指南是可执行的**：`examples/adopting-drill/` 就是按它写出来的第三方小库，
  作为工作区成员参与 `moon test`，指南失效会直接红。
- [docs/reports/independent-verification.md](docs/reports/independent-verification.md)
  —— 对 `Duckweed/moon-mqtt` 与 `binhongcha/moonamqp1` 的独立故障注入报告，
  含逐条场景、观察值与未覆盖范围，可直接复跑。

## 开发过程与 AI 可解释性

- 仓库公开，从第一天起连续提交；里程碑用 tag。
- `docs/pre-research.md`：选题占位核对原始证据（日期、包名、版本、仓库活跃度）。
- `docs/decisions.md`（随进度追加）：关键取舍，含“为什么不做运行时截停”的失败预案。
- AI 使用：代码/文档由 AI 辅助起草，人工逐段核对并跑测试；所有数字来自本仓库
  测试实测，README 不出现无法复跑的指标。

## License

MIT.
