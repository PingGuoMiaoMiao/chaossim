# 十二月赛项目申报 · 一页纸（chaossim）

> 用途：12-01 飞书表单「一页项目说明」+ 邮件备用。
> 原则（吸收 docmunch 初审教训）：先给外部基线和可测主张，再讲功能；
> 每个数字都必须能一条命令复跑；写清"不主张什么"。

---

## 一句话

给 MoonBit 生态一个**调度级故障注入测试台**：把**真实的**协议/状态机代码放进
确定性调度器，注入 crash / loss / partition / delay，每个失败场景产出**可逐字节
重放**的 JSON 工件。发现问题、复现问题、把问题交给别人——都在 `moon test` 秒级完成。

## 与现有方案的增量

| 现有 | 它们做的 | chaossim 多出来的 |
| --- | --- | --- |
| `oyjh0381/moonlab` | 仿真你**重写成模型**的协议 | 仿真**生产代码本体**；发现实现 bug，不是模型 bug |
| `lincheck` / `moon_historycheck` | 并发历史的一致性判定（oracle） | 不重造 oracle，作为不变量检查器接入；chaossim 负责**产生**可控执行 |
| 靶子自带的 scripted broker / 模拟簇 | 项目内部的正序自查 | **协议无关的可复用 harness**，跨两个协议验证 |
| Jepsen（生态外） | 真集群 + 真网络故障 | 同方法论的进程内确定性版：无部署、CI 秒级、可重放 |

## 完成度（每条都能一条命令复跑）

- **内核**：种子化投递调度 + 4 类故障（crash / loss / partition / 窗口化 delay）
  + 有界运行 + trace/计数；`Replay` JSON 工件自包含"场景+结果"，换实现必报分歧
- **两个真实靶子，同一套内核零改动**：
  - `Duckweed/moon-mqtt`（MQTT 3.1.1 客户端）：QoS1、QoS2 四段握手、双消息并发
    交错（seeds 1..8）、多客户端 partition 隔离（seeds 1..6）
  - `binhongcha/moonamqp1`（AMQP 1.0）：credit / settlement 记账在丢传输、
    丢结算、慢服务下全部成立
- **恢复路径按靶子文档逐项核对**：丢 PUBACK → `reconnect` +
  `replay_bytes()` → 重发 **DUP=1** 的 PUBLISH（DUP 位是解码读回来确认的）；
  丢 PUBCOMP → 重发 **PUBREL**（另一条分支，用独立计数器防止互相冒充）。
  含"不注入故障则无重放"的控制组
- **接入指南是可执行的**：`examples/adopting-drill/` 是完全按指南写出的第三方
  小库，随 `moon test` 跑；指南失效则构建红
- **性能**：约 460–500 ns / 调度步；1000 种子 × 20 步扫描约 9–10 ms
  （`moon run cmd/perf --release`）——全量种子扫描放 CI 可行
- **质量门**：39/39 测试、`moon check --deny-warn` 零警告、CI 跑库 + 两个适配器 +
  接入演练 + 验收自检；验收自检 **8 PASS / 0 WARN / 0 FAIL**

## 工程判断（主动否掉的扩张）

v0.3 spike 判定**运行时级确定性调度不可行**，并给出行号证据：`now()` 是固定 C FFI
导入、协程 `Scheduler` 私有、外部事件循环仅 native 且 JS 为空实现。因此范围收敛为
sans-I/O 状态机；"对真实 async 程序做事件注入"最多半确定性，**不会被包装成可重放**。

## 不主张什么

- 不主张"发现了靶子的 bug"：至今未发现行为 bug。主张的是**故障下的等价类与
  对账不变量**（丢 ACK 与 broker 崩溃在客户端侧不可区分；饿死场景 deferred=9
  仍可精确重放），这些任何人都能复跑核对。
- 不主张"比 Jepsen 更强"：只做进程内、单机、可重放这一层。

## 复跑

```sh
moon test --target native                       # 39 项（含接入演练）
moon run adapters/mqtt/bin  --target native     # MQTT transcript
moon run adapters/amqp1/bin --target native     # AMQP 1.0 transcript
moon run cmd/perf --target native --release     # 性能
python tools/acceptance.py --since 2026-11-01   # 验收自检
```

## AI 使用与可解释性

设计与文档 AI 辅助起草；代码由 AI 生成后逐行核对并跑测试。关键取舍全部留档于
`docs/decisions.md`（D1–D17），其中包含三次"断言从真实运行输出反向修正"、
一次"默认参数提案被生态惯例否决"、一次"自写基准的负载错误"，以及两次沙箱内
自伤事故的如实记录。所有 README 数字来自仓库测试实测。
