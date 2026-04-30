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
fn audit_skill_body() -> String {
  (
    #|---
    #|name: audit
    #|description: Spawn a Sarcasmotron worker to critically audit the current branch diff.
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
    #|   - Any relevant spec file from `.choir/context/<name>-spec.md`.
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
fn crystallize_skill_body() -> String {
  (
    #|---
    #|name: crystallize
    #|description: Crystallize an idea into a canonical spec via structured clarifying questions.
    #|---
    #|1. Pick a kebab-case feature slug. Confirm with the user.
    #|2. Call `crystallize_spec(feature_slug: <slug>)` MCP tool. It writes the
    #|   template at `.choir/context/<slug>-spec.md` with empty sections.
    #|3. Read the written file. Identify genuine blanks that would change the spec
    #|   (not "should I proceed?" — real ambiguities: error behavior, purity
    #|   boundary, scope forks, ordering constraints).
    #|4. Target 3–5 questions, absolute max 7. If you can't form 3 sharp questions,
    #|   you may not understand the task — read more source before asking.
    #|5. Ask them in ONE batch via `AskUserQuestion`. Each question: 2–4 options,
    #|   mark one `(Recommended)` where applicable, always allow "Other".
    #|6. Write the Q&A verbatim into the `## Clarifications` section of the spec
    #|   file. Format: `**Q: <question>?**\nA: <answer>`.
    #|7. Draft the remaining sections (Context, Goals, Non-Goals, Design, Verify,
    #|   Boundary, Follow-Ups) based on the clarifications. If a section needs
    #|   further user input, ask a second small batch — do not spawn with blanks.
    #|8. Print: "Spec crystallized at `.choir/context/<slug>-spec.md`. Run
    #|   `/decompose` to create the integration branch."
    #|
  )
}

///|
fn decompose_skill_body() -> String {
  (
    #|---
    #|name: decompose
    #|description: Create the integration branch from an existing crystallized spec.
    #|---
    #|1. Confirm the feature slug with the user (or infer from conversation if
    #|   crystallize was just run).
    #|2. Read `.choir/context/<slug>-spec.md`. Verify it exists; if not, print
    #|   "Run /crystallize first" and stop.
    #|3. Verify the `## Clarifications` section has at least one `**Q:...**\nA:...`
    #|   block. If empty, print "Spec has no Clarifications — run /crystallize first
    #|   to populate" and stop.
    #|4. Verify the `## Goals`, `## Non-Goals`, `## Design`, and `## Verify` sections
    #|   are non-empty. If any are empty, ask the TL to fill them before continuing.
    #|5. Bash: `git checkout -b feature/<slug> main && git push -u origin
    #|   feature/<slug>` (error if branch exists or tree dirty).
    #|6. Remind about decomposition principles: vertical slices not horizontal
    #|   layers, scaffold-as-interface-contract, independence as the goal,
    #|   merge-conflict-as-design-smell, smallest correct leaf.
    #|7. Print: "Ready. `fork_wave` with `parent_branch=feature/<slug>` and
    #|   `automerge=true`."
    #|
  )
}

///|
fn hooks_json_scaffold() -> String {
  let hooks : Map[String, Json] = {}
  hooks.to_json().stringify()
}

///|
fn merge_user_skills_into_plugin(
  plugin_dir : String,
  home : String,
) -> Result[Unit, @types.ChoirError] {
  let skills_dir = match @choir_commands.user_skills_dir_for(home) {
    Ok(d) => d
    Err(_) => return Ok(())
  }
  if !@sys.path_entry_exists(skills_dir) {
    return Ok(())
  }
  let entries = @sys.list_dir(skills_dir)
  for entry in entries {
    if entry == "audit" || entry == "crystallize" || entry == "decompose" {
      let msg = "choir claude: user skill '" +
        entry +
        "' clashes with builtin; rename or remove ~/.config/choir/skills/" +
        entry
      @sys.write_stderr(msg + "\n")
      return Err(@types.ChoirError::workspace_error(msg))
    }
    let src = skills_dir + "/" + entry
    let skill_md = src + "/SKILL.md"
    if !@sys.path_exists(skill_md) {
      let msg = "choir claude: user skill '" +
        entry +
        "' missing SKILL.md at " +
        skill_md
      @sys.write_stderr(msg + "\n")
      return Err(@types.ChoirError::workspace_error(msg))
    }
    let dst = plugin_dir + "/skills/" + entry
    if !@sys.copy_dir_recursive(src, dst) {
      return Err(
        @types.ChoirError::workspace_error("failed to copy user skill " + entry),
      )
    }
  }
  Ok(())
}

///|
fn synthesize_plugin_dir(
  project_dir : String,
  home : String,
) -> Result[Unit, @types.ChoirError] {
  let plugin_dir = project_dir + "/.choir/plugin"
  ignore(@sys.rm_rf(plugin_dir))

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

  if !@sys.create_dir_all(plugin_dir + "/skills/audit") {
    return Err(
      @types.ChoirError::workspace_error("failed to create skills/audit dir"),
    )
  }
  if !@sys.write_file_sync(
      plugin_dir + "/skills/audit/SKILL.md",
      audit_skill_body(),
    ) {
    return Err(
      @types.ChoirError::workspace_error("failed to write audit/SKILL.md"),
    )
  }

  if !@sys.create_dir_all(plugin_dir + "/skills/crystallize") {
    return Err(
      @types.ChoirError::workspace_error(
        "failed to create skills/crystallize dir",
      ),
    )
  }
  if !@sys.write_file_sync(
      plugin_dir + "/skills/crystallize/SKILL.md",
      crystallize_skill_body(),
    ) {
    return Err(
      @types.ChoirError::workspace_error("failed to write crystallize/SKILL.md"),
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

  merge_user_skills_into_plugin(plugin_dir, home)
}

///|
/// Build the `ClaudeCodeSettings` blob passed via `claude --settings <tempfile>`.
/// Synthesized per-invocation so bare `claude` runs see none of Choir's config.
fn build_claude_settings_json(
  role : @types.Role,
  session_name : String,
  user_mcp_path? : String? = None,
) -> String {
  let role_str = @config.role_to_string(role)
  // `alwaysLoad: true` opts out of Claude Code's tool-search deferral so the
  // TL has fork_wave / file_pr / merge_pr / wave_state / send_message / kv_*
  // / mutex_* etc. resolved up-front instead of paying a ToolSearch round-trip
  // on first use of each. Choir's MCP surface is the orchestration loop's hot
  // path; deferral was net cost, never net win.
  let mcp : Map[String, Json] = {
    "choir": {
      "type": "stdio".to_json(),
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role_str, "--name", session_name].to_json(),
      "alwaysLoad": true.to_json(),
    }.to_json(),
  }

  let merged_mcp = match user_mcp_path {
    Some(p) =>
      if @sys.path_exists(p) {
        let content = @sys.read_file(p)
        if content != "" {
          match @choir_commands.parse_mcp_config_json(content) {
            Ok(user_servers) => {
              let user_json : Map[String, Json] = {}
              for k, v in user_servers {
                let srv_obj : Map[String, Json] = {
                  "type": @choir_commands.mcp_transport_to_string(v.transport).to_json(),
                  "command": v.command.to_json(),
                }
                let args_json : Array[Json] = []
                for a in v.args {
                  args_json.push(a.to_json())
                }
                srv_obj.set("args", args_json.to_json())
                user_json.set(k, srv_obj.to_json())
              }
              match @choir_commands.merge_mcp_maps(mcp, user_json) {
                Ok(m) => m
                Err(e) => {
                  @sys.write_stderr("choir claude: " + e.message() + "\n")
                  @sys.exit(1)
                  mcp
                }
              }
            }
            Err(e) => {
              @sys.write_stderr(
                "choir claude: error parsing " + p + ": " + e.message() + "\n",
              )
              @sys.exit(1)
              mcp
            }
          }
        } else {
          mcp
        }
      } else {
        mcp
      }
    None =>
      match @choir_commands.user_mcp_json_path() {
        Ok(p) =>
          if @sys.path_exists(p) {
            let content = @sys.read_file(p)
            if content != "" {
              match @choir_commands.parse_mcp_config_json(content) {
                Ok(user_servers) => {
                  let user_json : Map[String, Json] = {}
                  for k, v in user_servers {
                    let srv_obj : Map[String, Json] = {
                      "type": @choir_commands.mcp_transport_to_string(
                        v.transport,
                      ).to_json(),
                      "command": v.command.to_json(),
                    }
                    let args_json : Array[Json] = []
                    for a in v.args {
                      args_json.push(a.to_json())
                    }
                    srv_obj.set("args", args_json.to_json())
                    user_json.set(k, srv_obj.to_json())
                  }
                  match @choir_commands.merge_mcp_maps(mcp, user_json) {
                    Ok(m) => m
                    Err(e) => {
                      @sys.write_stderr("choir claude: " + e.message() + "\n")
                      @sys.exit(1)
                      mcp
                    }
                  }
                }
                Err(e) => {
                  @sys.write_stderr(
                    "choir claude: error parsing " +
                    p +
                    ": " +
                    e.message() +
                    "\n",
                  )
                  @sys.exit(1)
                  mcp
                }
              }
            } else {
              mcp
            }
          } else {
            mcp
          }
        Err(_) => mcp
      }
  }

  let enabled_plugins : Map[String, Json] = { "choir@local": true.to_json() }
  let settings : Map[String, Json] = {
    "statusLine": {
      "type": "command".to_json(),
      "command": "choir statusline".to_json(),
    }.to_json(),
    "mcpServers": merged_mcp.to_json(),
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
/// Extract the `--lean` flag from forwarded args. When set, the wrapper
/// prepends `--system-prompt .` so Claude Code runs without its bloated
/// default system prompt — a workaround for Opus 4.7 performing better
/// without the tone/coding-style injections. Tool schemas, CLAUDE.md
/// loading, MCP servers, and skills are unaffected.
fn extract_lean_flag(args : Array[String]) -> (Bool, Array[String]) {
  let rest : Array[String] = []
  let mut lean = false
  for a in args {
    if a == "--lean" {
      lean = true
    } else {
      rest.push(a)
    }
  }
  (lean, rest)
}

///|
/// Spawn `claude` with a freshly synthesized `--settings <tempfile>` so statusline and choir MCP
/// wiring only apply to this invocation. Stops polluting project `.claude/settings.json`.
fn claude_wrapper_run() -> Unit {
  let args = @env.args()
  let forward_raw : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    forward_raw.push(args[i])
  }
  let (lean, forward) = extract_lean_flag(forward_raw)
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

  let home = match @sys.getenv("HOME") {
    Some(h) => if h == "" { "" } else { h }
    None => ""
  }

  match synthesize_plugin_dir(cwd, home) {
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
  if lean {
    claude_args.push("--system-prompt")
    claude_args.push(".")
  }
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
  @debug.assert_eq(top.get("name"), Some("choir".to_json()))
}

///|
test "skill bodies start with --- and have body" {
  let review = audit_skill_body()
  assert_true(review.has_prefix("---\n"))
  assert_true(review.length() > 20)

  let decompose = decompose_skill_body()
  assert_true(decompose.has_prefix("---\n"))
  assert_true(decompose.length() > 20)

  let crystallize = crystallize_skill_body()
  assert_true(crystallize.has_prefix("---\n"))
  assert_true(crystallize.length() > 20)
}

///|
test "crystallize_skill_body starts with frontmatter and has body" {
  let body = crystallize_skill_body()
  assert_true(body.has_prefix("---\nname: crystallize\n"))
  assert_true(body.contains("description:"))
  // Body exists after the closing ---
  let parts = body.split("---").to_array()
  // There should be a frontmatter block and content after the closing ---
  assert_true(parts.length() >= 3)
  let after_frontmatter = parts[2]
  assert_true(after_frontmatter.trim_start().length() > 0)
}

///|
test "decompose_skill_body does not contain .choir/spec/" {
  let body = decompose_skill_body()
  assert_false(body.contains(".choir/spec/"))
}

///|
test "decompose_skill_body contains .choir/context/" {
  let body = decompose_skill_body()
  assert_true(body.contains(".choir/context/"))
}

///|
test "audit_skill_body does not contain .choir/spec/" {
  let body = audit_skill_body()
  assert_false(body.contains(".choir/spec/"))
}

///|
test "audit_skill_body contains .choir/context/" {
  let body = audit_skill_body()
  assert_true(body.contains(".choir/context/"))
}

///|
test "audit_skill_body contains Sarcasmotron persona" {
  let review = audit_skill_body()
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
  let fake_home = "/tmp/choir-plugin-fake-home-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.rm_rf(fake_home))
  ignore(@sys.create_dir_all(tmp))

  match synthesize_plugin_dir(tmp, fake_home) {
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

  let review = @sys.read_file(tmp + "/.choir/plugin/skills/audit/SKILL.md")
  assert_true(review != "")

  let crystallize = @sys.read_file(
    tmp + "/.choir/plugin/skills/crystallize/SKILL.md",
  )
  assert_true(crystallize != "")

  let decompose = @sys.read_file(
    tmp + "/.choir/plugin/skills/decompose/SKILL.md",
  )
  assert_true(decompose != "")

  let hooks = @sys.read_file(tmp + "/.choir/plugin/hooks/hooks.json")
  assert_true(hooks != "")

  // Run again, must be identical
  match synthesize_plugin_dir(tmp, fake_home) {
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
test "synthesize_plugin_dir produces all three skill directories" {
  let tmp = "/tmp/choir-plugin-three-skills-" +
    @env.now().reinterpret_as_int64().to_string()
  let fake_home = "/tmp/choir-plugin-three-home-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.rm_rf(fake_home))
  ignore(@sys.create_dir_all(tmp))

  match synthesize_plugin_dir(tmp, fake_home) {
    Ok(_) => ()
    Err(e) => {
      fail("synthesize_plugin_dir failed: " + e.message())
      return
    }
  }

  // Verify all three builtin skill dirs exist
  assert_true(@sys.path_entry_exists(tmp + "/.choir/plugin/skills/audit"))
  assert_true(@sys.path_entry_exists(tmp + "/.choir/plugin/skills/crystallize"))
  assert_true(@sys.path_entry_exists(tmp + "/.choir/plugin/skills/decompose"))

  // Each has a SKILL.md
  assert_true(@sys.path_exists(tmp + "/.choir/plugin/skills/audit/SKILL.md"))
  assert_true(
    @sys.path_exists(tmp + "/.choir/plugin/skills/crystallize/SKILL.md"),
  )
  assert_true(
    @sys.path_exists(tmp + "/.choir/plugin/skills/decompose/SKILL.md"),
  )

  ignore(@sys.rm_rf(tmp))
}

///|
test "synthesize_plugin_dir removes stale user skill on rerun" {
  let tmp = "/tmp/choir-plugin-stale-test-" +
    @env.now().reinterpret_as_int64().to_string()
  let fake_home = "/tmp/choir-plugin-stale-home-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.rm_rf(fake_home))
  ignore(@sys.create_dir_all(tmp + "/.choir/plugin/skills/stale"))
  ignore(
    @sys.write_file_sync(tmp + "/.choir/plugin/skills/stale/SKILL.md", "stale"),
  )

  match synthesize_plugin_dir(tmp, fake_home) {
    Ok(_) => ()
    Err(e) => fail("synthesize_plugin_dir failed: " + e.message())
  }

  assert_false(@sys.path_entry_exists(tmp + "/.choir/plugin/skills/stale"))

  ignore(@sys.rm_rf(tmp))
  ignore(@sys.rm_rf(fake_home))
}

///|
test "merge_user_skills_into_plugin copies valid user skills" {
  let home = "/tmp/choir-plugin-test-home-" +
    @env.now().reinterpret_as_int64().to_string()
  let plugin_dir = "/tmp/choir-plugin-test-dir-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))

  let skills_dir = home + "/.config/choir/skills"
  ignore(@sys.create_dir_all(skills_dir + "/my-skill"))
  ignore(@sys.write_file_sync(skills_dir + "/my-skill/SKILL.md", "hello"))

  match merge_user_skills_into_plugin(plugin_dir, home) {
    Ok(_) => ()
    Err(e) => fail("merge failed: " + e.message())
  }

  assert_eq(@sys.read_file(plugin_dir + "/skills/my-skill/SKILL.md"), "hello")

  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))
}

///|
test "merge_user_skills_into_plugin returns Err on clash" {
  let home = "/tmp/choir-plugin-test-home-clash-" +
    @env.now().reinterpret_as_int64().to_string()
  let plugin_dir = "/tmp/choir-plugin-test-dir-clash-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))

  let skills_dir = home + "/.config/choir/skills"
  ignore(@sys.create_dir_all(skills_dir + "/audit"))
  ignore(@sys.write_file_sync(skills_dir + "/audit/SKILL.md", "hello"))

  match merge_user_skills_into_plugin(plugin_dir, home) {
    Ok(_) => fail("merge should have failed")
    Err(e) => assert_true(e.message().contains("clashes with builtin"))
  }

  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))
}

///|
test "merge_user_skills_into_plugin returns Err on crystallize clash" {
  let home = "/tmp/choir-plugin-test-home-crystallize-clash-" +
    @env.now().reinterpret_as_int64().to_string()
  let plugin_dir = "/tmp/choir-plugin-test-dir-crystallize-clash-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))

  let skills_dir = home + "/.config/choir/skills"
  ignore(@sys.create_dir_all(skills_dir + "/crystallize"))
  ignore(@sys.write_file_sync(skills_dir + "/crystallize/SKILL.md", "hello"))

  match merge_user_skills_into_plugin(plugin_dir, home) {
    Ok(_) => fail("merge should have failed for crystallize clash")
    Err(e) => assert_true(e.message().contains("clashes with builtin"))
  }

  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))
}

///|
test "merge_user_skills_into_plugin returns Err when SKILL.md is missing" {
  let home = "/tmp/choir-plugin-test-home-missing-skill-md-" +
    @env.now().reinterpret_as_int64().to_string()
  let plugin_dir = "/tmp/choir-plugin-test-dir-missing-skill-md-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))

  let skills_dir = home + "/.config/choir/skills"
  ignore(@sys.create_dir_all(skills_dir + "/broken"))

  match merge_user_skills_into_plugin(plugin_dir, home) {
    Ok(_) => fail("merge should have failed")
    Err(e) => assert_true(e.message().contains("missing SKILL.md"))
  }

  ignore(@sys.rm_rf(home))
  ignore(@sys.rm_rf(plugin_dir))
}

///|
test "build_claude_settings_json emits statusline and choir MCP stdio entry" {
  let tmp = "/tmp/choir-settings-empty-mcp-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let body = build_claude_settings_json(
    @types.Role::TL,
    "user-123-456",
    user_mcp_path=Some(tmp + "/missing-mcp.json"),
  )
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
  @debug.assert_eq(status.get("type"), Some("command".to_json()))
  @debug.assert_eq(status.get("command"), Some("choir statusline".to_json()))
  guard top.get("mcpServers") is Some(Object(servers)) else {
    fail("mcpServers missing or not an object")
    return
  }
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("mcpServers.choir missing or not an object")
    return
  }
  @debug.assert_eq(choir.get("type"), Some("stdio".to_json()))
  @debug.assert_eq(choir.get("command"), Some("choir".to_json()))
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
  // Claude Code's tool-search deferral is opt-out via `alwaysLoad: true`. The
  // TL hits choir's orchestration tools constantly; deferring them costs more
  // than it saves.
  @debug.assert_eq(choir.get("alwaysLoad"), Some(true.to_json()))
  guard top.get("enabledPlugins") is Some(Object(plugins)) else {
    fail("enabledPlugins missing or not an object")
    return
  }
  @debug.assert_eq(plugins.get("choir@local"), Some(true.to_json()))
  ignore(@sys.rm_rf(tmp))
}

///|
test "build_claude_settings_json merges user MCP from injected path" {
  let tmp = "/tmp/choir-settings-user-mcp-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let path = tmp + "/mcp.json"
  ignore(
    @sys.write_file_sync(
      path, "{\"servers\":{\"linear\":{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@linear/mcp-server\"]}}}",
    ),
  )

  let body = build_claude_settings_json(
    @types.Role::TL,
    "user-123-456",
    user_mcp_path=Some(path),
  )
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
  guard top.get("mcpServers") is Some(Object(servers)) else {
    fail("mcpServers missing or not an object")
    return
  }
  guard servers.get("linear") is Some(Object(linear)) else {
    fail("mcpServers.linear missing or not an object")
    return
  }
  @debug.assert_eq(linear.get("command"), Some("npx".to_json()))
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("mcpServers.choir missing or not an object")
    return
  }
  @debug.assert_eq(choir.get("command"), Some("choir".to_json()))

  ignore(@sys.rm_rf(tmp))
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

///|
test "extract_lean_flag strips --lean and preserves order of other args" {
  let (lean, rest) = extract_lean_flag(["--print", "--lean", "hello", "--foo"])
  assert_true(lean)
  assert_eq(rest.length(), 3)
  assert_eq(rest[0], "--print")
  assert_eq(rest[1], "hello")
  assert_eq(rest[2], "--foo")
}

///|
test "extract_lean_flag returns false when --lean absent" {
  let (lean, rest) = extract_lean_flag(["--print", "hello"])
  assert_false(lean)
  assert_eq(rest.length(), 2)
}

///|
test "extract_lean_flag handles multiple --lean occurrences idempotently" {
  let (lean, rest) = extract_lean_flag(["--lean", "x", "--lean"])
  assert_true(lean)
  assert_eq(rest.length(), 1)
  assert_eq(rest[0], "x")
}
