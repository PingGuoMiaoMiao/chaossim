# 当前状态快照（2026-11-25 实测）

> 用途：申报表/验收材料取数用，不必从多份文档里拼。
> 每一行都给出**取值方式**，所以过期了可以自己重算，而不是相信这份文档。
> 本文件是快照：数字属于 2026-11-25 11:40（UTC+8）。

## 关键事实

| 项 | 值 | 怎么取的 |
| --- | --- | --- |
| 仓库版本 | `0.3.0` | `moon.mod` 的 `version` |
| MoonCakes | **已发布 `0.3.0`**（构建 `success`） | `mooncakes.io/api/v0/manifest/PingGuoMiaoMiao/chaossim` → `latest_version` / `build_status` |
| 打包就绪 | ✅ 成品包解压后**重新检查通过** | `moon publish --dry-run` 会解压 zip 再 check 一遍 |
| 测试 | **74 / 74 全绿** | `moon test --target native` |
| 验收自检 | **8 PASS / 0 WARN / 0 FAIL** | `python tools/acceptance.py --since 2026-11-01` |
| 文档一致性 | **8 / 8 通过** | `python tools/consistency.py` |
| 提交数 | 见命令（每次提交都会变，不写死） | `git rev-list --count HEAD` |
| 最近提交 | 见命令 | `git log -1 --date=short` |
| GitHub Star / Fork / Issue | 1 / 0 / 0 | `gh api repos/PingGuoMiaoMiao/chaossim` |
| CI | 全绿（含库 / 工作区 / 两个 transcript / 接入演练 / 自检） | `gh run list --limit 1` |

## 三条核心证据（都可复跑）

**1. 真实协议代码在注入故障后的记账不变量**

```sh
moon run adapters/mqtt/bin --target native
```

打印逐场景 transcript。关键一行：注入 `loss` 丢弃 PUBACK 后
`node0: issued=1 acks=0 inflight=1 matches=true`——**丢包下记账仍然自洽**。

**2. 恢复路径按靶子文档核对过**

丢 PUBACK → `on_transport_close()` + `reconnect_bytes()` → `session_present=1` →
`replay_bytes()` → 重放帧 **DUP=1**（用 `decode_packet` 读回确认）→ `inflight=0`。
QoS2 走**另一条分支**：卡在 WaitPubcomp 时重放的是 **PUBREL** 而非 PUBLISH。
两个独立计数器防止两条分支互相冒充。

**3. 仓库之外的独立模块能用起来**

```sh
python tools/consumer_check.py
```

在临时目录新建完全独立的模块，按名字依赖 chaossim，跑真实 crash 场景：

```
steps=2 delivered=1 dropped=1 / replay_bytes=285 / verified_steps=2
```

第三步是重点——**replay 工件不是日志，是可执行的主张**，外部模块能自证。

## 性能（release，单机）

```sh
moon run cmd/perf --target native --release
```

| 形状 | 每次运行 | 每调度步 |
| --- | --- | --- |
| 4 步 | 2.00 us | 499 ns |
| 20 步 | 9.24 us | 462 ns |
| 200 步 | 107.8 us | 539 ns |

线性 ⇒ 成本就是"每调度步"。**1000 种子 × 20 步 ≈ 9–10 ms**，全量种子扫描放 CI 可行。

## 可以主张 / 不可以主张

**可以主张**（每条有可复跑证据）：

- 在**真实协议代码**上做调度级故障注入（不是仿真你重写的模型），失败场景可逐字节重放；
- 同一套内核**零改动**驱动三种靶子（MQTT 3.1.1 客户端 / AMQP 1.0 端点对 / AMQP 0-9-1 broker）；
- 靶子的**恢复语义被逐项核对**（QoS1 重发 DUP 帧、QoS2 重发 PUBREL），含控制组；
- 仓库之外的模块能用：注入故障、拿到工件、自证重放；
- 接入指南是**可执行的**（`examples/adopting-drill/` 随测试跑，指南失效即红）。

**不能主张**：

- 已发布（包已就绪，`202 Accepted`，但需 `moon login` → `moon publish`）；
- 已被采用（star 1 / fork 0 / issue 0，`docs/adoption.md` 列出四项判据当前全为 0）；
- 发现了靶子的 bug——**至今未发现**行为 bug，主张的是故障下可复核的等价类与
  对账不变量，不是 bug 标题党；
- 运行时级确定性调度（v0.3 spike 判定不可行，附行号证据）。

## 主动否掉的扩张（工程判断）

| 被否 | 理由 |
| --- | --- |
| 以 `moonbitstack/moonraft` 为靶 | 它自带确定性模拟簇（丢包/延迟/乱序/分区 + etcd 语料逐字节回放），在它身上注入故障等于复述它自己的测试 |
| 以 `Zcxssxx/moonmq` 为靶 | 最后推送 2026-09-27（停更两个月）且自带内嵌 broker，会把"测协议实现"变成"测我写的仿真 broker" |
| 运行时级调度接管 | `now()` 是固定 C FFI、协程 `Scheduler` 私有、外部事件循环仅 native——行号证据见 `docs/v0.3-async-verdict.md` |
| `moon bench` / `@bench.Bench` | 前者发现不了这些 bench；后者自动校准迭代，在这么便宜的工作负载上烧了 131 秒 CPU 还在跑 |

## 门禁抓到过的自身错误

这套检查不是装饰。**在本项目**上它拦下过：

- README 里过期的测试数（写 31/31，实为 39）与缺失的 ADR 条目（申报引用 D17 时它还不存在）； <!-- consistency:ignore -->
- README 贴的 transcript 与程序实际输出不符（写 reconciled=true，程序打印 matches=true）；
- 发布 zip 里混进工作区成员（adapters/、spikes/），外部消费者会拿到引用不到的源码；
- 验收脚本把测试数报成 26（moon test 不带 --target 时按后端分别打印，脚本只读了第一行）；
- broker 应答硬编码回 node0——单客户端永远测不出，是多客户端重构才暴露的；
- "CI 一直是红的"：工作流 YAML 一直合法，但引用了不存在的 action，30 次运行全失败。

明细见 `docs/decisions.md`（D9/D15/D20/D23/D27）。同一套工具在姊妹项目上还拦下过
重复的 ADR 编号、「0.3.1 已发布却写成未发布」等——战果分开记，不混算。
