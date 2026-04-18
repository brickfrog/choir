# Spec: Embedded Claude Code Plugin for `choir claude`

## Why
PR #237 shipped `choir claude` (wrapper that writes a per-invocation `--settings`
tempfile carrying statusLine + MCP registration). Settings JSON cannot carry
skills — those must live on disk as plugin files. Goal: zero-friction skill
distribution. User installs the choir binary, runs `choir claude`, and gets the
`/review` and `/decompose` skills with no manual copying.

## STEP 0 (do this first, before writing code)
Run `claude --help 2>&1 | rg -i plugin` and confirm the flag for a local plugin
directory. The design assumes `--plugin-dir <abs-path>`. If the actual flag is
different, adjust. If no local-plugin flag exists at all, stop and
`notify_parent` with the finding — do not guess.

## Approach
- Plugin dir is durable: `.choir/plugin/` (flat, not namespaced).
  - Must outlive the wrapper (future hooks fire during the session).
  - Content is pinned to binary version → concurrent writes are byte-identical
    and therefore benign.
- Settings JSON stays a tempfile.
  - Read once at claude startup, concurrent-safe, per-invocation variation.
- Symlink `.choir/last-claude-settings.json` → tempfile for post-mortem.
  - Cleanup unlinks the tempfile path directly; the symlink is left dangling
    between runs and overwritten on the next `symlink_force`.

## Plugin layout
```
.choir/plugin/
  .claude-plugin/plugin.json          manifest: {name, version, description}
  skills/review/SKILL.md              /review skill (YAML frontmatter + body)
  skills/decompose/SKILL.md           /decompose skill (YAML frontmatter + body)
  hooks/hooks.json                    scaffold: {}
```

## Skill content (procedural, model-invokable)

### /review
Trigger: user asks for a final review of the current branch, or invokes
`/review` explicitly.
Actions:
1. `git merge-base HEAD main` (or upstream parent).
2. `git diff <base>...HEAD` to get the review surface.
3. If a PR exists: `gh pr view --json reviews,comments,statusCheckRollup`.
4. Scan diff for CLAUDE.md-rule violations: dead code, compat shims,
   forbidden test patterns, bare `moon test` (must be `--target native`),
   stringly enums where enums exist, String-typed errors where ChoirError
   exists.
5. Emit a structured report: Critical / Nits / Suggestions, with file:line
   citations.
6. Offer to address critical findings via edits.

### /decompose
Trigger: user describes a feature and wants to start a feature branch.
Actions:
1. Confirm a kebab-case feature name.
2. `git checkout -b feature/<name> main` (error if branch exists or tree dirty).
3. Optionally seed `.choir/spec/<name>.md` with a crystallized spec
   (Goals / Non-Goals / Acceptance).
4. Print next step: "Fork leaves via `fork_wave` targeting `feature/<name>`."

## Files to change
1. `src/bin/choir/claude_wrapper.mbt` — extend. Add:
   - `build_plugin_manifest_json() -> String`
   - `review_skill_body() -> String` (use `#|` multiline literals)
   - `decompose_skill_body() -> String`
   - `hooks_json_scaffold() -> String` (returns `{}`)
   - `synthesize_plugin_dir(project_dir : String) -> Result[Unit, ChoirError]`
     (idempotent; `@sys.create_dir_all` + `@sys.write_file_sync`)
   - Extend `build_claude_settings_json` to include `enabledPlugins`
     (key shape: verify against Claude Code docs; plan assumes
     `{"choir@local": true}` but adjust if docs dictate otherwise).
   - Modify `claude_wrapper_run`:
     - Call `synthesize_plugin_dir(cwd)` before writing settings.
     - Resolve absolute plugin path (`@sys.getcwd()` or `PWD`).
     - Write settings tempfile (unchanged).
     - `@sys.create_dir_all(".choir")` and
       `@sys.symlink_force(settings_path, ".choir/last-claude-settings.json")`.
     - Pass `--plugin-dir <abs>` to claude alongside existing `--settings`.
     - Cleanup stays `@sys.rm_rf(settings_path)` (tempfile only).
2. `.gitignore` — add `.choir/plugin/` and `.choir/last-claude-settings.json`
   (verify `.choir/*` + `!.choir/context/` already excludes them; if covered,
   no change needed).

## Tests (inline in `claude_wrapper.mbt`)
- `build_plugin_manifest_json()` parses as JSON; `name == "choir"`.
- Skill bodies start with `---\n` and have non-empty body after closing `---`.
- `build_claude_settings_json(...)` parses as JSON; `enabledPlugins` has the
  `choir@local: true` entry.
- `synthesize_plugin_dir(tmp)` writes 4 expected files; re-running produces
  byte-identical output.
- `hooks_json_scaffold()` parses as JSON and is an empty object.

## Verify
```
claude --help 2>&1 | rg -i plugin
moon fmt
moon build --target native --release
moon test --target native
```

## Non-goals
- `src/workspace/launch.mbt` (leaf spawn path) stays unchanged.
- `src/hooks/` (WASM hook system) stays unchanged.
- Real hook events (SessionStop, PostToolUse, etc.) — scaffold `{}` only.
- Plugin marketplace publishing.
- Workflow changes (feature-branch-vs-main flow) — separate discussion.
- MCP role: stays `tl`.

## Boundary (do not)
- Create `_test.mbt` siblings — inline tests only.
- Add shell-harness tests that spawn real `claude`.
- Use bare `moon test` — always `--target native`.
- Introduce `String` for fixed domains — use enums.
- Return `Result[T, String]` for new error paths — use `ChoirError`.
- Hand-escape JSON via concatenation — use `Map[String, Json].to_json().stringify()`.
- Silently swallow errors in `synthesize_plugin_dir` — propagate `ChoirError`.
- Call `notify_parent` until every Copilot review thread is resolved
  (resolve via GraphQL `resolveReviewThread` mutation).
- `--amend` after a pre-commit hook failure — create a NEW commit.
