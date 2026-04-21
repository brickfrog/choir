# Pattern Library Spec

## Context

Choir's TL guide (`.choir/context/tl.md:63-96`) already endorses "reference
by analog" during spec crystallization — pointing leaves at an existing
function/file they should mirror. In practice this works well, but each TL
session has to rediscover the analog, and the reference is one-shot prose
embedded in a leaf spec.

Simon Willison's *Hoard things you know how to do* argues that working
examples become durable inputs for future agents. The Choir-shaped version
is a curated, in-repo library of short **pattern recipes** — one file per
recurring change shape — that a TL can cite by name (`"mirror pattern
add-mcp-tool"`) to replace a paragraph of behavior prose.

This is docs-only. No code or schema changes.

## Goals

1. Establish `.choir/context/patterns/` as the canonical home for pattern
   recipes, indexed by a short README.
2. Seed the library with 4 recipes drawn from work we've already shipped,
   so every pattern is backed by a concrete merged example rather than
   invented prose.
3. Wire the existing `reference by analog` guidance in `tl.md` to the new
   library so TLs naturally consult it during crystallization.
4. Encode a stale-guidance guardrail: each pattern cites specific
   functions/files so drift is visible and the pattern can be regenerated
   from the reference commit.

## Non-Goals

- **No new abstractions** — patterns are markdown files, not code.
- **No automated linter** — stale patterns are caught the same way stale
  comments are: by leaves reading them and TLs noticing mismatches. We
  already proved this works when Codex flagged `verify-fast.sh`.
- **No exhaustive coverage.** Four seed recipes. New patterns get added
  *after* a feature validates them, not speculatively.
- **Not a marketplace / plugin surface.** Purely internal guidance.
- **No changes to `fork_wave`, spec templates, or leaf prompts** beyond
  citing the library when an analog fits.

## Design

### Directory Layout

```
.choir/context/patterns/
├── README.md                        # index + meta-guide: when to add a pattern
├── add-mcp-tool.md                  # seed from report_usage (wave-telemetry)
├── add-cli-subcommand.md            # seed from `choir log` / `choir stats`
├── thread-enum-through-wire.md      # seed from AgentType wire roundtrip
└── synthesize-durable-dir.md        # seed from .choir/plugin/ synthesis
```

### Pattern File Format

Every pattern file follows the same short shape so a TL can cite it as
`mirror pattern <name>` and the leaf knows exactly where to look:

```markdown
# <pattern-name>

## When to use
One or two sentences. What change-shape does this pattern fit?

## Reference implementation
The concrete merged example:
- Primary file: `src/tools/report_usage.mbt`
- Tests: `src/tools/report_usage_test.mbt`
- Wire-up point: `src/server/handler_request.mbt:NNN` (dispatch arm)
- Shipped in: PR #NNN (commit shortsha)

## Steps (ordered, ~5-8)
1. …
2. …
3. …

## Gotchas
- Common mistake #1 (with reason).
- Common mistake #2 (with reason).

## Verification
The observable check that proves the pattern was followed correctly —
usually a `moon test --target native` filter + one behavioral probe.
```

The point is **brevity**. A pattern that balloons past one screen has
become a design doc and should move to `.choir/context/` proper.

### Seed Recipes — Scope Per File

1. **`add-mcp-tool.md`** — mirrors `report_usage`:
   - Add typed args struct in `src/tools/args.mbt`.
   - Implement handler in `src/tools/<name>.mbt` returning
     `Result[T, ChoirError]`.
   - Register in `src/server/handler_request.mbt` dispatch.
   - Add tool manifest entry (if surfaced via MCP).
   - Blackbox test in `src/tools/<name>_test.mbt`.
   - Gotchas: typed `ChoirError` not `String`, enum args not raw strings,
     effect-architecture — no direct `@sys.*` in `src/tools/` unless
     following the existing `wave_index.mbt` precedent.

2. **`add-cli-subcommand.md`** — mirrors `choir log` / `choir stats`:
   - Add arm in `src/bin/choir/main.mbt` subcmd match.
   - Implement `<name>_subcommand_run` in
     `src/bin/choir/<name>_subcommand.mbt`.
   - Argument parser returns `Result[<Cli>Args, ChoirError]`.
   - Exit codes + `@sys.exit` discipline.
   - Update usage string in `main.mbt` `_ =>` branch.
   - Gotchas: test placement (CLI arg parser tests go inline in source
     since the parser is private; rendering helpers go in blackbox tests).

3. **`thread-enum-through-wire.md`** — mirrors `AgentType`:
   - Define the enum in `src/types/` with `derive(Eq, Compare, Hash)`.
   - Add `to_wire_string` / `try_parse_wire` returning
     `Result[T, ChoirError]`.
   - Plumb through request/response types in `src/tools/args.mbt` and
     `src/mcp/`.
   - Parser rejects unknown-variant strings with `ChoirError::config_error`.
   - Blackbox roundtrip test.
   - Gotchas: `Unknown` sentinel variants must be rejected, not accepted.

4. **`synthesize-durable-dir.md`** — mirrors `.choir/plugin/`:
   - Embed content as `#|` multi-line string literals (see
     `src/workspace/command.mbt:147`).
   - Idempotent overwrite on each invocation (same input → same bytes).
   - Durable path (not tempdir) when content must outlive the current
     process.
   - `@sys.create_dir_all` + `@sys.write_file_sync` sequence.
   - Optional debuggability symlink via `@sys.symlink_force`.
   - Gotchas: never compute paths from `$PWD`; use `@sys.getcwd()` so
     absolute paths are stable under `cd`.

### README.md (Index)

- One-line summary per pattern with its "when to use" hook.
- Meta-guide: "How to add a new pattern" — requires a merged PR as the
  reference implementation; no speculative recipes.
- Link back to `tl.md` §Reference-by-analog for context.

### TL Guide Wiring

One small edit to `.choir/context/tl.md:63-96` §Reference-by-analog:

> **Reference by analog or pattern library.** Before writing a leaf task,
> check `.choir/context/patterns/README.md` for a named recipe that fits.
> If a pattern exists, cite it by name ("mirror pattern
> `add-mcp-tool`"). Otherwise, find a specific function/file analog as
> before. If neither exists, note it in the spec so the leaf knows it's
> greenfield.

No other existing doc changes.

## Decomposition

This is docs-only work with tight cross-file coherence (all recipes share
a format; the README indexes them). One leaf, Claude agent type, with the
full spec in hand. Decomposing into 2+ leaves would create merge friction
on the README without buying parallelism.

- **Leaf 1 (sole):** write all four pattern files, the README, and the
  one-paragraph edit to `tl.md`. Cites real source locations and real PR
  numbers. Verifies by grepping each cited file/function to confirm the
  anchor exists.

## Verification

1. **Grep check (leaf self-verify, pre-notify):** every `src/...` path and
   every function name cited in a pattern is resolvable:
   ```
   for each pattern file:
     extract `src/...` paths and function names
     assert each path exists; assert each function grep-hits
   ```
   If any anchor is stale at merge time, the pattern is wrong — fix or
   omit the anchor.

2. **`moon test --target native`** — must remain green. Docs changes
   should not touch code, but this guards against an accidental edit.

3. **Format consistency:** each pattern has all six sections (When to use,
   Reference implementation, Steps, Gotchas, Verification). No section
   over ~10 lines.

4. **Post-merge manual verification:** TL (next session) uses the library
   during a real crystallization — cites a pattern by name in a leaf
   spec — and the leaf understands the reference without needing
   additional context. This is the real acceptance test; it can't be
   automated.

## Open Pre-Build Notes

- The `add-mcp-tool` recipe will reference `report_usage` — confirm it
  actually captures the common shape, not an edge case. If `report_usage`
  turns out to be unusual (e.g., skipped registration steps), pick a
  different exemplar like `track_pr`.
- PR numbers for "Shipped in" anchors come from `git log --oneline main`
  scanning for the merge commit — the leaf does that lookup itself.

## Follow-Ups (not in this plan)

- Additional patterns as features validate them: `add-evidence-event`,
  `add-poller-handler`, `resolve-copilot-thread`, `add-hook-event`.
- If the library grows past ~15 entries, add category subdirectories
  (`patterns/tools/`, `patterns/cli/`, etc.) — not before.
- Consider a `choir doctor` check that scans pattern anchors for staleness
  and prints a report. Only worth building if manual drift-catching
  proves insufficient.
