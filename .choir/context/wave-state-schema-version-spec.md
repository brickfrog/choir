# Spec: wave-state-schema-version

## Context
`choir-ptz` (make `wave_state` authoritative for TL orchestration reads) was
groomed down: its `(B)` data-field additions (`mergeable`, `merge_state_status`,
`merge_gate_ready`, …) already landed (ff3df70) and the tl.md "use wave_state for
steady-state reads" rule is in place. The ONE remaining deliverable is to
**schema-version the `wave_state` response** so a TL/client can detect a server it
is incompatible with — exactly what the sibling `status_bar_state` already does
(`StatusBarSnapshot.schema_version`, validated `== 2` on parse). `WaveStateSnapshot`
currently emits no version. Outcome: `wave_state`'s response carries a
`schema_version`, mirroring the `status_bar_state` precedent.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How far does this go (full discovery/audit of gh-git reads, or just the
remaining piece)?**
A: Just the remaining piece. The grooming note (2026-05-28) rescoped the bead: the
`(B)` wave_state fields and the tl.md rule already shipped; only "schema-version
the wave_state response" is unimplemented (`grep schema_version
src/tools/wave_state.mbt` is empty). This spec is ONLY that.

**Q: Producer-only field, or full field + from_json validation like
status_bar_state?**
A: Full mirror of `status_bar_state`: add `schema_version : Int` to
`WaveStateSnapshot`, emit it in `to_json`, AND add a `from_json` that validates the
version (rejects a mismatch), with round-trip + version-mismatch tests. The
from_json + tests are the legitimate consumer (a typed parse API with coverage,
same as status_bar_state) — not dead code. wave_state has no `from_json` today.

## Goals
- A version constant for the wave_state snapshot schema (e.g.
  `wave_state_schema_version = 1`), defined once.
- `WaveStateSnapshot` gains `schema_version : Int`; `plan_wave_state` /the snapshot
  constructor set it to the constant.
- `WaveStateSnapshot::to_json` emits `"schema_version"` (first key, like
  `status_bar_state`).
- A `WaveStateSnapshot::from_json` that parses the snapshot and FAILS on a missing
  or mismatched `schema_version` (mirror `StatusBarSnapshot::from_json`'s
  `expected schema_version` error), round-tripping the existing fields.
- The live `wave_state` tool response now includes `schema_version` at the top
  level (observable in the JSON the TL reads).

## Non-Goals
- No new `(B)` data fields, no new MCP tool, no gh/git-read audit (those parts of
  ptz already shipped or are out of scope).
- Do NOT expand `wave_state` into a kitchen sink — only the version field.
- No change to `status_bar_state` (the precedent) or its version.
- No change to `wave_state` request-arg parsing (`parse_wave_state_args`).
- No bump to any existing schema version; this introduces wave_state's first.

## Design
Single leaf, small. `src/tools/wave_state.mbt`:
- Add `let wave_state_schema_version : Int = 1` (or a `pub` const if a consumer
  needs it).
- Add `schema_version : Int` to `pub(all) struct WaveStateSnapshot`; set it in the
  snapshot constructor / `plan_wave_state` (`wave_state.mbt:318`).
- Extend `WaveStateSnapshot`'s `ToJson` to emit `"schema_version"` first.
- Add `WaveStateSnapshot::from_json` mirroring `StatusBarSnapshot::from_json`
  (`status_bar_state.mbt:381-427`): require `schema_version` present and ==
  `wave_state_schema_version`, else a descriptive error; parse `supervisor`,
  `children`, `taken_at_ms`, etc. (Reuse the existing per-field json helpers; add
  child/PR `from_json` only as needed to make the snapshot parse.)
- Update any wave_state test asserting the exact response JSON to include
  `schema_version`.

Reference pattern: `status_bar_state.mbt` `schema_version` (field at :32, emit at
:368, validate at :383-398). Follow it closely.

## Verify
- Unit: `WaveStateSnapshot::to_json` includes `"schema_version": 1`; `from_json`
  round-trips a valid snapshot; `from_json` on a payload with a wrong/absent
  `schema_version` returns the descriptive error (mirror the status_bar tests).
- Observable: a `wave_state` call's response JSON contains a top-level
  `schema_version` (e.g. the existing wave_state dispatch test asserts the key, or
  grep the emitted JSON in a test).
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Only `src/tools/wave_state.mbt` (+ its tests). Do not touch other tools,
  `status_bar_state`, the poller, or dispatch arg-parsing beyond what's needed to
  set/emit the field.
- Keep `wave_state` shaped for orchestration decisions — add the version field
  ONLY; no new data fields.
- `from_json` must REJECT a version mismatch (that's the whole point —
  detect an incompatible server), not silently coerce.
- Effect architecture: pure JSON (de)serialization; no `@sys`/`@process`.

## Follow-Ups
- If a typed Moonbit client of `wave_state` is ever added (today the consumer is
  the TL agent reading JSON), it uses the new `from_json` to reject an incompatible
  server — the field is in place for it.
