# 证据索引（claim → command → artifact）

本页把所有对外主张映射到**一条复跑命令**和**仓库里的文件**。评审不必相信我，
跑一条命令即可。任何一条对不上，以你的运行为准并请告知。

约定：所有命令在仓库根目录执行；`--target native` 省略亦可，但 native 是本项目
声明的主目标。

## 核心主张

| 主张 | 命令 | 期望 |
| --- | --- | --- |
| 内核确定：同种子同故障 ⇒ 同结果 | `moon test --target native` | `Total tests: 39, passed: 39` |
| 重放工件可对账，换实现必报分歧 | 同上（`world_wbtest.mbt` 的 replay 用例） | `ReplayMismatch` 用例通过 |
| 真实靶子 1：MQTT 客户端跑在调度器下 | `moon run adapters/mqtt/bin --target native` | 打印各场景 trace + `reconciled=true` |
| 真实靶子 2：AMQP 1.0 端点对 | `moon run adapters/amqp1/bin --target native` | `credit_accounted=true` 且 `bad_events=0` |
| 恢复路径（QoS1 重发 DUP 帧） | `moon test adapters/mqtt/adapter --target native` | `ack loss is recovered by reconnect + replay with DUP set` 通过 |
| 恢复路径（QoS2 重发 PUBREL） | 同上 | `qos2 pubcomp loss recovers by replaying PUBREL, not PUBLISH` 通过 |
| 接入指南可执行 | `moon test examples/adopting-drill/drill/src --target native` | 3 项通过 |
| 性能足够进 CI | `moon run cmd/perf --target native --release` | 约 460–500 ns/步；1000 种子 × 20 步 ≈ 9–10 ms |
| 验收六条自检 | `python tools/acceptance.py --since 2026-11-01` | `8 pass, 0 warn, 0 fail` |

## 文件地图

| 想找什么 | 在哪 |
| --- | --- |
| 内核：调度 / 故障 / 重放 | `sim/world.mbt`、`sim/faults.mbt`、`sim/replay.mbt` |
| 契约测试（39 项） | `sim/world_wbtest.mbt`、`adapters/*/adapter_wbtest.mbt`、`examples/**/drill_wbtest.mbt` |
| 靶子适配器 | `adapters/mqtt/`、`adapters/amqp1/` |
| 场景 transcript | `adapters/*/bin/main.mbt` 的输出 |
| 接入指南 / 从零演练 | `docs/adopting.md`、`examples/adopting-drill/` |
| 上游验证报告 | `docs/reports/independent-verification.md` |
| 采用记录（未发布阶段能证明什么） | `docs/adoption.md`、`tools/consumer_check.py` |
| 体检工具与样板报告 | `adapters/moonmq/checkup`、`docs/checkup-moonmq.md`、`docs/checkup-guide.md` |
| 运行时可行性裁决 | `docs/v0.3-async-verdict.md`（含行号） |
| 每一个取舍的理由 | `docs/decisions.md`（D1–D17） |
| 靶子选型与被否候选 | `docs/w2-targets.md` |
| 性能方法与踩坑 | `docs/decisions.md` D15、`cmd/perf/main.mbt` |
| 申报一页纸 | `docs/registration-dec.md` |

## 这张表自己也会过期

证据索引最容易变成历史遗迹。缓解手段：`tools/acceptance.py` 与
`examples/adopting-drill/` 都挂在 CI 上（`moon test` / 校验脚本），
主张一旦失效会先让构建红，而不是让这张表悄悄说谎。

尚未自动化：本页「命令 → 期望」的对应关系本身。若某条命令的输出格式变了，
这里不会自动跟着变。已知缺口，不做掩饰。

## 新读者演练（2026-11-19 实测）

为了验证"从零 clone 能不能跑通"，没有在工作区里假设，而是真的重新 clone 到
一个空目录（无 `.mooncakes`、无 `_build`），照 README 逐条执行：

| 命令 | 退出码 | 耗时 |
| --- | --- | --- |
| `git clone`（60 个文件） | 0 | — |
| `moon test --target native` | 0 | 4.2 s（39/39，依赖自动解析） |
| `moon run adapters/mqtt/bin --target native` | 0 | 1.7 s |
| `moon run adapters/amqp1/bin --target native` | 0 | 1.2 s |
| `moon run cmd/main --target native` | 0 | 0.6 s |
| `python tools/acceptance.py --skip-build` | 0 | 7 pass / 1 warn（跳过构建的提示） |
| `python tools/consistency.py --skip-build` | 0 | 3 ok / 0 fail |

**这次演练改掉了一条真问题**：原本的 Quick start 只有三条命令
（build / test / run cmd/main），新读者照它走**永远看不到两个真实靶子**——
而那是本项目全部说服力所在。现在的 Quick start 把
`moon run adapters/mqtt/bin` 放在第二位，并注明"先看这条"。

未覆盖：Windows 之外的平台（本次演练在 Windows）；首次需要下载依赖时的网络耗时
（本机 registry 已有缓存）。
