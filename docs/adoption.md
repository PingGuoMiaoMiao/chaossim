# 采用记录

本文件把"数据"和"证据"分开，并且**不把下载量或 star 写成采用**。
chaossim 目前**尚未发布到 MoonCakes**，所以外部采用必然为零——这一点写在最前面，
而不是等读者自己发现。

## 1. 原始数据（截至 2026-11-20）

| 指标 | 数值 | 来源 |
| --- | --- | --- |
| MoonCakes 下载 | 无（未发布） | `moon publish --dry-run` 通过，但尚未 publish |
| GitHub Star / Fork / Issue | **1 / 0 / 0** | `gh api repos/PingGuoMiaoMiao/chaossim` |
| 仓库创建 | 2026-11-19 | 同上 |
| Clone 数据 | **取不到** | traffic API 需鉴权（`401`），本机无 token |

**怎么读**：1 个 star 说明有人点开看过；0 依赖者、0 fork、0 issue 说明**没有任何
第三方把用起来的痕迹**。这两件事不能混为一谈。

## 2. 未发布阶段能证明什么（比 star 硬）

发布前无法验证"从 registry 消费"，但可以验证**一个仓库之外的独立模块能不能真的
用起来**。这是本文件的核心证据：

```sh
python tools/consumer_check.py
```

它在临时目录新建一个**完全独立**的 MoonBit 模块（自己的 `moon.mod`，不在本仓库
里），按名字依赖 `PingGuoMiaoMiao/chaossim`，然后跑一个真实故障场景：

```
consuming PingGuoMiaoMiao/chaossim@0.3.0 from a module outside the repository
  steps=2 delivered=1 dropped=1     ← 注入 crash 后确实有消息被丢弃
  replay_bytes=285                  ← 产出可分发的 replay 工件
  verified_steps=2                  ← 工件被 replay_verify 重新执行并核对
```

它验证的不是"能编译"，而是"陌生模块能在自己的代码里注入故障、拿到可重放的工件、
并对工件自证"。第三步（`replay_verify`）尤其重要：它说明工件不是日志，是**可执行
的主张**。

另外三条已入 CI 的证据（都不依赖发布）：

| 证据 | 命令 | 说明 |
| --- | --- | --- |
| 干净 clone 能跑 | 见 `docs/evidence.md` | 空目录 clone 后 `moon test` 39/39，约 4 秒 |
| 接入指南可执行 | `moon test examples/adopting-drill/drill/src` | 完全按 `docs/adopting.md` 写出的第三方小库，随测试跑；指南失效即红 |
| 打包就绪 | `python tools/selfcheck.py --with-publish` | 解压成品包再检查一遍，抓"工作区能跑、包坏了" |

## 3. 什么才算"真采用"

以下任一才算，**不含下载量**：

- 别的仓库在 `moon.mod` 里依赖 `PingGuoMiaoMiao/chaossim`（MoonCakes 的
  `dependents` 计数会动）；
- 第三方**用 chaossim 写出过一个真实的故障场景**，并在其仓库/issue 里留下痕迹；
- 有人基于它提 issue 或 PR（含"这个场景要怎么表达"这类问题）；
- 独立实现满足我们声明的契约（目前尚无正式契约文档，属待办）。

**当前状态：四项全为 0。** 因此本文件不主张"已被采用"，只主张
"已具备可被采用的形态，且这个形态由可复跑脚本证明"。

## 4. 发布后要补的事

1. `moon publish`（当前包已 `202 Accepted`，只差维护者 `moon login`）；
2. publish 之后把 `tools/consumer_check.py` 从"路径依赖"切换成"从 registry 解析"
   ——脚本里已留了 `--version` 意图注释，切换是改几行而不是重写；
3. 重新跑 `python tools/selfcheck.py --with-registry`，让"已发布版本"这类主张
   由 registry 本身核对，而不是靠人记。
