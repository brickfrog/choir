# Choir

[English](README.md) | 简体中文

用 MoonBit 编写的本地多代理编排器。用昂贵的模型来思考（Claude 担任 TL），
用更便宜或更专业的模型来实现（Gemini、Codex、Moon Pilot、Cursor Agent 作为叶子代理）。
每个叶子在独立的 git worktree 中工作，完成后向 TL 分支提交 PR。内置 poller 自动请求
Copilot review、将 review/CI 反馈路由到对应面板、在 PR 可合并时通知 TL。
核心循环是 **scaffold → fork → converge**：TL 提交共享类型，派生一波并行叶子，
逐一合并 PR，然后继续下一波或向上提交自己的 PR。

## Chainlink

Choir 集成了 [Chainlink](https://github.com/dollspace-gay/chainlink)，这是一个本地 Git 后端 issue 追踪器，支持类型化评论（`plan`、`decision`、`observation`、`result`、`handoff`）。

```bash
chainlink issue create "功能标题"                    # 创建 issue，获取 ID
chainlink issue comment <id> "<规格>" --kind plan    # 写入规格
chainlink_next                                       # 继续下一个进行中的 issue
chainlink_show <id>                                  # 加载 issue 及其评论
```

当 `fork_wave` 携带 `issue_id` 调用时，每个叶子的 `TaskContract` 会自动从 Chainlink issue 中丰富：

- **goal** — 若叶子任务无明确目标，则回退为 issue 标题
- **review_context** — issue 描述 + 最近 5 条 plan/decision 评论（按 id 升序），追加到 TL 提供的上下文后（带分隔符）
- **constraints** — `blocked_by` 条目去重合并

纯函数 `task_contract_from_chainlink_issue` 将 `ChainlinkIssue` 映射为 `TaskContract`；`merge_chainlink_into_task_contract` 处理合并逻辑。

```
choir init
  服务端 (常驻, UDS)
    TL (Claude)
      │  1. scaffold 提交（共享类型/存根）
      │  2. fork_wave ──▶ 叶子 A ──file_pr──▶ PR → TL 分支
      │              ──▶ 叶子 B ──file_pr──▶ PR → TL 分支
      │                     │
      │        Poller ◀─ Copilot review ──▶ 叶子（修复）
      │        Poller ──▶ TL（通过后合并）
      │  3. WaveComplete → 再次 fork_wave（第 2 波）或向上提交 PR
      │
      └── 可选：fork_wave(role=tl) ──▶ Sub-TL
                    Sub-TL 运行同样的 scaffold-fork-converge 循环
                    Sub-TL 完成后向 TL 分支提交 PR
```

## 快速开始

```bash
choir init              # 拉起服务端 + TL 会话
choir stop              # 停止，保留恢复状态
choir init --recreate   # 重启，保留恢复状态
choir stop --purge      # 停止并清除工作树/状态
```

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

## Smoke 测试

```bash
choir smoke             # MCP bridge smoke
choir smoke --leafs     # live spawn/PR smoke
choir smoke --review    # live review 回流 smoke
choir smoke --e2e-live  # 完整 spawn/review/merge smoke
```

## 流程

```mermaid
flowchart TD
  U[用户] --> I["choir init"]
  I --> S["服务端"]
  I --> TL["TL (Claude)"]

  TL -->|"1. scaffold 提交\n(类型、存根、CLAUDE.md)"| TL
  TL -->|"2. fork_wave\n(需先提交并推送)"| L1["叶子 (Gemini/Codex/\nMoon Pilot/Cursor/Claude)"]
  TL -->|fork_wave| L2["叶子"]
  TL -->|"fork_wave role=tl"| STL["Sub-TL (Claude)"]
  TL -->|spawn_worker| W["Worker（仅研究）"]

  STL -->|"scaffold + fork_wave"| SL1["Sub-叶子"]
  STL -->|fork_wave| SL2["Sub-叶子"]
  SL1 -->|"file_pr → Sub-TL 分支"| GH[GitHub]
  SL2 -->|"file_pr → Sub-TL 分支"| GH
  STL -->|"file_pr → TL 分支"| GH

  L1 -->|"file_pr → TL 分支"| GH
  L2 -->|"file_pr → TL 分支"| GH

  GH -->|Copilot review| Poller
  Poller -->|"CHANGES_REQUESTED\n→ 叶子 + TL"| L1
  Poller -->|"APPROVED\n→ TL"| TL

  L1 -->|"notify_parent（自动）"| TL
  TL -->|merge_pr| GH
  TL -->|"3. WaveComplete\n→ 再次 fork 或向上提交 PR"| TL

  W -->|notify_parent| TL
  S --> Recovery["重启恢复"]
  Recovery --> Poller

  style S fill:#374151,color:#fff
  style TL fill:#7c3aed,color:#fff
  style STL fill:#6d28d9,color:#fff
  style L1 fill:#f59e0b,color:#000
  style L2 fill:#f59e0b,color:#000
  style SL1 fill:#d97706,color:#000
  style SL2 fill:#d97706,color:#000
  style W fill:#6b7280,color:#fff
  style GH fill:#1f2937,color:#fff
  style Poller fill:#6b7280,color:#fff
  style Recovery fill:#6b7280,color:#fff
```

## Releases

```bash
./scripts/release.sh patch
```

二进制：`choir-linux-x86_64`、`choir-macos-arm64`、`SHA256SUMS`。版本单一来源：`moon.mod.json`。

## Nix

```bash
nix develop   # 可复现开发环境 + MoonBit 工具链
```

## 致谢

架构参考了 [exomonad](https://github.com/tidepool-heavy-industries/exomonad)。代理树模型、scaffold-fork-converge 模式、角色上下文文件及若干工作流约定均源自该项目。

## 许可证

MIT
