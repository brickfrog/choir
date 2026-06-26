# Spec: worktree-dep-provisioning

## Context
choir leaves run in fresh git worktrees that lack gitignored, externally-sourced build/dependency artifacts (node_modules, rust `target/`, python `.venv`, etc.). Today each leaf IMPROVISES provisioning ("No node_modules — let me install…"), which: (1) wastes recompute/refetch per worktree; (2) re-executes arbitrary install/build scripts (npm postinstall, cargo `build.rs`) once per worktree, unsandboxed under `--dangerously-skip-permissions` with no gate; (3) risks the WRONG toolchain (a leaf running `npm` in a bun/cargo project → lost script-blocking + lockfile mismatch). We want a controlled, declared, ecosystem-agnostic provisioning step choir runs at worktree creation, so leaves never improvise dependency provisioning. (Surfaced from dere/Node+bun; generalizes to rust etc.)

## Clarifications
> The user originated the cache-vs-output + per-path-strategy framing. The spec was then adversarially audited against the code (12 findings); the audit changed two of the user's original calls on hard correctness grounds — flagged below as [AUDIT-REVISED] for redirect.

**Q (the central model — cache vs output): what actually gets provisioned?**
A: Two distinct layers. (a) The **global content-addressed CACHE** (bun store, `~/.cargo/registry`, npm/pip caches) is per-user/global and safe to share — leaves inherit it via ambient `HOME`/env. (b) The **per-worktree OUTPUT** (`node_modules`, `target/`, `.venv`) is what choir provisions, via a declared per-path strategy. Provisioning targets (b); it relies on (a) being shared.

**Q [AUDIT-REVISED] (cache sharing is NOT universal): is the inherited-HOME premise true for all leaves?**
A: Only for the agent types we actually run. `shared_env_pairs` inherits ambient `HOME` for Codex/Claude/MoonPilot/Cursor (caches shared ✓), but explicitly sets `HOME=<worktree>/.choir/agy-home` for Gemini and Unknown (`src/workspace/spawn.mbt:134-137`; asserted in `workspace_test.mbt:1844-1880`), which get a worktree-local HOME plus the separate agy cache-link mechanism. So the "caches already shared" claim holds for our default agents; for Gemini/Unknown a `command`-strategy provision (e.g. `bun install`) would refetch into the agy-home cache. Document this; do NOT promise universal cache sharing.

**Q [AUDIT-REVISED] (per-path strategy + the concurrency constraint): how is each output path provisioned, and is `symlink node_modules` safe?**
A: A declared strategy per path: `symlink`, `copy`, or `command`. The original spec recommended `symlink node_modules` — the audit shows that is **concurrency-unsafe**: leaves run with skip-permissions and v1 does not block leaf-side installs, so N worktrees symlinked to ONE root `node_modules` means any leaf install/repair/postinstall/native-rebuild mutates the shared dir for all siblings (and the root). REVISED strategy semantics:
- `symlink` — ONLY for truly immutable, never-written artifacts. NOT for `node_modules`/`target`/`.venv`/`dist`/`build`. (Symlink-node_modules becomes safe only after the leaf-install guard lands → v2 follow-up.)
- `copy` — reflink/`cp -a --reflink=auto` for dirs a leaf may mutate (the safe default for `node_modules`: each leaf gets its own copy, no cross-leaf corruption, still far cheaper than a from-scratch reinstall — no network, no postinstall re-run).
- `command` — run a declared setup command once in the worktree (e.g. `bun install`/`cargo fetch`).
HARD RULE: never `symlink`-share a concurrency-unsafe build/output dir. choir does NOT guess strategy — the project DECLARES per path — but choir DOES validate the declaration (next Q).

**Q [AUDIT-ADDED] (validation): does choir reject unsafe declarations?**
A: Yes — a pure validation phase before any command is emitted. Reject (typed `ChoirError`): empty path, absolute path, or `..` in path (mirror `validate_workspace_rel_path`, `src/workspace/command.mbt:113-120`). Reject `strategy=symlink` on a denylist of known-mutable dirs (`node_modules`, `target`, `dist`, `build`, `.venv`, `.tox`, `.pytest_cache`). Invalid config fails the spawn loudly (before launch), not silently. This makes the HARD RULE a choir guarantee, not just prose.

**Q (default when no config): does choir change behavior for un-configured projects?**
A: No. No provisioning config → status quo (leaf behaves as today). Explicit opt-in per project; NO magic auto-detect (wrong-guess risk). Ship recommended example configs per ecosystem in docs. `Config::default()` carries an empty provision array (cf. `prenotify_checks: []`).

**Q [AUDIT-REVISED] (config schema shape): how is the array-of-structs expressed?**
A: NOT as a TOML `[[worktree_provision]]` array-table — the config layer is a flat `Map[String,String]` (`src/config/toml.mbt:2-4`) that cannot parse array-tables or inline tables. Instead a single JSON-string field `worktree_provision_json`, parsed via `@json.parse` into `Array[ProvisionEntry]` — exactly the existing `companions_json` precedent. `ProvisionEntry = { path : String, strategy : ProvisionStrategy, command : String? }`; `ProvisionStrategy` is an ENUM (`Symlink | Copy | Command`). Missing/empty → empty array → status quo. `command` required when `strategy=Command`, else typed error.

**Q [AUDIT-REVISED] (hook point): when/where does provisioning run?**
A: At worktree creation, in the ordered command list assembled by `spawn_commands`/`build_spawn_commands` in **`src/workspace/spawn.mbt`** (NOT `src/workspace/git.mbt`, which only defines the `git_worktree_add` builder). Insert the provisioning Commands in the Worktree-isolation branch AFTER `command_seed_worktree_agent_runtime_gitexclude(workspace)` and BEFORE `write_worktree_config_toml(...)` (`spawn.mbt:700-773`), so they run before the zellij launch command. Pure command-builders emit the Commands; execution is at the interpreter seam (`RunCommands` via the injected runner, `src/tools/effects.mbt:163-180`).

**Q [AUDIT-ADDED] (failure semantics): what if a provision command fails?**
A: Native `run_sequence` stops on the first nonzero exit (`src/exec/exec_native.mbt:1481-1488`), so a failed provision command ABORTS the launch before the leaf starts — fail loud is correct here. Spawn-failure cleanup already removes a failed worktree (`src/tools/spawn.mbt:972-978`). Document that provisioning failure blocks the leaf by design.

**Q [AUDIT-ADDED] (worktree reuse + idempotency): what about reused worktrees?**
A: Worktree reuse deliberately skips destructive bootstrap (`git_worktree_add`, gitexclude seed) and starts the command list at config writes (`spawn.mbt:700-716`). v1: re-run provisioning idempotently on reuse too — `symlink` uses `ln -sfn` (replaces), `copy` does `rm -rf <dest> && cp -a` (replaces), `command` re-runs. This keeps a reused worktree consistent with the current declaration and clears stale provisioned paths from an older config.

**Q [AUDIT-ADDED] (missing source): what if the root source path doesn't exist (root has no node_modules yet)?**
A: For `symlink`/`copy`, validate the source `<root>/<path>` exists before emitting the command; if absent, fail the spawn loudly (a dangling symlink or a copy of nothing silently defeats the feature). `command` has no source requirement.

**Q [AUDIT-ADDED] (command strategy precise form): shell or argv?**
A: `command` is shell text run as `Command { program: "sh", args: ["-lc", <command>], workdir: Some(<worktree>) }` (cf. `prenotify.mbt:35`, `baseline_verify.mbt:105-106`), inheriting the launch environment. Injection surface is the project's own config (project-controlled, same trust level as the rest of `.choir/config`). Note it can run package-manager scripts — that is the project's explicit choice, narrower than today's per-leaf improvisation.

## Goals
- A declared per-project config field `worktree_provision_json` (JSON string → `Array[ProvisionEntry]{ path, strategy: Symlink|Copy|Command, command? }`, typed `ProvisionStrategy` enum), ecosystem-agnostic.
- A pure validation phase: reject empty/absolute/`..` paths and `symlink` on known-mutable build dirs (typed `ChoirError`); invalid config fails the spawn before launch.
- A pure command-builder that, given valid entries, emits `Array[Command]` inserted in `spawn_commands` (after gitexclude seed, before config write) so the leaf inherits provisioned deps and never improvises an install.
- `symlink` → immutable artifacts only; `copy` (reflink) → mutable dirs incl. the `node_modules` safe default; `command` → ecosystems needing a setup step. Never symlink-share a concurrency-unsafe build dir (validated).
- Missing-source fails loudly; reuse re-provisions idempotently; provision-command failure aborts launch.
- No-config projects: unchanged behavior (empty array, zero commands).
- Net: fewer per-worktree recomputes, fewer per-worktree untrusted script executions, no wrong-toolchain improvisation — without cross-leaf corruption.

## Non-Goals
- No auto-detection / magic provisioning (explicit config only).
- No blocking/forbidding leaf-side installs in v1 (guard is a follow-up; until it exists, `symlink node_modules` stays disallowed).
- No symlink-sharing of mutable build/output dirs (validated-rejected).
- No new TOML array-table parser — JSON-string field only.
- Not solving runtime malicious-dependency execution (lockfile integrity is the project's responsibility).
- Not a package manager / not vendoring deps into the repo.
- No universal cache-sharing guarantee (Gemini/Unknown get worktree-local HOME).

## Design
- **Types** (`src/types/`): `ProvisionStrategy` enum (`Symlink | Copy | Command`, derive Eq/Debug/ToJson/FromJson); `ProvisionEntry` struct `{ path : String, strategy : ProvisionStrategy, command : String? }`. Add `worktree_provision : Array[ProvisionEntry]` to `Config` with `Config::default()` → `[]`.
- **Config parse** (`src/config/config.mbt`): read `worktree_provision_json` string key, `@json.parse` → `Array[ProvisionEntry]` (mirror `companions_json`); empty/missing → `[]`. Add the field to `config_divergence` (`:861-957`) and any default-parse tests.
- **Validation** (pure, `src/workspace/`): `validate_provision_entries(entries) -> Result[Unit, ChoirError]` — clean relative path (reuse/mirror `validate_workspace_rel_path`), `command` present iff `strategy=Command`, `symlink` not on the mutable-dir denylist. Unit-testable, no I/O.
- **Command builder** (pure, `src/workspace/`): `provision_commands(root, worktree, entries) -> Array[Command]`. Per entry:
  - `Symlink` → `ln -sfn <root>/<path> <worktree>/<path>` (workdir worktree); guarded by source-exists check.
  - `Copy` → `sh -lc "rm -rf <worktree>/<path> && cp -a --reflink=auto <root>/<path> <worktree>/<path>"` (workdir worktree); source-exists guard. (Linux/GNU coreutils per repo platform; if a native copy sentinel is preferred over `cp`, add `native_worktree_provision_copy_program` interpreted in `src/exec` — implementer's call, but keep it a Command either way.)
  - `Command` → `sh -lc <command>` workdir worktree.
- **Hook** (`src/workspace/spawn.mbt`): in the Worktree branch of `spawn_commands`, after `command_seed_worktree_agent_runtime_gitexclude(workspace)` and before `write_worktree_config_toml(...)`, append `provision_commands(...)`. Reuse branch: also append (idempotent builders). Validation runs first; a validation error aborts plan construction (typed error surfaced to the caller).
- **Caches:** confirm no HOME isolation for Codex/Claude/MoonPilot/Cursor (true today); document the Gemini/Unknown worktree-local-HOME exception.
- **Effect-arch:** builders return `Array[Command]`; no `@sys.*`/`@process.*` in the builder or in `src/tools/` beyond the existing config-read seam; execution at the interpreter.

## Verify
- `moon test --target native`:
  - Config parse: a `worktree_provision_json` with one entry per strategy parses to the typed array; missing `command` on `Command` strategy → typed error; absent field → `[]`.
  - Validation: absolute path / `..` / empty → error; `symlink` on `node_modules`/`target` → error; valid mixed entries → ok.
  - Builder (pure, observable — grep the built command list): a `copy node_modules` entry emits the `cp -a --reflink=auto …/node_modules …` command; a `symlink <immutable>` entry emits `ln -sfn …`; a `command "bun install"` entry emits `sh -lc bun install` with worktree workdir; no-config → zero provisioning commands appended to the spawn list.
  - Hook ordering: in the assembled `spawn_commands` list, provisioning commands appear after the gitexclude seed and before the config write (assert by index, like `workspace_test.mbt:1434-1488`).
- `moon run src/bin/choir_lint --target native` — clean.
- Hermetic: pure builder/validation/parse tests asserting command shapes and typed errors; NO real worktree/filesystem mutation, no temp-git fixtures, no persisted git state.

## Boundary (do not)
- Preserve effect-architecture: pure command-builders return `Commands`; execution at the interpreter; typed `ProvisionStrategy` enum + typed `ChoirError` (no stringly strategy, no `Result[_,String]`).
- Do NOT `symlink` a mutable/build-output dir — `symlink` is immutable-artifacts-only and validated against a denylist; `node_modules` default is `copy`.
- Do NOT add TOML array-table parsing — JSON-string field via `@json.parse` only.
- Do NOT put the hook in `src/workspace/git.mbt`; it goes in `spawn_commands` (`src/workspace/spawn.mbt`) after the gitexclude seed, before config write.
- No-config → NO behavior change (status quo); do not auto-provision un-configured projects.
- Do NOT silently create dangling symlinks / empty copies — missing source fails the spawn.
- Do not block/intercept leaf-side installs (v1).
- Do NOT promise universal cache sharing — Gemini/Unknown have worktree-local HOME.
- Hermetic tests only — no real worktree/filesystem mutation beyond a dedicated temp area; no persisting git state in fixtures.

## Follow-Ups
- Guard/lint: when provisioning is declared, warn or prevent a leaf improvising its own install (the wrong-toolchain catch). Once this exists, `symlink node_modules` becomes safe → re-enable it as a strategy for node_modules (the original v1 intent, deferred for safety).
- Auto-append provisioned paths to worktree `.git/info/exclude` (next to the gitexclude seed) so a declared, not-already-ignored path doesn't dirty the worktree.
- Recommended per-ecosystem example configs (node/bun: copy node_modules; rust: `cargo fetch` + fresh target via command; python: `.venv` copy; moonbit) — in docs and `choir:onboard`.
- `choir:onboard` could scaffold a provision config for the detected ecosystem.
- Native copy/symlink sentinel programs in `src/exec` if the `sh -lc`/`cp`/`ln` argv form proves fragile or non-portable.
- Lockfile-integrity guidance (orthogonal supply-chain hardening).
