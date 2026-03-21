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
  I --> S[choir serve]
  I --> T[TL session]
  T --> B["choir mcp-stdio"]
  B --> S
  T --> P["spawn leaf / worker"]
  P --> L[Leaf session]
  L --> F[file_pr]
  F --> G[GitHub PR]
  G --> R[Review / CI]
  R --> O[Poller]
  O --> L
  O --> T
  T --> M[merge_pr]
  M --> G
  S --> X[restart recovery]
  X --> O
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

## See Also

- [CLAUDE.md](CLAUDE.md)
- [AGENTS.md](AGENTS.md)
