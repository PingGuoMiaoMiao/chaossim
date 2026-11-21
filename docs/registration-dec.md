# 十二月赛项目申报 · 一页纸（chaossim）

> 用途：12-01 飞书表单「一页项目说明」+ 邮件备用。
> 原则：先给外部基线和可测主张，再讲功能；每个数字都能一条命令复跑；写清"不主张什么"。
> 取数：所有对外数字集中在 [status.md](status.md)（含取值命令），不要从多份文档里拼。
> 按标准申报书格式（基本信息/项目简介/核心功能/移植说明/许可证）的版本见 [application-dec.md](application-dec.md)。
> 本页数字属于 `4ae34ce`（2026-11-21 实测）。

## 一句话

给 MoonBit 生态一个**协议库体检工具**：给它一个真实的协议实现，它跑一遍丢包 / 崩溃 /
分区 / 延迟，输出一份 Markdown 报告，告诉你**哪些恢复与记账路径没有处理**。

```sh
moon run adapters/moonmq/checkup --target native   # 11 项检查 → 一份报告
```

它同时是调度级故障注入测试台：每个失败场景产出**可逐字节重放**的 JSON 工件。
发现问题、复现问题、把问题交给别人——都在 `moon test` 秒级完成。

## 与现有方案的增量

| 现有 | 它们做的 | chaossim 多出来的 |
| --- | --- | --- |
| `oyjh0381/moonlab` | 仿真你**重写成模型**的协议 | 仿真**生产代码本体**；问题若存在，暴露在实现层而非模型层 |
| 靶子自带的 scripted broker / 模拟簇 | 项目内部的正序自查 | **协议无关的可复用 harness**，跨两个域验证 |
| Jepsen（生态外） | 真集群 + 真网络故障 | 同方法论的进程内确定性版：无部署、CI 秒级、可重放 |
| 线性一致性检查器 | 判定并发历史是否合法（oracle） | 本项目**不重造 oracle**：见下节"复用声明"——按定义自己实现了一个并验证了拒绝路径 |

## 复用声明（核实过，结论是"没有可复用的包"）

验收包提到 `moon_historycheck` / `lincheck`。**这两个包在 MoonCakes 上都不存在**：

```sh
moon fetch moonbit-community/moon_historycheck   # -> was not found in the registry
moon fetch moonbit-community/lincheck            # -> was not found in the registry
```

`moonbitlang/moon_historycheck`、`moonbit-community/moon_lincheck`、
`moonbit-community/linearizability` 同样不存在（registry API 返回 404）。

因此**没有第三方实现可复用，也没有第三方许可证可声明**。线性一致性检查按**定义**
实现（[sim/lincheck.mbt](../sim/lincheck.mbt)），出处写在文件头：

- Herlihy & Wing, *Linearizability: A Correctness Condition for Concurrent Objects*,
  ACM TOPLAS 12(3), 1990 —— 定义；
- Wing & Gong, 1993 —— 本检查器采用的搜索法。

未抄任何代码，许可义务仅限本项目自身的 MIT。

## 完成度（每条都能一条命令复跑）

- **内核**：种子化投递调度 + 4 类故障（crash / loss / partition / 窗口化 delay）
  + 有界运行 + trace/计数；`Replay` JSON 工件自包含"场景+结果"，换实现必报分歧
- **不变量钩子**：按**每一步**回调，不只看结尾。三条内置钩子均为投递无关：计数不为负、
  `delivered + dropped == step`（抓消息凭空消失）、trace 不得有空行（防静默步骤）
- **线性一致性检查**：7 条测试**双向**验证——顺序一致通过、**实时序禁止的旧读被拒绝**、
  **写偏斜被拒绝**、并发的两个读可通过、未返回操作不约束、预算耗尽报 unknown 而非通过
- **三个真实靶子，同一套内核零改动**（分两个域）：
  - **消息域**：`Duckweed/moon-mqtt`（MQTT 3.1.1 客户端）、`binhongcha/moonamqp1`
    （AMQP 1.0 端点对）、`Zcxssxx/moonmq`（AMQP 0-9-1 broker，**服务端**语义）
  - **事务域**：`black-duck666/moontxnkit`（MVCC 事务引擎）——脏读、写写冲突、
    快照隔离、保存点、删除、压缩，10 项检查
- **两份体检报告**（命令生成，非手写）：[checkup-moonmq.md](checkup-moonmq.md)、
  [checkup-moontxnkit.md](checkup-moontxnkit.md)；换域指南见
  [checkup-guide.md](checkup-guide.md)（形状可照抄，规则按域重写）
- **恢复路径按靶子文档逐项核对**：丢 PUBACK → `reconnect` + `replay_bytes()` →
  重发 **DUP=1** 的 PUBLISH（DUP 位是解码读回来确认的）；丢 PUBCOMP → 重发
  **PUBREL**（另一条分支，用独立计数器防止互相冒充）。含"不注入故障则无重放"的控制组
- **并发交错扫描**：两个客户端抢同一队列，2 种脚本 × 4 组故障 × 40 种子 =
  **320 次运行，0 违规**（重复投递 / 跨客户端误确认 / 记账闭合）
- **接入指南是可执行的**：`examples/adopting-drill/` 是完全按指南写出的第三方小库，
  随 `moon test` 跑；指南失效则构建红。`examples/quickstart/` 是最小可跑示例
- **性能**：493–570 ns / 调度步（release）；1000 种子 × 20 步扫描约 10 ms
  （`moon run cmd/perf --release`）——全量种子扫描放 CI 可行
- **质量门**：**74/74** 测试、`moon check --deny-warn` 零警告、CI 跑库 + 四个适配器
  + 体检报告 + 接入演练 + 验收自检；验收自检 **8 PASS / 0 WARN / 0 FAIL**，
  文档一致性 **7/7**

## 工程判断（主动否掉的扩张）

1. **运行时级确定性调度不可行**，给出行号证据：`now()` 是固定 C FFI 导入、
   协程 `Scheduler` 私有、外部事件循环仅 native 且 JS 为空实现。范围因此收敛为
   sans-I/O 状态机；"对真实 async 程序做事件注入"最多半确定性，**不会被包装成可重放**。
2. **不以 `moonbitstack/moonraft` 为靶**：它自带确定性模拟簇（丢包/延迟/乱序/分区 +
   etcd 语料逐字节回放），在它身上注入故障等于复述它自己的测试。
3. **不以 `Zcxssxx/moonmq` 的"发现 bug"为目标**：17 条尖角探针 + 320 次交错扫描后
   未发现缺陷，结论如实记为 0，而不是把"故障下自洽"包装成"发现 bug"。

## 不主张什么

- **不主张"发现了靶子的 bug"**：至今未在任何靶子上发现行为 bug。主张的是**故障下的
  等价类与对账不变量**（丢 ACK 与 broker 崩溃在客户端侧不可区分；饿死场景 deferred=9
  仍可精确重放），这些任何人都能复跑核对。
- **不主张"比 Jepsen 更强"**：只做进程内、单机、可重放这一层。
- **不主张体检报告"已证明会发现问题"**：11 条判定规则各自用故意给错的输入验证过
  会报 RISK（27 个断言），但**观测层**——用一个真实写坏的库端到端跑——尚未完成。
  报告里把这两层分开写，不合并成"工具可靠"。
- **不主张"已被采用"**：star 1 / fork 0 / issue 0，`docs/adoption.md` 列了四项判据
  当前全为 0。

## 复跑

```sh
moon test --target native                              # 74 项（含接入演练与对照测试）
moon run adapters/mqtt/bin   --target native           # MQTT transcript
moon run adapters/amqp1/bin  --target native           # AMQP 1.0 transcript
moon run adapters/moonmq/bin --target native           # AMQP 0-9-1 broker transcript
moon run adapters/moonmq/checkup    --target native    # 体检报告 1（11 项 + 交错扫描）
moon run adapters/moontxnkit/checkup --target native   # 体检报告 2（事务域，10 项）
moon run examples/quickstart/src --target native       # 最小示例
moon run cmd/perf --target native --release            # 性能
python tools/acceptance.py --since 2026-11-01          # 验收自检
```

## 验证闭环：门禁**实际抓到过什么**（不是"我们很仔细"）

评分准则第 04 项要的是"能展示其实际发现和防止错误的效果"，所以列实证。
三档自检均可复跑，且每一档都验证过**能失败**（不能失败的门禁等于没有）：

```sh
python tools/selfcheck.py                  # 验收六条 + 文档与代码一致性（离线，CI 用）
python tools/selfcheck.py --with-publish   # + 打包就绪：解压成品包再检查（无需登录）
python tools/selfcheck.py --with-registry  # + 关于 registry 的说法是否属实
```

**这套门禁实际拦下的错误。** 同一套工具用在两个项目上，下表标明是哪一边抓到的——
不把别处的战果记在自己账上：

| 类型 | 具体实例 | 抓到于 |
| --- | --- | --- |
| 数字漂移 | README 写 `31/31 测试`（实为 39） | 本项目 | <!-- consistency:ignore -->
| 数字漂移 | "115 个测试"（实为 116）；ADR 数在同一文档里写成 "53+" 与 "56" 两版 | 文档检索项目 | <!-- consistency:ignore -->
| 结构损坏 | `decisions.md` 中 **D61/D62 各重复两次**、**D51 整条缺失** | 文档检索项目 |
| 文档说谎 | README 贴的 transcript 写 `reconciled=true`，程序实际打印 `matches=true` | 本项目 |
| 外部事实 | 六份文档（含给组委会的回信）称"0.3.1 未发布"，而 registry 上已发布数日；下载数写 35（实为 44） | 文档检索项目 |
| 打包缺陷 | 发布 zip 里混进工作区成员（`adapters/`、`spikes/`），外部消费者会拿到引用不到的源码 | 本项目 |
| 检查器自身 | 验收脚本报 26/26（实为 39）：`moon test` 不带 `--target` 按后端分别打印，脚本只读了第一行 | 本项目 |
| 测试盲区 | QoS2 恢复是**另一条分支**（重放 PUBREL 而非 PUBLISH），QoS1 的测试覆盖不到 | 本项目 |
| 实现 bug | 多客户端重构暴露 broker 应答硬编码回 node0——单客户端永远测不出 | 本项目 |
| **CI 从未绿过** | 工作流 YAML 一直合法，但引用了不存在的 action，30 次运行全部失败 | 本项目 |

两个副产物值得单列，因为它们是"门禁本身可信"的证据：
- 每个检查项都做过**故意让它失败**的验证（改数字、排除被引用文件、篡改输出行）；
- 检查器把"问不到"（网络）与"答错了"（FAIL）分开：前者 SKIP，否则门禁会变成狼来了。

## AI 使用与可解释性

设计与文档 AI 辅助起草；代码由 AI 生成后逐行核对并跑测试。关键取舍全部留档于
`docs/decisions.md`（**D1–D35**），其中包含：

- 三次"断言从真实运行输出反向修正"；
- 一次"默认参数提案被生态惯例否决"、一次"自写基准的负载错误"；
- 两次沙箱内自伤事故的如实记录；
- **一次"从头实现后又回退"的失败记录**（D33 之后的观测层对照尝试：trait 改造撞上
  句柄类型不可构造，栈溢出，显式回退而非静默丢弃）；
- 一次"验收包要求的两个包在 registry 上不存在"的核实记录（D35）。

所有 README 数字来自仓库测试实测。
