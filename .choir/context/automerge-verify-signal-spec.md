# Spec: automerge-verify-signal

## Context

`fork_wave(automerge, iterative)` leaf PRs never auto-merge: the merge-gate
evaluation cascade (`evaluation_cascade` in `src/types/domain.mbt`) requires a
`VerifyResultObserved` evidence record for every entry in `task_contract.verify`
whose `details` stamp the *current merge HEAD sha* (`verify_result_for_head` /
`verify_details_head_matches` in `src/evidence/evidence.mbt`). `file_pr` does run
and record the contract's verify commands — but it records them stamped against
the file_pr-time HEAD, and the moment Copilot review prompts a fix-push the HEAD
moves, so the recorded result goes stale → `NotObserved` → cascade returns
`NeedsHuman("local verify not observed: moon test --target native")`. Result: the
TL must do `choir tl-parent-override on` → `merge_pr force=true` →
`choir tl-parent-override off` on **every** leaf PR. Observable target: a healthy
`fork_wave(automerge, iterative)` leaf PR with green CI on its merge HEAD and zero
unresolved threads auto-merges with no TL override action.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: Which fix for the needs_human verify-stall should be the primary mechanism?**
A: CI-green-on-HEAD satisfies verify. When the merge-HEAD CI rollup is `Success`
and the wave declares that CI runs the verify commands, the evaluation cascade
treats `verify_required` as satisfied. CI re-runs on every fix-push, the poller
already records `CiObserved(status, head_sha)`, and a green CI run of the same
command on the same SHA is a strictly stronger signal than a leaf self-report.
Gated behind an explicit opt-in (next answer) so it is not a silent downgrade.

**Q: How is "CI runs the verify commands" declared (so accepting CI-green isn't a
silent skip)?**
A: A `task_contract` field `verify_satisfied_by_ci : Bool`, set by
`fork_wave`/`spawn`, **default `true`** for this repo (CI here *is*
`moon test --target native`). A caller can pass `verify_satisfied_by_ci=false`
to force the strict file_pr-record path. Per-wave granularity; lives with the
rest of the contract.

**Q: Should the leaf prompt / fork_wave flow ALSO be hardened to mandatorily emit
the verify signal (the choir-q4y direction)?**
A: No — gate-side only for this bead. Leaf-prompt hardening (mandatory terminal
verify-emit + re-emit on fix-push) stays in `choir-q4y` as a separate effort.
Keep this leaf small and focused.

## Goals

- `TaskContract` gains `verify_satisfied_by_ci : Bool` (default `true`;
  serializable; the `parse.mbt` task-contract parser fills it from tool args,
  absent ⇒ `true`). `fork_wave` and `spawn` write it into the contracts they
  emit. Existing serialized contracts that lack the field still load (absent ⇒
  `true` — use `Bool?` with `None ⇒ true` if derived `FromJson` can't tolerate a
  missing field; implementer's call).
- A new evidence-layer helper (sibling of `verify_results_for_required_at_head`
  in `src/evidence/evidence.mbt`) that, given the project dir, agent id, required
  verify commands, merge HEAD sha, and `verify_satisfied_by_ci`, upgrades any
  `NotObserved` result to `Passed` **iff** `verify_satisfied_by_ci` is true AND
  the latest `CiObserved` evidence record for that agent has `status == Success`
  and `head_sha == <merge HEAD sha>` (non-empty). The upgraded result's `details`
  read e.g. `satisfied by CI rollup success at <sha>`. A `Failed` result is never
  upgraded; a HEAD mismatch or non-success CI never upgrades; `head_sha == ""`
  never upgrades. The cascade ordering is otherwise untouched (failed-verify hard
  block, changes-requested, threads, CI-failing, then this).
- The three sites that build verify results for the gate —
  `merge_pr_verify_results_for_tracked` (`src/tools/merge_pr.mbt`),
  `handler_automerge.mbt`'s automerge eval, and `handler_poll_delivery.mbt`'s
  poller eval — call the new helper, passing the contract's
  `verify_satisfied_by_ci` (they already have `task_contract` and the head sha in
  scope).
- End-to-end: a `fork_wave(automerge, iterative)` leaf PR — contract verify =
  `["moon test --target native"]`, `verify_satisfied_by_ci = true` — that has a
  green merge-HEAD CI rollup, Copilot issue comment seen, and zero unresolved
  threads, reaches cascade verdict `Ready` and the server automerges it with **no
  TL `merge_pr force=true` / `tl-parent-override` action**. A fix-push after
  review (new HEAD) does not break this: CI re-runs, the poller re-records
  `CiObserved` at the new HEAD, the helper matches it, `Ready` again.
- Strict path preserved: with `verify_satisfied_by_ci = false`, behavior is
  exactly today's — only a file_pr-recorded `VerifyResultObserved` stamped at the
  merge HEAD satisfies verify; otherwise `NeedsHuman`.

## Non-Goals

- Leaf-prompt / spawn-prompt changes to make the leaf re-run + re-record verify
  on fix-push, or to make verify-emit as mandatory as `notify_parent`. That is
  `choir-q4y`.
- Re-running `moon test --target native` server-side on `FixesPushed`.
- Per-CI-job introspection (parsing which workflow/check ran which command). We
  trust the wave-level `verify_satisfied_by_ci` declaration, not a per-job map.
- Subsuming `tl-parent-override` into typed gates / removing the force-merge
  override entirely — that is `choir-kqv.8`. (This bead removes the *need* to use
  it on the happy path; it does not remove the mechanism.)
- Changing the `Blocked` vs `NeedsHuman` semantics for *failed* or genuinely
  *unobserved* verify (no CI green and no record ⇒ still `NeedsHuman`).
- Accepting a leaf's `notify_parent` verify *prose* as a signal (option (c) in
  `choir-8z1` — rejected).

## Design

**`src/types/domain.mbt`**
- Add `verify_satisfied_by_ci : Bool` to `pub(all) struct TaskContract` (keep
  `derive(Debug, Eq, ToJson, FromJson)`). If the derived `FromJson` rejects a
  missing field on replay of an older contract, make it `verify_satisfied_by_ci :
  Bool?` and treat `None` as `true` at every read site via one helper
  (`task_contract_verify_satisfied_by_ci(contract) -> Bool`). The `evaluation_cascade`
  function itself does **not** change — the CI-green upgrade happens before the
  cascade, at the verify-results-building layer (the cascade only ever sees
  `Passed`/`Failed`/`NotObserved`).

**`src/evidence/evidence.mbt`**
- Add `verify_results_for_required_at_head_with_ci(project_dir, agent_id,
  required, head_sha, verify_satisfied_by_ci) -> Array[VerifyCheckResult]`
  (name negotiable). Implementation: start from
  `verify_results_for_required_at_head(...)`; if `verify_satisfied_by_ci` and
  `head_sha != ""`, replay the agent's evidence records, find the latest
  `CiObserved`, and if `status == Success && head_sha == <merge HEAD>` map every
  `NotObserved` result → `{ ..r, status: Passed, details: "satisfied by CI
  rollup success at " + head_sha }`. Keep `verify_results_for_required_at_head`
  as-is (other callers / `verify_satisfied_by_ci=false` path use it, or call the
  new one with the flag false). Pure (filesystem-reads only via the existing
  `replay_agent_evidence_records` seam) — unit-testable with fixture `.jsonl`.

**`src/tools/merge_pr.mbt`** — `merge_pr_verify_results_for_tracked` (≈ line 307)
already takes `project_dir`, `tracked`, `task_contract`; switch its
`@evidence.verify_results_for_required_at_head(...)` call to the new helper,
passing the contract's `verify_satisfied_by_ci` (default-true via the helper).

**`src/server/handler_automerge.mbt`** (≈ line 239) and
**`src/server/handler_poll_delivery.mbt`** (≈ line 28) — same one-line switch;
both already have `task_contract` and a head sha in scope.

**`src/tools/parse.mbt`** — the task-contract arg parser (the
`task_contracts=[{...}]` / per-leaf contract path; see the test at
`parse.mbt:1978` asserting `parsed.task_contracts[0].verify`): read an optional
`verify_satisfied_by_ci` bool, default `true` when absent.

**`src/tools/fork_wave.mbt`, `src/tools/spawn.mbt`** (wherever the `TaskContract`
is constructed for spawned children) — populate `verify_satisfied_by_ci` (pass
through from args, default `true`).

**`src/mcp/translate.mbt`** — if `fork_wave`/`spawn_worker`/`spawn` advertise a
`verify` arg in their MCP schema, add an optional `verify_satisfied_by_ci`
boolean alongside it (default true) with a one-line desc.

No `@sys.*` / `@process.*` in `src/server` / `src/tools` — the evidence helper
uses the existing record-replay seam; everything else is pure data threading.

## Verify

- `moon test --target native` — unit tests for: `TaskContract` round-trips with
  and without `verify_satisfied_by_ci` (absent ⇒ true); the new evidence helper
  upgrades `NotObserved → Passed` only when CI-success + head-match + flag-true,
  and leaves `Failed`, head-mismatch, non-success CI, empty head, and flag-false
  cases unchanged; `evaluation_cascade` reaches `Ready` given the upgraded
  `Passed` results + green CI + copilot-seen + zero threads; `parse.mbt`
  task-contract parsing defaults the flag to true.
- Observable: with a temp `.choir/events/<agent>.jsonl` fixture containing
  `evidence.ci_observed` (status=success, head_sha=X) and *no*
  `evidence.verify_result_observed`, plus a contract `verify=["moon test --target
  native"]`, `verify_satisfied_by_ci=true`, head=X — drive the merge-readiness
  evaluation path (the same function `merge_pr` preflight uses) and assert the
  verdict is `Ready` / not `NeedsHuman("local verify not observed...")`. Flip
  `verify_satisfied_by_ci=false` (or head=Y≠X) and assert it goes back to
  `NeedsHuman`. (A pure-function test against the eval entrypoint is fine — no
  live server / live gh.)
- Manual smoke (post-merge, optional, document in PR): next `fork_wave(automerge,
  iterative)` wave — leaf PR with green CI + 0 threads auto-merges with no TL
  `merge_pr force=true`; `choir logs --grep "needs_human"` shows no
  "local verify not observed" line for that PR.

## Boundary (do not)

- Do not weaken the `Failed` verify path: an observed-and-failed verify command
  is always a hard `Blocked`, never upgraded by CI green.
- Do not accept CI green when `head_sha == ""` or when the latest `CiObserved`'s
  `head_sha` doesn't equal the merge HEAD — stale CI must not satisfy verify.
- Do not change `evaluation_cascade`'s ordering or the `Blocked` vs `NeedsHuman`
  split; the CI-green upgrade happens strictly upstream, in the verify-results
  builder.
- Default must be `verify_satisfied_by_ci = true` *for contracts this repo's
  `fork_wave`/`spawn` create*, and absent-in-JSON must read as `true` — but
  `verify_satisfied_by_ci=false` must reproduce today's exact strict behavior.
- No `@sys.*` / `@process.*` direct calls in `src/server` / `src/tools` / the
  evidence helper beyond the existing record-replay/file-read seam.
- Do not touch the leaf spawn prompt or `notify_parent` flow (that's `choir-q4y`).
- Do not remove or alter `tl-parent-override` / `merge_pr force=true` (that's
  `choir-kqv.8`).

## Follow-Ups

- `choir-q4y` — make the leaf's terminal sequence emit a structured verify-result
  (and re-emit after every fix-push) as mandatorily as `notify_parent`, so a wave
  with `verify_satisfied_by_ci=false` (or a repo whose CI doesn't run the verify
  commands) still auto-merges.
- `choir-kqv.8` — subsume `tl-parent-override` + `merge_pr force=true` into typed
  gates now that the happy path no longer needs them.
- Consider per-check CI introspection (map workflow/job → command) so
  `verify_satisfied_by_ci` could be derived rather than declared — only if the
  declaration proves error-prone in practice.
- If `.choir/config.toml` gains a repo-level settings block, a
  `ci_runs_verify`-style default for `verify_satisfied_by_ci` could live there.
