# Choir Repo Rules

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

- **No direct I/O in orchestration logic.** Code in `src/server/`, `src/tools/`, `src/poller/`, `src/phase/`, `src/runtime/` must not call `@sys.*` or `@process.*` directly. Emit typed effects or use injected adapter functions. All host I/O (Git, GitHub, Zellij, filesystem) goes through `src/exec/` or injected function parameters.
- **Use enums, not strings, for fixed domains.** Agent types use `AgentType`, roles use `Role`, states use `AgentState`. Do not introduce new `String` fields for values drawn from a fixed set — define an enum.
- **Use `ChoirError` suberror, not `String`, for errors.** New error paths should return `Result[T, ChoirError]` or `raise ChoirError`, not `Result[T, String]`. The `ChoirError` type in `src/types/error.mbt` has variants for common cases.
- **Inject I/O dependencies.** Functions that need to run commands, capture output, or read files should take the capability as an optional parameter with a default (see `dispatch()` pattern with `runner?`, `capture?`, `git_capture?`). This enables testing with mocks.

### Do not widen

The former known gaps (typed lifecycle triggers, typed lifecycle snapshots in event logging, injected hook capture in `handle_request` / `fire_hook_async`) are resolved; do not reintroduce stringly triggers, manual JSON stringification at call sites for lifecycle transitions, or direct `@exec.capture_hook_script_merged` in those paths.

## Safety

- Never let test fixtures write to the real checkout outside their dedicated temp area.
- Prefer pure state-machine, parser, and helper tests over integration-heavy harnesses.
- If a test design risks poisoning local repo state, stop and choose a smaller boundary.

## No Dead Code

- **Delete code that no longer serves a purpose.** Backward-compatibility shims, format translation layers, renamed wrappers, and compat tests for behavior that no longer exists must be removed immediately — not left behind "just in case."
- If something exists only to support an old on-disk format, an old API shape, or a removed feature: delete it. The next restart wipes state. There is no "someone might need this later."
- If you add a function named `legacy_*`, `compat_*`, or `*_old`: that is a red flag. Either the old thing is gone and so should this be, or rename it to reflect what it actually does now.

## Commits

- Semantic commits only

## TL Workflow

When a user brings a feature request, follow the VSDD pipeline in `.choir/context/tl.md`:
**Spec Crystallization → TDD Leaves (Red Gate) → Code Review Gate → Convergence.**
Use Chainlink `issue_id` in `fork_wave` to track every leaf's work.

## Leaf Agent Rules

- **Always verify with `moon test --target native`**, not bare `moon test`. Bare `moon test` includes wasm-gc/js targets that have pre-existing failures unrelated to any leaf's changes. CI runs `moon test --target native`; that is the only verification that matters.
- **Do not call `notify_parent` until all Copilot review threads are resolved.** Filing a PR and immediately reporting it as ready is incorrect if unresolved inline threads remain. Wait for Copilot to review, address every thread, and confirm zero unresolved threads before notifying the parent.
- **Copilot reviews once.** It does not re-review after fixes are pushed. After addressing review comments, the leaf must resolve each thread itself via `gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<id>"}) { thread { isResolved } } }'`, then verify zero unresolved threads before notifying parent.
