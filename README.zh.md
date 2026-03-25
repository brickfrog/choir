# Choir

[English](README.md) | 简体中文

用 MoonBit 编写的本地多代理编排器。用你昂贵的订阅来思考（Claude 担任 TL），
用更便宜或更专业的订阅来实现（Gemini、Codex、Moon Pilot 作为叶子代理）。
每个叶子代理在独立的 git worktree 中工作，完成后提交 PR，内置 poller 自动接收
GitHub Copilot 的 review 反馈。TL 在 PR 通过后合并，将所有分支折叠回 main。

```
choir init
  服务端 (常驻, UDS)
    TL (Claude) ──fork_wave──▶ 叶子 (Gemini/Codex/Moon Pilot) ──file_pr──▶ GitHub PR
                                                                               │
                               Poller ◀── Copilot review ─────────────────────┘
                               Poller ──▶ 叶子 (修复 review 意见)
                               Poller ──▶ TL   (通过后合并)
```

## 概要

```bash
choir init              # 拉起服务端 + TL 会话
choir stop              # 关闭服务端
choir serve             # 直接运行服务端
choir mcp-stdio         # MCP JSON-RPC 桥接（每个代理一个）
choir smoke             # MCP bridge smoke 测试
choir smoke --leafs     # live spawn/PR smoke
choir smoke --review    # live review 回流 smoke
choir smoke --e2e-live  # 完整 spawn/review/merge smoke
```

## 构建

```bash
moon check
moon test --target native
moon build --target native --release
moon fmt
```

## 运行依赖

发布产物主要是 `choir` 可执行文件，但完整工作流仍依赖一些外部工具。

- 必需：`git`
- PR 工作流必需：`gh`
- 本地会话管理必需：`zellij`（0.44+）
- 你实际使用到的代理 CLI：`claude`、`gemini`、`moon`、`codex`

Nix dev shell 会提供上面的开源依赖。专有代理 CLI 仍需要你自行安装并完成认证。

## Releases

原生二进制计划通过 GitHub Releases 分发。

- `choir-linux-x86_64`
- `choir-macos-arm64`
- `SHA256SUMS`

版本单一来源：`moon.mod.json`。

发版命令：

```bash
./scripts/release.sh patch
```

## Nix

```bash
nix develop
```

当前 flake 提供的是 Choir 的可复现开发环境和 MoonBit 工具链；暂时还没有
暴露独立的 `nix build .#choir` 打包产物。

## 快速开始

```bash
choir init
```

该命令会拉起：

- 一个常驻服务会话
- 一个 TL 客户端会话
- 位于 `.choir/` 的本地状态目录

## Smoke 测试

```bash
choir smoke
choir smoke --companions
choir smoke --leafs
choir smoke --review
choir smoke --e2e-live
```

- `choir smoke`：MCP bridge / runtime smoke
- `choir smoke --companions`：`init` companion 隔离 smoke
- `choir smoke --leafs`：Moon Pilot + Gemini 的 live spawn/PR smoke
- `choir smoke --review`：live review 回流 smoke
- `choir smoke --e2e-live`：live spawn/review/merge smoke

## 流程

```mermaid
flowchart TD
  U[用户] --> I["choir init"]
  I --> S["服务端"]
  I --> TL["TL (Claude)"]

  TL -->|mcp-stdio| S
  TL -->|fork_wave| G1["叶子 (Gemini)"]
  TL -->|fork_wave| G2["叶子 (Gemini)"]
  TL -->|"agent_type=codex"| X1["叶子 (Codex)"]
  TL -->|"agent_type=moon_pilot"| M1["叶子 (Moon Pilot)"]
  TL -->|"agent_type=claude"| C1["叶子 (Claude)"]
  TL -->|spawn_worker| W["Worker"]

  G1 -->|file_pr| GH[GitHub PR]
  G2 -->|file_pr| GH
  X1 -->|file_pr| GH
  M1 -->|file_pr| GH
  C1 -->|file_pr| GH

  GH -->|Copilot review| Poller
  Poller -->|ReviewReceived| G1
  Poller -->|ReviewReceived| G2
  Poller -->|notify parent| TL

  G1 -->|notify_parent| TL
  TL -->|merge_pr| GH

  W -->|notify_parent| TL
  S --> Recovery[重启恢复]
  Recovery --> Poller

  style S fill:#374151,color:#fff
  style TL fill:#7c3aed,color:#fff
  style G1 fill:#f59e0b,color:#000
  style G2 fill:#f59e0b,color:#000
  style X1 fill:#22c55e,color:#000
  style M1 fill:#10b981,color:#000
  style C1 fill:#3b82f6,color:#fff
  style W fill:#6b7280,color:#fff
  style GH fill:#1f2937,color:#fff
  style Poller fill:#6b7280,color:#fff
  style Recovery fill:#6b7280,color:#fff
```

## 文件

```text
.choir/config.toml        主配置
.choir/server.sock        本地 UDS socket
.choir/tasks/             任务文件
.choir/kv/                键值存储
.choir/worktrees/         派生工作树
.choir/hooks/hook.wasm    可选 WASM hook 插件
.choir/rewrite_rules.json 可选 PII 重写规则
CLAUDE.md                 操作/开发说明
AGENTS.md                 叶子代理说明
```

## WASM Hooks

Choir 通过 [extism](https://extism.org/) 支持 Gemini 模型 hook（BeforeModel/AfterModel）的 WASM 插件。插件使用 MoonBit 的 `extism/moonbit-pdk` 编写并编译为 WASM。

当 `.choir/hooks/hook.wasm` 存在时，Gemini 代理会自动启用模型 hook。无插件则无 hook。

功能：
- **before_model**：重写 LLM 请求中的 PII（真实信息 → 令牌）
- **after_model**：反向重写 LLM 响应（令牌 → 真实信息）
- **pre_tool_use**：拦截已知的 Gemini 故障模式

## 状态

- 本地 UDS 工作流：已验证
- zellij 后端（0.44+）：已验证
- 叶子代理：Claude、Gemini、Moon Pilot、Codex
- 结构化日志：[moontrace](https://github.com/brickfrog/moontrace)，支持彩色输出和 OTLP span 导出
- companion / 叶子代理 / review / merge 的 live smoke：已具备
- TCP/remote 路径：已实现，但验证程度低于本地 UDS

## 致谢

Choir 的架构参考了 [exomonad](https://github.com/tidepool-heavy-industries/exomonad)（一个 Rust/WASM 多代理编排框架）。代理树模型、角色上下文文件、prompt 临时文件模式等工作流约定均源自该项目。

## 许可证

MIT

## 另见

- [CLAUDE.md](CLAUDE.md)
- [AGENTS.md](AGENTS.md)
