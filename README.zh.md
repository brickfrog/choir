# Choir

[English](README.md) | 简体中文

> [!NOTE]
> 这个主要是给我自己的工作流程用的，所以可能会随着它们或者这个领域的发展而改变。

用 MoonBit 编写的本地多代理编排器。用昂贵的模型来思考（Claude 担任 TL），
用更便宜或更专业的模型来实现（Gemini、Codex、Moon Pilot、Cursor Agent 作为叶子代理）。
每个叶子在独立的 git worktree 中工作，完成后向 TL 分支提交 PR。内置 poller 自动请求
Copilot review、将 GitHub PR review/CI 反馈路由到对应面板、在 Copilot 批准 PR 后通知 TL。
核心循环是 **scaffold → fork → converge**：TL 提交共享类型，派生一波并行叶子，
逐一合并已批准的 PR，然后继续下一波或向上提交自己的 PR。

对于跨多波的特性，TL 先用 `/crystallize` 把想法结晶为规范，再用 `/decompose`
把规范展开为 `feature/<slug>` 集成分支，然后在该分支上运行 scaffold-fork-converge 循环。
小型一次性修复可以直接从 `main` 派生。

```
choir init
  服务端 (常驻, UDS)
    TL (Claude)
      │  0. （可选）/crystallize → /decompose → feature/<slug>
      │  1. scaffold 提交（共享类型/存根）
      │  2. fork_wave ──▶ 叶子 A ──file_pr──▶ PR → 父分支
      │              ──▶ 叶子 B ──file_pr──▶ PR → 父分支
      │                     │
      │        Poller ◀─ GitHub PR review/CI/issue 评论 ──▶ 叶子（修复）
      │        Poller ──▶ TL（Copilot 批准后合并）
      │  3. WaveComplete → 再次 fork_wave（第 2 波）或向上提交 PR
      │
      └── 可选：fork_wave(role=tl) ──▶ Sub-TL
                    Sub-TL 运行同样的 scaffold-fork-converge 循环
                    Sub-TL 完成后向 TL 分支提交 PR
```

## 快速开始

```bash
choir init                # 拉起服务端 + TL 会话
choir claude [--lean]     # 在已运行的服务端上重启 TL 面板
                          #   （--lean 去掉 Claude Code 默认的系统提示）
choir stop                # 停止，保留恢复状态
choir init --recreate     # 重启，保留恢复状态
choir stop --purge        # 停止并清除工作树/状态
```

## TL 技能

由 `choir claude` / `choir init` 自动安装到 TL 面板：

- `/crystallize <slug>` — 通过结构化问答把想法结晶为 `.choir/context/<slug>-spec.md` 规范。
- `/decompose <slug>` — 把规范展开为 `feature/<slug>` 集成分支。
- `/audit` — 派生一个 Sarcasmotron worker 对当前分支 diff 做严苛审查。

## 波次遥测

```bash
choir log --wave <wave-id>                       # 单个波次的事件日志
choir stats [--wave <id>|--agent-type <type>]    # token / 成本 / 时长汇总
```

TL 还可以通过 `wave_state` MCP 工具拿到每个叶子的 PR / review / CI 类型化快照——
直接读它，不要从通知文本里推断。

## 构建

```bash
moon build --target native --release
moon test --target native
moon fmt
```

可选的 pre-commit hook：

```bash
git config core.hooksPath .githooks   # 运行 moon fmt + moon check
```

## 运行依赖

- `git`、`gh`（PR 工作流）、`zellij` 0.44+（会话管理）
- 你使用的代理 CLI：`claude`、`gemini`、`moon`、`codex`、`agent`（Cursor）
- Nix dev shell 提供开源依赖；专有 CLI 需单独安装

## CLI 工具访问

```bash
choir tool agent_list
choir tool fork_wave --caller-role tl --json '{"caller_id":"root","tasks":["task A","task B"]}'
```

响应：`{"ok":true,"result":{...}}` 或 `{"ok":false,"error":"..."}`。

## 父分支临时绕过

在一个进行中的波次里，父分支被视为不可变：叶子向其提 PR，TL 逐个合并。
如果需要在父分支上做一次性的直接修改（热修复、替代某个叶子等），用临时开关：

```bash
choir tl-parent-override on
# 在父分支上编辑 + 提交
choir tl-parent-override off
```

`merge_pr force=true` 以及直接对父分支的提交都受此开关把关。

## 致谢

架构参考了 [exomonad](https://github.com/tidepool-heavy-industries/exomonad)。代理树模型、scaffold-fork-converge 模式、角色上下文文件及若干工作流约定均源自该项目。

## 许可证

MIT
