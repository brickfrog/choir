# Wave Telemetry: index + `choir log` + `choir stats`

Three features bundled on one feature branch, unified by a single new
piece of infrastructure: a stable `wave_id → [agent_id]` index persisted
under `.choir/waves/<wave_id>.json`. That index anchors wave replay,
cost tracking, and (eventually) resume.

## Goals

1. **Wave index scaffold.** Persist `.choir/waves/<wave_id>.json` at
   `fork_wave` time: `{wave_id, parent_branch, fork_ts_ms, agent_ids:
   [...], usage: {<agent_id>: {tokens_in, tokens_out, elapsed_s,
   cost_usd?}}}`. Thread `wave_id` through event/lifecycle payloads
   going forward. No backfill of in-flight or historical waves.
2. **`choir log --wave <wave_id>`.** Render a unified, timestamp-ordered
   timeline of every event across every agent in the wave.
3. **`choir stats`.** Roll up self-reported usage per wave and per
   agent_type. Leaves report via a new MCP tool `report_usage` called
   during shutdown (self-report only — no CLI-output parsing).

## Non-Goals

- **Resume / checkpoint across server restart** — deeper, separate
  feature. Needs per-agent MCP reconnect logic. Revisit after the
  telemetry features are felt in practice.
- **Backfill** of wave indexes for already-merged or in-flight waves.
  Index starts at the scaffold commit; earlier waves stay un-indexed.
- **Retroactive `wave_id`** on pre-scaffold lifecycle / evidence events.
  New events get the field; old events stay as-is.
- **CLI-output parsing** for token counts. Leaves self-report only. If
  a leaf forgets or crashes, its usage is absent (documented, not a
  bug).
- **Worker-from-leaf cost aggregation.** Workers' usage is logged under
  their own agent_id, not rolled up into the dev leaf. `choir stats`
  shows both flat.
- **Rescue de-duplication.** `rescue_leaf` mints a new agent_id; the
  old one's usage (if any was reported before rescue) and the new
  one's usage appear as separate line items. The old line item is
  marked `rescued → <new_id>` in the wave index.
- **Handling of killed / watchdog-killed leaves.** No graceful
  shutdown ⇒ no `report_usage` ⇒ no cost entry. `choir stats` flags
  missing rows as `<killed or crashed, no usage>`.

## Reference-by-analog

- **Wave index persistence** mirrors `pending_wave_kv_key` at
  `src/tools/pending_wave.mbt:16-18` — same KV-pattern, different prefix
  (`wave--<id>` vs `pending-wave--<id>`), but JSON body instead of the
  current shape.
- **`choir log` subcommand** mirrors `choir skill list` at
  `src/bin/choir/skill_subcommand.mbt:152` — read disk state, render to
  stdout, `--help` with example.
- **`choir stats` subcommand** mirrors `choir skill list` for the same
  reason.
- **`report_usage` tool handler** mirrors `notify_parent` at
  `src/tools/notify_parent.mbt` — typed args, simple dispatch,
  appends to KV.
- **Event schema extension with optional `wave_id`** mirrors the
  existing `parent_id?` and `branch?` optional fields in
  `src/phase/lifecycle_jsonl.mbt:17` — additive, backward-compat.

## Data model

### `.choir/waves/<wave_id>.json`

```json
{
  "wave_id": "wv-abc123",
  "parent_branch": "feature-wave-telemetry",
  "fork_ts_ms": 1776625500000,
  "agent_ids": [
    "feature-wave-telemetry.user-ext-audit-fix-0",
    "feature-wave-telemetry.user-ext-audit-fix-1"
  ],
  "rescued": {
    "feature-wave-telemetry.old-id": "feature-wave-telemetry.new-id"
  },
  "usage": {
    "feature-wave-telemetry.user-ext-audit-fix-0": {
      "agent_type": "codex",
      "tokens_in": 12500,
      "tokens_out": 3400,
      "elapsed_s": 420,
      "cost_usd": 0.18,
      "reported_at_ms": 1776625900000
    }
  }
}
```

- `agent_ids` is append-only for `depends_on` waves where members land
  over time.
- `rescued` maps old→new when `rescue_leaf` replaces a leaf mid-wave.
- `usage` is keyed by agent_id. Missing entries mean "no report filed"
  (killed / crashed / leaf forgot).

### Event schema extension

`src/evidence/evidence.mbt` event records and
`src/phase/lifecycle_jsonl.mbt` lifecycle transitions both gain an
optional `wave_id : String?` field. `None` for historical entries and
any code path not yet threaded through.

## User-facing CLI

```
choir log --wave <wave_id> [--format plain|json]
  Render timeline of all events across agents in the wave.
  --format defaults to plain.
  Errors if the wave_id has no index file.

choir log --help
  (usage + example)

choir stats
  Show per-wave rollups (most recent N waves, default 10) plus
  per-agent-type aggregate (tokens_in/out, elapsed_s, cost_usd).

choir stats --wave <wave_id>
  Show rollup for a single wave with per-agent breakdown.

choir stats --agent-type <type>
  Filter the aggregate view to one agent_type (gemini/claude/codex/etc.).

choir stats --help
  (usage + example)
```

Plain-format `choir log` sample:

```
wave wv-abc123 (feature-wave-telemetry, forked 2026-04-19 15:05:00)
members: user-ext-audit-fix-0 (codex), user-ext-audit-fix-1 (codex)

15:05:02  [audit-fix-0]  lifecycle: Dev(Red)
15:05:10  [audit-fix-1]  lifecycle: Dev(Red)
15:06:47  [audit-fix-0]  evidence: ci_observed(in_progress)
15:07:12  [audit-fix-0]  evidence: review_observed(commented)
15:07:13  [audit-fix-0]  lifecycle: Dev(ReviewOwned(Commented))
15:08:45  [audit-fix-0]  lifecycle: Dev(Done(Merged))
15:09:02  [audit-fix-1]  lifecycle: Dev(Done(Merged))
```

The sample is **illustrative**, not an exhaustive contract. Known event
types (`lifecycle.transition`, `evidence.ci_observed`,
`evidence.review_observed`) render cleanly as shown; any other event
type falls back to `<category>: <subtype> <json-dump>`. Extending
clean rendering to more subtypes is a follow-up, not a bug.

## MCP tool: `report_usage`

```
report_usage(
  caller_id: AgentId,
  tokens_in: Int,
  tokens_out: Int,
  elapsed_s: Int,
  cost_usd: Float?,
)
```

Server behavior:
1. Look up the caller's `wave_id` via the agent's config (written at
   fork time into `.choir/agents/<id>/config.local.toml` as a new
   optional `wave_id = "..."`).
2. If found, load `.choir/waves/<wave_id>.json`, set the
   `usage.<caller_id>` entry, write back atomically.
3. If no `wave_id` (user-invoked root TL or pre-scaffold agent),
   silently ignore — this is by design (TL itself is out of scope
   for wave cost).

Leaf responsibility: call `report_usage` during its shutdown path,
after final work but before the server teardown. The TDD protocol /
spawn prompt gets an explicit "call `report_usage` before
`notify_parent --status success`" instruction for new leaves.

**Cost calculation:** `cost_usd` is optional. If the leaf can compute
it (from provider API response), great. Otherwise, the server fills
it in from `config.toml`'s `[pricing.<agent_type>]` table on write
(lookup `tokens_in * rate_in + tokens_out * rate_out`, one-off per
write, no recomputation). Missing rate table = `cost_usd` stays
`None`, `choir stats` shows `—`.

## Behavioral contract

- **Idempotency:** writing the same `report_usage` twice overwrites
  the entry. No accumulation.
- **Atomicity:** wave index writes go via unique-suffix temp-file
  (`.tmp.<pid>-<nanos>`) + POSIX `rename(2)`. This is atomic against a
  concurrent reader — readers see either the old content or the new,
  never a truncated body — but it is **not** crash-safe across power
  loss: `write_file_sync` does not fsync the file or the directory
  before rename. If crash-durability is needed later, add fsync before
  rename and add a directory fsync after.
- **Concurrent forks:** if two waves are forked in parallel, each
  gets its own `.choir/waves/<wave_id>.json`. Wave-id collision
  safety is already handled by `allocate_pending_wave_id` at
  `src/tools/pending_wave.mbt:62-82`.
- **Missing event files:** `choir log` treats an absent
  `.choir/events/<agent_id>.jsonl` as empty and continues with other
  members.
- **Killed leaves:** `choir stats` surfaces `<no usage reported>` for
  missing entries; it does not infer.
- **Rescue:** fork_wave handler detects rescue and appends to the
  wave's `rescued` map + adds the new agent_id to `agent_ids`.
- **`report_usage` from a non-dev agent:** TL / Worker calls are
  accepted but no-op if the caller has no `wave_id`. Documented.

## Purity boundary

- **Pure core** (testable with fixture bytes):
  - `parse_wave_index_json(s: String) -> Result[WaveIndex, ChoirError]`
  - `render_wave_index_json(idx: WaveIndex) -> String`
  - `interleave_events(all: Array[Event]) -> Array[Event]` (stable
    sort by `ts_ms`, ties broken by agent_id)
  - `format_log_plain(idx: WaveIndex, events: Array[Event]) -> String`
  - `rollup_stats(waves: Array[WaveIndex]) -> StatsRollup`
- **Effectful shell** (injected adapters / called from subcommand
  runners):
  - `wave_index_path(project_dir, wave_id) -> String`
  - `load_wave_index(project_dir, wave_id) -> Result[WaveIndex, ChoirError]`
  - `save_wave_index(project_dir, idx) -> Result[Unit, ChoirError]`
  - `list_wave_ids(project_dir) -> Array[String]`
  - `read_agent_events(project_dir, agent_id) -> Array[Event]`

## Files

### New

- `src/tools/wave_index.mbt` — `WaveIndex` struct, persistence, readers,
  `append_agent_id`, `record_usage`, `record_rescue`, blackbox tests
  for parse / render / schema.
- `src/bin/choir/log_subcommand.mbt` — `log_subcommand_run()`, event
  interleave, plain + json renderers, per-subcommand `--help`.
- `src/bin/choir/log_subcommand_test.mbt` — blackbox tests for pure
  interleave + format.
- `src/bin/choir/stats_subcommand.mbt` — `stats_subcommand_run()`,
  per-wave + per-agent-type rollup, `--help`.
- `src/bin/choir/stats_subcommand_test.mbt` — blackbox rollup tests.
- `src/tools/report_usage.mbt` — MCP tool implementation.

### Modified

- `src/tools/fork_wave.mbt` — at spawn time, allocate + persist wave
  index file, thread `wave_id` into each spawned agent's config.
  Call `append_agent_id` for `depends_on` late-binding waves.
- `src/tools/rescue_leaf.mbt` — call `wave_index.record_rescue` on
  successful rescue.
- `src/evidence/evidence.mbt` — add optional `wave_id : String?` to
  event schema. Renderers handle `None`.
- `src/phase/lifecycle_jsonl.mbt` — add optional `wave_id` to
  lifecycle transition entries.
- `src/bin/choir/main.mbt` — add `"log"` and `"stats"` dispatch arms.
  Update usage string.
- `src/bin/choir/moon.pkg` — register new native files.
- `src/types/config.mbt` (or wherever the `Config` struct lives) —
  add optional `[pricing.<agent_type>]` table for cost computation.
- Tool registry / MCP schema — register `report_usage`.

## Tests

### Pure-core blackbox (`*_test.mbt` siblings)

- `parse_wave_index_json`: valid, malformed JSON, missing required
  fields, unknown-key tolerance (for forward-compat).
- `render_wave_index_json` + round-trip through `parse`.
- `interleave_events`: stable ordering, ties broken consistently,
  empty input, single agent.
- `format_log_plain`: snapshot of a canonical wave → expected text.
- `rollup_stats`: sum across multiple waves, filter by agent_type,
  missing usage entries (counted as zero? or explicit gap?).

### Whitebox inline

- `wave_index_path` returns expected filesystem layout.
- `save_wave_index` atomic-rename semantics (idempotent on rerun).
- `record_rescue` updates the map correctly.

### Integration-ish (hermetic, tmpdir)

- `log_subcommand_run` against a seeded fixture wave + synthetic
  event files in `/tmp/choir-log-test-.../`.
- `stats_subcommand_run` with multiple fake wave files → expected
  rollup.

## Observable verify (per tl.md Spec Hygiene)

**Leaf verify array must use the built binary with temp project
dirs and HOME overrides. Do NOT run `choir init` or `choir claude` —
those spawn zellij and recurse.**

Per feature:

- **Scaffold:** set up a fake wave index file in a temp project dir,
  `cd <tmp> && ./_build/native/release/build/src/bin/choir/choir.exe log --wave wv-demo` → expected output.
- **Leaf A (log):** seed two fake agent event files + a wave index,
  invoke `choir log --wave <id>`, grep for interleaved timestamps.
- **Leaf B (stats):** seed a wave index with usage entries, invoke
  `choir stats --wave <id>`, grep for expected tokens/cost row.

## Decomposition

**Feature branch:** `feature-wave-telemetry`.

**Scaffold commit (TL, pre-fork):**
- Create `src/tools/wave_index.mbt` with struct + persistence +
  readers + `append_agent_id` + blackbox tests.
- Add `wave_id : String?` to lifecycle + evidence event schemas
  (optional, `None` default).
- Wire wave-index persistence into `fork_wave` spawn flow:
  persist `.choir/waves/<wave_id>.json` at spawn completion; write
  `wave_id` into each spawned agent's `config.local.toml`.
- Wire `record_rescue` into `rescue_leaf`.
- Stub `"log"` and `"stats"` and `report_usage` handlers (print
  "not implemented", exit 1).
- Register them in `main.mbt` dispatch + tool registry.

Scaffold = compilation firewall. Both leaves compile against the
same `wave_index.mbt` API.

**Wave 1 (parallel leaves, `parent_branch=feature-wave-telemetry`,
`automerge=true`):**

- **Leaf A — replay (`choir log`)** (agent_type=codex):
  - Implement `log_subcommand_run` + `interleave_events` +
    `format_log_plain` + `format_log_json`.
  - Tests per the "Tests" section (log-specific).
  - Observable verify: fixture wave + events → rendered timeline.
  - **Does NOT touch** `stats_subcommand.mbt`, `report_usage.mbt`,
    `wave_index.mbt` writers.

- **Leaf B — cost (`choir stats` + `report_usage`)**
  (agent_type=codex):
  - Implement `report_usage` MCP tool handler (calls
    `wave_index.record_usage`).
  - Implement `stats_subcommand_run` + `rollup_stats` renderers.
  - Add optional `[pricing.<agent_type>]` to config with one
    sample agent_type entry for tests.
  - Tests per the "Tests" section (stats-specific).
  - Observable verify: seeded wave index with usage → `choir stats`
    shows the expected row.
  - **Does NOT touch** `log_subcommand.mbt`,
    `wave_index.mbt` readers.

Leaves are file-disjoint except `wave_index.mbt` — Leaf A only adds
readers, Leaf B only adds `record_usage` (which goes in the scaffold
if feasible; otherwise Leaf B adds it and Leaf A is designed to
compile against the scaffolded reader surface). Scaffold should
include the `record_usage` signature as a stub (returns
`Err(not_implemented)`) so Leaf B replaces the body only.

**Post-wave:**

1. `/audit` — Sarcasmotron on `main...feature-wave-telemetry`. Expect
   findings on missing event cases, rescue handling, and the self-
   report trust assumption.
2. Address must-fix findings via a follow-up wave.
3. `gh pr create --base main --head feature-wave-telemetry`. User
   merges manually.

## Post-merge user verification

(Outside leaf scope — documented here so the manual test is
discoverable.)

- Fork a trivial test wave, let it run, verify
  `.choir/waves/<wave_id>.json` exists with both agent_ids.
- Confirm each leaf's lifecycle events have `wave_id` populated.
- Run `choir log --wave <id>` → see the interleaved timeline.
- Confirm each leaf called `report_usage` (visible in the wave
  index `usage` map).
- Run `choir stats` → per-wave rollup plus per-agent-type
  aggregate for the last N waves.

## Open items for leaves to resolve

- **Spawn-prompt update for `report_usage`:** the leaf spawn prompt
  (in `src/tools/fork_wave.mbt` or wherever the prompt template
  lives) should instruct leaves to call `report_usage` before
  `notify_parent --status success`. Leaf B owns the prompt edit if
  this isn't already done in the scaffold.
- **`--format json` for `choir log`:** minimum shape is one event per
  line, `{ts_ms, agent_id, type, data}`. Leaf A picks whether to
  support streaming-JSON-lines or a single JSON array. Prefer lines
  for consistency with the existing `.jsonl` event files.
- **`choir stats` default "most recent N":** N=10 default, overridable
  via `--limit`. Leaf B picks whether to sort by fork_ts_ms desc.
