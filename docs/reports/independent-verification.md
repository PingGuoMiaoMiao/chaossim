# 独立验证报告（可发给上游维护者）

本文件记录 chaossim 对两个生态项目做的**独立故障注入验证**。它们不是本项目的
依赖方，也没有参与设计；结论由本仓库的测试与 transcript 产出，任何人可复跑。

复跑方式：

```sh
moon test --target native                      # 全部 34 项
moon run adapters/mqtt/bin  --target native    # MQTT transcript
moon run adapters/amqp1/bin --target native    # AMQP 1.0 transcript
```

---

## 1. `Duckweed/moon-mqtt@0.3.15` — MQTT 3.1.1 客户端

验证对象：`core/ClientCore`（纯计算核心，四后端可测），不涉及 TCP/WebSocket 传输层。

### 已验证成立的行为

| 场景 | 注入 | 观察 | 结论 |
| --- | --- | --- | --- |
| QoS1 正常闭环 | 无 | `inflight` 0→1→0 | 与文档一致 |
| QoS1 确认丢失 | `loss(1,0,from 3)` | `inflight` 停在 1，`acks=0` | 符合预期：确认没到就不算完 |
| QoS1 确认永久慢 | `delay(0,3,2)` | 同一 ACK 被反复延迟（deferred=9），`inflight` 恒 1 | 慢节点会饿死确认；记账仍精确 |
| QoS1 确认窗口慢 | `delay_window(0,3,2,until 5)` | 窗口结束后送达，`inflight` 归零 | 窗口语义可用 |
| QoS2 完整握手 | 无 | 恰好 6 步收敛（CONNECT/CONNACK/PUBLISH/PUBREC/PUBREL/PUBCOMP），仅 PUBCOMP 清在途 | 与规范一致 |
| QoS2 PUBCOMP 丢失 | `loss(1,0,from 6)` | 卡在 WaitPubcomp，`inflight` 恒 1 | 符合预期 |
| 两条 QoS2 并发 | `count=2`，seeds 1..8 | 8/8 全部收敛归零，无坏事件 | 交错调度下不串号 |
| 双客户端隔离 | `partition([0],[1],from 1)` | 被隔离客户端 `issued=0`，对端完整完成 | lanes 相互独立 |

### 恢复路径（重点）

文档承诺：断线后 `reconnect()`，若 `session_present=1` 则按 `replay_bytes()`
重发在途 QoS1/2 且置 DUP。

注入 `loss(1,0,from 3)` 使 PUBACK 丢失后，按该流程恢复：

```
阶段 A: send 1 CONNECT → send 2 CONNACK → send 3 PUBLISH → drop 4 PUBACK (loss)
阶段 B: send 1 CONNECT → send 2 CONNACK(session_present=1) → send 3 PUBLISH(DUP=1) → send 4 PUBACK
结果:   connects=2 replays=1 dups=1 inflight=0 reconciled=true
```

`dups=1` 是把重放帧用 `decode_packet` 解回来读 `dup` 字段得到的，不是推断。
控制组（同样两阶段但不注入故障）得到 `replays=0`，排除"无论如何都重放"。

**结论：该恢复路径在注入故障后确实恢复，且重放帧 DUP 标记正确。**

### 未覆盖

- 传输层（`transport/`、`browser/` 的 WebSocket 胶水）不在覆盖范围，它们是
  C FFI / JS 边界，本方法只覆盖纯计算核心。
- MQTT 5.0 未实现，自然未验证。

---

## 2. `binhongcha/moonamqp1@0.2.1` — AMQP 1.0 协议核心

验证对象：`Endpoint` 对（application sender ↔ service receiver），全程只用
`drain()` / `receive(bytes)` / `events()` 三个公开接口——与该项目自己的示例
驱动方式一致。

### 已验证成立的行为

| 场景 | 注入 | 观察 | 结论 |
| --- | --- | --- | --- |
| 单条消息闭环 | 无 | `sends=1 received=1 settled=1 pending=(0,0)` | 与文档一致 |
| 传输丢失 | `loss(0,1,from 1)` | `received=0 settled=0 pending=(1,0)`；**credit 记账仍精确** | 发送方扣了 credit，帧没到，状态自洽 |
| 结算丢失 | `loss(1,0,from 2)` | `received=1 settled=0 pending=(1,0)` | 服务端收到并确认，确认没回到发送方 → 保持未结算（正是重试决策需要看到的状态） |
| 服务端慢 | `delay_window(1,2,3,until 6)` | 收敛回 `(0,0)` | 延迟不影响最终一致性 |
| 种子扫描 | seeds 1..6 × 三种故障 | credit 等式全部成立 | 记账与投递无关 |

关键不变量（始终成立）：

```
credit_before - sends == link_credit(now)
```

### 未覆盖

- 握手（start/begin/attach/grant）在适配器里是**同步**执行的，没有被调度器
  打散——故障注入从消息周期开始。握手期间的故障未覆盖。
- 该项目 README 明确不支持的部分（broker、TCP、SASL、TLS、持久 outbox）不在
  范围。

---

## 说明

本报告不做任何"质量评价"，只陈述在本仓库可复跑的观察。若上游希望把这些场景
并入各自的 CI，`adapters/*/adapter_wbtest.mbt` 可直接作为起点；若发现本文描述
与你当前实现不符，以你的仓库为准并请告知，我会更新场景。
