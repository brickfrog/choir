# Choir

A typed local agent orchestrator built in MoonBit. Choir uses Claude as a Team
Lead and various AI agents (Gemini, Codex, Moon Pilot, Cursor Agent, Pi) as leaf
devs to implement tasks in parallel git worktrees.

---

## How it works

Choir provides a Team Lead (TL) agent with a set of tools to decompose and
implement tasks. Each leaf works in its own git worktree, files a PR targeting
the TL's branch when done, and receives GitHub Copilot review feedback
automatically. The TL merges approved PRs and can fork further waves.

### The Cycle
1.  **Decompose**: TL uses `fork_wave` to spawn a set of parallel tasks.
2.  **Execute**: Leaf agents implementation the tasks and call `file_pr`.
3.  **Review**: Choir automatically requests a review from GitHub Copilot, injecting architectural context to ensure helpful feedback.
4.  **Converge**: TL uses `merge_pr` once CI is green and Copilot is satisfied.
5.  **Repeat**: Wave complete; repeat until the feature is finished.

---

## Key Features

- **Typed Core**: Authorized orchestration logic in MoonBit with strict effect boundaries.
- **Pi Integration**: Pi as a first-class agent runtime and operator surface.
- **Robust Poller**: Canonical TL decision engine tracks PR status, CI rollups, and Copilot feedback.
- **Auto-Recovery**: Recovers offline agents and PR tracking across server restarts.
- **MCP Native**: Plugs into the Model Context Protocol ecosystem for leaf tooling.

---

## Quick Start

### Installation
Requires [MoonBit](https://www.moonbitlang.com/), [gh CLI](https://cli.github.com/), and [zellij](https://zellij.dev/).

```bash
moon build --target native
alias choir="$PWD/target/native/debug/choir"
```

### Initializing a Session
```bash
# Start a new session with Pi as Team Lead
choir init --tl pi
```

### Driving from Pi
Once inside the Pi TL pane, you can use the native Choir tools:
- `fork_wave(count: 3, task: \"refactor the parser\")`
- `agent_list()`
- `merge_pr(pr_number: 123)`

---

## Architecture

Choir follows an **Exomonad-style** architecture:
- **Core**: Pure state machine logic and transition planners.
- **Effects**: Typed effect requests emitted by planners.
- **Interpreters**: Host-specific adapters (Zellij, Git, GitHub) that execute effects.

For the full architectural vision, see [PI_NORTH_STAR.md](PI_NORTH_STAR.md).

## Progress

- [x] CLI control plane (`choir tool`)
- [x] Pi extension and TL runtime
- [x] Git worktree isolation
- [x] Strict architecture effect boundary (Migrations 1-6)
- [x] Copilot review automation & context
- [ ] Autonomous Team Flow (Self-driving team)
