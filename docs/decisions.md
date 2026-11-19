# 决策记录（chaossim）

格式对齐 docmunch 的 decisions.md：每条 = 决定 + 为什么 + 放弃了什么。
AI 辅助起草，人工逐条核对并跑测试验证。

## D1 — `run_bounded` 用 `raise SimError`，不用 `Result` 手递

无效故障计划是**编程错误**，不是运行时业务分支；raise+catch 让正常路径保持
干净（`let r = run(...)`），错误路径在入口一次 catch。与 docmunch 的
`pub suberror` + `-> T raise E` 工具链惯例一致。放弃：`Result[RunResult,
SimError]` 会让每个示例都多两层 match，README 演示变糊。

## D2 — `Fault` 用 string-kind 结构体，不用 enum

故障列表要**原样往返 JSON**（replay 工件），enum 的 serde 形态在不同版本间
更脆；结构体 + 构造器（`crash/loss/delay/partition`）把字符串封装在 API 后，
用户不手打 kind。代价：编译期穷尽性丢失 → 用 `check()` 在运行第一步前 fail
fast，并有 `expect_invalid` 测试族兜底。放弃：`#derive(ToJson)` on enum。

## D3 — delay 是"每次调度都生效"，不是"每条消息只延迟一次"

`delay(node, from_step, hold)` 拦截的是**投递动作**：节点慢，重试就再慢。
因此慢节点 + 永远重试的 handler = 可观察的 livelock，trace 里逐条可见
（`world_wbtest` 的 "slow-node livelock" 用例把它钉成契约）。若按"每条只
延迟一次"实现，需要给消息加身份标记，破坏 Msg 的纯数据性，也和真实慢节点
行为不符。放弃：once-per-message 延迟。

## D4 — replay 工件同时存"输入"和"结果"

只存输入的话，工件无法自证"当时确实跑出了这个结果"；只存结果的话无法重跑。
`Replay { seed, max_steps, initial, faults, result }` 让 `replay_verify`
做**主张对账**：重放 ≠ 记录 ⇒ `ReplayMismatch`，报错带首个差异行。这是
"issue 附件"级别的复现物。代价：工件体积翻倍（trace 本来就不大）。

## D5 — 调度步数即"时间"，不引入墙上时间

时钟 tick = 步；held 消息按步释放；空步也计数。一切从 seed 出发可重放，
跨后端逐字节一致。真实时长语义留给 v0.3 spike（async 运行时截停）再谈。

## D6 — 靶子选择：否决 moonraft，选定 moon-mqtt

原计划 W2 用 `moonbitstack/moonraft` 做示范靶。核实 README 后发现它自带
确定性模拟簇（丢包/延迟/乱序/分区/崩溃 + 安全不变量逐步复查 + etcd 语料
逐字节回放）——在它身上"注入故障"是在复述它自己的测试。选定标准改为
"**没有自带调度级故障注入 harness 的真实协议项目**"：`Duckweed/moon-mqtt`
的三条已修 bug 全是交错/帧边界类，且其测试为脚本化正序路径 + 人工验收，
无乱序/延迟/重放注入面。详见 docs/w2-targets.md。

## D7 — 先 spike 后适配器；wire codec 不手写偏移

spike（spikes/mqtt-seam）只回答一个问题：外部 harness 能否用
`start/feed/publish` 纯字节接缝驱动 ClientCore。8/8 通过。过程中第一次
FAIL 是我手写 MQTT 偏移出错（PUBLISH 的 packet-id 在 topic 之后，不在
固定头后），库的行为是对的——这直接定下适配器规则：**报文解析必须复用
protocol 包自身编解码，chaossim 侧只调度"已解码的事件"，不再碰裸偏移**。

## D8 — delay 拆成 `delay`（永久慢）与 `delay_window`（窗口慢），不引入默认参数

触发：适配器第一条 delay 场景的断言与实现语义相撞——`delay(node, from, hold)`
按 D3 是"每次投递都延迟"，对 ACK 就是**永久饿死**；run 的 transcript 显示
`deferred=9`、inflight 恒 1、而对账不变量 `inflight == issued - delivered`
依然成立。这是好证据，不是 bug：它同时刻画了"慢节点饿死"和"记账在故障下
仍自洽"。于是补窗口变体 `delay_window(..., until)`（窗口外恢复正常投递）。
曾先试 `until : Int32 = -1` 默认参数——编译器要求 label 参数，而本地生态
（moon-mqtt、依赖树全部包）没有一个默认参数，惯例是 option-struct 或双函数。
跟随生态惯例，撤销默认参数。教训同 D7：断言来自第一次真实运行的输出，
不来自想象中的语义。

## D9 - 多客户端：节点号 = 2*idx，broker = 1；脚本 broker 保持无状态

重构 `World` 从单 core 变成 `cores[] / bfors[] / issued[] / acks_delivered[]`，
节点编号规约：客户端占偶数（0, 2, 4...），broker 固定 1。三个理由：
1. **分区故障的表达力**：`partition([0],[1])` 天然表示"切掉 node0 与 broker 的
   链路"，另一条链路不受影响——单客户端模型根本表达不了"隔离一个、放行另一个"。
2. **多 core 不共享状态**：每个客户端独立 ClientCore/独立 Framer，`issued` 与
   `acks_delivered` 都按客户端记账，bad_events 保持全局（任何客户端出问题都是
   发现）。
3. **broker 无状态是有意的**：脚本 broker 只回 pid 回声（PUBACK/PUBREC/PUBCOMP
   全部用库自己的编码器），不建模会话表。理由是"加入会话状态等于自己写一个
   broker simulator，把靶子问题变成'我的仿真 broker 对不对'"——超出本层职责。

同时修了一处**只有双客户端才能暴露的真 bug**：broker 的应答原先硬编码发往
node 0（单客户端时永远正确）。改成回给 `msg.from`。这条 bug 是本次重构的
直接收益，记在这里作为"为什么值得做多客户端"的证据。

### 关键设计约束（写测试时踩到的）
分区切断点若落在"两个 CONNACK 还没发完"的窗口里，`issued` 会因客户端是否
拿到 CONNACK 而分叉，**断言不再 seed 无关**。因此测试只钉两类由构造保证
seed 无关的场景：① 从第 1 步切断（对方根本建不起会话）② 窗口内延迟恢复。
"第 5 步切断"这种中途隔离放进 bin transcript 展示，不写进硬断言——同 D8。

## D10 - 工作区成员不进发布包：用 .moonignore，不是 moon.mod 的 exclude

发现：`moon package` 把 `adapters/mqtt/` 与 `spikes/mqtt-seam/` 一起打进了
发布 zip。这两个是**独立模块**（各有 moon.mod）且依赖 `Duckweed/moon-mqtt`——
不是主库的依赖。后果是消费者下载后拿到一堆引用不到包的源码，外加一个
moon.work 邀请构建器把它们当成员解析。

先试 `moon.mod` 的 `exclude = [...]`：本工具链（0.1.20261104）直接拒绝，
报 "Unexpected key 'exclude' found in moon.mod"。registry 里 moon-mqtt 的
exclude 字段是发布侧生成的元数据，不是同名配置项的来源。改用 `.moonignore`
（`adapters/`、`spikes/`、`moon.work`），打包后逐条目验证：泄漏 0 条，
只留 sim/ + cmd/ + docs/ + 元数据。

权衡：测试文件（world_wbtest.mbt）保留在包里——消费者可以自己 `moon test`
验证行为，这是"可验证"卖点的一部分，体积代价可忽略。

CI 里仍然构建工作区成员（adapters/spikes）。理由：适配器是"库能驱动真实
协议代码"的证明，它回归就是真回归；但它不该出现在别人下载的包里。这两件事
互不矛盾，靠 .moonignore 分开。

## D11 - 第二靶子选 MoonAMQP1（而非 MoonMQ）：活跃度 + sans-I/O + 无自带 broker

原候选 `Zcxssxx/moonmq`（AMQP 0-9-1 核 + 内嵌内存 broker）被否，三条理由：
1. **停更**：GitHub 最后推送 2026-09-27，是 9 月赛项目，已近两个月无动静；
   给它报 bug 没人接，"采用"故事也立不住。
2. **自带 broker**：它把 broker 也实现了，等于半个仿真环境；在它身上注入故障
   容易变成"测它的 broker 对不对"，而不是"测协议实现在故障下的记账"。
3. 依赖 async 0.20.2 且 preferred_target=wasm，驱动面偏重。

改选 `binhongcha/moonamqp1@0.2.1`（AMQP 1.0）：
- 11-16 仍活跃；
- **sans-I/O 是设计目标**（bytes/commands -> bytes/events，README 原话"无内置
  broker、TCP 客户端、SASL、TLS"），接缝天然就是 chaossim 要的形状；
- 带**可断言的数值状态**：link credit、session window position、pending、
  settlement。这让"与投递无关的不变量"成为可能，而不是只能断言"消息到了没"。

关键不变量（本轮实测全部成立）：

    credit_before - sends == link_credit(now)

理由：AMQP 在 `send()` 时就扣 credit，与帧是否抵达无关。所以丢传输、丢结算、
慢服务三种故障下，credit 算术都必须成立——这条断言不依赖"正确的 broker 会回
什么"，正好避开"我的仿真 broker 对不对"的陷阱。

边界声明：握手（start/begin/attach/grant）同步完成、不进调度器。握手是固定
交换，放进调度器只增加抖动不增加信息；被调度的是消息周期，故障在那里才有意义。

## D12 - 恢复路径用"两阶段运行"验证，阶段 A 的计数必须快照

目标：不只验证"故障发生了"，而是验证**库文档承诺的恢复路径在故障后真的能恢复**。
moon-mqtt README 写的是：断线后 `reconnect()`，若 broker 回 `session_present=1`
则按 `replay_bytes()` 重发在途 QoS1/2（DUP=1），而不是重新发新消息。

实现要点三条：
1. **两阶段两次 `run_bounded`，World 跨调用存活**。阶段 A 注入 `loss(1,0,from 3)`
   让 PUBACK 消失，客户端留在"1 条未结算"；阶段 B 手工 `on_transport_close()`
   + `reconnect_bytes()`，再把这次 CONNECT 喂进新的 run。用一次 run 做不到，
   因为"断线"不是线上消息，是本地事件。
2. **`Scenario.phase_a_acks` 快照**。World 是共享可变的，阶段 B 会把 `acks` 计数器
   改成 1；不快照阶段 A 的 0，"阶段 A 确实没收到 ack"这句话在事后就无法观测。
   第一次写测试时就踩了这个坑（断言 `acks_of == 0` 失败，因为读的是终态）。
3. **控制组**：同样的两阶段形状但不注入故障，断言 `replays == 0`——否则恢复测试
   可能是"无论如何都会重放"而假通过。

实测（seeds 1..6 全绿）：阶段 A `drop 4: 1->0 #3 (loss)`；阶段 B
`connects=2 replays=1 dups=1 inflight=0 reconciled=true`，且重放帧的 DUP 位
经 `decode_packet` 读出来确认为 1。这条把"文档说能恢复"变成了"我们注入故障后
它确实恢复了，并且重放帧标记正确"。

顺带修的第二个真 bug（这次在**适配器**里，不是靶子里）：`connects` 一开始做成
全局计数，导致双客户端下"谁的 CONNECT 先被调度"决定谁被当成恢复会话——
`run_multi` 的干净线路测试立刻炸了（node0 issued=0）。改成按客户端计
（`connects : Array[Int32]`，broker 从 `msg.from` 取索引）。这是"重放相关性"在
适配器自身的又一次体现：任何跨客户端的全局计数器都是种子依赖。

## D13 - 运行时级确定性调度：判定不可行，范围维持 sans-I/O

风险前置项做完了，结论是否定的，依据带行号（详见 docs/v0.3-async-verdict.md）：
1. `now()` 在 native 上是固定 C FFI 导入（`event_loop.mbt:195`
   `"time/get_ms_since_epoch"`），定时器以它为锚（`timer.mbt:28`、
   `event_loop.mbt:306`）。外部事件循环能决定 `poll` 等多久，**改不了时间**。
2. 协程 `Scheduler` 是 `priv struct`，公开面只有查询与 `reschedule()`，
   没有"按给定顺序执行"的入口。
3. `set_external_event_loop` 在 JS 后端是空实现（`event_loop.js.mbt:25` 直接
   `ignore`），仅 native 可用；唤醒回调还要求"只调 C FFI 且不做引用计数"。

所以"接管调度 → 逐字节重放真实 async 程序"这条走不通。**不做**第 3 层，
也不把"事件注入"（native only、半确定性）包装成"可重放"。这条取舍写进
README 的边界表，评审可以看到我们主动否掉了自己的扩张冲动。

副产品：反证了两个靶子选型是对的——它们把纯计算核心单独拆出来
（moon-mqtt `core/` 四后端可测、MoonAMQP1 明确 sans-I/O 无内置 broker），
正是为了绕开上面这些运行时约束。若哪天 `now()` 可注入，重新评估的改动点
是运行时本身，不是本项目内核。
