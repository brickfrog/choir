# Spec: native-ffi-hermeticity-lint

## Context
The hermetic-test invariant has a known parallel hole (choir-6fu8, found by the choir-yi0h re-audit). The `CHOIR_TEST_NO_EXEC` tripwire is `src/exec/`-scoped and only fires on the `exec.run` path; `choir_lint` only flags `@process.*` / `capture_*` / `@exec.*`. But a real-I/O FFI surface bypasses both: `@sys.git_fetch_origin_branch_best_effort_native` (a real NETWORK fetch), the worktree bootstrap-cleanup / seed-gitexclude natives (real FS mutation), and `init_cleanup_*_native` (real FS mutation) — plus their `@workspace.run_native_*` wrappers — are reachable DIRECTLY with no tripwire and no lint rule. Today nothing outside the sanctioned seam calls them in a leaking way (suite green), but the invariant has a real gap: a test or an orchestration-layer file could call one and do real network/FS I/O undetected. We want `choir_lint` to flag those hazardous natives when called from outside the sanctioned composition-root seam, so the hole is closed statically like the rest of the I/O surface.

## Clarifications
> Spec-audit (codex) corrected the original draft on two make-or-break points: choir_lint is AST-based (not textual), and a blunt "all *_native" rule would turn CI red. Findings folded below. TL-decided scoping; redirect any.

**Q [AUDIT-CORRECTED] (lint mechanism): how does choir_lint actually work?**
A: It is AST-based, not a textual scan. The CLI recursively collects `.mbt` files under `src` (skipping `target`/`.mooncakes`/`.git`/`.choir`), reads each, and calls `@lint.lint_source(file, source)` (`src/bin/choir_lint/main.mbt:2-18,23-33,42-60`). `lint_source` parses with moonbitlang/parser and visits the AST, resolving package aliases from `moon.pkg` (`src/lint/lint.mbt:2037-2057,1410-1447,1635-1725`). Existing rules identify package-qualified refs via AST + alias resolution (e.g. detecting `@ex.run` when `ex` aliases `src/exec`), and express exemptions as ad-hoc code-level allowlists (path special-cases like `src/lint/lint.mbt:339-357`, test-name allowances `:1224-1278`, exact-key allowlists `:1125-1220`). So the new rule MUST be an AST-based rule added in `src/lint/lint.mbt` using the same parser/alias machinery and a code-level allowlist — NOT a substring scan. Inline `test` blocks are already distinguishable from impls (`TopTest`, `:1421-1444`), so the rule can treat inline tests like test files.

**Q [AUDIT-CORRECTED] (scope — which symbols): the whole `*_native` family, or a subset?**
A: A SUBSET — the natives that do real network / FS-mutation I/O and bypass the tripwire (the bead's actual concern). FLAGGED set:
- `@sys.git_fetch_origin_branch_best_effort_native` (network)
- `@sys.worktree_bootstrap_cleanup_native` (FS mutation)
- `@sys.worktree_seed_agent_runtime_gitexclude_native` (FS mutation)
- `@sys.init_cleanup_runtime_artifacts_native`, `@sys.init_cleanup_purge_artifacts_native` (FS mutation)
- their wrappers: `@workspace.run_native_git_fetch_origin_branch_best_effort_command`, `@workspace.run_native_worktree_bootstrap_cleanup_command`, `@workspace.run_native_worktree_seed_agent_runtime_gitexclude_command`
EXCLUDED: `@sys.realpath_native` — read-only path resolution (stat-like), used legitimately as an injected default across `src/exec` and `src/bin` (`exec_native.mbt:34`, `claude_wrapper.mbt:417,456`, `uds_server.mbt:2226`, `exec_test.mbt:117`); it is not a real-exec/network/mutation hazard, and flagging it would turn CI red. EXCLUDED: the `run_native_agy_*` / `run_native_leaf_helpers_*` / `*_with_io` wrappers — they take injected I/O and/or are `/tmp`-isolated (the `_with_io` helpers are hermetic), and `workspace_test.mbt` exercises them legitimately (`:2086-2636`); they are not in the hazard set. (Rationale recorded so a future implementer does not assume `_native` suffix == hazard.)

**Q [AUDIT-CORRECTED] (allowlist — stays green?): where are the flagged symbols legitimately called today?**
A: Census (verified by the audit): the flagged hazard symbols are called only from `src/sys/**` (definitions), `src/workspace/command.mbt` (the `run_native_*` wrappers calling the `@sys.*_native`), `src/exec/**` (the interpreter dispatching wrappers), and `src/bin/**` (composition root — `init.mbt:373,563`, `runtime_commands.mbt:25,27`, `uds_server.mbt:3752` call `init_cleanup_*_native` at real startup/teardown, which is legitimate production I/O). So the ALLOWLIST (exempt) is: `src/sys/**`, `src/workspace/command.mbt`, `src/exec/**`, `src/bin/**`. With `realpath_native` excluded and `bin/**` exempt, this allowlist exactly covers today's legitimate call sites → the rule stays GREEN on the current tree. The spec-audit must re-confirm no flagged symbol is called from `src/server`, `src/tools`, `src/poller`, `src/phase`, `src/runtime`, or any test today (census found none).

**Q (what gets flagged): which callers fail the rule?**
A: Any reference to a flagged symbol from outside the allowlist — i.e. from `src/server`, `src/tools`, `src/poller`, `src/phase`, `src/runtime`, OR any `_test.mbt` file OR any inline `test` block (even inside an allowlisted source file — use `TopTest` detection so an inline test in `command.mbt` calling a flagged native is still caught; the effect-arch/hermeticity invariant binds tests regardless of file).

**Q (rule id + message): how does it report?**
A: A new `rule_id` `native-ffi-bypass`, emitted in the existing `file:loc: rule_id: message` shape (`src/bin/choir_lint/main.mbt:38`, exits 1 on findings `:49-60`, and CI runs it `.github/workflows/ci.yml:57-60`). Message: the call does real network/FS I/O that bypasses the `CHOIR_TEST_NO_EXEC` tripwire; route through `exec.run` / the sanctioned `run_native_*` wrapper instead.

## Goals
- A new AST-based `choir_lint` rule (`src/lint/lint.mbt`, using parser + package-alias resolution + a code-level allowlist, mirroring existing rules) that flags the FLAGGED hazard-native set referenced from outside the allowlist (`src/sys/**`, `src/workspace/command.mbt`, `src/exec/**`, `src/bin/**`).
- The rule fires on `_test.mbt` files and inline `test` blocks (`TopTest`), including inline tests inside otherwise-allowlisted source files.
- `moon run src/bin/choir_lint --target native` stays GREEN on the current tree (allowlist + excluded `realpath_native` exactly cover today's legitimate sites).
- New `rule_id` `native-ffi-bypass`; emitted in the existing finding format; fails CI on any hit.
- A self-test proving the catch: a flagged symbol called from a non-allowlisted path → finding; from an allowlisted path → none; from an inline test → finding.

## Non-Goals
- No runtime NO_EXEC tripwire on the natives (defense-in-depth follow-up; `src/sys` ← `src/exec` layering wrinkle).
- No flagging of `realpath_native` (read-only) or the injected/`/tmp`-isolated `run_native_agy_*` / `_with_io` wrappers.
- No change to the `*_native` / `run_native_*` functions, `exec.run`, the tripwire, or any existing test (the scoping is chosen specifically to avoid migrating `workspace_test.mbt`).
- No general direct-FFI policy for other `extern "C"` surfaces (`@sys.system`, `@sys.rm_rf`, `@sys.write_file_sync`, etc.) — named as a separate concern, out of scope.
- No refactor of choir_lint's architecture — add one rule in the existing style.

## Design
- **Rule** (`src/lint/lint.mbt`): add an AST visitor rule that resolves the package alias for `src/sys` and `src/workspace` in the file under lint, and reports a `native-ffi-bypass` finding when a call expression references one of the FLAGGED symbols AND the current file/impl is not in the allowlist. Reuse the existing alias-resolution helpers (`:1635-1725`) and the `TopTest` distinction (`:1421-1444`) so inline tests are covered. Encode the FLAGGED symbol set and the allowlist (`src/sys/**`, `src/workspace/command.mbt`, `src/exec/**`, `src/bin/**`) as code-level constants next to the existing allowlists.
- **Allowlist style**: mirror how current rules exempt their seam (path-prefix / exact-path special cases, `:339-357`); do not invent a divergent mechanism.
- **Self-test** (`src/lint/lint_test.mbt`): call `pub lint_source(file, source, read_file?, path_exists?, package_alias_cache?)` (`:2037-2057`) with synthetic PARSEABLE MoonBit snippets + a chosen `file` path and injected alias cache — assert a `native-ffi-bypass` finding for a non-allowlisted path, none for an allowlisted path, and a finding for an inline-test snippet. (Snippets must parse; not arbitrary line text. No real-tree scan, mirroring `lint_test.mbt:308-361`.)
- Confirm enforcement: `choir_lint` is in the verify set (`config_schema.mbt:195-200`) and CI (`.github/workflows/ci.yml:57-60`), and `main` exits 1 on findings (`main.mbt:49-60`).

## Verify
- `moon run src/bin/choir_lint --target native` — GREEN on the current tree (the key observable: no false positives; allowlist + `realpath_native` exclusion match existing sites).
- `moon test --target native` — the rule's self-test: flagged symbol from non-allowlisted path → `native-ffi-bypass` finding; allowlisted path → none; inline-test snippet → finding.
- Observable manual check (document in PR, do NOT commit): adding `@sys.git_fetch_origin_branch_best_effort_native(...)` to a scratch line in `src/tools/` makes `choir_lint` report `native-ffi-bypass` at that line; removing it returns to green.
- `moon check --target native` — clean.

## Boundary (do not)
- Do NOT implement this as a substring/textual scan — it is an AST rule using parser + package-alias resolution, like the existing rules.
- Do NOT flag `realpath_native` or the injected/`_with_io`/agy wrappers — only the FLAGGED hazard set.
- Do NOT allowlist `src/server`, `src/tools`, `src/poller`, `src/phase`, `src/runtime`, or any `_test.mbt` / inline test — those are the surfaces the rule must guard (inline tests in allowlisted files included, via `TopTest`).
- Do NOT modify the `*_native` / `run_native_*` functions, `exec.run`, the tripwire, or any existing test/`workspace_test.mbt` (scoping is chosen to avoid that).
- Do NOT add a divergent lint mechanism or a new finding format — reuse `rule_id`/emit/exit.
- Keep the self-test pure (parseable synthetic source via `lint_source`, injected adapters); no real-tree scan, no exec, no git-state fixtures.
- The lint must stay GREEN on the current tree — if it goes red, the allowlist/scope is wrong (fix it) or a real leak was found (fix the leak / surface to TL), never blanket-suppress.

## Follow-Ups
- Runtime NO_EXEC tripwire on the real-I/O natives (defense-in-depth), resolving the `src/sys` ← `src/exec` layering (low-level env check usable from `src/sys`, or a guard at the wrapper layer).
- Consider including `realpath_native` once its injected-default call sites are confirmed test-safe, or a deny-by-default-all-natives policy with an explicit per-symbol seam allowlist (broader than this bead).
- General direct-FFI policy for other real-I/O `@sys.*` wrappers without the `_native` suffix (`system`, `rm_rf`, `write_file_sync`, `exec_native.mbt` replace-self) — `_native` suffix != FFI/hazard coverage.
