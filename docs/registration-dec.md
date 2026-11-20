# 十二月赛项目申报 · 一页纸（chaossim）

> 用途：12-01 飞书表单「一页项目说明」+ 邮件备用。
> 原则（吸收 docmunch 初审教训）：先给外部基线和可测主张，再讲功能；
> 每个数字都必须能一条命令复跑；写清"不主张什么"。

---

> 取数：所有对外数字集中在 [status.md](status.md)（含取值命令），不要从多份文档里拼。

## 一句话

给 MoonBit 生态一个**调度级故障注入测试台**：把**真实的**协议/状态机代码放进
确定性调度器，注入 crash / loss / partition / delay，每个失败场景产出**可逐字节
重放**的 JSON 工件。发现问题、复现问题、把问题交给别人——都在 `moon test` 秒级完成。

## 与现有方案的增量

| 现有 | 它们做的 | chaossim 多出来的 |
| --- | --- | --- |
| `oyjh0381/moonlab` | 仿真你**重写成模型**的协议 | 仿真**生产代码本体**；问题若存在，暴露在实现层而非模型层 |
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
- **质量门**：57/57 测试、`moon check --deny-warn` 零警告、CI 跑库 + 两个适配器 +
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

## 验证闭环：门禁**实际抓到过什么**（不是"我们很仔细"）

评分准则第 04 项要的是"能展示其实际发现和防止错误的效果"，所以列实证。
三档自检均可复跑，且每一档都验证过**能失败**（不能失败的门禁等于没有）：

```sh
python tools/selfcheck.py                  # 14 项：验收六条 + 文档与代码一致性（离线，CI 用）
python tools/selfcheck.py --with-publish   # + 打包就绪：解压成品包再检查（无需登录）
python tools/selfcheck.py --with-registry  # + 关于 registry 的说法是否属实
```

**这套门禁实际拦下的错误。** 同一套工具用在两个项目上（本项目与一个文档检索项目），
下表按类型列出，并标明是哪一边抓到的——不把别处的战果记在自己账上：

| 类型 | 具体实例 | 抓到于 |
| --- | --- | --- |
| 数字漂移 | README 写 `31/31 测试`（实为 39） | 本项目 | <!-- consistency:ignore -->
| 数字漂移 | "115 个测试"（实为 116）；ADR 数在同一文档里写成 "53+" 与 "56" 两版 | 文档检索项目 | <!-- consistency:ignore -->
| 结构损坏 | `decisions.md` 中 **D61/D62 各重复两次**、**D51 整条缺失** | 文档检索项目 |
| 文档说谎 | README 贴的 transcript 写 `reconciled=true`，程序实际打印 `matches=true`（凭记忆抄输出） | 本项目 |
| 外部事实 | 六份文档（含给组委会的回信）称"0.3.1 未发布"，而 registry 上已发布数日；下载数写 35（实为 44） | 文档检索项目 |
| 打包缺陷 | 发布 zip 里混进工作区成员（`adapters/`、`spikes/`），外部消费者会拿到引用不到的源码 | 本项目 |
| 检查器自身 | 验收脚本报 26/26（实为 39）：`moon test` 不带 `--target` 按后端分别打印，脚本只读了第一行 | 本项目 |
| 测试盲区 | QoS2 恢复是**另一条分支**（重放 PUBREL 而非 PUBLISH），QoS1 的测试覆盖不到 | 本项目 |
| 实现 bug | 多客户端重构暴露 broker 应答硬编码回 node0——单客户端永远测不出 | 本项目 |

两个副产物值得单列，因为它们是"门禁本身可信"的证据：
- 每个检查项都做过**故意让它失败**的验证（改数字、排除被引用文件、篡改输出行）；
- 检查器把"问不到"（网络）与"答错了"（FAIL）分开：前者 SKIP，否则门禁会变成狼来了。

## AI 使用与可解释性

设计与文档 AI 辅助起草；代码由 AI 生成后逐行核对并跑测试。关键取舍全部留档于
`docs/decisions.md`（D1–D17），其中包含三次"断言从真实运行输出反向修正"、
一次"默认参数提案被生态惯例否决"、一次"自写基准的负载错误"，以及两次沙箱内
自伤事故的如实记录。所有 README 数字来自仓库测试实测。
