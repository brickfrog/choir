# Kill-Agent Robustness Spec

## Context

In a user's `mbtrl` repo, `kill_agent` returned success but left the
agent's CLI process running as a zombie: `moon_pilot` at PID 1965822 with
cwd `/mnt/data/Code/mbtrl/.choir/worktrees/w2-0 (deleted)` — the worktree
had been removed out from under it. The zellij tab also survived. The
user had to find the PID manually, `kill` it, then close the tab via
`zellij action close-tab`.

Root causes in `src/tools/shutdown.mbt` and `src/tools/fork_wave.mbt`:

1. **Process survival.** `interpret_kill_agent` runs
   `choir zellij-action close <target>` and `git worktree remove`, then
   marks the registry entry `Failed`. When the zellij close fails to
   resolve the tab/pane (e.g., `zellij_target_tab_id` returns None →
   exit 1 → warning attached but interpreter continues), nothing kills
   the process. Even when tab close succeeds, SIGHUP from zellij goes
   through `sh -lc` which doesn't reliably propagate to the grandchild
   `node/moonagent` or similar runtime. The worktree is wiped while the
   process keeps going.

2. **Slug collision.** `fork_wave_spawn_plan` (`src/tools/fork_wave.mbt:61`)
   skips already-registered agent_ids only when their state is `Active`
   or `Completing`. After `kill_agent` marks an entry `Failed`, a
   subsequent `fork_wave` with the same `slug_prefix` happily reuses
   that same agent_id — producing duplicate registry rows and branch
   name collisions when the respawn tries to push.

## Goals

1. `kill_agent` reliably terminates the agent's CLI process, not just
   the zellij surface and worktree. Belt-and-suspenders: run the
   existing zellij close + worktree remove, THEN hard-kill any process
   whose cwd is under the agent's workspace path.
2. `fork_wave` treats any registry entry for the computed agent_id as
   "taken" — Active, Completing, Failed, Completed, etc. — and bumps
   the slug to the next unused suffix rather than silently overwriting.
3. Both changes ship behind unit tests; no test requires spawning a
   real process or real zellij.

## Non-Goals

- No rewrite of the zellij-close path. The pane/tab close command stays
  as-is — the `/proc` fallback handles the failure case.
- No SIGHUP-propagation fix through the `sh -lc` launch shell. Out of
  scope; the process-kill fallback catches it anyway.
- No changes to `shutdown` (the cooperative agent exit) — `kill_agent` is
  the forced-termination path; cooperative shutdown already works.
- No Windows/macOS support. `/proc` is Linux-only; choir is Linux-only.
- No new MCP tool. Fixes are internal to `interpret_kill_agent` and
  `fork_wave_spawn_plan`.

## Design

### Leaf A — Process-kill fallback in `kill_agent`

**Files:** `src/sys/stub.c`, `src/sys/io.mbt`, `src/sys/io_stub.mbt`,
`src/sys/io_test.mbt` (or a new `src/sys/proc_test.mbt`),
`src/tools/shutdown.mbt`, `src/tools/shutdown_test.mbt`.

**New C FFI:** `int choir_list_pids_with_cwd_prefix(const char *prefix,
int *out_pids, int max)` — walks `/proc/*/cwd`, reads each symlink,
matches when:
- `target == prefix` (exact — cwd is the workspace itself), OR
- `target == prefix + " (deleted)"` (cwd was workspace, now deleted), OR
- `target` has prefix `prefix + "/"` (cwd is inside workspace), OR
- `target` has prefix `prefix + "/"` with ` (deleted)` suffix.

Writes matching PIDs into `out_pids`, returns the count (bounded by
`max`). Skip self-PID (don't nuke choir's own process if it happens to
have the matching cwd — unlikely but guard it).

**MoonBit wrapper:** `pub fn list_pids_with_cwd_prefix(prefix : String,
max : Int = 64) -> Array[Int]`.

**Wire-up in `interpret_kill_agent`:** after the worktree remove branch,
add:
```
let victims = @sys.list_pids_with_cwd_prefix(agent.workspace)
for pid in victims {
  @sys.kill_server_pid_sequence_best_effort(pid)  // SIGTERM, wait, SIGKILL
}
```
Log the kill count via `@moontrace.warn` for observability.

**Response:** if zellij close failed AND no victims were found, keep the
existing warning. If zellij close failed but victims WERE killed, change
the warning to note that fact (the tab may linger, but the process is
dead).

**Testing:**
- Unit test for the /proc helper isn't worth faking /proc in tests.
  Instead: test that `interpret_kill_agent` invokes the helper by using
  a spy runner and a fake workspace path, and that the kill call runs
  after pane-close + worktree-remove in the expected order.
- C-level smoke: spawn a brief subprocess in a known cwd (use `/tmp/<uuid>`),
  call `list_pids_with_cwd_prefix`, assert the PID is returned, then
  kill it. Run only in a new `kill_pids_integration_test.mbt` file
  gated to native + skipped in CI if `/proc` isn't present (CI runs
  Linux so this is fine).

### Leaf B — Slug collision across all registry states

**Files:** `src/tools/fork_wave.mbt`, `src/tools/fork_wave_test.mbt`.

**Change:** in `fork_wave_spawn_plan`, rewrite the `already_alive`
check (current lines 61-72) to `already_registered`:
```
let already_registered = match registry {
  Some(reg) => try { let _ = reg.get(agent_id); true } catch { _ => false }
  None => false
}
```
Keep the same skip/bump behavior (add to `skipped_ids`, increment
`skipped_count`, continue to next iteration of the for-loop — which
will try `wave-1`, `wave-2`, …).

**Rename `already_alive` → `already_registered`** to reflect the new
semantics.

**Testing:**
- Existing "skips active agents" test stays green.
- New test: "skips Failed agents after kill_agent" — seed the registry
  with `AgentState::Failed`, call `fork_wave_spawn_plan`, assert the
  slug bumped to `wave-1`.
- New test: "skips Completed agents" — same shape, with Completed.

## Decomposition

Two leaves, file-disjoint:
- **Leaf A:** `src/sys/*`, `src/tools/shutdown*.mbt`. Claude agent — C
  FFI + effects wiring benefits from careful reading of existing
  patterns.
- **Leaf B:** `src/tools/fork_wave*.mbt`. MoonPilot agent — small
  logic-only change, straightforward tests.

No shared files, no blocking dependency. Parallel.

## Verification

1. `moon test --target native` green on the feature branch after both
   leaves merge.
2. Existing shutdown and fork_wave tests remain green.
3. New tests: process-kill call order in `kill_agent`; collision-on-Failed
   bumps slug.
4. Post-merge manual verification: in a throwaway repo, fork a leaf,
   `kill_agent`, then `ps -ef | grep <agent_type>` should show no
   matching process with cwd under the worktree path. Re-run
   `fork_wave` with the same slug_prefix — new leaf gets a bumped slug,
   not the killed one's agent_id.

## Constraints

- CLAUDE.md Effect Architecture: the `/proc` scan is host I/O and belongs
  in `src/sys/`; `src/tools/shutdown.mbt` calls it through the existing
  injected runner pattern where possible, or as a direct `@sys.*` call
  matching the precedent already set by `pending_wave.mbt` and
  `wave_index.mbt` (both already call `@sys.*` from `src/tools/`).
- `ChoirError` over `String` for any new error paths.
- No shell-harness tests; use fakes/spies for the kill call ordering.

## Follow-Ups (not in this plan)

- Fix SIGHUP propagation through the `sh -lc` launch shell so zellij's
  close-tab reliably terminates the grandchild process. Out of scope.
- Proactive stale-worktree detection: a `choir doctor` command that
  scans the registry for `Failed` agents whose workspace paths have
  processes running, and reports them. Future enhancement.
- Strengthen `fork_wave` to also detect existing remote branches named
  `<parent_branch>.<slug>` even when the registry entry is gone —
  catches the case where a crashed choir server lost registry state
  but git branches survived.
