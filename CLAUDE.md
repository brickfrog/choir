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

Choir follows an exomonad-style architecture. Respect these invariants:

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
