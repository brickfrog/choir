# Spec: worktree-dep-provisioning

## Context
choir leaves run in fresh git worktrees that lack gitignored, externally-sourced build/dependency artifacts (node_modules, rust `target/`, python `.venv`, etc.). Today each leaf IMPROVISES provisioning ("No node_modules — let me install…"), which: (1) wastes recompute/refetch per worktree; (2) re-executes arbitrary install/build scripts (npm postinstall, cargo `build.rs`) once per worktree, unsandboxed under `--dangerously-skip-permissions` with no gate; (3) risks the WRONG toolchain (a leaf running `npm` in a bun/cargo project → lost script-blocking + lockfile mismatch). We want a controlled, declared, ecosystem-agnostic provisioning step choir runs at worktree creation, so leaves never improvise dependency provisioning. (Surfaced from dere/Node+bun; generalizes to rust etc.)

## Clarifications
> TL-decided defaults on the design forks (the user originated the cache-vs-output + concurrency framing); flagged for redirect. Goal hook directed momentum.

**Q (the central model — cache vs output): what actually gets provisioned?**
A: Two distinct layers. (a) The **global content-addressed CACHE** (bun store, `~/.cargo/registry`, npm/pip caches) is already per-user/global and safe to share — leaves inherit it via HOME/env; choir must simply NOT isolate it (vetted-once fetch, fast). (b) The **per-worktree OUTPUT** (`node_modules`, `target/`, `.venv`) is what choir provisions, via a declared per-path strategy. Provisioning targets (b); it relies on (a) being shared.

**Q (per-path strategy + the concurrency constraint): how is each output path provisioned?**
A: A declared strategy per path: `symlink` (point the worktree path at the root checkout's — for read-mostly dirs like `node_modules`), `copy` (reflink/cp — for dirs a leaf may mutate), or `command` (run a setup command once, e.g. `bun install`/`cargo fetch`). HARD RULE: never `symlink`-share a build-output dir the toolchain locks/writes concurrently (cargo `target/` — concurrent leaves would corrupt it); those use `copy` or a fresh `command`. choir does NOT guess strategy — the project DECLARES per path.

**Q (default when no config): does choir change behavior for un-configured projects?**
A: No. No provisioning config → status quo (leaf behaves as today). Explicit opt-in per project; NO magic auto-detect (wrong-guess risk). Ship recommended example configs per ecosystem in docs.

**Q (hook point): when does provisioning run?**
A: At worktree creation — right after `git_worktree_add` (`src/workspace/git.mbt`), alongside the existing gitexclude-seed step, BEFORE the leaf's claude process starts. Pure command-builders emit the provisioning Commands; execution happens at the interpretation seam (effect-arch).

**Q (block leaf-side installs?): does this forbid a leaf from running its own install?**
A: Not in v1. Provisioning makes leaf-side install unnecessary; a guard/lint that prevents leaves improvising installs when provisioning is declared is a follow-up (can't cleanly intercept a leaf's Bash today).

## Goals
- A declared `.choir` config (per-project, ecosystem-agnostic): an array of provisioning entries `{ path, strategy: symlink|copy|command, command? }`.
- choir applies it at worktree creation (after `git_worktree_add`), so the leaf inherits provisioned deps and never improvises an install.
- `symlink` for safe read-mostly dirs (node_modules); `copy` for dirs a leaf mutates; `command` for ecosystems needing a setup step — never symlink-share a concurrency-unsafe build dir.
- Safe global caches remain shared (not isolated) → vetted-once, fast fetches.
- No-config projects: unchanged behavior (explicit opt-in).
- Net: fewer per-worktree recomputes, fewer per-worktree untrusted script executions, no wrong-toolchain improvisation.

## Non-Goals
- No auto-detection / magic provisioning (explicit config only).
- No blocking/forbidding leaf-side installs in v1 (guard is a follow-up).
- No symlink-sharing of concurrency-unsafe mutable build dirs (cargo `target/`).
- Not solving runtime malicious-dependency execution (lockfile integrity is the project's responsibility; orthogonal to install frequency).
- Not a package manager / not vendoring deps into the repo.

## Design
- **Config schema:** extend `.choir` config (`src/types/config_schema.mbt` + parse in `src/config/config.mbt`, reusing the `parse_string_array_config_value`/overlay helpers) with a typed `worktree_provision` array of `{ path : String, strategy : ProvisionStrategy, command : String? }`; `ProvisionStrategy` is an ENUM (`Symlink | Copy | Command`), not a string.
- **Hook point:** in the worktree-seed path (`src/workspace/git.mbt`, near `git_worktree_add` + `command_seed_worktree_agent_runtime_gitexclude`), a pure builder emits provisioning Commands per declared entry: `symlink` → link `<root>/<path>` → `<worktree>/<path>`; `copy` → reflink/cp -r; `command` → run the declared command in the worktree cwd. Commands are returned (pure); executed at the interpretation seam.
- **Caches:** confirm the leaf env does not isolate HOME/cache dirs (so bun store / `~/.cargo` / npm cache are inherited). Document if any isolation exists.
- **Ordering:** provisioning runs after worktree add + gitexclude seed, before the leaf launch command.

## Verify
- `moon test --target native` — config parse of the provision array (each strategy variant; missing-command on `command` strategy → typed error); the worktree-seed builder emits the correct Command per strategy; no-config → zero provisioning commands; `symlink`/`copy` build the expected link/copy command shapes.
- Observable: a hermetic builder test asserting that, given a declared `symlink node_modules` entry, the generated worktree-setup commands include the node_modules symlink (grep the built command list); given a `command` entry, include that command.
- `moon run src/bin/choir_lint --target native` — clean.

## Boundary (do not)
- Preserve effect-architecture: pure command-builders return Commands; execution at the interpretation seam; typed `ProvisionStrategy` enum, typed config (no stringly strategy).
- NEVER symlink-share a concurrency-unsafe build dir by default (cargo `target/`) — project declares per-path; choir does not guess.
- No-config → NO behavior change (status quo); do not auto-provision un-configured projects.
- Do not block/intercept leaf-side installs (v1).
- Hermetic tests only — no real worktree/filesystem mutation beyond a dedicated temp area; no persisting git state in fixtures.

## Follow-Ups
- Guard/lint: when provisioning is declared, warn or prevent a leaf improvising its own install (the wrong-toolchain catch).
- Recommended per-ecosystem example configs (node/bun: symlink node_modules; rust: `cargo fetch` + fresh target; python: `.venv` copy; moonbit) — in docs and `choir:onboard`.
- `choir:onboard` could scaffold a provision config for the detected ecosystem.
- Optional opt-in auto-detect if explicit config proves tedious in practice.
- Lockfile-integrity guidance (orthogonal but related supply-chain hardening).
