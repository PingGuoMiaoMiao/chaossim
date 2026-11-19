# 30 行接上 chaossim（给别人的库用）

目标是：**不改你的实现**，只写一层胶水，让 chaossim 的种子调度 + 故障注入
跑在你的真实代码上，并且能断言"故障下状态仍然自洽"。

## 前提（先自查，不满足就别硬接）

1. **你的核心是可计算的**：有 `bytes/事件 进 → bytes/事件 出` 这样的接口，
   或者至少"喂一条消息、返回要发出的消息"。sans-I/O 的状态机最理想。
2. **有可断言的数值状态**：`pending`、`credit`、`inflight`、`discard` 之类。
   没有的话，你只能断言"没崩"，价值有限。
3. **没有自带故障注入台**。如果已经有，接 chaossim 只是重复建设。

## 三步

### 第 1 步：定义 World（你唯一的存储）

```moonbit
pub(all) struct World {
  core : @yourlib.Core          // 你的真实对象
  mut frames : Array[Bytes]     // 待发帧的槽位
  mut issued : Int32            // 你关心的计数
  mut acks : Int32
  mut bad_events : Int32        // 不该出现的事件
}
```

`frames` 是关键：chaossim 的 `Msg.payload` 是 `Int32`，所以**用槽位下标传字节**，
不要试图把报文塞进整数。槽位只追加、注册顺序确定，重放才稳定。

### 第 2 步：写 Handler（两个节点就够）

```moonbit
pub fn make_handler(w : World) -> @sim.Handler {
  let box : Array[World] = [w]        // 单元素数组换取可变性
  (node, msg) =>
    if node == 0 {
      step_client(box[0], box[0].frames[msg.payload])   // 你的客户端
    } else {
      step_peer(box[0], box[0].frames[msg.payload])     // 脚本化的对端
    }
}
```

对端（broker/服务端）**保持无状态**：只按报文类型回 Ack。一旦你给它加会话表，
你就开始测试"你写的仿真对端"而不是被测库了。

### 第 3 步：选不变量 + 故障，跑

```moonbit
let s = @sim.run_bounded(
  make_handler(w),
  [{ from: 0, to: 1, payload: first_slot }],
  seed,          // 种子
  100,           // 步数上限
  [@sim.loss(1, 0, 3)],   // 从第 3 步起，1->0 的帧全丢
)
assert_eq(s.result.dropped >= 1, true)
assert_eq(w.inflight == w.issued - w.acks, true)   // 与投递无关的记账
```

## 不变量怎么挑（最重要的一步）

优先选**与投递无关**的等式，例如：

- `inflight == issued - delivered`（消息在途数 = 发出 − 确认送达）
- `credit_before - sends == credit_now`（信用在 send 时扣除，与是否抵达无关）
- `pending_out == 0` 仅在"完整握手后"才断言，不要在中途断言

反面教材：只断言"消息送到了"——那在故障场景里本来就是期望失败的，
断言它等于没断言。

## 常见坑

| 坑 | 症状 | 处理 |
| --- | --- | --- |
| 用全局计数器记跨客户端状态 | 双客户端时结果随种子变 | 改成按客户端数组，键从 `msg.from` 取 |
| 断言写"想象中的语义" | 测试第一次就红，怀疑库 | 先跑一遍打印真实值，再按实测写断言（本项目的 D8 就是这么来的） |
| 对端加状态 | "我的仿真 broker 说不通" | 对端保持无状态，只回类型对应的 Ack |
| 忘了 `raise` | 一堆 "Function with error can only be used inside..." | handler 里的可抛调用用 `try { } catch { _ => bad_events += 1 }` 包住，把异常记成发现 |

## 现成范例

- `adapters/mqtt/`：MQTT 3.1.1 客户端（QoS1/QoS2、恢复路径）
- `adapters/amqp1/`：AMQP 1.0 端点对（credit / settlement）

两份加起来不到 700 行，含测试与 transcript。
