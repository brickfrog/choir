# Spec: boot-hygiene

## Context
Choir's boot output and cross-session state both still carry forward cruft
from prior sessions: drifted prompt files emit WARNs that operators learn to
ignore (drowning real signal); transient `agent-tl-NNNNNNN` IDs accumulate in
the registry; zellij Server/TL tabs from prior sessions stay around;
unexpected-disconnect leaves orphan their zellij tab forever. dl2x landed the
lifecycle-KV reap; this feature extends that hygiene story across four
adjacent surfaces so a fresh boot has zero unexplained WARNs and a clean UI.

## Clarifications

**Q: Prompt drift — auto-resync, gate startup, or explicit CLI?**
A: Explicit CLI. Add `choir prompts diff` (show drifted files + a unified
diff vs the embedded default) and `choir prompts sync` (overwrite drifted
files with the embedded default, optionally with a backup). Startup keeps
WARNing on drift (signal, not noise — operator should know), but the path
to resolution is one command instead of "edit each file by hand against
unknown baseline."

**Q: TL-id leak — fix at register-time or sweep at boot?**
A: Fix at register-time. Trace which call path registers `agent-tl-NNNNNNN`
IDs, then either reuse the parent TL's agent_id or skip register entirely
for that probe. Boot-time sweep would mask the bug; register-time fix is
mechanical.

**Q: Zellij tab reap — also reap mid-session, or boot-only?**
A: Boot-only for the carryover case (choir-zellij-tab-reap). Mid-session
orphan-on-disconnect is a separate surface (choir-disconnect-zellij-tab-
orphan) — fix both in this feature branch but in different leaves.

**Q: How does the disconnect-orphan leaf know which lifecycle paths need
CloseTerminal?**
A: Audit `plan_fail` and `plan_finalize` in `src/phase/lifecycle.mbt`
(or wherever the effect emitters live) — every terminal transition that
already emits other teardown effects should also emit `CloseTerminal(target)`
when the agent has a `terminal_target: Some(_)`. Today only the
Done-via-merge path emits it; Failed via UnexpectedDisconnect does not.

**Q: Will the four leaves conflict on shared files?**
A: Minimally. The natural touchpoints:
- prompt-drift-resync: `src/bin/choir/prompts_cmd.mbt` (new), `src/bin/choir/main.mbt` (1 line to register), `src/prompts/loader.mbt` (read-only)
- tl-id-leak: `src/server/handler.mbt` register-tool handler + `src/server/goal_judge.mbt`
- zellij-tab-reap: `src/bin/choir/init.mbt` + the zellij-action surface in `src/workspace/`
- disconnect-zellij-tab-orphan: `src/phase/lifecycle.mbt` (effect emitter) + `src/server/handler_disconnect.mbt` (testing).
Only `src/bin/choir/main.mbt` and possibly `src/server/handler_disconnect.mbt`
might see two leaves touching them; we'll keep edits surgical.

## Goals
- `choir prompts diff` outputs a unified diff for each drifted file vs the
  embedded default; exits non-zero when any drift exists.
- `choir prompts sync` rewrites each drifted file from the embedded default
  with a `.choir/prompts-backup/<file>.<ts>.bak` copy of the prior content.
- `agent-tl-NNNNNNN` registrations no longer accumulate in
  `wave_state`/`status_bar_state` snapshots across a session; root cause is
  fixed at the registration point, not swept post-hoc.
- `choir init` on a fresh session reaps any leftover literal `Server` /
  `TL` zellij tabs from prior sessions before spawning fresh ones, using
  the existing zellij-action surface. Leaf-branch tab tracking is
  deferred — see Follow-Ups.
- A leaf whose process transitions to `ProcessState::Failed(reason=UnexpectedDisconnect)`
  has its zellij tab closed by the same `CloseTerminal` effect path that
  fires on `Done`-via-merge, within ~1 tick.

## Non-Goals
- No automatic prompt resync on startup. Drift remains an operator decision.
- No mid-session re-sweep of zellij tabs for the reap leaf — boot-only.
  Mid-session orphan handling is the disconnect leaf's scope.
- No registry-side post-hoc sweep of `agent-tl-*` entries. Fix the source.
- No new CLI subcommands beyond `choir prompts {diff,sync}`.
- No backwards-compatibility shims for prior register paths.
- No changes to dl2x's `RecoveryAction::ReapStaleLifecycle` machinery.
  Future epics may extend it (children--*, phase-dev--*, pending-wave--*)
  but those stay tracked separately.
- No changes to the PR-policy epic (choir-9j5 et al.).

## Design

### Leaf 1 — `choir prompts diff` / `choir prompts sync` (choir-prompt-drift-resync)
Files: `src/bin/choir/prompts_cmd.mbt` (new), `src/bin/choir/main.mbt`
(register the subcommand), `src/prompts/loader.mbt` (re-use existing
drift-detection accessor; add a helper that returns drifted files + their
embedded defaults if the accessor doesn't already).

Approach:
1. Add a `prompts` subcommand at the top-level `choir` CLI surface.
2. `choir prompts diff` walks the prompt set the binary baked in, compares
   each file's on-disk content to the baked default, and prints
   `--- defaults/<name>` / `+++ disk/<name>` style diff for any mismatch.
   Exits 0 when no drift; non-zero when any.
3. `choir prompts sync` does the same walk, copies each drifted file to
   `.choir/prompts-backup/<name>.<unix-ts>.bak`, then overwrites the disk
   file with the embedded default. Idempotent for clean trees (no diff →
   no-op, no backup).
4. Both subcommands are pure file I/O at the CLI boundary; no server RPC.

### Leaf 2 — TL-id leak (choir-tl-id-leak)
Files (as shipped — spec hypothesis was wrong): `src/bin/choir/mcp_mode.mbt`
(client-side identity resolver; the actual producer of `agent-tl-NNNNNNN`
IDs), `src/server/handler_test.mbt` (the registry-doesn't-grow regression).
The initial spec hypothesis pointed at `src/server/handler.mbt` and
`src/server/goal_judge.mbt`; the real source was MCP stdio bridges falling
back to a pid-derived synthetic agent_id when no stable `--name` or local
config was set. The fix routes those probes through the stable supervisor
caller and skips the register handshake entirely.

Approach (as shipped):
1. Locate the call site that registers under `agent-tl-NNNNNNN` — turned
   out to be MCP stdio fallback on supervisor-shaped bridges with no
   identity config.
2. Skip the register handshake entirely for those bridges (option b: the
   probe is ephemeral) and route their requests through the stable
   supervisor caller (root).
3. Hermetic regression in `src/server/handler_test.mbt` drives 20
   transient TL register cycles and asserts the registry does not grow.

### Leaf 3 — Zellij tab reap on init (choir-zellij-tab-reap)
Files: `src/bin/choir/init.mbt`, the existing zellij-action surface
in `src/workspace/` (likely `src/workspace/zellij.mbt` or similar — grep
`zellij_list_tabs` / `close_tab`).

Approach (as shipped — narrower than the initial spec hypothesis):
1. At init time, before spawning fresh Server/TL tabs, enumerate existing
   zellij tabs in the target session. Close only tabs literally named
   `Server` or `TL` — those are the duplicate-from-prior-session offenders
   in the bead's evidence (Server×3, TL×4). A heuristic dotted-slug matcher
   was prototyped and rejected because it false-positived on common user
   tab names (`v1.0.0`, `package.json`, `notes.md`). Leaf-branch tab
   tracking via a persistent registry is deferred (Follow-Ups).
2. Only run on fresh init (not on `--recreate`); the recreate path is
   already destructive in the right way. Use the existing init guard.
3. Hermetic test: mock `zellij_list_tabs` to return a known set including
   literal Server/TL plus user-tab false-positive shapes
   (v1.0.0, package.json, README.md, my.feature.branch, leaf-branch
   slugs); assert close is called only for the literal Server/TL.

### Leaf 4 — Disconnect-orphan zellij tab (choir-disconnect-zellij-tab-orphan)
Files: `src/phase/lifecycle.mbt` (the `plan_fail` / `plan_finalize` effect
emitter), `src/server/handler_disconnect.mbt` (test infra).

Approach:
1. Locate the effect emitter for terminal lifecycle transitions. The
   Done-via-merge path emits `CloseTerminal(target)` when
   `agent.terminal_target: Some(_)`. The `Failed(UnexpectedDisconnect)`
   path should mirror that.
2. Add the `CloseTerminal` emission to the disconnect-failure branch of
   the emitter. Be careful that the parent-notification effect still
   fires (don't reorder effects to lose NotifyParent on the way).
3. Hermetic test: drive a leaf into `Failed(UnexpectedDisconnect)` with a
   `terminal_target: Some(...)` and assert the emitted effects include
   `CloseTerminal(target)` in addition to the existing
   `NotifyParent`/`PersistLifecycle`/etc.

## Verify
- **Leaf 1 (observable):** `choir prompts diff` from a clean checkout exits 0
  with no output. Edit one prompt file (e.g. append a newline to
  `.choir/prompts/skills/tl-stance.md`), re-run — exit non-zero, diff shown.
  Run `choir prompts sync` — file resets to default, `.choir/prompts-backup/
  tl-stance.md.<ts>.bak` exists with the edited content. Re-run diff — clean.
- **Leaf 2 (observable):** spawn a session, drive 20 register-call cycles
  (via the test harness or by triggering 20 stop-hook re-evaluations), then
  query `wave_state` / `status_bar_state` and grep for `agent-tl-` — count
  must not grow per cycle.
- **Leaf 3 (observable):** the reap only fires through zellij's
  resurrection cache, not against a live session — `choir init` against
  a live session takes the early-attach return at init.mbt:1006-1007
  and never reaches the reap. To exercise the reap end-to-end: set up
  a zellij session with synthetic stale tabs `Server`, `TL`, plus
  user-tab false-positive shapes (`v1.0.0`, `package.json`, `README.md`,
  `my.feature.branch`, and a leaf-branch slug like `feature-x.leaf-0`),
  then DETACH the session (and let it sit long enough that
  `zellij list-sessions` no longer shows it as alive) so the
  resurrection cache holds the layout. Run `choir init`; zellij
  resurrects the session; the reap then closes the literal Server/TL
  tabs while preserving all others.
- **Leaf 4 (observable):** drive a leaf to `Failed(UnexpectedDisconnect)`
  (via a test fixture that simulates the disconnect timeout), assert
  the zellij tab is closed in the same tick. Grep serve.log for the
  close-terminal call against the leaf's `terminal_target`.
- **All:** `moon check --target native` clean; `moon test --target native`
  green; no new lint findings.

## Boundary (do not)
- No `--no-verify`, no `--no-gpg-sign`.
- No direct `@sys.*` / `@process.*` / `@workspace.run_*` calls from
  `src/server/`, `src/tools/`, `src/runtime/`, `src/phase/` orchestration
  paths — go through typed effects or injected adapters.
- No `legacy_*` / `compat_*` / `*_old` wrappers.
- No new `String` fields for values drawn from a fixed set — use enums.
- No `Result[T, String]` — use `Result[T, ChoirError]` for new error paths.
- No shell-harness tests with broad git or filesystem mutation outside
  hermetic tmp areas.
- No tests that depend on a live zellij session — use injected
  `zellij_list_tabs`/`zellij_close_tab` capabilities.
- No tests that invoke `choir init`, `choir claude`, or `choir-sanity` —
  those spawn zellij and would recurse in the leaf's pane.
- No changes to dl2x's `RecoveryAction::ReapStaleLifecycle` shape.
- No automatic prompt-resync on startup. Drift is operator-driven.

## Follow-Ups
- Track leaf-branch zellij tabs via a persistent registry (`.choir/zellij-
  tabs.json` or equivalent) so init-time reap can close them
  deterministically without heuristic name matching. Filed as choir-axk2
  (or whichever ID was assigned).
- Widen the reap planner to also handle `agents/` and `inline/` containers
  (currently `worktrees/`-only — see the AUDIT comment in
  `src/runtime/recovery.mbt`).
- Add `children--*`, `phase-dev--*`, `phase-tl--*`, `pending-wave--*` KV
  reaping if their cruft starts appearing in boot logs.
- Consider promoting prompt-drift to a hard startup gate once the operator
  workflow `prompts diff` / `prompts sync` is in place.
