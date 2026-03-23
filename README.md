# Choir

English | [简体中文](README.zh.md)

## Name

`choir` - MoonBit agent orchestration server.

## Synopsis

```bash
choir init
choir stop
choir serve
choir mcp-stdio
choir smoke
choir smoke --companions
choir smoke --leafs
choir smoke --review
choir smoke --e2e-live
```

## Description

Choir runs a persistent local server and coordinates coding agents in isolated
workspaces.

- local transport: UDS by default
- optional transport: TCP
- local terminal backends: `tmux`, `zellij`
- agent CLIs: Claude, Gemini, Moon Pilot
- workflow: spawn, message, file PR, track review, merge, recover after restart

## Build

```bash
moon check
moon test --target native
moon build --target native --release
moon fmt
```

## Runtime Dependencies

The release artifact is the `choir` executable, but the workflow also expects
some external tools.

- required: `git`
- required for PR workflow: `gh`
- required for local session management: `tmux` or `zellij`
- required for the agent CLIs you actually use: `claude`, `gemini`, `moon`

The Nix dev shell includes the open-source dependencies above. Proprietary
agent CLIs still need to be installed and authenticated separately.

## Releases

Native binaries are intended to ship through GitHub Releases.

- `choir-linux-x86_64`
- `choir-macos-arm64`
- `SHA256SUMS`

Release source of truth: `moon.mod.json`.

Release cut:

```bash
./scripts/release.sh patch
```

## Nix

```bash
nix develop
```

The flake currently provides a reproducible development shell and MoonBit
toolchain for Choir. It does not yet expose a standalone `nix build .#choir`
package.

## Quick Start

```bash
choir init
```

This brings up:

- one persistent server session
- one TL client session
- local state under `.choir/`

## Smoke Tests

```bash
choir smoke
choir smoke --companions
choir smoke --leafs
choir smoke --review
choir smoke --e2e-live
```

- `choir smoke`: MCP bridge/runtime smoke
- `choir smoke --companions`: `init` companion isolation smoke
- `choir smoke --leafs`: live Moon Pilot + Gemini spawn/PR smoke
- `choir smoke --review`: live review delivery smoke
- `choir smoke --e2e-live`: live spawn/review/merge smoke

## Flow

```mermaid
flowchart TD
  U[User] --> I["choir init"]
  I --> S["Server"]
  I --> TL["TL (Claude)"]

  TL -->|mcp-stdio| S
  TL -->|fork_wave| G1["Leaf (Gemini)"]
  TL -->|fork_wave| G2["Leaf (Gemini)"]
  TL -->|"fork_wave agent_type=claude"| C1["Leaf (Claude)"]
  TL -->|spawn_worker| W["Worker (Moon Pilot)"]

  G1 -->|file_pr| GH[GitHub PR]
  G2 -->|file_pr| GH
  C1 -->|file_pr| GH

  GH -->|Copilot review| Poller
  Poller -->|ReviewReceived| G1
  Poller -->|ReviewReceived| G2
  Poller -->|ReviewReceived| C1
  Poller -->|notify parent| TL

  G1 -->|notify_parent| TL
  TL -->|merge_pr| GH

  W -->|notify_parent| TL
  S --> Recovery[restart recovery]
  Recovery --> Poller

  style S fill:#374151,color:#fff
  style TL fill:#7c3aed,color:#fff
  style G1 fill:#f59e0b,color:#000
  style G2 fill:#f59e0b,color:#000
  style C1 fill:#3b82f6,color:#fff
  style W fill:#10b981,color:#000
  style GH fill:#1f2937,color:#fff
  style Poller fill:#6b7280,color:#fff
  style Recovery fill:#6b7280,color:#fff
```

## Files

```text
.choir/config.toml        main config
.choir/server.sock        local UDS socket
.choir/tasks/             task files
.choir/kv/                key-value store
.choir/worktrees/         spawned worktrees
CLAUDE.md                 operator/developer notes
AGENTS.md                 leaf-agent instructions
```

## Status

- local UDS workflow: proven
- `tmux` backend: proven
- `zellij` backend: working
- live companion/leaf/review/merge smokes: present
- TCP/remote path: implemented, less proven than local UDS
- Claude `--channels`: not usable for manual MCP servers yet

## Acknowledgements

Choir's architecture is informed by [exomonad](https://github.com/tidepool-heavy-industries/exomonad), a Rust/WASM agent orchestration framework. The tree-of-agents model, role context files, prompt-via-temp-file pattern, and several workflow conventions originated there.

## License

MIT

## See Also

- [CLAUDE.md](CLAUDE.md)
- [AGENTS.md](AGENTS.md)
