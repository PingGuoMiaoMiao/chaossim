# chaossim 项目申报书

## 基本信息

- 项目名称：chaossim：MoonBit 的确定性故障注入测试台
- 参赛者：陈永祺
- 联系方式：15920836869
- GitHub 仓库链接：https://github.com/PingGuoMiaoMiao/chaossim
- 项目方向：MoonBit 测试基础设施 / 分布式与并发正确性工具
- 是否为移植项目：**否**（原创项目；灵感来源与借鉴关系见下方"参考与借鉴说明"）

## 项目简介

chaossim 面向 MoonBit 中编写**协议实现、消息中间件、事务引擎、并发状态机**的库作者，
提供一套进程内的确定性故障注入测试台：把**真实的生产代码**接入一个种子化的投递调度器，
注入崩溃 / 丢包 / 分区 / 延迟四类故障，每一步都运行用户声明的不变量钩子，失败场景产出
**可逐字节重放**的 JSON 工件。

它同时提供一个**工具形态的入口**：给一个协议实现，跑一遍故障，输出一份 Markdown
体检报告，指出哪些恢复与记账路径没有处理。

```sh
moon run adapters/moonmq/checkup --target native   # 11 项检查 → 一份报告
```

项目解决的具体问题：**"某条消息丢了、某个节点挂了之后，我的代码还自洽吗"** 这类缺陷
只在特定交错与故障下出现，正常测试全绿、代码评审也看不出，线上偶发且无法复现。
chaossim 把它变成 `moon test` 里秒级完成、同种子必定复现的一次执行。

## 核心功能范围

- **确定性调度内核**：种子化投递顺序 + 有界运行（防活锁跑飞）+ 完整 trace 与计数；
  同一种子在同一实现上产出逐字节相同的 trace 与结果；
- **四类故障注入**：节点崩溃（crash）、链路丢包（loss）、分组隔离（partition）、
  窗口化延迟（delay / delay_window）；
- **可重放工件**：`Replay` JSON 自包含"场景 + 结果"，`replay_verify` 重新执行并核对
  ——工件不是日志，是可执行的主张；换实现必报分歧；
- **不变量钩子**：按**每一步**回调，而非只在结尾断言（结尾正确但中途经过坏状态是
  末尾断言看不见的）。内置三条投递无关钩子：计数不为负、`delivered + dropped == step`
  （抓"消息凭空消失"）、trace 不得有空行（防静默步骤藏在计数器后）；
- **线性一致性检查**：对记录的并发历史做线性化搜索，判定是否线性一致；预算耗尽报
  `unknown` 而非谎报通过；**拒绝路径已测**（实时序禁止的旧读、无合法顺序的写偏斜均被拒绝）；
- **协议无关的体检电池**（两个域，共 21 项检查）：
  - 消息域（11 项）：重复确认、重投后旧 tag、预取上限、取消消费者重投、未确认时删队列、
    批量确认原子性、跨会话隔离、扇出、主题通配路由；
  - 事务域（10 项）：脏读、读自己的写、写写冲突、版本推进、回滚无痕、快照隔离、
    引擎自检、保存点回滚、删除语义、压缩保留当前值；
- **并发交错扫描**：两个客户端抢同一队列，多种脚本 × 多组故障 × 多种子，
  逐次检查"同一消息不被两个客户端持有 / 不跨客户端误确认 / 记账闭合"
  （实测 320 次运行，0 违规）；
- **五个真实靶子，同一内核零改动**：
  - `Duckweed/moon-mqtt`（MQTT 3.1.1 客户端）：QoS1、QoS2 四段握手、双消息交错、多客户端隔离；
  - `binhongcha/moonamqp1`（AMQP 1.0）：credit / settlement 记账在丢传输、丢结算、慢服务下成立；
  - `Zcxssxx/moonmq`（AMQP 0-9-1 broker）：**服务端**语义，确认/重投/预取记账；
  - `black-duck666/moontxnkit`（MVCC 事务引擎）：隔离、冲突检测、恢复；
  - `moonbitstack/moonredis`（RESP2/RESP3 纯编解码器）：第三种目标类型，没有消息可丢，
    审计按 codec 的性质重写（往返、截断必拒、随机字节不崩、深嵌套不爆栈）；
- **恢复路径按靶子文档逐项核对**：丢 PUBACK → `reconnect` + `replay_bytes()` → 重发
  DUP=1 的 PUBLISH（DUP 位解码读回确认）；丢 PUBCOMP → 重发 PUBREL（另一条分支，
  独立计数器防止互相冒充）；含"不注入故障则无重放"的控制组；
- **接入指南是可执行的**：`examples/adopting-drill/` 是完全按指南写出的第三方小库，
  随 `moon test` 跑，指南失效则构建红；`examples/quickstart/` 为最小可跑示例；
- **质量门与自检**：**74/74** 测试、`moon check --deny-warn` 零警告、CI 覆盖库 +
  五个适配器 + 两份体检报告（`moonmq` 11 项 / `moontxnkit` 10 项，落盘为文档）+
  一份编解码审计（`moonredis`，CI 每次生成）+ 接入演练 + 验收自检；三档自检
  （验收六条 / 打包就绪 / registry 说法核实）每一档都验证过**能失败**。

## 参考与借鉴说明

**本项目不是移植项目**：没有对应的上游代码库，全部实现在本仓库内完成。

方法论上参考了以下工作（均为**公开文献/工程实践**，未复制任何代码）：

| 来源 | 借鉴的内容 | 与本项目的差别 |
| --- | --- | --- |
| FoundationDB 的确定性仿真测试（工程实践） | "用虚拟时间与固定种子取代真实时钟与真实网络"的思想 | FoundationDB 的仿真器内嵌在其数据库内；chaossim 是**协议无关的独立测试台** |
| Jepsen（Kyle Kingsbury） | 用故障注入判定分布式系统正确性的方法论 | Jepsen 跑真集群、真网络故障；chaossim 做**进程内确定性版**：无部署、CI 秒级、可重放 |
| Herlihy & Wing, *Linearizability: A Correctness Condition for Concurrent Objects*, ACM TOPLAS 12(3), 1990 | 线性一致性的**定义** | — |
| Wing & Gong (1993) | 本检查器采用的"按实时序选取下一个可线性化操作"搜索法 | — |

### 关于"复用 moon_historycheck / lincheck"的核实结论

验收说明中提到 `moon_historycheck` / `lincheck`。**核实后这两个包在 MoonCakes 上都不存在**：

```sh
moon fetch moonbit-community/moon_historycheck   # -> was not found in the registry
moon fetch moonbit-community/lincheck            # -> was not found in the registry
```

`moonbitlang/moon_historycheck`（registry API 404）、`moonbit-community/moon_lincheck`、
`moonbit-community/linearizability` 同样不存在。

因此**没有第三方实现可复用，也没有第三方许可证需要声明**。线性一致性检查按**定义**
实现（`sim/lincheck.mbt`），出处写在文件头，未抄任何代码。

## 许可证

本项目许可证：**MIT**（`LICENSE`）。依赖项目的许可证见 `docs/adoption.md` 与
`tools/acceptance.py` 的自动检查（六条验收规则之一）。

## 与参考方案相比的简化和重新设计

- **不做真多进程 / 真网络故障**：只做进程内、单机、可重放这一层。这是刻意的范围收敛，
  理由与行号证据见 `docs/v0.3-async-verdict.md`（`now()` 是固定 C FFI 导入、协程
  `Scheduler` 私有、外部事件循环仅 native 且 JS 为空实现）——**运行时级确定性调度不可行**，
  因此收敛为 sans-I/O 状态机，且"对真实 async 程序做事件注入"最多半确定性，
  不会被包装成可重放；
- **不重写被测对象**：直接接入真实库的生产代码，而**不是**把协议重写成仿真模型。
  差别在问题暴露的层：模型错了是设计问题，真实代码错了是实现问题；
- **不提供内嵌 broker / 仿真对端**：脚本化对端保持无状态（只回 Ack），否则测的就变成
  "我写的仿真对端对不对"，而不是"被测库在故障下自洽吗"；
- **判定与观测分离**：体检电池的"什么算缺陷"抽成纯函数，可以用故意给错的输入逐条验证
  会报 RISK；这是"报告不是橡皮章"的前提。


## 复跑

```sh
moon test --target native                              # 74 项
moon run adapters/mqtt/bin   --target native           # MQTT transcript
moon run adapters/amqp1/bin  --target native           # AMQP 1.0 transcript
moon run adapters/moonmq/bin --target native           # AMQP 0-9-1 broker transcript
moon run adapters/moonmq/checkup    --target native    # 体检报告 1（11 项 + 交错扫描）
moon run adapters/moontxnkit/checkup --target native   # 体检报告 2（事务域，10 项）
moon run examples/quickstart/src --target native       # 最小示例
moon run cmd/perf --target native --release            # 性能
python tools/acceptance.py --since 2026-11-01          # 验收自检
python tools/selfcheck.py                              # 一条命令看全部状态
```

数字属于 `f6071fb`（2026-11-21 实测）；当前值见 `docs/status.md`（每条都带取值命令）。
