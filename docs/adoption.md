# 采用记录

本文件把"数据"和"证据"分开，并且**不把下载量或 star 写成采用**。
chaossim 已于 **2026-11-25 发布到 MoonCakes**（`0.3.0`，registry 构建 `success`），
但外部采用仍然为零——这一点写在最前面，而不是等读者自己发现。

## 1. 原始数据（截至 2026-11-25）

| 指标 | 数值 | 来源 |
| --- | --- | --- |
| MoonCakes 版本 | **0.3.0**（构建 `success`） | `mooncakes.io/api/v0/manifest/PingGuoMiaoMiao/chaossim` |
| MoonCakes 下载 | 发布当天 1（活数字，以 registry 为准） | 同上 → `downloads` |
| MoonCakes 依赖者 | **0** | 同上 → `dependents` |
| GitHub Star / Fork / Issue | **1 / 0 / 0** | `gh api repos/PingGuoMiaoMiao/chaossim` |
| 仓库创建 | 2026-11-19 | 同上 |
| Clone 数据 | **取不到** | traffic API 需鉴权（`401`），本机无 token |

**怎么读**：1 个 star 说明有人点开看过；0 依赖者、0 fork、0 issue 说明**没有任何
第三方把用起来的痕迹**。这两件事不能混为一谈。

## 2. 发布之后能证明什么（比 star 硬）

发布后可以验证最硬的一条：**一个仓库之外的独立模块，不引用本地路径，直接从
registry 解析 `PingGuoMiaoMiao/chaossim@0.3.0`，能不能真的用起来**。这是本文件的核心证据：

```sh
python tools/consumer_check.py
```

它在临时目录新建一个**完全独立**的 MoonBit 模块（自己的 `moon.mod`，不在本仓库
里），按名字依赖 `PingGuoMiaoMiao/chaossim`，然后跑一个真实故障场景：

```
consuming PingGuoMiaoMiao/chaossim@0.3.0 from a module outside the repository (mode=registry)
  steps=2 delivered=1 dropped=1     ← 注入 crash 后确实有消息被丢弃
  replay_bytes=285                  ← 产出可分发的 replay 工件
  verified_steps=2                  ← 工件被 replay_verify 重新执行并核对
```

它验证的不是"能编译"，而是"陌生模块能在自己的代码里注入故障、拿到可重放的工件、
并对工件自证"。第三步（`replay_verify`）尤其重要：它说明工件不是日志，是**可执行
的主张**。

另外三条已入 CI 的证据：

| 证据 | 命令 | 说明 |
| --- | --- | --- |
| 干净 clone 能跑 | 见 `docs/evidence.md` | 空目录 clone 后 `moon test` 74/74，约 4 秒 |
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

## 4. 发布这件事做完之后

1. ✅ `moon publish` 已执行（2026-11-25，`Server status: 200 OK`，registry 构建 `success`）；
2. ✅ `tools/consumer_check.py` 已切换为**默认从 registry 解析**（`--mode registry`），
   并保留 `--mode local` 作为离线/发布前的等价检查；registry 索引过期时脚本会自己
   `moon update` 后重试一次；
3. ✅ `python tools/selfcheck.py --with-registry` 现在会拿 registry 的实际 latest 与
   下载数核对 `docs/adoption.md` 里的说法。

**下一步才算"采用"**：别的仓库在 `moon.mod` 里依赖它、有人基于它提 issue/PR、
或第三方用自己的实现满足我们声明的契约。这些当前都还是 0。
