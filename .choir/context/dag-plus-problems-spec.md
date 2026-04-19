# Feature Spec: DAG Waves + PROBLEMS.md

Two related capabilities shipping on one feature branch.

## Goals

1. **PROBLEMS.md auto-include.** A living tribal-knowledge file at
   `.choir/context/problems.md` that `fork_wave` prepends to every leaf's
   `read_first` automatically. Lets the TL capture "don't do X, we tried that
   and it broke" once, and have every future leaf see it without being told.

2. **Dependency-aware waves.** `fork_wave` accepts `depends_on: ["<agent-id>", ...]`.
   When present, the wave is queued — its leaves are not spawned until every
   named dep's PR is merged. Lets the TL lay out a multi-wave DAG up front and
   step away.

## Non-Goals

- No cross-wave coordination beyond PR-merged signals (nothing fancier than
  "wait for upstream to merge").
- No retry/backoff of failed deps; a failed dep fails the downstream wave, TL
  decides what to do.
- No UI/TUI dashboard; statusline gets a tiny pending-count indicator only.
- No changes to the leaf spawn protocol beyond what's needed for `read_first`
  auto-include and deferred spawn.
- Feature 2 first, Feature 1 second. Two separate waves on this feature branch.

---

## Feature 2 — PROBLEMS.md auto-include

**First wave. Small. 1 leaf. `automerge=true`.**

### Scope
- Create `.choir/context/problems.md` seeded with the section structure:
  ```
  # Choir PROBLEMS.md

  Living list of known footguns. Every leaf reads this before starting.

  ## <YYYY-MM-DD> — <short title>
  **Rule:** ...
  **Why:** (incident / past PR link / commit sha)
  **How to apply:** ...
  ```
  Include one real starter entry drawn from session memory, e.g. the
  "gemini CLI crashes on long prompts" lesson from PR #237's wave.
- Modify `fork_wave`'s read_first builder (in `src/tools/fork_wave.mbt` or
  the shared spawn-prompt path) to unconditionally prepend
  `.choir/context/problems.md` to the leaf's `read_first` list if the file
  exists. Deduplicate — if the TL already named the file, don't include
  twice.
- Add an inline test asserting the behavior: given a fork_wave spec with
  `read_first=["src/foo.mbt"]` and a present `problems.md`, the resulting
  leaf prompt's read_first contains both, `problems.md` first.

### Non-goals for Feature 2
- No `/problem` skill. Not yet — keep this wave tight. Can add a
  `/problem` skill in a follow-up once the mechanism is proven.
- No server-side subcommand to append entries. TL edits the file directly
  for now.

### Done criteria
- `.choir/context/problems.md` exists with the section structure + one
  starter entry.
- `fork_wave` auto-prepends it when present.
- Inline test covers both the "file exists, auto-include" and "file
  missing, behavior unchanged" cases.
- `moon fmt`, `moon build --target native --release`, `moon test --target native` all green.

---

## Feature 1 — Dependency-aware waves

**Second wave. Larger. Fork after Feature 2 merges onto this feature branch.**

### Scope

**New argument: `depends_on`**
- `fork_wave_args` gains `depends_on: Array[String]` (parsed from a JSON
  array string to match the existing `tasks` pattern).
- Validation: every entry must match an existing leaf agent_id in KV state.
  Unknown IDs → immediate `ChoirError::config_error`.

**Pending-wave storage**
- Serialize the full `fork_wave_args` + a generated wave id into
  `.choir/kv/pending-wave--<wave-id>`.
- Atomic write via existing `write_file_atomic` helper.

**Spawn trigger**
- After `merge_pr` succeeds, the server scans `.choir/kv/pending-wave--*`.
- For each pending wave: look up each dep's latest lifecycle state.
  - If all deps are in a terminal "merged" state (derive from existing
    lifecycle fields; new state not required), spawn the wave and delete
    the pending entry.
  - If any dep is `Failed` / killed / abandoned, mark the pending wave
    failed: delete the pending entry, write a `.choir/kv/failed-wave--<id>`
    marker with reason, and `notify_parent` a `[DEP FAILED]` message.
  - Otherwise, leave pending.

**Kill semantics**
- `kill_agent` on a pending wave id: delete the pending entry, no spawn.
- `kill_agent` on a dep whose pending wave exists: triggers the failed-dep
  path above.

**Statusline**
- If any pending waves exist, append `⧗N` (dim blue) to the leaf-counts
  section of the statusline. Reuse existing `statusline_kv_files_with_prefix`.

### Done criteria
- `fork_wave(depends_on=[...])` accepts the arg and stores a pending entry.
- After merge_pr of the last dep, the pending wave auto-spawns with the
  stored args.
- Failed deps propagate to failed-wave marker + TL notification.
- `⧗N` renders in statusline when pendings exist.
- `kill_agent` on pending id cleans up without spawning.
- Inline tests cover: arg parsing, pending serialize/deserialize, spawn
  trigger after dep merge, failed-dep propagation.
- `moon fmt` / build / test all green.

---

## Workflow reminder
- Feature 2 forks first. `parent_branch=feature/dag-plus-problems`,
  `automerge=true`, 1 leaf.
- After Feature 2's PR lands on the feature branch, fork Feature 1 with
  2–3 leaves (probably split: args-parsing+storage / server spawn-trigger /
  statusline+tests).
- Once both features are merged onto `feature/dag-plus-problems`, invoke
  `/audit` for a Sarcasmotron pass against the full diff vs main.
- Address findings, then open a PR to main with `gh pr create --base main
  --head feature/dag-plus-problems`. User merges manually.

## Boundary (applies to every leaf)
- Use `moon test --target native`, never bare.
- `ChoirError` over `String` for new error paths.
- Enums over stringly values.
- Tests inline, no `_test.mbt` siblings for these changes.
- No shell-harness tests.
- No dead code / compat shims.
- Resolve every Copilot inline review thread via GraphQL
  `resolveReviewThread` before `notify_parent`.
