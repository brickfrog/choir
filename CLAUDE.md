# Choir Repo Rules

## Banned Antipatterns

- **Gates must not satisfy themselves.** If a gate (validation, precondition, receipt check) fails for a caller that has no way to produce the required artifact, the fix is NEVER to make the gate produce the artifact itself by spawning a worker / running a sidecar / inlining the missing work. The fix is to (a) give the caller the capability, or (b) move the gate to a caller that already has it. Heartbeats, cycle caps, soft-fail timeouts, and "incomplete" status fields layered onto a self-satisfying gate are all symptoms — when you see them, the gate is in the wrong place. (Historical case: file_pr's 900-line audit-on-file-pr subsystem.)

## Test Boundaries

- Do not add shell-harness tests that drive large `sh` scripts, temp git repos, or broad filesystem mutation when the behavior can be covered by a unit test or a narrow adapter test.
- Do not add tests that persist git config, alter repo identity, or mutate repo-local git state as part of fixtures.
- Do not add tests that depend on ambient cwd, inherited `GIT_*` environment, or other host process state.
- If a test needs real git/process integration, keep it tightly scoped, hermetic, and isolated from the main checkout.

## Test Placement

MoonBit has two test modes — use the right one:

- **Blackbox tests** (`_test.mbt` files): test only `pub`/`pub(all)` API. If a test only calls public functions, it goes here.
- **Whitebox/inline tests** (`test` blocks in source `.mbt` files): test private/internal functions. Only use when the test needs private symbol access.

Do not place public-API-only tests inline in source files. Do not place tests that need private symbols in `_test.mbt` files (they won't compile).

## Effect Architecture

- **No direct I/O in the authoritative control plane.** Code in `src/control/`, `src/workflow/`, `src/migration/`, `src/command/`, `src/harness/`, `src/conformance/`, `src/sandbox/`, `src/storage/`, and `src/types/` must not call `@sys.*` or `@process.*` directly. Emit typed decisions and effects or accept injected capabilities.
- **Keep host effects at the host boundary.** Git, GitHub, provider, process, and filesystem execution belongs in `src/exec/`. `src/sys/` supplies low-level host primitives, and `src/bin/` is the native composition root that may invoke those boundaries. Tooling helpers outside the authoritative control plane must keep host reads injectable for narrow tests.
- **Use enums, not strings, for fixed domains.** Providers, lifecycle states, completion modes, cancellation causes, and other closed workflow values use enums or typed newtypes. Do not introduce a new `String` field for a fixed domain.
- **Use `ChoirError` suberror, not `String`, for errors.** New error paths should return `Result[T, ChoirError]` or `raise ChoirError`, not `Result[T, String]`. The `ChoirError` type in `src/types/error.mbt` has variants for common cases.
- **Inject I/O dependencies.** Pure orchestration receives effects as values. Host adapters and composition-root helpers may provide defaults, but their decision logic must accept injected functions or capability records so tests remain narrow and hermetic.

### Authority boundaries

- `src/control/` owns typed lifecycle transitions and passive assurance gates.
- `src/workflow/` owns durable state-machine decisions and typed effect planning.
- `src/exec/` executes and reconciles authorized host effects; it does not decide that missing evidence should exist.
- `src/bin/choir/` wires the native daemon, CLI, and Conductor boundary. Keep policy in the pure packages rather than growing a second state machine in the binary.

## Safety

- Never let test fixtures write to the real checkout outside their dedicated temp area.
- Prefer pure state-machine, parser, and helper tests over integration-heavy harnesses.
- If a test design risks poisoning local repo state, stop and choose a smaller boundary.

## No Dead Code

- **Delete code that no longer serves a purpose.** Backward-compatibility shims, format translation layers, renamed wrappers, and compat tests for behavior that no longer exists must be removed immediately — not left behind "just in case."
- If something exists only to support an old on-disk format, an old API shape, or a removed feature: delete it. The next restart wipes state. There is no "someone might need this later."
- If you add a function named `legacy_*`, `compat_*`, or `*_old`: that is a red flag. Either the old thing is gone and so should this be, or rename it to reflect what it actually does now.

## Commit & PR Style

Applies to every commit and PR opened by any agent. No exceptions, no AI-attribution footers.

- **Commits:** semantic prefix (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`/`chore:`), imperative subject ≤72 chars, no body unless it adds non-obvious context. Never add `Generated with` / `Co-Authored-By: Claude` / robot-emoji footers.
- **PR title:** same semantic prefix + one-line description.
- **PR body — scale to the change:**
  - Trivial/single-Part PR: 1–3 lines. Just what changed and the verify command result.
  - Substantial PR (feature→main, multi-Part): `## Summary` (2–4 sentences), `## What changed` (bullets), `## Verification` (commands + results). Add `## Follow-ups` only if real ones exist.
  - Do not narrate the development process, list every Part, or recount review history unless it materially affects the reviewer's decision.
- Never paste this guideline, tool output, or process commentary into a PR/commit that doesn't need it.

## Conductor Role

The above are repository-editing invariants. The interactive Conductor follows
the generated Goal skill and the
[Goal workflow charter](docs/charters/goal-workflow.md); it proposes and steers
durable Goals but does not spawn provider sessions, mint receipts, integrate
commits, or decide completion itself. Those actions remain `choird` authority.
