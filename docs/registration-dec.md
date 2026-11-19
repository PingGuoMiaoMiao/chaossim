# 十一月…不对，十二月赛项目申报 · 一页纸（chaossim）

> 用途：12-01 飞书表单"一页项目说明"字段 + 邮件备用。
> 写法吸取 docmunch 初审教训：先给外部基线和可测主张，再讲功能；不写不能复跑的数字。

## 一句话

给 MoonBit 生态一个**调度级故障注入测试台**：把你**真实的**协议/状态机代码放进
确定性调度器，注入 crash / loss / partition / delay（窗口化），每个失败场景产出
可逐字节重放的 JSON 工件——发现问题、复现问题、给别人看问题，都在 `moon test` 级别完成。

## 与现有方案的增量（外部基线，评审可逐条核对）

| 现有 | 它们做的 | chaossim 多出来的 |
| --- | --- | --- |
| `oyjh0381/moonlab` | 仿真你**重写成模型**的协议 | 仿真**生产代码本体**（handler 就是库的真实入口函数）；发现的是实现 bug 类，不是模型 bug 类 |
| `NekoYume517/lincheck`、`123123213weqw/moon_historycheck` | 并发历史的一致性判定（oracle） | 不重造 oracle：作为不变量检查器接入；chaossim 负责**产生**可控执行 |
| `Duckweed/moon-mqtt` 自带 scripted-broker、`moonbitstack/moonraft` 自带模拟簇 | 各自项目内部的正序/自查仿真 | **协议无关的可复用 harness** + 跨项目验证（现成用例：驱动 moon-mqtt 真实 ClientCore，5 种故障下记账不变量 `inflight == issued − acks_delivered` 全绿，含 ACK 饿死场景 deferred=9） |
| Jepsen（生态外） | 真集群 + 真实网络故障 | 同方法论的进程内确定性版：无部署、CI 秒级、逐字节重放 |

## 当前完成度（全部可复跑，命令在 README）

- 内核：种子化投递调度 + 4 类故障 + 有界运行 + trace/计数，13 项契约测试
- 重放工件：场景+结果自包含 JSON，`replay_verify` 换实现必报分歧
- 真实靶子：moon-mqtt 适配器（全部应答走**库自己的编码器**），6 项联合不变量测试
- 质量门：workspace 19/19 测试，`moon check --deny-warn` 零警告，5 个 commit 连续公开历史（11-19 起）

## 本月计划（十二月赛验收前）

1. QoS2 四段握手场景 + 3 节点 partition；乱序重放注入（对应 D3/D8 语义）
2. 不变量接入 `moon_historycheck` 或 `lincheck`（复用声明：出处+许可证）
3. 第 2 个真实靶子接入（候选：`Zcxssxx/moonmq` AMQP broker，尚无自带故障台）
4. 发布 mooncakes 0.3.0（带真实靶子用例后首发）

## AI 使用与可解释性

设计与全部文档 AI 辅助起草；代码由 AI 生成后人逐行核对并跑测试，关键取舍在
`docs/decisions.md`（D1–D8，含两次"断言从真实运行输出反向修正"与一次"默认参数
提案被生态惯例否决"的如实记录）。所有 README 数字 = 仓库测试实测，可逐条复跑。

## 边界（明确不做）

真多进程 / 真网络包劫持 / 任意 async 程序的运行时级截停（v0.3 spike 明示
可行与否后再承诺）；不做模型描述语言（那是 moonlab 的位置）。
