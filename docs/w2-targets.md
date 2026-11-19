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
