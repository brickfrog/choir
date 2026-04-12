# Choir

English | [简体中文](README.zh.md)

A local agent orchestrator built in MoonBit. One expensive model thinks
(Claude as team lead), cheaper models implement (Gemini, Codex, Moon Pilot,
Cursor Agent as leaves). Each leaf gets its own git worktree, files a PR
targeting the TL's branch, and a built-in poller automates Copilot review
requests, routes GitHub PR review/CI feedback to the right pane, and tells
the TL when Copilot has approved the PR. The core loop is **scaffold → fork
→ converge**: the TL commits shared types, forks a wave of parallel leaves,
merges approved PRs one at a time, then either forks another wave or files
its own PR upward.

```
choir init
  Server (persistent, UDS)
    TL (Claude)
      │  1. scaffold commit (shared types/stubs)
      │  2. fork_wave ──▶ Leaf A ──file_pr──▶ PR → TL branch
      │              ──▶ Leaf B ──file_pr──▶ PR → TL branch
      │                     │
      │        Poller ◀─ GitHub PR review/CI/issue comments ──▶ Leaf (fix)
      │        Poller ──▶ TL (merge after Copilot approval + snapshot)
      │  3. WaveComplete → fork_wave again (wave 2) or file own PR up
      │
      └── optional: fork_wave(role=tl) ──▶ Sub-TL
                      Sub-TL runs same scaffold-fork-converge cycle
                      Sub-TL files PR → TL branch when done
```

## Quick Start

```bash
choir init              # bring up server + TL session
choir stop              # shut down server, keep recovery state
choir init --recreate   # restart server + TL, keep recovery state
choir stop --purge      # shut down and remove worktrees/state
```

## Build

```bash
moon build --target native --release
moon test --target native
moon fmt
```

Optional pre-commit hook:

```bash
git config core.hooksPath .githooks   # runs moon fmt + moon check
```

## Runtime Dependencies

- `git`, `gh` (PR workflow), `zellij` 0.44+ (session management)
- Agent CLIs you use: `claude`, `gemini`, `moon`, `codex`, `agent` (Cursor)
- Nix dev shell provides the open-source deps; proprietary CLIs need separate install

## CLI Tool Access

```bash
choir tool agent_list
choir tool fork_wave --caller-role tl --json '{"caller_id":"root","tasks":["task A","task B"]}'
```

Responses: `{"ok":true,"result":{...}}` or `{"ok":false,"error":"..."}`.

## Acknowledgements

Architecture informed by [exomonad](https://github.com/tidepool-heavy-industries/exomonad). The tree-of-agents model, scaffold-fork-converge pattern, role context files, and several workflow conventions originated there.

## License

MIT
