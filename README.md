# Choir

English | [简体中文](README.zh.md)

A local agent orchestrator built in MoonBit. One expensive model thinks
(Claude as team lead), cheaper models implement (Gemini, Codex, Moon Pilot,
Cursor Agent as leaves). Each leaf gets its own git worktree, files a PR
targeting the TL's branch, and a built-in poller automates Copilot review
requests, routes review/CI feedback to the right pane, and tells the TL
when a PR is merge-ready. The core loop is **scaffold → fork → converge**:
the TL commits shared types, forks a wave of parallel leaves, merges their
PRs one at a time, then either forks another wave or files its own PR upward.

Orchestration logic is pure — typed effect planners with no direct I/O.
Host adapters (Git, GitHub, Zellij, filesystem) are injected and testable.

## VSDD Pipeline

Choir's TL follows a built-in **Verify-Spec-Develop-Deploy** pipeline for every feature request:

1. **Spec Crystallization** — TL helps articulate the behavioral contract (preconditions, edge cases, purity boundary). Spec is written to a Chainlink issue as a `plan` comment.
2. **Adversarial Spec Review** — `spawn_worker(type="adversary")` invokes Sarcasmotron, a hyper-critical reviewer who finds every gap in the spec before a line of implementation is written.
3. **TDD Red Gate** — Leaves write all tests first, commit, push, confirm every new test fails, then `notify_parent "[RED GATE]"` and wait. The TL spawns a research worker to verify the failures, then sends the green light.
4. **Adversarial Code Review** — After Copilot review is clean, the TL spawns a second adversary on the PR branch (pre-merge). Nothing lands on main until the adversary is satisfied.
5. **Convergence** — The adversary produces only wording nitpicks. TL reports convergence to the user and merges.

## Chainlink

Choir integrates with [Chainlink](https://github.com/dollspace-gay/chainlink), a local Git-backed issue tracker with typed comment kinds (`plan`, `decision`, `observation`, `result`, `handoff`).

```bash
chainlink issue create "Feature title"       # create issue, get ID
chainlink issue comment <id> "<spec>" --kind plan   # write spec
chainlink_next                               # pick up next in-progress issue
chainlink_show <id>                          # load issue + comments
```

When `fork_wave` is called with an `issue_id`, each leaf's `TaskContract` is automatically enriched from the Chainlink issue:

- **goal** — falls back to issue title if the leaf task has no explicit goal
- **review_context** — issue description + last 5 plan/decision comments (sorted by id), appended to any TL-supplied context with a separator
- **constraints** — `blocked_by` entries merged in without duplication

The pure function `task_contract_from_chainlink_issue` maps a `ChainlinkIssue` to a `TaskContract`; `merge_chainlink_into_task_contract` handles the enrichment merge logic.

```
choir init
  Server (persistent, UDS)
    TL (Claude)
      │  1. scaffold commit (shared types/stubs)
      │  2. fork_wave ──▶ Leaf A ──file_pr──▶ PR → TL branch
      │              ──▶ Leaf B ──file_pr──▶ PR → TL branch
      │                     │
      │        Poller ◀─ review/CI/issue comments ──▶ Leaf (fix)
      │        Poller ──▶ TL (merge per policy + snapshot)
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

## Smoke Tests

```bash
choir smoke             # MCP bridge smoke
choir smoke --leafs     # live spawn/PR smoke
choir smoke --review    # live review delivery smoke
choir smoke --e2e-live  # full spawn/review/merge smoke
```

## Flow

```mermaid
flowchart TD
  U[User] --> I["choir init"]
  I --> S["Server"]
  I --> TL["TL (Claude)"]

  TL -->|"1. scaffold commit\n(types, stubs, CLAUDE.md)"| TL
  TL -->|"2. fork_wave\n(commit+push required)"| L1["Leaf (Gemini/Codex/\nMoon Pilot/Cursor/Claude)"]
  TL -->|fork_wave| L2["Leaf"]
  TL -->|"fork_wave role=tl"| STL["Sub-TL (Claude)"]
  TL -->|spawn_worker| W["Worker (research only)"]

  STL -->|"scaffold + fork_wave"| SL1["Sub-Leaf"]
  STL -->|fork_wave| SL2["Sub-Leaf"]
  SL1 -->|"file_pr → Sub-TL branch"| GH[GitHub]
  SL2 -->|"file_pr → Sub-TL branch"| GH
  STL -->|"file_pr → TL branch"| GH

  L1 -->|"file_pr → TL branch"| GH
  L2 -->|"file_pr → TL branch"| GH

  GH -->|PR state, reviews, Copilot issue comments| Poller
  Poller -->|"changes / actionable TLDecision\n→ leaf + TL"| L1
  Poller -->|"merge gate + policy\n→ TL"| TL

  L1 -->|"notify_parent (auto)"| TL
  TL -->|merge_pr| GH
  TL -->|"3. WaveComplete\n→ fork again or file own PR"| TL

  W -->|notify_parent| TL
  S --> Recovery["restart recovery"]
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

Binaries: `choir-linux-x86_64`, `choir-macos-arm64`, `SHA256SUMS`. Version source of truth: `moon.mod.json`.

## Nix

```bash
nix develop   # reproducible dev shell with MoonBit toolchain
```

## Acknowledgements

Architecture informed by [exomonad](https://github.com/tidepool-heavy-industries/exomonad). The tree-of-agents model, scaffold-fork-converge pattern, role context files, and several workflow conventions originated there.

## License

MIT
