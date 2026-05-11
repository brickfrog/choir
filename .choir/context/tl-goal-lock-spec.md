# Spec: tl-goal-lock

## Context

Claude Code's `/goal` command (released 2026-05-11) sets a completion condition
and a small judge keeps the conversation going until it's met. Choir already
has the right primitives (`TaskContract.verify` for shell-command checks,
beads for declarative state, a poller that delivers messages to agent panes),
but no concept of "the TL is pursuing a specific goal and a background loop
keeps poking it until the acceptance is verified." This adds that: an active
goal owns a small judge that periodically evaluates the acceptance checks and
sends progress/completion messages to the TL pane. Same UX shape as Claude
Code's `/goal`, implemented as a native scheduled task inside `choir serve`
(no extra Claude agent / API cost).

## Clarifications

> Q&A from the crystallize step. Durable; leaves read this.

**Q: Acceptance checks — what can an acceptance condition be?**
A: Both, free mix. Each check is either a shell command (exit 0 = pass) or a
bead-state assertion (e.g. `choir-foo` is closed). A goal carries any
combination of the two.

**Q: Goal source — how is a goal declared?**
A: Either: bead ID or ad-hoc string, auto-detected. `choir goal choir-kqv`
locks to that epic and inherits its acceptance; `choir goal "ship the
dashboard" --verify '<cmd>'…` is a freeform goal with explicit verify
commands. Choir picks by shape (matches existing bead ID regex → bead-tied,
otherwise → freeform).

**Q: TL respawn behavior — when a new TL starts and a pending goal exists,
what happens?**
A: Not durable across TL respawns. Per user clarification: `/goal` in Claude
Code is just a small judge that keeps prodding the running session; if the
session dies, the judge dies. Choir matches that — the judge is ephemeral,
tied to the current TL session, and the user reissues `choir goal` after a
respawn if the goal is still relevant. No KV-resume / no cross-restart
restoration.

## Goals

- `choir goal <bead-id|text> [--verify <cmd>]...` declares an active goal for
  the current TL session and starts a judge task that runs until the goal is
  met or `choir goal-clear` is run.
- The judge evaluates acceptance on a schedule (periodic poll + on wave /
  merge / notify events) by running the verify shell commands and querying
  bead state.
- While the goal is active, the choir statusline shows a `[GOAL: <slug>
  <N>/<M>]` segment.
- Judge progress prods are delivered to the TL pane via the existing
  poller-delivery channel, rate-limited so an unchanged state doesn't spam
  the pane (one prod per state transition + at most one per 5min while open).
- When all checks pass, the judge sends `[GOAL COMPLETE: <slug>]` to the TL
  pane, clears the goal KV, and exits cleanly. If the goal is bead-tied, the
  bead is left untouched (auto-closing is a follow-up).
- `choir goal-clear` manually cancels the active goal (kills the judge,
  removes KV).
- Listing/inspection: `choir goal status` prints the active goal + last
  evaluation result.

## Non-Goals

- No KV-persisted goal that auto-resumes across TL crashes. Goals die with
  the TL session; reissue after respawn.
- No hard-block on `fork_wave`/`merge_pr`/other tool calls based on
  goal-relevance. The "lock" is just "judge keeps the goal alive and prods",
  not "TL is restricted to goal-related work".
- No goal stacking. One active goal per TL session at a time; declaring a
  new goal supersedes the previous one (with a `[GOAL SUPERSEDED]` prod).
- Not generalizing to leaves/workers. Goals are a TL-only concept.
- Not changing the TL phase machine. Goal state is sidecar KV, not a
  `WorkflowState::Supervisor` variant.
- Not spawning a separate Claude agent for the judge. Cheaper to run the
  checks deterministically in `choir serve` itself.

## Design

**Files / modules to touch:**

- `src/types/goal.mbt` (new): `Goal { slug, source: BeadId(String) | Text(String),
  checks: Array[GoalCheck], started_unix_sec, last_eval: Option[GoalEvalResult] }`
  and `GoalCheck = ShellCommand(String) | BeadStateClosed(String)`,
  `GoalEvalResult { passing: Int, total: Int, failing_summary: String,
  evaluated_unix_sec }`.
- `src/server/goal_judge.mbt` (new): the scheduled check-runner. Plugs into
  the existing tick loop in `src/server/state.mbt` (alongside the poller and
  watchdog). On each tick (default 30s) AND on poller events (wave merged,
  PR merged, notify_parent), it: reads the active goal KV, evaluates each
  check (shell via injected `runner`, bead via `bd show <id> --json`),
  compares to last_eval, decides whether to emit a prod, and on all-pass
  emits `[GOAL COMPLETE]` + clears KV.
- `src/tools/goal.mbt` (new): the MCP-tool entry points `goal_set`,
  `goal_clear`, `goal_status`. The CLI `choir goal <args>` dispatches to
  these.
- `src/bin/choir/main.mbt`: add `goal` / `goal-clear` / `goal status`
  subcommands routed through `src/tools/goal.mbt`.
- `src/bin/choir/statusline.mbt`: append a `[GOAL: <slug> <N>/<M>]` segment
  when `.choir/kv/tl-goal--<session>.json` exists. Read-only.
- `.choir/kv/tl-goal--<session>.json`: stores the serialized `Goal`. One
  file per session. Cleared on completion / explicit clear / session
  teardown.
- `src/tools/dispatch.mbt`: thread the goal-judge handle through dispatch
  for `goal_set`/`goal_clear`/`goal_status` (same injection seam as the
  existing capabilities — no direct `@sys.*` in the tool body).

**Bead-state check primitive:**
`BeadStateClosed(bead_id)` resolves to "pass" iff `bd show <id> --json` returns
`"status":"closed"`. Inheriting acceptance from a bead-tied goal: when the
user runs `choir goal <bead-id>`, the judge defaults its check list to
`[BeadStateClosed(bead-id)]`. Any `--verify <cmd>` flags append shell checks.

**Prod rate-limiting:**
- Always emit on a state transition (a check newly passes or newly fails, or
  the passing count changes).
- While state is unchanged AND all checks are still open, emit at most one
  reminder prod every 5min ("[GOAL: <slug>] still <N>/<M> — keep going").
- Emit `[GOAL COMPLETE]` exactly once, then the judge exits.

**Pane delivery:**
Reuse the existing poller delivery channel (`@delivery` / `send_message` to
the TL agent_id `root`). The TL pane treats `[GOAL: …]` / `[GOAL COMPLETE: …]`
prods like any other poller event — no special handling required at the
harness level.

## Verify

- `moon test --target native` — covers goal-parser (`bead-id` vs `text`
  auto-detect), `Goal::evaluate` (shell + bead checks), rate-limiter,
  KV serialization.
- `choir goal "always-true" --verify 'true' && sleep 2 && grep -q '\[GOAL
  COMPLETE: always-true\]' .choir/delivery.log` — observable: a passing goal
  emits the completion line within one poll cycle.
- `choir goal "never-true" --verify 'false' && sleep 2 && grep -q '\[GOAL:
  never-true\] 0/1' .choir/delivery.log` — observable: a failing goal emits
  the progress prod.
- `choir goal choir-kqv` while choir-kqv is open, then `bd close choir-kqv`,
  then within ≤30s `grep -q '\[GOAL COMPLETE: choir-kqv\]' .choir/delivery.log`
  — observable: bead-tied goals close when the bead closes.
- `choir statusline` output contains `[GOAL: <slug> <N>/<M>]` while a goal
  is active and does not when it isn't.
- `choir goal-clear` removes the KV file and the next statusline render
  drops the `[GOAL: …]` segment.

## Boundary (do not)

- The judge MUST NOT call `merge_pr`, `fork_wave`, `kill_agent`, `file_pr`,
  `task_create`/`task_update`. It is read-only on choir state plus
  `send_message`/delivery.
- The judge MUST NOT modify the TL's lifecycle / phase state.
  No `enter_decision`, no `mark_done`, no `WorkflowState` writes.
- The judge MUST NOT auto-spawn on TL respawn. If the TL session ends and a
  new one starts, the user reissues `choir goal` if still relevant.
- The judge MUST rate-limit reminder prods. An unchanged failing state
  produces at most one prod per 5min — never per-tick.
- `goal_set` MUST supersede (not stack) — declaring a new goal while one is
  active clears the old one with a `[GOAL SUPERSEDED]` prod.
- KV path is exactly `.choir/kv/tl-goal--<session>.json` — one active goal
  per session, never multi-keyed.
- No direct `@sys.*` / `@process.*` calls in `src/tools/goal.mbt` /
  `src/server/goal_judge.mbt`. Inject capabilities through the dispatch
  pattern (runner, capture, write_file_atomic, path_exists).

## Follow-Ups

- Bead-tied goals could auto-close the bead with a `[GOAL MET]` comment on
  completion (currently the bead is left untouched).
- Prod templates customizable via `.choir/config.toml` (default templates
  hardcoded for v1).
- Multi-goal stacking (parent goal + sub-goals) — out of scope for v1, would
  need a goal-tree data model.
- Cross-workspace goal aggregation (pairs with the broader `choir agents`
  cross-session view feature surfaced from the same Claude Code release).
- A `/goal` slash command inside the TL session (in addition to the
  `choir goal` CLI) — UX nicety; the CLI is the source of truth.
- A "judge transcript" status-line segment showing the last N prods —
  UI polish.
