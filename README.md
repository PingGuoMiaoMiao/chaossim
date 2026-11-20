# chaossim (MoonBit)

Deterministic fault-injection simulation **for your real MoonBit state
machine** — no model rewrite. You keep your handler/protocol code as it is;
chaossim controls *which message is delivered next* (seeded RNG), *what time
it is* (virtual clock), and *which node is down* (crash plan). Every run is
replayable byte-for-byte from its seed and produces a trace you can diff,
shrink and attach to an issue.

`v0.3.0` · 61 项测试全绿 · 验收自检 8 PASS / 0 WARN · MIT · CI 覆盖库 + 三个适配器

## 你会拿到什么

一次注入故障的运行，输出就是这样（真实转录，`moon run adapters/mqtt/bin`）：

```
== qos1 ack loss from step 3
   send 1: 0->1 #0
   send 2: 1->0 #1
   send 3: 0->1 #2
   drop 4: 1->0 #3 (loss)          <- 注入：PUBACK 被丢弃
   dropped=1 deferred=0 bad_events=0
   node0: issued=1 acks=0 inflight=1 matches=true
```
（逐字转录，未改格式；`matches=true` 就是记账自洽：`inflight == issued - acks`）

再往下一步就是恢复：重连（`session_present=1`）-> 靶子文档里的 `replay_bytes()`
-> 重放帧带 DUP=1 -> `inflight=0`。每一步都有断言，换实现会报分歧。

## 它是什么 / 不是什么

| | chaossim | 说明 |
| --- | --- | --- |
| 被测对象 | **生产代码本体**（你的 `(node, msg) -> outgoing` 处理函数就是真实现） | 不需要把协议重写成另一套“仿真模型” |
| 调度 | 种子化确定性投递顺序 + 虚拟时钟 + 有界步数 | 同一 `(handler, initial, seed, plan)` ⇒ 同一 trace |
| 故障 | crash / loss（定向链路）/ partition（分组，可愈合）/ delay 与 delay_window（永久慢 vs 窗口慢）| 故障类型封顶 4 种，超出宁缺毋滥；无效计划在第一步前 `InvalidFault` 快速失败 |
| 不变量 | 交付/丢弃/延迟计数、trace 逐行相等、有界收敛；`Replay` 工件 = 场景+结果自包含，换 handler 重放必报差异 | 线性一致性**不自研**，计划对接 `moon_historycheck` / `lincheck` |

**明确不做**：真多进程、真网络包注入、任意 `moonbitlang/async` 程序的运行时
级截停。v0.3 spike 已给出裁决与行号证据
（[docs/v0.3-async-verdict.md](docs/v0.3-async-verdict.md)）：运行时不提供可注入的
时钟，协程调度器私有，外部事件循环仅 native。因此本项目只宣称
"sans-I/O 状态机可逐字节重放"；"事件注入"即便将来实现也只是半确定性。

## 外部基线（评审准则第 03 条要求，先摆在这里）

| 现有方案 | 它做到哪 | chaossim 的差异 |
| --- | --- | --- |
| [`oyjh0381/moonlab`](https://github.com/oyjh0381/MoonLab)（Q1 项目，11-12 仍在维护） | 把协议**重写成** typed 纯迁移模型（boot/step/observe），仿真模型本身；含 replay/trace/shrink CLI | 被测对象是**真实代码**而非模型——差别在**问题出在哪一层**：模型错了是设计问题，真实代码错了是实现问题。两者互补：moonlab 验证设计，chaossim 验证代码 |
| [`NekoYume517/lincheck`](https://github.com/NekoYume517/lincheck)、`123123213weqw/moon_historycheck` | 并发历史的线性一致性判定（oracle） | 不重造 oracle，作为检查器接入；chaossim 负责产生可控执行 |
| `zhangbowen2006/moonbit-target-parity` | 跨后端行为一致性 | 维度不同（后端 vs 调度交错），可同场使用 |
| `wcx789ll/moonsim` / `mizchi/machinations` | 离散事件仿真（游戏经济/DES） | 目标是协议正确性测试，不是仿真业务 |
| Jepsen/faultcanvas | 真集群/真 HTTP 故障代理 | 进程内、零部署、CI 秒级反馈 |

一句话基线主张（README 第一屏承诺，验收时逐条对数）：**生态里有“仿真你的模型”
（moonlab）和“检查你的历史”（lincheck/historycheck），但没有“在你自己的代码上
注入调度与故障”的那一层。chaossim 补这层，并给出可复跑证据。**

## 背景

为 2026 MoonBit 年度黑客松（Q2 赛季，12 月赛申报）新建。立项调研与占位核对见
[docs/pre-research.md](docs/pre-research.md)，申报一页纸见
[docs/registration-dec.md](docs/registration-dec.md)。

## Quick start

需要 MoonBit 工具链（`0.1.20261104` 或更新）。**只有** `tools/` 下的自检脚本需要
Python 3.9+；库本身与三个适配器都是纯 MoonBit。

从零 clone 后按这个顺序跑，每一条都是独立可验证的（实测总耗时约 8 秒）：

```sh
moon test --target native                    # 39 项契约测试（确定性/故障/重放/恢复）
moon run adapters/mqtt/bin  --target native  # ★ 真实靶子 1：MQTT 客户端的故障注入 transcript
moon run adapters/amqp1/bin --target native  # ★ 真实靶子 2：AMQP 1.0（另一套协议，同一内核）
moon run cmd/perf --target native --release  # 吞吐与 CI 预算
moon run cmd/main --target native            # 最小内核演示：同种子重放 + crash 注入

# 看它到底怎么用：完整可跑的例子（跑一次 / 扫种子 / 出 replay 工件）
moon run examples/quickstart/src --target native

# 体检一个协议库：11 项恢复/记账检查 + 并发交错扫描，直接出 Markdown 报告
moon run adapters/moonmq/checkup --target native
# 样板报告（由上面那条命令生成，不是手写）：docs/checkup-moonmq.md

# 自检：一条命令看全部状态（验收六条 + 文档与代码一致性）
python tools/selfcheck.py
# 可选加测：打包就绪（解压成品包再检查一遍，不上传、不需要登录）
python tools/selfcheck.py --with-publish
# 可选加测：关于 registry 的说法是否属实（查 manifest API，网络失败记为 SKIP）
python tools/selfcheck.py --with-registry
# 可选加测：仓库之外的独立模块能否真的用起来（跑通故障场景并自证重放）
python tools/selfcheck.py --with-consumer
```

注意 `--target native` 别省：不带 target 时 `moon test` 会**按后端分别报告**
（本机会看到 `[wasm]` 与 `[native]` 两行合计），容易误读成"总共有 26 个测试"。 <!-- consistency:ignore -->
本项目声明的主目标是 native，验收脚本也按 `moon.mod` 的 `preferred_target` 跑。

先看第二条：它打印的 trace 就是本项目存在的理由——真实协议代码在注入故障后
`reconciled=true`，以及丢 PUBACK 后按文档恢复、重放帧带 DUP。

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
      同一套内核零改动驱动三种靶子：MQTT 3.1.1 客户端 + AMQP 1.0 端点对 + AMQP 0-9-1 broker，
      61/61 测试。AMQP 给出"投递无关不变量"的范例：`credit_before - sends ==
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

## 变更记录

[CHANGELOG.md](CHANGELOG.md) 按**能力**组织（不是 git log 的搬运），每条带可复跑命令与 commit；被否决的方向与已知限制也记在里面。

## 文档为什么可信

文档会说谎——本项目自己的 README 就曾贴出与程序实际输出不符的 transcript。
因此这里的每一条可核实主张都挂在门禁上：

| 门禁 | 抓什么 |
| --- | --- |
| `tools/consistency.py` | 测试数/ADR 数/ADR 编号/相对链接/引用的 commit 是否存在/**贴出的输出是否逐字为真** |
| `tools/acceptance.py` | 赛事验收六条（MoonBit 为主、历史、可运行、许可、AI 可解释等） |
| `--with-publish` | 成品包解压后能否通过检查（抓"工作区能跑、打包后坏"） |
| `--with-registry` | 关于已发布版本/下载数的说法是否与 mooncakes.io 一致 |

每一项都验证过**能失败**；网络不可达记为 SKIP 而非 FAIL。

这套门禁在**本项目**上实际拦下过：README 里过期的测试数（`31/31` 实为 39）、 <!-- consistency:ignore -->
与程序实际输出不符的 transcript（写了 `reconciled=true`，程序打印的是
`matches=true`）、发布包里混进工作区成员、以及验收脚本把测试数报成 26（实为 39）。
同一套工具在另一个项目上还拦下过重复的 ADR 编号、「0.3.1 已发布却写成未发布」等
——战果分开记，不混算。

## 本地环境两条注意

1. **工具链版本差会让本地与 CI 的"绿"含义不同**。CI 装 `latest`（版本化 URL 在
   CDN 上 403，无法钉死），本机可能更旧。判断依据在 CI 日志里（`moon version --all`）。
   两个版本在个别诊断上结论相反（本仓库已知一处：`core/` 的 json 依赖在新版被判
   unused），CI 因此只允许这一条并把它打印出来。
2. **`moon test` 报 `@fs.tmpdir(): Access is denied` 时是环境问题**：某些机器的
   `%TEMP%` 不允许进程建目录。把 `TEMP`/`TMP` 指到可写目录即可（自检脚本已自动指向
   工程内 `.testtmp/`）；库代码无需改动。

## 当前状态

[docs/status.md](docs/status.md) 是**实测快照**：版本、发布就绪、测试/验收/一致性结果、
性能数字、可主张与不可主张清单，每条都带取值命令。

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
