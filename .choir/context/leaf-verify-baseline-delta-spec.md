# Spec: leaf-verify-baseline-delta

## Context
The leaf verify gate (TDD green-check and file_pr) runs the leaf's whole-repo
verify command inside the leaf's worktree and blocks on any non-zero exit. When
the fork-point baseline is already red (e.g. a wave whose whole purpose is fixing
N repo-wide failures: each leaf fixes one, every worktree still carries the other
N-1), each leaf's gate trips on failures it did not cause and cannot self-file.
Observed 3x in the moonbump-p3 wave; all leaves were forced onto Path B (TL files
via gh). We want a leaf blocked only by failures it *introduced* relative to its
fork-point baseline, not by the baseline's pre-existing red.

This spec covers the "too broad" half of choir-60dl (the baseline gate). The
"too narrow" half (the hermeticity lint missing from leaf verify) ships
separately as a quick leaf, see Non-Goals / Follow-Ups.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How to fix "too broad" (leaves blocked by an already-red baseline)?**
A: Per-command baseline gate. Record the fork-point sha; when a verify command
exits non-zero, re-run that same command against the baseline. A command that
was already RED at baseline is advisory (pre-existing, does not block the leaf);
only a command that was GREEN at baseline and is now RED blocks. Exit-code only,
no output parsing. Coarse (a new failure inside an already-red command slips past
the leaf gate) but the post-wave integration test is the backstop. Chosen over
the full failure-diff delta (fragile output-parsing) and over leaning on
verify_satisfied_by_ci (a red baseline makes CI red too, so CI can't distinguish
the delta either).

**Q: How much goes in this one effort?**
A: Ship the choir_lint "too narrow" fix first as its own quick single leaf
(independently correct, immediate CI-parity win); do this baseline gate as its
own spec/wave after. This spec is the baseline gate only.

**Q: Add choir_lint to the leaf verify for every leaf, in both gates?**
A: Yes, default-on in both gates, invoked via `moon run src/bin/choir_lint`
(which the verify normalizer leaves alone). That is the separately-shipped half;
this spec assumes it has landed.

## Goals
- The fork-point baseline sha (the commit leaves branch from: post-scaffold
  parent-branch HEAD, or parent HEAD when no scaffold) is recorded per wave at
  `fork_wave` time, alongside the existing `parent_branch` / `fork_ts_ms`.
- At both gates (`interpret_tdd_green_check`, `file_pr_run_required_verify`), a
  verify command that exits non-zero is re-run against the baseline; if it also
  fails at baseline it is **advisory** (logged, does not block); if it passed at
  baseline it **blocks** (the leaf introduced the regression).
- A wave on a red baseline can self-file (no Path B) as long as each leaf
  introduces no new command regression.
- The baseline re-run is **lazy**: it runs only when a leaf's verify command
  actually fails (most leaves pass and pay nothing).
- The advisory case emits a clear signal (e.g. `verify: <cmd> failed but was
  already red at baseline <sha> -> advisory, not blocking`) so the operator can
  see what was tolerated.

## Non-Goals
- Per-failure / structured parsing of `moon check` / `moon test` output. The gate
  is exit-code-only by decision; do not lift the 600/1200-char output truncation
  for diffing.
- The choir_lint "too narrow" fix (add the hermeticity lint to leaf verify). That
  ships first as a separate quick leaf (bead 60dl child); this spec assumes it.
- Mid-flight task-contract mutation (choir-35qw). The baseline is wave-level and
  recorded at spawn; do NOT add a contract mutator here.
- Scoped / per-module verify (collides with the module-blind normalizer,
  choir-praa). Separate.
- Changing `moon_verify_normalize_command` (choir-praa).

## Design
The verify command source is the per-leaf `TaskContract.verify : Array[String]`
(`src/types/domain.mbt:1017-1028`), read by both gates. Pass/fail is pure exit
code today, and full output IS captured (truncated) at both gates, so the gate
already has the command string and exit code it needs; the only new inputs are
the baseline sha and a baseline re-run.

### Leaf A — record the fork-point baseline sha on the wave
- `src/tools/effects.mbt` (fork_wave; it already captures a transient
  `pre_scaffold_sha` at :438): capture the sha leaves branch from (post-scaffold
  parent HEAD, or parent HEAD with no scaffold) and persist it.
- Wave record writer (`src/tools/pending_wave.mbt` / `src/tools/args.mbt:52`
  area; wave JSON `.choir/waves/<wave_id>.json` currently holds `parent_branch`,
  `fork_ts_ms`, `agent_ids`, ...): add `baseline_sha`.
- Expose a server-side lookup `baseline_sha_for_agent(agent_id)` (agent -> wave ->
  baseline_sha) for the gates, wired near `task_contract_for_agent`
  (`src/server/handler.mbt:~348`).

### Leaf B — shared baseline re-run helper (hermetic, injected)
- A pure-ish helper that, given (baseline_sha, command, project_dir, capture/
  worktree adapters), runs `command` against a throwaway checkout of
  `baseline_sha` and returns its exit code. Use `git worktree add <tmp>
  <baseline_sha>` -> run via the existing `sh -lc` capture -> `git worktree
  remove <tmp>`. ALL git/process calls go through injected adapters (no direct
  `@sys`/`@process` in `src/tools`); the temp worktree must be cleaned up on
  every path and must never touch the leaf worktree or main.
- Returns `BaselineOutcome::{ AlreadyRed, GreenAtBaseline, Unknown }`. `Unknown`
  (e.g. baseline_sha missing, checkout failed) falls back to today's behavior
  (block), never silently passes.

### Leaf C — wire the baseline gate into both verify paths
- TDD: `verify_tdd_command_outcome` / `interpret_tdd_green_check`
  (`src/tools/tdd_state.mbt:372-411, 662-704`). The TDD path joins commands with
  ` && ` into one `sh -lc`, so it sees one exit code for the whole script; to do
  per-command adjudication it must run the contract's verify commands
  individually here (like file_pr already does) so a single command's
  baseline-red status can be isolated. On a non-zero command, consult Leaf B; if
  AlreadyRed, treat as advisory.
- file_pr: `file_pr_run_required_verify` (`src/tools/file_pr.mbt:800-845`) already
  runs each command separately and short-circuits on first non-zero. On non-zero,
  consult Leaf B; if AlreadyRed, continue instead of erroring; record the advisory
  in the verify evidence event.

## Verify
- New unit/adapter tests with a mocked baseline-rerun adapter:
  - command red-at-baseline + red-at-head -> advisory, gate passes.
  - command green-at-baseline + red-at-head -> blocks (regression).
  - command green-at-head -> passes without any baseline re-run (laziness: assert
    the baseline adapter was NOT invoked).
  - baseline_sha missing / Unknown -> blocks (safe fallback).
- Observable: a scripted scenario (temp git repo, hermetic) where a baseline
  commit fails `cmdX`, a leaf that does not fix `cmdX` reaches file_pr, and the
  response/log shows `advisory, not blocking` for `cmdX` rather than a verify
  failure error. Grep the gate output for the advisory line.
- `moon test --target native` and `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Do not parse `moon` output into per-failure sets; exit-code-per-command only.
- Do not run the baseline re-run eagerly; only when a command fails.
- Do not add direct `@sys.*` / `@process.*` in `src/tools` gate logic; the
  baseline checkout + command run go through injected adapters (the gates already
  thread `capture`).
- Do not leave a temp worktree behind; remove it on every path. Never check out
  the baseline in the leaf's own worktree or in main.
- Do not mutate the write-once task contract; baseline_sha is wave-level.
- Do not change the normalizer or add scoped/per-module verify.
- `Unknown` baseline outcome must fall back to blocking, never silently pass.

## Follow-Ups
- choir-60dl "too narrow" half: add choir_lint to leaf verify (ships first, quick
  leaf).
- choir-praa: normalizer is module-blind (`moon -C hooks test` -> `--target
  native`); prerequisite for any scoped/per-module verify mitigation.
- choir-35qw: write-once contract / mid-flight verify swap; needed only if we
  later want per-leaf mid-flight verify narrowing.
- choir-dic7: `verify_satisfied_by_ci` per-leaf override semantics; adjacent.
- Full failure-diff delta (precise per-failure, catches regressions inside an
  already-red command at the leaf gate): revisit ONLY if the coarse per-command
  gate proves too lossy in practice. Do not pre-build.
