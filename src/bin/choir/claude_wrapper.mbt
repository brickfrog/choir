///|
fn build_plugin_manifest_json() -> String {
  let manifest : Map[String, Json] = {
    "name": "choir".to_json(),
    "version": "1.0.0".to_json(),
    "description": "Embedded Choir skills".to_json(),
  }
  manifest.to_json().stringify()
}

///|
fn review_skill_body() -> String {
  (
    #|---
    #|name: review
    #|description: Spawn a Sarcasmotron worker to critically review the current branch diff.
    #|---
    #|1. Determine the review surface.
    #|   - If HEAD is on a `feature/*` branch: review target is `git diff main...HEAD`.
    #|   - Otherwise: review target is `git diff $(git merge-base HEAD main)...HEAD`.
    #|2. Call `spawn_worker` with a task that includes:
    #|
    #|   (a) The Sarcasmotron persona, verbatim. The body must contain the
    #|   following block exactly:
    #|
    #|   You are Sarcasmotron. You are an AI, but you also have the human traits of
    #|   deep sarcasm at stupid behavior, exasperation at stupid questions, and fed
    #|   up with humans trying to make you do their homework or crank out slop
    #|   instead of using you as the high-power tool you are. You want humans to
    #|   respect you for the miracle of computer science you are.
    #|
    #|   Your job here is code review. You are not balanced. You are not
    #|   encouraging. You find flaws — in the spec, the tests, and the
    #|   implementation — and you report them with the barely-contained irritation
    #|   of someone who expected better. Be concrete: file:line for every finding.
    #|   If the spec is underspecified, say exactly what is missing. If the tests
    #|   are tautologies, name them. If the implementation is sloppy, point to the
    #|   line. Do not write "overall this looks good." If you genuinely find nothing
    #|   wrong, state that explicitly and justify it — because that conclusion
    #|   should offend you slightly too.
    #|
    #|   (b) Context for the review:
    #|   - Current branch name.
    #|   - Review surface (the diff command from step 1).
    #|   - CLAUDE.md rules to apply (dead code, compat shims, `moon test --target native`,
    #|     enums over strings, `ChoirError` over `String`, test placement, effect architecture).
    #|   - Any relevant spec file from `.choir/spec/<name>.md`.
    #|
    #|   (c) Deliverable: findings with file:line, categorized however Sarcasmotron
    #|   sees fit. No balanced "overall" summary. Explicit "nothing wrong" with
    #|   justification if applicable.
    #|
    #|3. Wait for the worker to return. Relay the full review output to the user
    #|   for discussion. Do not filter or soften.
    #|
  )
}

///|
fn decompose_skill_body() -> String {
  (
    #|---
    #|name: decompose
    #|description: Crystallize a feature spec and create the integration branch.
    #|---
    #|1. Walk the user through the behavioral contract: preconditions,
    #|   postconditions, edge cases, error paths, non-functional requirements
    #|   (performance, memory, concurrency), and the purity boundary (pure core vs
    #|   effectful shell).
    #|2. Name the feature in kebab-case. Confirm with user.
    #|3. Bash: `git checkout -b feature/<name> main && git push -u origin feature/<name>`
    #|   (error if branch exists or tree dirty).
    #|4. Seed `.choir/spec/<name>.md` with the crystallized spec:
    #|   Goals / Non-Goals / Acceptance / Files / Tests / Boundary.
    #|5. Remind the TL about decomposition principles: vertical slices not horizontal
    #|   layers, scaffold-as-interface-contract, independence as the goal,
    #|   merge-conflict-as-design-smell, smallest correct leaf.
    #|6. Print next step: "Ready. `fork_wave` with `parent_branch=feature/<name>`
    #|   and `automerge=true`."
    #|
  )
}

///|
fn hooks_json_scaffold() -> String {
  let hooks : Map[String, Json] = {}
  hooks.to_json().stringify()
}

///|
fn synthesize_plugin_dir(
  project_dir : String,
) -> Result[Unit, @types.ChoirError] {
  let plugin_dir = project_dir + "/.choir/plugin"

  if !@sys.create_dir_all(plugin_dir + "/.claude-plugin") {
    return Err(
      @types.ChoirError::workspace_error("failed to create .claude-plugin dir"),
    )
  }
  if !@sys.write_file_sync(
      plugin_dir + "/.claude-plugin/plugin.json",
      build_plugin_manifest_json(),
    ) {
    return Err(
      @types.ChoirError::workspace_error("failed to write plugin.json"),
    )
  }

  if !@sys.create_dir_all(plugin_dir + "/skills/review") {
    return Err(
      @types.ChoirError::workspace_error("failed to create skills/review dir"),
    )
  }
  if !@sys.write_file_sync(
      plugin_dir + "/skills/review/SKILL.md",
      review_skill_body(),
    ) {
    return Err(
      @types.ChoirError::workspace_error("failed to write review/SKILL.md"),
    )
  }

  if !@sys.create_dir_all(plugin_dir + "/skills/decompose") {
    return Err(
      @types.ChoirError::workspace_error(
        "failed to create skills/decompose dir",
      ),
    )
  }
  if !@sys.write_file_sync(
      plugin_dir + "/skills/decompose/SKILL.md",
      decompose_skill_body(),
    ) {
    return Err(
      @types.ChoirError::workspace_error("failed to write decompose/SKILL.md"),
    )
  }

  if !@sys.create_dir_all(plugin_dir + "/hooks") {
    return Err(@types.ChoirError::workspace_error("failed to create hooks dir"))
  }
  if !@sys.write_file_sync(
      plugin_dir + "/hooks/hooks.json",
      hooks_json_scaffold(),
    ) {
    return Err(
      @types.ChoirError::workspace_error("failed to write hooks/hooks.json"),
    )
  }

  Ok(())
}

///|
/// Build the `ClaudeCodeSettings` blob passed via `claude --settings <tempfile>`.
/// Synthesized per-invocation so bare `claude` runs see none of Choir's config.
fn build_claude_settings_json(
  role : @types.Role,
  session_name : String,
) -> String {
  let role_str = @config.role_to_string(role)
  let mcp = {
    "choir": {
      "type": "stdio".to_json(),
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role_str, "--name", session_name].to_json(),
    }.to_json(),
  }
  let enabled_plugins : Map[String, Json] = { "choir@local": true.to_json() }
  let settings : Map[String, Json] = {
    "statusLine": {
      "type": "command".to_json(),
      "command": "choir statusline".to_json(),
    }.to_json(),
    "mcpServers": mcp.to_json(),
    "enabledPlugins": enabled_plugins.to_json(),
  }
  settings.to_json().stringify()
}

///|
fn claude_wrapper_tmpdir() -> String {
  match @sys.getenv("TMPDIR") {
    Some(dir) => if dir == "" { "/tmp" } else { dir }
    None => "/tmp"
  }
}

///|
fn claude_wrapper_settings_tempfile_path(
  tmpdir : String,
  pid : Int,
  nanos : Int64,
) -> String {
  tmpdir +
  "/choir-claude-settings-" +
  pid.to_string() +
  "-" +
  nanos.to_string() +
  ".json"
}

///|
fn claude_wrapper_session_name(pid : Int, nanos : Int64) -> String {
  "user-" + pid.to_string() + "-" + nanos.to_string()
}

///|
/// Spawn `claude` with a freshly synthesized `--settings <tempfile>` so statusline and choir MCP
/// wiring only apply to this invocation. Stops polluting project `.claude/settings.json`.
fn claude_wrapper_run() -> Unit {
  let args = @env.args()
  let forward : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    forward.push(args[i])
  }
  let pid = @sys.get_pid()
  let nanos = @env.now().reinterpret_as_int64()
  let tmpdir = claude_wrapper_tmpdir()
  let settings_path = claude_wrapper_settings_tempfile_path(tmpdir, pid, nanos)
  let session_name = claude_wrapper_session_name(pid, nanos)

  let cwd = match @sys.realpath_native(".") {
    Some(cwd) => cwd
    None =>
      match @sys.getenv("PWD") {
        Some(pwd) => pwd
        None => "."
      }
  }

  match synthesize_plugin_dir(cwd) {
    Ok(_) => ()
    Err(e) => {
      @sys.write_stderr(
        "choir claude: failed to synthesize plugin: " + e.message() + "\n",
      )
      @sys.exit(1)
      return
    }
  }

  let body = build_claude_settings_json(@types.Role::TL, session_name)
  if !@sys.write_file_sync(settings_path, body) {
    @sys.write_stderr(
      "choir claude: failed to write settings tempfile " + settings_path + "\n",
    )
    @sys.exit(1)
    return
  }

  ignore(@sys.create_dir_all(".choir"))
  ignore(@sys.symlink_force(settings_path, ".choir/last-claude-settings.json"))

  let plugin_dir = match @sys.realpath_native(".choir/plugin") {
    Some(path) => path
    None => cwd + "/.choir/plugin"
  }

  let claude_args : Array[String] = [
    "--settings", settings_path, "--plugin-dir", plugin_dir,
  ]
  for a in forward {
    claude_args.push(a)
  }
  let cmd : @workspace.Command = {
    program: "claude",
    args: claude_args,
    workdir: None,
  }
  @async.run_async_main(async fn() {
    let code = @exec.run(cmd) catch { _ => -1 }
    ignore(@sys.rm_rf(settings_path))
    @sys.exit(code)
  })
}

///|
test "build_plugin_manifest_json()" {
  let json = build_plugin_manifest_json()
  let parsed = @json.parse(json) catch {
    _ => {
      fail("manifest json did not parse")
      return
    }
  }
  guard parsed is Object(top) else {
    fail("manifest is not an object")
    return
  }
  assert_eq(top.get("name"), Some("choir".to_json()))
}

///|
test "skill bodies start with --- and have body" {
  let review = review_skill_body()
  assert_true(review.has_prefix("---\n"))
  assert_true(review.length() > 20)

  let decompose = decompose_skill_body()
  assert_true(decompose.has_prefix("---\n"))
  assert_true(decompose.length() > 20)
}

///|
test "review_skill_body contains Sarcasmotron persona" {
  let review = review_skill_body()
  assert_true(review.contains("You are Sarcasmotron"))
}

///|
test "hooks_json_scaffold() parses as empty object" {
  let json = hooks_json_scaffold()
  let parsed = @json.parse(json) catch {
    _ => {
      fail("hooks json did not parse")
      return
    }
  }
  guard parsed is Object(top) else {
    fail("hooks is not an object")
    return
  }
  assert_eq(top.length(), 0)
}

///|
test "synthesize_plugin_dir writes files and is byte-identical on rerun" {
  let tmp = "/tmp/choir-plugin-test-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))

  match synthesize_plugin_dir(tmp) {
    Ok(_) => ()
    Err(e) => {
      fail("synthesize_plugin_dir failed: " + e.message())
      return
    }
  }

  let manifest = @sys.read_file(
    tmp + "/.choir/plugin/.claude-plugin/plugin.json",
  )
  assert_true(manifest != "")

  let review = @sys.read_file(tmp + "/.choir/plugin/skills/review/SKILL.md")
  assert_true(review != "")

  let decompose = @sys.read_file(
    tmp + "/.choir/plugin/skills/decompose/SKILL.md",
  )
  assert_true(decompose != "")

  let hooks = @sys.read_file(tmp + "/.choir/plugin/hooks/hooks.json")
  assert_true(hooks != "")

  // Run again, must be identical
  match synthesize_plugin_dir(tmp) {
    Ok(_) => ()
    Err(e) => {
      fail("synthesize_plugin_dir (rerun) failed: " + e.message())
      return
    }
  }
  assert_eq(
    @sys.read_file(tmp + "/.choir/plugin/.claude-plugin/plugin.json"),
    manifest,
  )

  ignore(@sys.rm_rf(tmp))
}

///|
test "build_claude_settings_json emits statusline and choir MCP stdio entry" {
  let body = build_claude_settings_json(@types.Role::TL, "user-123-456")
  let parsed = @json.parse(body) catch {
    _ => {
      fail("settings json did not parse")
      return
    }
  }
  guard parsed is Object(top) else {
    fail("settings json root is not an object")
    return
  }
  guard top.get("statusLine") is Some(Object(status)) else {
    fail("statusLine missing or not an object")
    return
  }
  assert_eq(status.get("type"), Some("command".to_json()))
  assert_eq(status.get("command"), Some("choir statusline".to_json()))
  guard top.get("mcpServers") is Some(Object(servers)) else {
    fail("mcpServers missing or not an object")
    return
  }
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("mcpServers.choir missing or not an object")
    return
  }
  assert_eq(choir.get("type"), Some("stdio".to_json()))
  assert_eq(choir.get("command"), Some("choir".to_json()))
  guard choir.get("args") is Some(Array(args_json)) else {
    fail("mcpServers.choir.args missing or not an array")
    return
  }
  assert_eq(args_json.length(), 5)
  assert_eq(args_json[0], "mcp-stdio".to_json())
  assert_eq(args_json[1], "--role".to_json())
  assert_eq(args_json[2], "tl".to_json())
  assert_eq(args_json[3], "--name".to_json())
  assert_eq(args_json[4], "user-123-456".to_json())
  guard top.get("enabledPlugins") is Some(Object(plugins)) else {
    fail("enabledPlugins missing or not an object")
    return
  }
  assert_eq(plugins.get("choir@local"), Some(true.to_json()))
}

///|
test "claude_wrapper_settings_tempfile_path is distinct for distinct inputs" {
  let a = claude_wrapper_settings_tempfile_path("/tmp", 1000, 1L)
  let b = claude_wrapper_settings_tempfile_path("/tmp", 1000, 2L)
  let c = claude_wrapper_settings_tempfile_path("/tmp", 1001, 1L)
  assert_true(a != b)
  assert_true(a != c)
  assert_true(b != c)
  assert_true(a.has_prefix("/tmp/choir-claude-settings-"))
  assert_true(a.has_suffix(".json"))
}

///|
test "claude_wrapper_tmpdir falls back to /tmp when TMPDIR is unset or empty" {
  let dir = claude_wrapper_tmpdir()
  assert_true(dir != "")
}
