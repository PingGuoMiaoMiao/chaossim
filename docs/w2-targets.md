# W2 目标核实（2026-11-19）

目标：给 chaossim 找"没有自带模拟器的真实协议项目"做故障注入靶子。

## 候选核查结果

| 候选 | 结论 | 证据 |
| --- | --- | --- |
| `moonbitstack/moonraft` | **否决**。它自带确定性模拟器（`Cluster`：丢包/延迟/乱序/分区/崩溃重启 + 每步复查安全不变量），还有 etcd datadriven 语料逐字节回放、浏览器 5-worker wasm demo、787 条测试、与参考 Go 实现对练。它不是靶子，是同类设施的完成形态——用它做演示只会复述它自己的测试 | [README](https://github.com/moonbitstack/moonraft)（v0.8.1，11-18 活跃）"Deterministic simulation harness (Cluster)" 一节 |
| `Duckweed/moon-mqtt` | **选定**。纯计算 `ClientCore::start/feed`（字节进→事件+字节出），不依赖 transport；README"已修"清单里三条（等待 PUBACK 期间入站 PUBLISH 插帧、畸形帧后未收尾、解码错误后同批后续帧未停）全是**交错/帧边界类 bug，靠人工发现和验收暴露，不是靠故障注入测试台系统性找出**。它没有跨 reconnect 边界的重放/乱序 harness——正是 chaossim 的注入面 | README"已知限制"原文；v0.3.15，11-18 活跃 |

## 已验证的接缝（spikes/mqtt-seam，8/8 通过）

1. `start()` 出 CONNECT ✓ 2. CONNACK→`ConnackReceived` ✓ 3. §3.1.4 门控
（CONNACK 前 publish 无输出）✓ 4. PUBACK 清在途（inflight 1→0）✓
5. 入站 QoS1 PUBLISH→`PublishReceived` ✓ 6. 核心自动回 PUBACK ✓
7-8. 全部线路报文可编码进 `sim.Msg`（kind/pid 无损映射）✓

诚实记录：spike 第一次 FAIL 是**我自己**把 PUBLISH 的 packet-id 位置读错
（MQTT 的 PUBLISH 是 topic 在前、pid 在后；PID 在 `4+topic_len` 处），库行为
完全正确。这条教训进适配器设计：wire codec 不能手写偏移，必须用 protocol
包自己的编解码。

## 下一步（W2 主体）

把 ClientCore 包成 chaossim 的 Handler：节点 0 = 真实 ClientCore，节点 1 =
脚本化 broker（只按报文类型应答，无状态假设）；注入面 = wire 上的
loss（丢 PUBACK）/ delay（晚到 PUBCOMP）/ 重放（reconnect_bytes 后再投）。
不变量 = inflight 计数有界、自动 ACK 字节合法、`FramerError` 后不再发帧。
任何"库行为与 README 声称不符"的发现，走 issue 披露流程（先复现 trace 再提）。

## 首次运行记录（适配器，seed 7 / max_steps 20）

| 场景 | 故障 | 结果 |
| --- | --- | --- |
| clean | 无 | CONNECT→CONNACK→PUBLISH→PUBACK，inflight 归零，对账成立 |
| ack loss | `loss(1,0,from 3)` | PUBACK 被丢：acks_delivered=0，inflight=1，`inflight == issued - delivered` 仍成立 |
| crash | `crash(1,from 3)` | 与 loss 同终局（从客户端不可区分）——正是期望的等价类 |
| ack delayed (window) | `delay_window(0,3,2,until=5)` | 延迟一次、step6 送达、inflight 归零 |
| ack delayed forever | `delay(0,3,2)` | **饿死**：deferred=9、ACK 永不达、inflight 恒 1，但记账不变量成立 |

诚实结论：首轮未发现 moon-mqtt 的行为 bug（其 QoS1 路径在注入下记账自洽）。
价值主张不依赖"发现 bug"而依赖"**可复核的等价类与不变量**"：饿死与丢失
在客户端侧不可区分、对账式不变量在全部故障下成立——这些是任何人可以
`moon run adapters/mqtt/bin` 复跑的。下一步（W2b）：QoS2 四段握手场景与
多消息交错扫描（已完成，见下），3 节点 partition 待做；届时才谈给上游提
issue 或把等价类报告做成 PR。

## W2b 首轮记录（QoS2，2026-11-19）

| 场景 | 配置 | 结果 |
| --- | --- | --- |
| QoS2 完整握手 | `run_scenario_ex(7, 30, [], qos=2, count=1)` | 恰好 6 步收敛：CONNECT→CONNACK→PUBLISH→PUBREC→PUBREL→PUBCOMP；仅 PUBCOMP(kind 7) 清在途；对账成立 |
| PUBCOMP 丢失 | 同上 + `loss(1,0,from 6)` | 卡死在 WaitPubcomp：inflight 恒 1、acks_delivered=0，`inflight == issued − acks` 仍成立 |
| 双 QoS2 并发交错 | `count=2`，seeds 1..8 | 8/8 全部：握手链完全交叉调度后仍收敛归零、无坏事件、对账成立——**调度顺序即乱序测试**，无一条 seed 触发记账漂移 |

方法论注记：steps==6 与"step 6 丢 PUBCOMP 恰好钉住"两个断言一次通过（预测
来自 QoS 状态机推演）；交错扫描的断言只写不变量与终局，不写 trace 逐行——
后者留给 bin 的 transcript 展示，避免把调度顺序的美观误当契约。
