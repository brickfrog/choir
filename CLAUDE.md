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

## Safety

- Never let test fixtures write to the real checkout outside their dedicated temp area.
- Prefer pure state-machine, parser, and helper tests over integration-heavy harnesses.
- If a test design risks poisoning local repo state, stop and choose a smaller boundary.
