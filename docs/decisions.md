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

## D14 - QoS2 恢复是另一条分支，必须单独断言（不能靠 QoS1 的测试覆盖）

D12 验证的是 QoS1：WaitPubAck 状态重发带 DUP 的 PUBLISH。QoS2 卡在 WaitPubcomp
时，`replay_bytes()` 产出的却是 **PUBREL**——完全不同的报文类型、且**没有 DUP 位**。
同一个"恢复"动词下藏着两个互斥的实现分支，用 QoS1 的测试覆盖不到。

因此加 `run_recovery_ex(.., qos)` 与独立计数器 `replays_pubrel`，断言写成
"镜像"形式：

- QoS1 恢复：`replays=1, dups=1, replays_pubrel=0`
- QoS2 恢复：`replays=0, dups=0, replays_pubrel=1`

用两个计数器而不是一个"replays"总数，是为了让这两条分支**不能互相冒充**：
如果哪天实现把 PUBREL 也当成 PUBLISH 重发，`replays` 会变 1、`replays_pubrel` 归零，
测试立刻红。实测（seeds 1..6）全部符合预期。

顺带确认了一个容易想当然的细节：`dups=0` 在 QoS2 恢复里是**正确**的，
不是漏设——MQTT 3.1.1 的 DUP 标志只属于 PUBLISH。

## D15 - 吞吐测量：自己计时，不依赖 `moon bench`；两次测量缺陷都留档

为了让"CI 里跑得动"从一个形容词变成数字，做了 `cmd/perf`。过程中两次踩坑，
都记下来：

1. `moon bench` **没发现**我们的 bench 入口（报 "no test entry"），且它的
   `Summary` 类型是包内私有的。改用可执行文件 + `core/env` 计时。
2. 先试了 `@bench.Bench::bench`：它会**自动校准迭代次数**，对这么便宜的工作负载
   会不断加批次，跑了两分钟还在烧 CPU（实测进程累计 CPU 131 s）。CI 面向的报告
   必须有界可预测，因此放弃。
3. 自计时方案的第一版**负载写错了**：ping-pong 型 handler 在 payload≥3 时自己
   排空，导致三种 max_steps 实测都只跑 3–4 步，输出自相矛盾（"20 步"和"200 步"
   每 run 耗时一样）。改成"每次投递必产出一条"的饱和负载，max_steps 才真正决定
   工作量。
4. 第二版又踩一次：给这条永续链加上 `loss` 故障后，被丢弃的那条不再产生后继，
   链条被截断，测量又退回 3 步。于是**基线测量用无故障**，"故障评估开销"单独
   测一组做差值——这反而比原计划更有信息量。

最终数字（release，单机）：**约 460–500 ns / 调度步**，短/中/长三种形状线性一致；
叠加 4 个故障后每步 501 ns，即故障评估约 **+9%**。据此 1000 种子 × 20 步的扫描
约 **9–10 ms**——这是可以写进 CI 预算的量级。

已知的优化空间：每步都在拼 trace 字符串，这多半是主要成本；若将来吞吐成为瓶颈，
把 trace 改成结构化惰性记录（只在下游要求时格式化）是显然的第一步。本次不改——
先有数字，再谈优化。

## D16 - 验收自检脚本的两处缺陷（多模块工作区 / 裸 MIT）

拿官方口径的 `tools/acceptance.py` 自查本项目时，两条 WARN 都是**检测器误判**：

1. **多模块工作区被当成"外部检出"**。脚本原逻辑把任何含 `moon.mod` 的子目录都
   视为无关 checkout 并跳过，于是只统计到根模块的 8 个文件 / 879 行——本项目
   真正的形状是"库 + 两个适配器 + 演练示例"的工作区。修法：先读 `moon.work`
   的成员列表，成员目录**不算外部**；`moon.work` 没列出的嵌套模块仍然跳过，
   所以"工作区里真躺着一个别人的仓库"这种情况依然不会被误算进分母。
2. **裸 `MIT` 不被识别**。`OSI_RE` 里写的是 `mit license`，而 `moon.mod` 声明的是
   `license = "MIT"`，于是依赖被标成 "unrecognised"——其实 MIT 完全是 OSI 许可。
   修法：改成 `\bmit\b` / `\bisc\b` 的单词边界匹配（`\b` 保证不会误命中
   submit/commit 之类）。

修完实测：本项目 **8 PASS / 0 WARN / 0 FAIL**（18 个 .mbt / 2430 行、
4 个测试文件 / 191 条断言），且 docmunch 那边没有回归（仍 8/8，比例 2.00x 的
WARN 是它 Python 测试基座的真实体积，不是误判）。

脚本本体同时存在于三处并保持同步：本项目 `tools/`（让评审可自行复跑）、
docmunch 的 `tools/`、以及 `moonbit-hackathon-acceptance` 技能的
`scripts/`。CI 里现在也跑它——验收口径一旦变严，构建会先红。

## D17 — 一致性巡检工具，以及"数字主张"为什么必须机器核对

`tools/consistency.py`（与 docmunch 共用同一份）检查三件事：测试数主张 vs 真实
`moon test` 总数、ADR 编号连续性与重复、相对链接可解析。三项进 CI。

在本仓库抓到两条真问题：README 仍写 `31/31 测试`（实际 39）<!-- consistency:ignore -->、ADR 只到 D16
而申报里引用了 `D1–D17`。前者是文档漂移，后者说明"声明了却不存在"同样危险。

设计上的三个决定：
1. **只认贴近测试词的数字**。本项目里 `8/8`（验收通过行数）、`6/6`（种子数）
   都合法存在，宽松匹配会把它们全判成错误——那样的检查会被关掉，比没有更糟。
2. **快照文件自声明豁免**（`w2-targets.md` 是分轮实验记录、`reports/` 是当时
   报告）。标记写成注释，人也能看见。
3. **宁可漏报也不误报**：漏报的后果是某个旧数字留下，误报的后果是整个检查被
   绕过。所以判定取窄。

一次自伤记录：收紧正则时把跨分支反向引用写成 `\1`，导致第二分支永不匹配、
检查**静默零命中**。是"打印扫描到的主张数"这一设计把它兜住的——只报 PASS/FAIL
的检查器此时会说谎。

## D18 - README 第一屏按"冷读者"重排；贴出来的输出必须逐字为真

以陌生人视角只读前 60 行做检查，发现四个问题：
1. **最有力的东西不在第一屏**：真实故障注入的 transcript 藏在 adapters 的输出里，
   读者要读完表格和基线才能知道"跑起来长什么样"。现在第一屏直接给一段真实转录。
2. **竞赛背景挡在功能前面**：第 10 行就讲"为黑客松新建"，而读者此刻还不知道这是
   什么东西。移到"背景"一节，放到功能说明之后。
3. **内部编号外泄**：故障表格里写了"（D8）"，那是我们自己决策记录的编号，读者
   无从查起。删掉。
4. **缺一行成熟度状态**：版本、测试数、自检结果、许可证，读者判断"能不能用"最先
   看这些。现在放在标题下第一行。

顺带发现一处**文档说谎**：我在 README 里贴的 transcript 写的是
`counters: ... reconciled=true`，而程序真实打印的是
`dropped=1 deferred=0 bad_events=0` 与 `node0: ... matches=true`。凭记忆写输出
就是会错——这正是本项目禁止靶子文档里做的事，自己却犯了一次。

因此把这条也变成检查（`tools/consistency.py` 的 Transcript 项）：README
「你会拿到什么」代码块里的每一行（`<-` 之后是注释，剥掉）都必须真的出现在
`moon run adapters/mqtt/bin` 的输出里。**并且验证过它会失败**——故意把
`matches=true` 改成 `matches=TRUE` 后检查器立刻报 FAIL，改回来才 PASS。
一个不会失败的检查器等于没有。

## D19 - CHANGELOG 按能力组织并引用 commit；引用的 hash 必须存在

`git log` 不是变更记录：27 个 commit 里有 chore、有修自己笔误、有回滚，读者无法
从中判断"这个月到底做成了什么"。因此 `CHANGELOG.md` 按**能力**分节（内核 / 真实
靶子 / 工程与验证 / 被否决的方向 / 已知限制），每条带可复跑命令与 commit 范围。

三个刻意的选择：
1. **被否决的方向也写进去**（moonraft 作靶、moonmq 作靶、运行时级调度、
   `moon bench`）。这既是给评审看的取舍证据，也是防止后人重复试错。
2. **已知限制单独一节**，包含"未发现靶子的 bug"和"0.3.0 尚未发布"。
3. **引用的 commit hash 进一致性检查**：文档里出现 `\`abc1234\`` 就必须能在
   仓库里找到该 commit。一个引用不存在 hash 的变更记录比不写更糟——它看起来
   可核实，实际不可。

实测：本仓库 20 个引用 hash 全部存在且主题匹配（写完后逐个 `git log -1` 核对过，
然后才把检查加进去）。

## D20 - 主张形态：`N/N` 只是其中一种；`N 个测试` 同样会漂

巡检上线后仍漏掉了报名文档里的"115 个测试全绿"（实际 116）——因为它不是 <!-- consistency:ignore -->
`115/115` 这种形态。补了两个模式：`N 个/项测试` 与 `N tests`，并加负向前瞻
`(?!\s*文件)`，否则"4 个测试**文件**"（文件数）会被误判成测试数。 <!-- consistency:ignore -->

同时确认了一类不该被追究的数字：**ADR 里的"后果：…全部 72 个测试通过"** 是决策 <!-- consistency:ignore -->
当时的记录，dated 对照文档里的"79 个测试全绿"同理。它们由快照机制豁免——注意该 <!-- consistency:ignore -->
机制只豁免测试数，ADR 编号与链接仍然检查。

教训：检查器的覆盖率跟"人怎么写"一样会漂。发现方式是外部文档（报名表草稿）与
仓库状态比对，而不是等检查器报错。

## D21 - 活数字不写死；ADR 计数也进检查

审计申报书时遇到两类数字：
1. **不会自己变但对不上**：单测 95（实为 116）、ADR 49/66（实为 67）。这类是遗漏，
   补上即可，但要防止再漏——于是把 "N 条 ADR" 也做成检查项，与测试数同类。
   第一次跑就抓到 4 处（`maintainability.md` 47、`registration.md` 两处 66）。
2. **每次提交都会变**：文件里写"85 个提交"这种数字，提交完这一版它就错了。这类
   不写死，改成"自 2026-11-01 起连续提交（见仓库提交记录）"——数字由 GitHub 提供，
   文档只描述性质。

检查器新增 ADR 计数项（`N 条/个 ADR` vs `docs/decisions.md` 的 `## D<N>` 数量），
并沿用同一套豁免规则：dated 评估文档（`maintainability.md`）标记为快照。

**代价与改法**：精确数字写在 prose 里，每加一条 ADR 就要改 4 处——本轮的 D68
就是这样当场把 4 处打红的。因此改成**下限式**表述（"60+ 条 ADR"），检查器同时 <!-- consistency:ignore -->
接受两种形态：`N 条` 要求相等，`N+ 条` 要求 `N <= 实际`。下限真值能稳定很久，
而且仍然可被机器核对——这与"写个模糊数就完事"是两件事。

## D22 - 验收脚本报的测试数必须等于文档里的数（多后端陷阱）

发现：`python tools/acceptance.py` 报 `26/26 tests passed`，而文档与 <!-- consistency:ignore -->
`moon test --target native` 都是 **39**。一个评委若同时看到这两个数字，只会
得出"这个项目连自己有几个测试都说不清"的结论。

根因：不带 `--target` 时 `moon test` **按后端分别打印 TOTAL**（本机 `[wasm]` 26 +
`[native]` 13），而脚本的正则只吃了第一行。这不是文档错，是检查器错。

修法两条：
1. 脚本改为读 `moon.mod` 的 `preferred_target` 并显式传 `--target`，同时汇总所有
   TOTAL 行而不是取第一行；
2. README 里加一句说明——不带 target 会看到两行合计，别误读成"总共 26 个"。

教训：**检查器与被检对象描述同一件事时，两者必须用同一条命令**。脚本此前跑的是
另一个命令形态，于是"验收通过"和"文档正确"可以同时为真却互相矛盾。

## D23 - 单入口自检：一条命令答"这份提交有没有问题"

此前评委要看三个脚本（acceptance / consistency / consumer_check），README 也得
写三行。现在 `python tools/selfcheck.py` 一次跑完并打印统一表格：验收六条 +
文档一致性六项（可选再加外部消费验证），3.8 秒返回，**有 FAIL 就 exit 1**。

实现上刻意用子进程 + `--json` 合并，而不是把两个脚本 import 进来：
- 每个脚本仍能单独跑（CI 里排错时只想跑一个）；
- 一个脚本崩溃不会静默污染另一个的结果——`error` 会单独成行显示。

失败路径**验证过**：往 README 里加一行"本项目有 7 个测试"，selfcheck 立刻 <!-- consistency:ignore -->
`exit=1` 并打印 `FAIL Test counts README.md:193: claims 7/7, suite has 39`。
（注意 `--skip-build` 时这一项会 SKIP，因为没跑 `moon test` 就没有可比的真实值；
SKIP 与 PASS 在表格里分开计数，不混为一谈。）

CI 里两个独立步骤合并成一个 Self-check 步骤——少一个会漂的脚手架。

## D24 - 发布就绪门禁：`moon publish --dry-run` 不需要登录，而且会解压重检

原本以为"发布前验证"必须真的 publish，或者至少需要登录。实测发现
`moon publish --dry-run` **不需要登录**就能完成三件事：`moon check` → 打包 →
**把包解压到临时目录再跑一遍 `moon check`** → 报 `Server status: 202 Accepted`。

中间那步是关键：它抓的正是"工作区能跑、打包后坏掉"这一类问题（工作区成员被打进
包、被引用的文件被 `.moonignore` 排除、路径依赖没写进 manifest……）。本项目的
`.moonignore` 与工作区结构恰好属于最容易出这类问题的形态。

因此做成自检的可选项 `--with-publish`（默认不开：它需要联网问一次 registry）。
失败路径**验证过**：临时把 `sim/replay.mbt` 加进 `.moonignore`，工作区仍能过，
而 `--with-publish` 立刻 `FAIL dry-run: moon check failed`，退出码 1。

CI 里不启用这一项（CI 不该依赖 registry 可达）；它属于"发布前手动跑一次"的门。

## D25 - 关于外部世界的主张，去问外部世界（`--with-registry`）

上一轮发现六份文档同时声称"0.3.1 未发布"，而 registry 上它已存在数日；下载数也
写成 35（实为 44）。根因不是笔误，而是**信任了一份描述外部世界的内部文档**。

于是把这件事也做成检查：`tools/consistency.py --with-registry` 直接查
`mooncakes.io/api/v0/manifest/<module>`，然后核对 `docs/adoption.md` 里的
"已发布版本"是否包含 latest、下载数是否**不超过**实际值（下载只增不减，报大是错、
报小只是过期）。

三条设计约束：
1. **网络问题一律 SKIP，绝不 FAIL**——把"问不到"当成"答错了"，会让门禁变成
   狼来了；
2. 下载数只查"报大"（`claimed > actual` 才失败），因为数字会涨，允许偏保守；
3. 默认关闭、CI 不启用。它是发布前手动跑的门，不是每次提交的门。

失败路径验证过：把 adoption.md 的下载数改成 99，立刻
`FAIL Registry: adoption.md claims 99 downloads, registry says 44`，退出码 1。

## D26 - 未发布阶段的"采用"证据：仓库之外的独立模块跑通故障场景

发布前拿不到 registry 消费证据，但"能编译"也不足以说明可被采用。补了一条更硬的：
`tools/consumer_check.py` 在临时目录新建**完全独立**的模块（自己的 moon.mod、
不在本仓库内），按名字依赖 chaossim，跑一个真实 crash 场景，再让
`replay_verify` 把产出的工件重新执行一遍。实测：

```
steps=2 delivered=1 dropped=1 / replay_bytes=285 / verified_steps=2
```

第三步是关键——工件不是日志，是**可执行的主张**；外部模块能自证这一点，才算
"这个库对别人有用"。

同 docmunch 的口径（对方项目的 D60）：`docs/adoption.md` 把原始数据与证据分层，
并明确列出"什么才算真采用"（被依赖 / 被写出真实场景 / 有 issue 或 PR / 独立实现
满足契约），当前**四项全为 0**，因此不主张"已被采用"。

顺手记一个操作教训：用 shell heredoc 往 `.mbt` 里写 `\{expr}` 会被转义吃掉
一层，导致插值变成字面量。写含插值的 MoonBit 源码要用文件写入工具，不要走 shell
字符串。

## D27 - CI 从未运行过：三个连环故障，全靠"去看它跑了没有"才暴露

**事实**：chaossim 建仓起 CI 跑了 30 次，**全部失败**；工作流文件语法一直合法——
所以"YAML 有效"是个毫无用处的检查，真正的检查是**它跑过没有、跑出了什么**。

三个故障叠在一起，修好一层才露出下一层：

1. **引用了不存在的 action**：`moonbitlang/setup-moonbit@main` 返回 404，所有 job
   在 "Set up job" 就死。
2. **版本钉死但 CDN 上没有**：安装脚本把版本拼进下载 URL，而
   `binaries/0.1.20261104/...` 等**所有探过的版本都 403**（只有 `latest` 200，
   目标名是 `linux-x86_64` 不是 `linux-amd64`）。改为装 latest，**下一步打印
   `moon version --all`** 记录实际版本——没有的钉死不写在注释里装作有。
3. **两个只在 CI 条件出现的失败**：
   - Format：CI 的 moon 是 0.1.20261117，本机 0.1.20261104；新 core 把
     `@json.JsonPath` 改名 `@json.DecodeContext`，导致 `pkg.generated.mbti` 被
     重新生成。**生成产物不该被格式门禁管**，改为只查 `*.mbt` / `*.mbt.md`。
   - Self-check：shallow clone 没有历史，"文档引用的 commit 不存在"报了二十个
     假阳性。改为 `fetch-depth: 0`，并让工具**识别 shallow 仓库并 SKIP**。

关键教训：**门禁失败时要让它自己输出诊断**。这两步最初只报"失败"，本地复现不了、
日志接口又 403，白转几轮。给 Format/Self-check 加上失败即打印（改动文件、`cat -A`
看空白、行尾、python/moon 版本）后一次定位。

另一个发现：本机 `gh` 已登录，`gh run view <id> --log-failed` 能直接读日志，
比 GitHub API 的 403 好用得多——后续排 CI 应先试它。

## D28 - 工具链版本差让"本地绿"与"CI 绿"不再是同一件事

三件事互不相同，共同点是**都不会让测试失败，只会让门禁说谎**：

1. **`moon check` 是增量的**。本地打印 "no work to do"，把真实警告藏了；CI 全量才报。
2. **两个工具链判据相反**。`core/` 里 `moonbitlang/core/json` 这一行：本机
   0.1.20261104 **必须**有（去掉就 `Cannot use @json` 编不过）；CI 的 0.1.20261117
   判它 `unused_package`，`--deny-warn` 直接失败。而 CDN 上所有带版本号的 URL 都
   403，只有 `latest` 可安装——无法钉死版本。因此 CI 的警告门禁改为"允许这一条
   已知分歧、其余任何诊断一律失败"，并打印该消息保持可见。
3. **`%TEMP%` 不可写会被读成"测试坏了"**。本机 `moon test` 报 23 个
   `@fs.tmpdir(): Access is denied`。库是对的，是沙箱 ACE 不允许进程在 `%TEMP%`
   下建目录。修在测试基座（给子进程传可写 TEMP），没有往那 23 处测试里撒回退——
   也撒不出来，`@fs.tmpdir` 是 async fs 里唯一的唯一目录创建器。

教训：**"本地/CI 绿"只在你确知两边跑同一工具链时才是证据**。版本差一旦存在，
门禁要么放宽到失去意义，要么开始说假话；正确做法是把差异显式写出来。

## D29 - 第三个靶子：AMQP 0-9-1 broker（确认/重投记账）

前两个靶子都是**客户端一侧**的逻辑，这次换成**服务端**：`Zcxssxx/moonmq` 的
`Broker` 有 publish / get / ack / reject / delete_queue / queue_stats 的完整语义，
正好能被"线上丢失回复"打到。

节点划分同前：节点 1 = 真实 `Broker`，节点 0 = 脚本化客户端（操作码走 `payload`），
故障注入在两者之间。不变量：

- **I1** 已 ack 的 tag 不会再出现；
- **I2** 有未确认投递时 `delete_queue(if_empty=false)` 必须被拒绝（broker 没有静默丢消息）；
- **I3** 记账闭合：`acked + unacked ≤ published`；
- **I4**（测试）`reject(tag, requeue=true)` 后消息必须能再次被 `get` 到。

**第一版不变量写错了，值得记**：I3 最初写成 `delivered ≤ published`，在"reject 后
重投"用例上立刻失败。那不是 broker 的 bug，是我把不变量写窄了——**一条消息合法地
可以被投递两次**。正确约束是记账而不是投递次数。同源教训见 D15/D20：不变量要挑
"故障下仍然成立"的性质，否则测的是自己的假设。

顺带**实测**了一个语义（非推测）：队列有 1 条未确认投递时
`queue_stats().message_count()` 返回 1（publish 了 2 条）——只算 ready，不含 unacked。

MoonBit 两个坑：`match` 里小写标识符是**绑定模式**不是常量比较（我最初的分支全部
命中第一条）；`Broker` 方法返回 `Result` 而非 raise，误用 `catch` 会报 error type mismatched。

## D30 - 审计 moonmq：17 条尖角探针，0 个缺陷，1 个我自己的假警报

原始卖点写着"跑崩 N 次、抓出 M 个真实 bug（附 issue 链接）"。这一轮去兑现它，
**结果是 0**——必须如实记，而不是把"故障下自洽"包装成"发现了 bug"。

探针覆盖（每条打印靶子的真实回答，断言写"应该"）：重复 ack、reject 后 ack、
reject(discard) 后的 ready 计数、prefetch=1 的第二次 poll、**cancel 时未确认投递是否
重投**（答案：会，ready 回到 1）、delete_queue(if_empty) 三态、ack_many 含无效 tag 的
原子性（答案：整体失败、有效 tag 未被误用）、**跨会话隔离**（ownerB 无法 ack
ownerA 的 tag）、fanout 扇出、topic 通配、delete_queue(if_unused) 在消费者存在时拒绝。

全部符合 AMQP 语义；该库自带边界测试，质量扎实。

**一个假警报值得入档**：第一版 fanout/topic 探针报"两个队列都没收到"，看着像严重
bug。查靶子自己的测试才发现是我把 bind_queue(exchange, queue, key) 的参数顺序写反了。
**排除自身错误之前不要声称对方有缺陷**——这是本轮最大的产出：先读靶子的用法，再判它错。

申报措辞因此定为：不主张"发现上游 bug"，主张"对三个真实靶子做了可复跑的边界审计，
探针本身公开可复核"。比 bug 标题弱，但它是真的。

## D31 - 排序扫描：320 次交错，0 违规；结论仍是"未发现缺陷"

D30 的 17 条探针是**确定性**的——固定顺序调 API。只有仿真才能打到的是**交错**：
两个客户端同时从同一队列取，谁的操作先到由种子决定，回复被丢由故障决定。

判据（每次投递/确认都在边上检查）：

- **V1** 一个 tag 不会同时被两个客户端持有（重复投递）
- **V2** 客户端不会 ack 它没拿到的 tag（跨客户端误确认）
- **V3** acked + outstanding ≤ published

两种脚本 × 四组故障（无 / 丢 client0 回复 / 丢 client1 回复 / 延迟）× 40 种子 =
**320 次运行，0 违规**。其中一种脚本刻意插入 reject(requeue=true)——重投与另一
客户端取消息并发，是发现重复投递最锋利的场景。

结论因此不变而且更强：moonmq 在这两条路径上没有并发语义缺陷。申报措辞仍是
"可复跑的审计 + 未发现缺陷"，不是"发现了 bug"。

下一步若要真找 bug，只能换靶子（更年轻、自带测试更少的库），而不是继续加码这个库
——继续加码只会得到更长的"没问题"，对采用故事没有帮助。

## D32 - 从"框架"改成"工具"：一个命令出一份体检报告

三轮解释之后暴露的不是文档问题，是**形态错了**：需要先理解"确定性仿真"才能产生价值的
项目，在申报材料里撑不住——评委不会给你解释的机会。

新形态：`moon run adapters/moonmq/checkup --target native` 直接打印 Markdown 体检报告
——11 项恢复/记账检查（每项写明在验证什么）+ 120 次并发交错扫描，结论只有
通过 / 风险 / 未覆盖 三态，风险项附观察到的现象。样板见 `docs/checkup-moonmq.md`，
由命令生成、不手改。

价值主张因此变成一句话：**给它一个协议库，它告诉你哪些恢复路径没处理**——不必先懂仿真。

**负向对照（部分补完，见 D33）**：判定规则已用故意给错的输入逐条验证，坏观测必报
RISK；但**观测层**仍未端到端验证——没有用一个真实写坏的库跑过。报告里两层分开写。

## D33 - 负向对照：把"判定"与"观测"拆开，RISK 分支不再是死代码

D32 留下的问题：11 项全 PASS，无法区分"库没问题"和"检测器坏了"。

做法：`checkup_rules.mbt` 把判定抽成纯函数（`judge_*` / `why_*`），
`checkup_wbtest.mbt` 给每条规则喂**故意错的观测**，要求必报 RISK，再喂好观测要求必报 PASS。
4 条对照测试随主测试跑（现 74/74）。

这证明的是**判定层**：坏输入不会被写成 PASS。仍未证的是**观测层**——没有一个真实写坏的
库端到端跑过，所以"检查能否采到坏现象"还没验证。报告的"检测能力自检"一节把这两层
分开写，不合并。

## D34 - 第二个域：MVCC 事务引擎，10 项检查，证明工具不是"broker 专用脚本"

工具写在一个 broker 上，"能换域"此前只是设计主张。现在有第二份报告：
`black-duck666/moontxnkit`（MVCC 事务 + 逻辑恢复），**问题完全不同**——
脏读、读自己的写、写写冲突、版本推进、回滚无痕、快照隔离、自检、保存点回滚、
删除语义、压缩保留当前值。

**10/10 通过**。这个库也写得扎实。

值得记的三件事：

1. **判定层不能照抄**。D33 那 11 条是 broker 语义；事务引擎的"什么算缺陷"完全不同。
   照抄的是**形状**（观测 → 纯判定 → 结论），不是函数本身。`docs/checkup-guide.md`
   原先写"判定层可照抄"过强了，这里修正为"形状可照抄，规则按域重写"。
2. **每换一个域，负向对照要重做一遍**：10 条新规则各配了坏输入用例
   （`adapters/moontxnkit/adapter/checkup_wbtest.mbt`，3 条测试）。
3. **仍未找到风险项**。两个域、17 项检查、320 次交错扫描，全部通过。这个结论现在
   更硬了：不是"这个库碰巧没问题"，而是"两个成熟库在各自的核心路径上都没问题"。

结论仍是：不主张"发现上游缺陷"，主张"可复跑的边界审计 + 判定能力有对照"。

## D35 - 不变量钩子 + 线性一致性检查（含"复用声明"的核实结果）

### 复用声明：两个包都不存在

验收包要求"对接 moon_historycheck/lincheck 的线性一致性示例（复用声明写明出处与许可证）"。
先核实，结论是**这两个包在 MoonCakes 上都不存在**：

```
$ moon fetch moonbit-community/moon_historycheck
Error: module `moonbit-community/moon_historycheck` was not found in the registry
$ moon fetch moonbit-community/lincheck
Error: module `moonbit-community/lincheck` was not found in the registry
```

`moonbitlang/moon_historycheck`（registry API 404）、`moonbitlang/lincheck`、
`moonbit-community/moon_lincheck`、`moonbit-community/linearizability` 同样不存在。
所以**没有第三方实现可复用**，也不存在需要抄录的许可证。凭空写一条复用声明会是评委
能当场证伪的假话——正是本项目一直在抓的那类错误。

### 实际做法：按定义实现，出处写在文件头

`sim/lincheck.mbt` 按**定义**实现、不抄任何代码，文件头写明出处：

- Herlihy & Wing, *Linearizability: A Correctness Condition for Concurrent Objects*,
  ACM TOPLAS 12(3), 1990（定义来源）；
- Wing & Gong, 1993（本检查器采用的"按实时序取下一个可线性化操作"搜索法）。

没有第三方代码，许可证义务仅限本项目自身 MIT。

### 不变量钩子（`sim/hooks.mbt`）

场景**结尾正确**但中途经过坏状态，是末尾断言看不见的。钩子按步骤回调，返回违规步号。
三条内置钩子都是投递无关的：计数不为负、`delivered + dropped == step`（抓消息凭空消失）、
trace 不得有空行（防静默步骤藏在计数器后）。

### 判定能力：这次双向验证了

7 条测试：顺序一致→通过；**put 后读到旧值（实时序禁止）→拒绝**；两个读与 put 并发→通过；
**写偏斜无顺序可解释→拒绝**；未返回的操作不约束历史→通过；预算耗尽→unknown（不谎报通过）。

这是 D33"判定层已证、观测层未证"之后第一次把**拒绝路径**跑通。

写这段时也修了自己两个缺陷：`search` 早期版本在失败分支间泄漏 `Map` 写入（改为按候选
前缀重建 store）；一条 fixture 少了前置 `put`，检查器**正确地**拒绝了它。
