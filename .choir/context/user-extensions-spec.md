# User Extensions: `choir skill` + `choir mcp`

Let users add their own skills and MCP servers to choir-scoped Claude sessions
without rebuilding the binary or polluting project `.claude/`. User extensions
live under `~/.config/choir/` and are merged into the synthesized plugin at
`choir claude` launch time. **Built-in skills and the built-in `choir` MCP
server always win on name collision — a clash is a loud stderr error, not a
silent override.**

## Goals

- `choir skill add <path>` — register a user skill (dir import).
- `choir skill list` — show built-in + user skills.
- `choir skill remove <name>` — delete a user skill.
- `choir mcp add <name> -- <command> [args...]` — register a user MCP server.
- `choir mcp list` — show built-in + user MCP servers.
- `choir mcp remove <name>` — delete a user MCP server.
- Merge these into the synthesized plugin + settings blob on every
  `choir claude` launch, with binary-wins-loud collision behavior.

## Non-Goals

- `choir plugin add` (skipped — trivial bulk wrapper, revisit if anyone wants a
  real multi-skill bundle).
- Single-file skill add (dir-only per user decision — `add <dir>` copies the
  whole tree, `<dir>/SKILL.md` required).
- XDG_CONFIG_HOME resolution nuance (use `$HOME/.config/choir` unconditionally;
  XDG can be a follow-up if someone asks).
- Hooks in user-config (keep built-in scaffold only; user hooks are a separate
  future feature).
- URL-fetching for skills (local paths only).

## Reference-by-analog

- New helpers mirror `init_bootstrap_ensure_choir_dir_and_config_if_absent`
  (`src/bin/choir/init_bootstrap.mbt:3`) — tiny `create_dir_all` +
  `write_file_sync` + `exit(1)` idiom for user-facing bootstrap.
- `skill_subcommand_run` / `mcp_subcommand_run` mirror `claude_wrapper_run`
  (`src/bin/choir/claude_wrapper.mbt:212`) — read `@env.args()`, flat match on
  sub-subcommand, inline bodies.
- Recursive directory copy: no existing primitive; new helper goes in
  `src/sys/io.mbt` next to `list_dir` (`src/sys/io.mbt:118`). Pattern:
  `list_dir` + recurse on each entry, `read_file` + `write_file_sync` on leaves.
- User-home resolution: `@sys.getenv("HOME")` + error-on-unset, matching
  `trust_gemini_folder.mbt:20`.
- Subcommand dispatch: flat `match` in `main.mbt:8`. `"skill"` and `"mcp"`
  drop in next to `"claude"` / `"statusline"`.

## User-facing CLI

```
choir skill add <dir>
  <dir> must contain SKILL.md. Skill name = basename(<dir>).
  Copies the whole tree to ~/.config/choir/skills/<name>/.
  Errors on builtin name (audit, decompose).
  Overwrites existing user skill of the same name without prompt.

choir skill list
  Prints:
    builtin:
      audit      — Spawn a Sarcasmotron worker to critically audit...
      decompose  — Crystallize a feature spec and create the integration branch.
    user:
      <name>     — <description from SKILL.md frontmatter>

choir skill remove <name>
  Errors if <name> is a builtin.
  Errors if user skill does not exist.
  Deletes ~/.config/choir/skills/<name>/.

choir mcp add <name> -- <command> [args...]
  Appends {"<name>": {"type":"stdio","command":"<command>","args":[...]}}
  to ~/.config/choir/mcp.json (creating the file if absent).
  Errors on builtin name (choir).
  Overwrites existing user entry of the same name.

choir mcp list
  Prints:
    builtin:
      choir      — choir mcp-stdio --role <role> --name <session>
    user:
      <name>     — <command> <args...>

choir mcp remove <name>
  Errors if <name> is a builtin.
  Errors if user entry does not exist.
```

All four subcommands (`skill`, `skill add`, `skill list`, `skill remove`, and
the `mcp` equivalents) support `--help` printing the usage + one example.

## On-disk layout

```
~/.config/choir/
├── skills/<name>/SKILL.md       # plus any sibling files from the source dir
└── mcp.json                     # {"servers": {"<name>": {...same shape as builtin...}}}
```

`mcp.json` schema:

```json
{
  "servers": {
    "linear": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@linear/mcp-server"]
    }
  }
}
```

## Merge semantics at `choir claude` launch

**Skills merge** (in `synthesize_plugin_dir`):

1. Write built-in skills first (current behavior: `audit`, `decompose`).
2. `list_dir(~/.choir/skills)` — skip if dir absent.
3. For each user skill dir:
   - If name ∈ `{"audit", "decompose"}`: write to stderr
     `choir claude: user skill '<name>' clashes with builtin; rename or remove ~/.config/choir/skills/<name>/`
     and exit 1.
   - Otherwise: recursively copy the user tree into
     `.choir/plugin/skills/<name>/`.

**MCP merge** (in `build_claude_settings_json`):

1. Start with `mcpServers = {"choir": {...}}` (current behavior).
2. If `~/.config/choir/mcp.json` exists, parse it.
3. For each entry in `.servers`:
   - If name == `"choir"`: stderr error, exit 1 (same shape as skills).
   - Otherwise: insert into the `mcpServers` map.

Collision behavior is uniform: **stderr message + exit 1 before spawning
claude**. The user sees the error immediately and must rename or remove the
offending entry.

## Behavioral contract

- **Idempotency**: `choir claude` rewrites `.choir/plugin/` from scratch on
  every launch (current behavior). User merges happen during that rewrite.
  Running `choir claude` twice with no config change produces byte-identical
  output.
- **Absent `~/.config/choir/`**: behavior is unchanged from today. No error,
  no prompt, merge pass is a no-op.
- **Malformed `~/.config/choir/mcp.json`**: stderr error with parse location,
  exit 1. Do not silently skip malformed config.
- **Missing `SKILL.md` in a user skill dir**: stderr error naming the skill
  dir, exit 1. Do not silently skip.
- **`HOME` env var unset**: `choir skill` / `choir mcp` subcommands print
  `error: HOME is not set` and exit 1 (matches `trust_gemini_folder.mbt:23`).
  `choir claude` merge pass treats HOME-unset as "no user config" and proceeds
  (to preserve today's behavior in minimal environments).

## Purity boundary

- **Pure core** (testable with fixture dirs):
  - `parse_mcp_config_json(s: String) -> Result[Map[String, McpServer], ChoirError]`
  - `validate_skill_name(name: String, builtins: Array[String]) -> Result[Unit, ChoirError]`
  - `merge_mcp_maps(builtin: Map, user: Map) -> Result[Map, ChoirError]`
  - `render_skill_list(builtin: Array[SkillDesc], user: Array[SkillDesc]) -> String`
- **Effectful shell** (injected adapters):
  - `user_config_home() -> Result[String, ChoirError]` (reads HOME)
  - `copy_dir_recursive(src: String, dst: String) -> Result[Unit, ChoirError]`
  - `list_user_skills() -> Result[Array[SkillDesc], ChoirError]`

## Files to change

### New

- `src/bin/choir/user_config.mbt` — `user_config_home()`, `user_skills_dir()`,
  `user_mcp_json_path()`. All return `Result[String, ChoirError]`.
- `src/bin/choir/skill_subcommand.mbt` — `skill_subcommand_run()` +
  `add_skill`, `list_skills`, `remove_skill` helpers + tests.
- `src/bin/choir/mcp_subcommand.mbt` — `mcp_subcommand_run()` +
  `add_mcp`, `list_mcp`, `remove_mcp` helpers + tests.
- `src/sys/io.mbt` — add `copy_dir_recursive(src, dst) -> Bool` helper (pure
  traversal via existing `list_dir` + `read_file` + `write_file_sync`).

### Modified

- `src/bin/choir/main.mbt` — add `"skill" => skill_subcommand_run()` and
  `"mcp" => mcp_subcommand_run()` to the dispatch match; extend usage string.
- `src/bin/choir/claude_wrapper.mbt`:
  - `synthesize_plugin_dir` — call new `merge_user_skills_into_plugin`
    helper at the end; on err, propagate.
  - `build_claude_settings_json` — take an optional pre-merged
    `user_mcp: Map[String, Json]` arg (default empty); or call a helper
    internally. (Leaf picks the cleaner approach — either is fine.)
- `.gitignore` — no change; `~/.config/choir/` is outside the repo.
- `src/bin/choir/moon.pkg` — register new `.mbt` files for `native` target.

## Tests

### Pure-core (blackbox `*_test.mbt`)

- `parse_mcp_config_json`: valid config, malformed JSON, missing `.servers`,
  non-object entry, entry missing `command`.
- `validate_skill_name`: builtin clash, valid user name, empty name,
  path-traversal attempt (`../foo`).
- `merge_mcp_maps`: clean merge, `choir` collision, multiple user entries.
- `render_skill_list`: empty user list, populated user list, formatting stable.

### Whitebox inline (in the `.mbt` source files)

- `user_skills_dir` returns `<HOME>/.config/choir/skills` when HOME set.
- `user_config_home` returns `Err` when HOME unset.
- `copy_dir_recursive` against a temp fixture: nested files preserved,
  byte-identical to source.

### Integration-ish (but hermetic — temp dirs, no real HOME mutation)

- `merge_user_skills_into_plugin`: with a fixture `user_skills_dir`,
  produces expected `.choir/plugin/skills/<n>/SKILL.md`.
- Clash test: fixture with `user_skills/audit/SKILL.md` → returns `Err` with
  the expected message shape.

## Observable verify (per tl.md Spec Hygiene)

Every leaf's `verify` array must include **at least one** command that
exercises the built binary against expected observable state:

- `choir skill add ./test-fixtures/demo-skill && choir skill list | grep demo`
  — confirms add + list work end-to-end.
- `choir skill add ./test-fixtures/demo-skill && cd /tmp/scratch-$(date +%s) && git init && choir init --tl claude && ls .choir/plugin/skills/demo/SKILL.md`
  — confirms the merge happens at init-time (since `choir init` also calls
  `synthesize_plugin_dir` via `launch.mbt`).
- Clash test: create `~/.config/choir/skills/audit/` manually, run
  `choir claude --version 2>&1 | grep clashes` — confirms the binary-wins
  error fires.
- `choir mcp add linear -- npx -y @linear/mcp-server && cat ~/.config/choir/mcp.json | jq .servers.linear.command` → `"npx"`.

## Decomposition

**Feature branch**: `feature-user-extensions`.

**Scaffold commit on the feature branch** (TL, pre-fork, no leaf):
- Add `src/bin/choir/user_config.mbt` with `user_config_home()`,
  `user_skills_dir()`, `user_mcp_json_path()` + inline tests.
- Update `moon.pkg` to register it.
- Wire `"skill"` and `"mcp"` stubs in `main.mbt` that just print
  `"not implemented"` and exit 1 (so both leaves have a clean match arm to
  replace).

This scaffold is the compilation firewall — both leaves compile against the
same path helpers and dispatch table.

**Wave 1 (parallel leaves, `parent_branch=feature-user-extensions`,
`automerge=true`)**:

- **Leaf A — skills flow** (`agent_type=gemini`):
  - Implement `skill_subcommand_run` + add/list/remove.
  - Add `copy_dir_recursive` to `src/sys/io.mbt`.
  - Implement `merge_user_skills_into_plugin`, wire into
    `synthesize_plugin_dir`.
  - Tests per the "Tests" section above (skills portion).
  - Observable verify: `choir skill add` + `choir skill list | grep`; clash
    test.

- **Leaf B — mcp flow** (`agent_type=gemini`):
  - Implement `mcp_subcommand_run` + add/list/remove.
  - Implement `parse_mcp_config_json`, `merge_mcp_maps`.
  - Wire user-mcp merge into `build_claude_settings_json`.
  - Tests per the "Tests" section above (mcp portion).
  - Observable verify: `choir mcp add` + `cat ~/.config/choir/mcp.json | jq`.

Leaves are independent — different files, different functions. Scaffold
covers the shared helpers.

**Post-wave**:
1. Run `/audit` (Sarcasmotron worker on `main...feature-user-extensions`).
2. Address findings via a follow-up wave if needed.
3. `gh pr create --base main --head feature-user-extensions`.
4. Human merges on GitHub.

## Open items for the leaf to resolve

- **`copy_dir_recursive` error modes**: what to do on partial failure (some
  files copied, then a write fails)? Proposed: return `Bool` like the rest
  of `src/sys/io.mbt`, leave partial state; caller decides whether to
  `rm_rf` and retry. Leaf can refine if the tests argue for something else.
- **`--help` output stability**: if we snapshot-test `--help`, leaf should
  commit the snapshot. Otherwise a spot-check test for presence of key
  strings is fine.
- **Skill description extraction** for `skill list`: parse the YAML
  frontmatter's `description:` line with a tiny scanner, not a full YAML
  parser. Fail gracefully (print `<no description>`) on malformed
  frontmatter.
