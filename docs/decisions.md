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
