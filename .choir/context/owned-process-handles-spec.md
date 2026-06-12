# Spec: owned-process-handles

## Context

`kill_agent` and the startup reaper find victim processes by scanning the
entire `/proc` table — `/proc/*/cwd` symlinks matched against the agent's
worktree path, and `/proc/*/stat`+`/proc/*/cmdline` grepped for
`choir mcp-stdio`. This is guess-by-forensics: false positives (any process
that `cd`s into a worktree gets SIGKILLed — a guard in `shutdown.mbt` exists
solely to stop an empty workspace from killing the whole host) and false
negatives (an agent that `cd`s out of its worktree escapes). The owned
handles that make scanning unnecessary already exist: every spawn wraps the
CLI in `setsid bash` and writes the process-group ID to
`.choir/pids/<sanitized-agent-id>` (`src/workspace/launch.mbt:80–98`), and
the mcp-stdio shim sets `PR_SET_PDEATHSIG=SIGTERM` at startup
(`src/bin/choir/mcp_mode.mbt:643`) so it dies with its parent. The
server-side disconnect path already kills the tracked pgroup
(`src/server/handler_disconnect.mbt:245`). This feature wires `kill_agent`
to the pgroup handle and deletes all `/proc` table scanning.

## Clarifications

> Derived from the user's directive ("fix this") endorsing the
> owned-process-handle design over the `/proc` fallback, plus repo rules.

**Q: Keep the `/proc` cwd scan as a belt-and-suspenders fallback when the
pidfile is missing?**
A: No. Delete it outright. The cwd scan was added by
`kill-robustness-spec.md` *before* the setsid+pidfile wrapper existed; it is
now a redundant, less-correct mechanism (per the "no dead code" rule and
"gates must not satisfy themselves" philosophy — give the killer a handle,
don't teach it forensics). If the pidfile is missing, `kill_agent` still
closes the pane and removes the worktree, and attaches a warning that no
process handle was found. Agents that joined via bare `register` (arbitrary
workspace, never spawned by us) were never ours to kill — not killing their
host processes is correct, and is strictly safer than the old behavior of
SIGKILLing whatever happened to cd there.

**Q: Should the mcp-stdio shim report its PID at registration so the server
can kill it directly?**
A: No — that would be dead plumbing. The shim is a descendant of the
setsid'd pgroup (pgroup kill covers it) and sets PDEATHSIG (parent death
covers it). With the cmdline grep deleted, a reported shim PID would have no
consumer. Do not add it.

**Q: What replaces the startup orphan-shim reaper
(`init_reap_orphan_mcp_stdio_bridges`)?**
A: Nothing. Orphan shims (ppid==1) can no longer accumulate: PDEATHSIG
terminates the shim when its parent dies. The reaper existed to clean up
orphans created before PDEATHSIG was added; a fleet restart clears any
historical stragglers. Delete the reaper and the whole process-table-scan
machinery it rests on.

**Q: Is `kill(-pgid)` safe across server restarts / PID reuse?**
A: Same risk profile as the existing, already-shipped
`kill_tracked_agent_pgroup` disconnect path, which reads the same pidfile.
We are not adding new exposure; pidfiles are deleted on kill/forget, which
bounds staleness. PID-reuse hardening (e.g. recording process start time) is
a follow-up, not in scope.

**Q: Existing analog to pattern-match?**
A: Yes — mirror `kill_server_pid_sequence_best_effort`
(`src/sys/io.mbt:309`, C helper `c_init_kill_server_pid_sequence` in
`src/sys/stub.c`) for the new pgroup TERM→pause→KILL sequence, and the
injected-capability seam already present in `interpret_kill_agent`
(`list_pids?`/`kill_pid?` optional params with `@sys.*` defaults).

## Goals

- `interpret_kill_agent` terminates the agent via its recorded process
  group: read pgid from `.choir/pids/<sanitized-agent-id>` (path helper
  `agent_pid_file_path`, `src/workspace/launch.mbt:56`), send SIGTERM to the
  pgroup, brief pause, SIGKILL the pgroup, then delete the pidfile.
- All `/proc` process-table scanning is deleted from the codebase:
  `list_pids_with_cwd_prefix` (+ C helper `c_list_pids_with_cwd_prefix` and
  the 1024 hard cap), `list_orphan_choir_mcp_stdio_pids`,
  `list_choir_mcp_stdio_pids_for_agent`, `read_proc_process_table_entries`,
  `process_table_ppid_from_proc_stat`,
  `orphan_choir_mcp_stdio_pids_from_processes`,
  `choir_mcp_stdio_pids_for_agent_from_processes`,
  `process_cmdline_has_token`, `init_reap_orphan_mcp_stdio_bridges`, and the
  `ProcessTableEntry` type if nothing else uses it — including stub.c
  bodies, `io_stub.mbt` stubs, and their tests.
- `/proc/self/exe` (reload path) is untouched — it is not a table scan.
- `kill_agent`'s response still distinguishes "pane close failed but process
  group killed" from "pane close failed and no process handle found".
- `moon test --target native` green; all surviving shutdown/disconnect tests
  green.

## Non-Goals

- No shim-PID registration field (dead plumbing — see Clarifications).
- No startup sweep of stale `.choir/pids` entries (follow-up).
- No PID-reuse hardening (start-time stamps in pidfiles) — follow-up.
- No change to the zellij pane-close or worktree-remove steps in
  `kill_agent`; their ordering stays pane-close → worktree-remove → pgroup
  kill.
- No change to the server-side disconnect pgroup kill
  (`handler_disconnect.mbt`) beyond what compiles.
- No change to `wrap_with_setsid_and_pgroup_cleanup` or the pidfile format.
- No Windows/macOS support; choir is Linux-only.

## Design

Single leaf — the deletions and the wiring touch the same files
(`src/sys/io.mbt`, `src/sys/stub.c`, `src/tools/shutdown.mbt`), so splitting
would manufacture merge conflicts.

### src/sys (capability)

- Add `kill_pgid_sequence_best_effort(pgid : Int) -> Unit`: SIGTERM the
  process group, ~300ms pause, SIGKILL. Mirror the existing
  `c_init_kill_server_pid_sequence` C helper but signal `-pgid`; reuse the
  guard style of `kill_pgid_best_effort` (`src/sys/io.mbt:303`) — reject
  pgid <= 1.
- Delete the scanning functions/types listed in Goals from `io.mbt`,
  `process_table.mbt`, `io_stub.mbt`, and their C bodies in `stub.c`.
- Keep `write_pid_file`, `kill_pgid_best_effort`,
  `kill_server_pid_sequence_best_effort`, `pid_is_alive`,
  `set_parent_death_signal_term` — all still used.

### src/tools/shutdown.mbt (kill path)

- Replace the `list_pids?` and `list_mcp_stdio_pids?` injected params with:
  - `read_agent_pgid? : (String) -> Int?` — default reads and parses
    `.choir/pids/<sanitized-agent-id>` under `project_dir` (read-only
    `@sys.read_file` at the tool dispatch seam is permitted per CLAUDE.md).
  - `kill_pgid? : (Int) -> Unit = @sys.kill_pgid_sequence_best_effort`.
  - `remove_pid_file? : (String) -> Unit` — default deletes the pidfile
    after the kill (mirror how `forget_agent_pid` cleans up in
    `src/server/state.mbt:454–479`).
- Delete the `shutdown_safe_choir_worktree_path` gating of the scan; keep
  that predicate only if the worktree-remove step still uses it, otherwise
  delete it too.
- Keep ordering: pane close → worktree remove → pgroup kill → pidfile
  delete → registry `Failed` → beads mirror.
- Warning text: if pane close failed and a pgid was found+killed, say the
  tab may linger but the process group was killed; if pane close failed and
  no pidfile existed, say the process may survive.

### src/bin/choir/init.mbt

- Delete `init_reap_orphan_mcp_stdio_bridges` and its call from
  `init_cleanup_recreate_artifacts` (line ~197), plus its tests.

### Tests

- Update `src/tools/shutdown_test.mbt`: spy `read_agent_pgid`/`kill_pgid`/
  `remove_pid_file`; assert kill order (pane close, worktree remove, pgroup
  kill), assert pidfile delete after kill, assert no-pidfile path attaches
  the right warning and kills nothing.
- Delete tests for the removed scanners in `src/sys/process_table.mbt`
  (inline tests) and any `io_test.mbt` coverage of
  `list_pids_with_cwd_prefix`.
- One hermetic native test for `kill_pgid_sequence_best_effort`: spawn
  `setsid sleep 30` in `/tmp`, kill its pgroup, assert it is gone
  (`pid_is_alive` false). Tightly scoped, no repo-state mutation, mirrors
  the precedent in `handler_disconnect_native_wbtest.mbt`. Whitebox vs
  blackbox placement per CLAUDE.md Test Placement rules.

## Verify

- `moon test --target native` — green.
- `! grep -rn "list_pids_with_cwd_prefix\|mcp_stdio_pids\|read_proc_process_table_entries\|process_table_ppid_from_proc_stat\|ProcessTableEntry" src/` — scanning machinery fully gone.
- `! grep -rn "choir_list_pids_with_cwd_prefix" src/sys/stub.c` — C body gone.
- Observable: `setsid bash -c 'echo $$ > /tmp/choir-pgid-test; sleep 60' & sleep 0.2; pgid=$(cat /tmp/choir-pgid-test)` then exercise the new kill sequence via the hermetic native test (`moon test --target native -p sys -f <test file>`) and confirm the sleeper is dead (`! ps -o pid= -$pgid`). The leaf should script the equivalent inside the native test rather than as a shell harness.

## Boundary (do not)

- Do not keep any `/proc` table scan "as a fallback" — deletion is the
  point. `/proc/self/exe` and targeted `kill(pid, 0)` liveness checks are
  fine; iterating `/proc` entries is not.
- Do not add a shim-PID registration field or any other new wire-protocol
  field.
- Do not touch `src/server/handler_disconnect.mbt`'s pgroup-kill logic,
  `wrap_with_setsid_and_pgroup_cleanup`, the pidfile path/format, or the
  server reload (`/proc/self/exe`) path.
- Do not call `@sys.*` mutations directly from `src/tools/` — new
  capabilities go through injected params with defaults (read-only
  `@sys.read_file` at the dispatch seam is the only allowed direct call).
- Do not add shell-harness tests, temp git repos, or tests that mutate repo
  state; the single process-integration test stays in `/tmp` and is
  hermetic.
- Do not signal pgid 0, 1, or negative inputs from the new sequence helper.
- `moon test --target native` is the verification target, never bare
  `moon test`.

## Follow-Ups

- Startup sweep of stale `.choir/pids` entries (kill pgroup + remove file
  for agents in terminal states) — replaces the last recovery gap without
  scanning.
- PID-reuse hardening: record process start time alongside the pgid and
  verify before signaling.
- Update the TL prompt hint at `src/prompts/loader.mbt:430` ("check
  /proc/<pid>/cwd if leaf goes silent") — still valid for diagnosis, but
  could point at `.choir/pids` instead.
- `choir doctor` check: report registered-but-dead agents whose pidfile
  still exists.
