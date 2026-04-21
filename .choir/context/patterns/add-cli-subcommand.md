# add-cli-subcommand

## When to use
You are adding a top-level `choir <verb>` subcommand (e.g. `choir log`,
`choir stats`, `choir skill`) that parses its own flags, touches the local
filesystem or Choir state, and writes to stdout/stderr with an explicit exit
code.

## Reference implementation
`choir log`, shipped in PR #250 (merge `bd7170b`). Commit `e4c01f2`.
- Dispatch arm: `src/bin/choir/main.mbt:25` — `"log" => log_subcommand_run()`
- Usage string: `src/bin/choir/main.mbt:31` — `_ =>` branch
- Entry point: `src/bin/choir/log_subcommand.mbt` — `pub fn log_subcommand_run`
- Help text: same file — `fn log_help`
- Error path: same file — `fn log_subcommand_error` (`@sys.write_stderr` + `@sys.exit(1)`)
- `moon.pkg` entry: `src/bin/choir/moon.pkg` — both `log_subcommand.mbt` and
  `log_subcommand_test.mbt` marked `[ "native" ]`
- Tests: `src/bin/choir/log_subcommand_test.mbt` — blackbox coverage for the
  `choir log` reference implementation lives here

## Steps
1. Create `src/bin/choir/<name>_subcommand.mbt` with `pub fn <name>_subcommand_run() -> Unit`.
2. Register the file (and any `_test.mbt`) under `targets` in `src/bin/choir/moon.pkg`
   with `[ "native" ]`.
3. Add the match arm to the subcommand dispatcher in `src/bin/choir/main.mbt`
   and extend the `_ =>` usage string with the new verb.
4. Parse args manually off `@env.args()` starting at index 2; on bad input,
   call an error helper that does `@sys.write_stderr` + `@sys.exit(1)`.
5. Support `--help`/`-h` by dumping a multi-line `#|` literal and returning
   (no exit code — `--help` is success).
6. Render output with `@sys.write_stdout`; load Choir state through the
   existing `@tools`/`@workspace` APIs, never ad-hoc `@sys.read_file`.
7. Tests: put argument-parser tests inline in the source file (private
   symbols); put formatter/rendering helpers behind `pub fn` and test them
   from `<name>_subcommand_test.mbt`.

## Gotchas
- `@env.args()` starts at index 0; the subcommand name is at index 1, so
  loop `i = 2` — off-by-one here silently drops the first flag.
- `--help` must NOT call `@sys.exit(1)` — help is a success exit.
- Do not run interactive work inside the dispatch arm; `main.mbt` is not
  `async`. If you need async, wrap with `@async.run_async_main` as
  `claude_wrapper_run` does.
- Test placement: a blackbox test importing `@<pkg>` cannot reach private
  helpers — if the test only calls `pub fn`, it belongs in `_test.mbt`;
  otherwise it must be a `test` block in the source file.
- No shell-harness tests. CLAUDE.md §Test Boundaries forbids tests that
  drive `sh` scripts, spin up temp git repos, or mutate the working tree
  for coverage. Cover parser/formatter logic with narrow MoonBit tests;
  if the CLI surface genuinely needs integration, pick a smaller boundary
  (inject the capability) rather than shelling out.

## Verification
```
moon test --target native -p choir/src/bin/choir
choir <name> --help
choir <name> <bad-flag>   # exit 1, stderr starts with "error:"
```
Then grep: `rg -n '"<name>"' src/bin/choir/main.mbt` must hit both the
dispatch arm and the usage string.
