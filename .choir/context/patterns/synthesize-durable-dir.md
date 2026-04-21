# synthesize-durable-dir

## When to use
You need to materialize a directory tree of generated files on disk every
time Choir runs — Claude plugin skills, hook scaffolds, leaf helper scripts.
The content is derived from embedded string literals, must be idempotent
(same input → identical bytes), and must live at a durable project-relative
path the child process can read.

## Reference implementation
`.choir/plugin/` synthesis, shipped in PR #238 (merge `4b5b048`). Commit
`295136a`.
- Entry point: `src/bin/choir/claude_wrapper.mbt` — `fn synthesize_plugin_dir`
- Body builders: same file — `fn build_plugin_manifest_json`, `fn audit_skill_body`,
  `fn decompose_skill_body`, `fn hooks_json_scaffold`
- Invocation site: same file — `fn claude_wrapper_run` wraps the call with
  `@sys.exit(1)` on `Err`
- Idempotence test: same file — `test "synthesize_plugin_dir writes files and is byte-identical on rerun"`
- Stale-entry test: same file — `test "synthesize_plugin_dir removes stale user skill on rerun"`

## Steps
1. Resolve the target directory from an absolute path (`@sys.realpath_native(".")`
   fallback `@sys.getenv("PWD")`), never a bare relative string — `claude_wrapper_run`
   is the reference.
2. Wipe the target with `ignore(@sys.rm_rf(<root>))` before rewriting so stale
   entries from prior runs are guaranteed gone.
3. For each subdirectory: `@sys.create_dir_all(path)`; bail out with
   `Err(ChoirError::workspace_error(...))` if it returns false.
4. For each file: embed content as a `#|` multi-line literal body builder
   (see `audit_skill_body`), then `@sys.write_file_sync(path, body)`; bail
   with `workspace_error` on failure.
5. Return `Result[Unit, @types.ChoirError]` from the synthesizer. The caller
   (`claude_wrapper_run`) prints `e.message()` to stderr and `@sys.exit(1)`.
6. If you need a stable debug link, `ignore(@sys.symlink_force(...))` after
   the write — optional, non-fatal.
7. Add two tests: one asserts required files exist and a second run produces
   byte-identical content; another asserts pre-existing stale entries under
   the synthesized root are removed on rerun.

## Gotchas
- Never compute the target from `$PWD` alone; fall back to
  `@sys.realpath_native(".")` first so `cd`-then-invoke and symlinked
  worktrees both resolve stably (see `claude_wrapper_run` line 365).
- `@sys.create_dir_all` + `@sys.write_file_sync` both return `Bool`, not
  `Result`; wrap each in an `if !... { return Err(...) }` or the failure is
  silently swallowed.
- Do not write to `/tmp` for content the spawned process needs later — the
  tempfile race in `claude_wrapper_run` is specifically for the
  `--settings` blob, not the plugin tree. Durable outputs live under the
  project dir.
- Don't `@sys.rm_rf` a path the caller didn't hand you: all writes stay
  under the computed `<project_dir>/.choir/<feature>` root.

## Verification
```
moon test --target native -p choir/src/bin/choir
rg -n 'synthesize_plugin_dir' src/bin/choir/claude_wrapper.mbt
```
Behavioral probe: run the subcommand twice in a scratch dir and diff the
generated tree — output must be byte-identical on rerun.
