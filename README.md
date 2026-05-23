# Choir

English | [简体中文](README.zh.md)

> [!NOTE]
> This is primarily used for my own workflows, so may change as they / the space evolves.

A local agent orchestrator built in MoonBit. One expensive model thinks
(Claude as team lead), Codex is the default leaf, and Gemini, Moon Pilot, or
Cursor Agent can be selected for specialized leaves. Each leaf gets its own git worktree, files a PR
targeting the TL's branch, and a built-in poller automates Copilot review
requests, routes GitHub PR review/CI feedback to the right pane, and tells
the TL when Copilot has approved the PR. The core loop is **scaffold → fork
→ converge**: the TL commits shared types, forks a wave of parallel leaves,
merges approved PRs one at a time, then either forks another wave or files
its own PR upward.

For multi-wave features, the TL first crystallizes a spec via `/crystallize`
and decomposes it into a `feature/<slug>` integration branch via `/decompose`,
then runs the scaffold-fork-converge loop on that branch. One-shot fixes can
fork directly off `main`.

```
choir init
  Server (persistent, UDS)
    TL (Claude)
      │  0. (optional) /crystallize → /decompose → feature/<slug>
      │  1. scaffold commit (shared types/stubs)
      │  2. fork_wave ──▶ Leaf A ──file_pr──▶ PR → parent branch
      │              ──▶ Leaf B ──file_pr──▶ PR → parent branch
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
choir init                # bring up server + TL session
choir claude [--lean]     # restart the TL pane on an existing server
                          #   (--lean strips Claude Code's default system prompt)
choir stop                # shut down server, keep recovery state
choir init --recreate     # restart server + TL, keep recovery state
choir stop --purge        # shut down and remove worktrees/state
```

## TL Skills

Auto-installed in the TL pane by `choir claude` / `choir init`:

- `/crystallize <slug>` — idea → spec at `.choir/context/<slug>-spec.md` via structured Q&A.
- `/decompose <slug>` — spec → `feature/<slug>` integration branch.
- `/audit` — spawn a Sarcasmotron worker that critically reviews the current branch diff.

## Wave Telemetry

```bash
choir log --wave <wave-id>                       # event log for one wave
choir stats [--wave <id>|--agent-type <type>]    # tokens / cost / duration rollup
```

The TL also has the `wave_state` MCP tool for typed per-leaf PR / review / CI snapshots
during a live wave — read that instead of inferring from notification prose.

## Issue Tracking

Choir uses [Beads](https://github.com/gastownhall/beads) (`bd`) for durable
issue, backlog, and dependency tracking. Beads is the planning/backlog layer;
Choir remains the orchestration layer for spawning agents, tracking lifecycle,
filing and merging PRs, and enforcing review/CI/thread/verify gates.

Useful commands:

```bash
bd prime                  # Choir-specific Beads workflow reminder
bd ready --json           # dependency-aware ready work
bd --readonly show <id> --json  # issue detail from workers/read-only flows
bd update <id> --claim    # claim work
bd close <id> --reason "Merged in PR #N"
choir beads wave-from <epic-id> --parent-branch feature/<slug>
choir beads wave-from <epic-id> --execute
choir beads gate <id> bead "waiting on API" --await-id api:api-123
choir beads merge-slot acquire
choir beads doctor
```

The `task_list`, `task_get`, `task_create`, and `task_update` Choir tools are
Beads-backed compatibility surfaces. `fork_wave` and `spawn_worker` also accept
`beads_issue_id` to pass a tracked issue into the spawned prompt.

Choir mirrors live orchestration milestones back to Beads on a best-effort
basis: spawn claims/metadata, `file_pr` PR notes, `notify_parent` handoff
notes, `report_usage` telemetry, `merge_pr` closure, and compact audit records.
Choir remains authoritative for live lifecycle, PR, review, CI, thread, verify,
and merge decisions; Beads is the durable backlog and handoff log.

## Build

```bash
moon build --target native --release
moon test --target native
moon fmt
```

After cloning, run `choir init` to configure the lint canary hook automatically, or set it manually with `git config --local core.hooksPath .githooks`.

## Runtime Dependencies

- `git`, `gh` (PR workflow), `zellij` 0.44+ (session management), `bd` (Beads issue tracking)
- Agent CLIs you use: `claude`, `codex`, `gemini`, `moon`, `agent` (Cursor)
- Nix dev shell provides the open-source deps; proprietary CLIs need separate install

## CLI Tool Access

```bash
choir tool agent_list
choir tool fork_wave --caller-role tl --json '{"caller_id":"root","tasks":["task A","task B"]}'
```

Responses: `{"ok":true,"result":{...}}` or `{"ok":false,"error":"..."}`.

## Parent-Branch Override

The parent branch is treated as immutable during a live wave: leaves PR into it,
the TL merges them in. For one-off direct edits on the parent branch (hotfix,
superseding a leaf, etc.) toggle the override:

```bash
choir tl-parent-override on
# edit + commit on the parent branch
choir tl-parent-override off
```

`merge_pr force=true` and direct parent-branch commits are gated on this flag.

## Acknowledgements

Architecture informed by [exomonad](https://github.com/tidepool-heavy-industries/exomonad). The tree-of-agents model, scaffold-fork-converge pattern, role context files, and several workflow conventions originated there.

## License

MIT
