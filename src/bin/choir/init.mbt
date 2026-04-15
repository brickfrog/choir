///|
fn init_no_attach(args : Array[String]) -> Bool {
  args.contains("--no-attach")
}

///|
fn init_kill_session_command(session : String) -> @workspace.Command {
  @workspace.zellij_kill_session(session)
}

///|
async fn init_tab_exists(session : String, tab_name : String) -> Bool {
  try {
    let (code, output) = @exec.capture_command_merged(
      @workspace.zellij_query_tab_names_command(session),
    )
    if code != 0 {
      false
    } else {
      @workspace.zellij_tab_name_exists_in_query_output(output, tab_name)
    }
  } catch {
    _ => false
  }
}

///|
fn init_parse_server_pid_line(s : String) -> Int? {
  Some(@string.parse_int(s.trim().to_string())) catch {
    _ => None
  }
}

///|
fn init_kill_server_pid_string(pid_str : String) -> Unit {
  match init_parse_server_pid_line(pid_str) {
    Some(pid) => @sys.kill_server_pid_sequence_best_effort(pid)
    None => ()
  }
}

///|
/// Exit code compatible with former `sh -c '...kill -0...'`: 0 when `.choir/server.pid` parses to a
/// live PID, else non-zero.
fn init_server_running_exit_code() -> Int {
  let raw = @sys.read_file(".choir/server.pid")
  match init_parse_server_pid_line(raw) {
    Some(pid) => if @sys.pid_is_alive(pid) { 0 } else { 1 }
    None => 1
  }
}

///|
fn init_should_launch_server_tab(server_alive : Bool) -> Bool {
  !server_alive
}

///|
/// Relative paths removed by runtime-only cleanup (mirrors native `choir_init_cleanup_runtime_artifacts`).
fn init_runtime_cleanup_paths() -> Array[String] {
  [".choir/server.pid", ".choir/server.sock", ".choir/run_id"]
}

///|
/// Markers for purge-only cleanup (mirrors native `choir_init_cleanup_purge_artifacts`).
fn init_purge_cleanup_marker_substrings() -> Array[String] {
  [
    ".choir/worktrees", ".choir/inline", ".choir/poller_state.json", "lifecycle--",
    "children--", "phase-dev--", "phase-tl--",
  ]
}

///|
test "init session lifecycle commands use zellij" {
  let list_cmd = @workspace.zellij_list_sessions_command()
  assert_eq(list_cmd.program, "env")
  assert_eq(list_cmd.args, ["NO_COLOR=1", "zellij", "list-sessions"])

  let tab_q = @workspace.zellij_query_tab_names_command("choir")
  assert_eq(tab_q.program, "env")
  assert_eq(tab_q.args, [
    "NO_COLOR=1", "zellij", "--session", "choir", "action", "query-tab-names",
  ])

  let kill = init_kill_session_command("choir")
  assert_eq(kill.args, ["delete-session", "--force", "choir"])
}

///|
test "cleanup paths separate runtime restart from purge" {
  let rt = init_runtime_cleanup_paths()
  assert_eq(rt.length(), 3)
  for p in rt {
    assert_false(p.contains("worktrees"))
    assert_false(p.contains("poller"))
    assert_false(p.contains("inline"))
  }
  let purge = init_purge_cleanup_marker_substrings()
  assert_true(purge.length() >= 4)
  let mut has_wt = false
  let mut has_poller = false
  for m in purge {
    if m == ".choir/worktrees" {
      has_wt = true
    }
    if m == ".choir/poller_state.json" {
      has_poller = true
    }
  }
  assert_true(has_wt)
  assert_true(has_poller)
}

///|
test "init server cleanup commands separate runtime restart from purge" {
  assert_eq(init_parse_server_pid_line("123"), Some(123))
  assert_eq(init_parse_server_pid_line(" 42 \n"), Some(42))
  assert_eq(init_parse_server_pid_line(""), None)
  assert_eq(init_parse_server_pid_line("12a"), None)
  assert_true(@sys.pid_is_alive(@sys.get_pid()))
  assert_true(init_should_launch_server_tab(false))
  assert_false(init_should_launch_server_tab(true))
  let rt = init_runtime_cleanup_paths()
  assert_eq(rt.length(), 3)
  for p in rt {
    assert_false(p.contains("worktrees"))
    assert_false(p.contains("poller"))
  }
  let purge = init_purge_cleanup_marker_substrings()
  let mut has_inline = false
  for m in purge {
    if m == ".choir/inline" {
      has_inline = true
    }
  }
  assert_true(has_inline)
}

///|
fn init_default_terminal_session(project_dir : String) -> String {
  let mut end = project_dir.length()
  while end > 1 && project_dir[end - 1] == '/' {
    end = end - 1
  }
  let trimmed = project_dir[:end].to_string()
  let base = if trimmed == "" {
    "project"
  } else {
    let mut last_slash = -1
    for i = 0; i < trimmed.length(); i = i + 1 {
      if trimmed[i] == '/' {
        last_slash = i
      }
    }
    if last_slash < 0 || last_slash + 1 >= trimmed.length() {
      trimmed
    } else {
      trimmed[last_slash + 1:].to_string()
    }
  }
  let buf = StringBuilder::new()
  for c in base {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' {
      buf.write_char(c)
    } else {
      buf.write_char('-')
    }
  }
  let normalized_raw = buf.to_string()
  let mut start = 0
  let mut finish = normalized_raw.length()
  while start < finish && normalized_raw[start] == '-' {
    start = start + 1
  }
  while finish > start && normalized_raw[finish - 1] == '-' {
    finish = finish - 1
  }
  let suffix = normalized_raw[start:finish].to_string()
  let normalized = if suffix == "" { "project" } else { suffix }
  "choir-" + normalized
}

///|
fn init_config_toml_content(default_session : String) -> String {
  "default_role = \"tl\"\n" +
  "project_dir = \".\"\n" +
  "listen_uds = \".choir/server.sock\"\n" +
  "terminal_session = \"" +
  default_session +
  "\"\n"
}

///|
fn init_config_has_terminal_session(content : String) -> Bool {
  content.contains("terminal_session")
}

///|
fn init_parse_tl_type(args : Array[String]) -> String {
  for i = 0; i < args.length() - 1; i = i + 1 {
    if args[i] == "--tl" {
      return @workspace.normalize_tl_type(args[i + 1])
    }
  }
  "claude"
}

///|
test "init TL launch command defaults to claude" {
  let cmd = @workspace.init_tl_agent_command("claude", ".")
  let s = cmd.to_string()
  assert_true(s.contains("claude"))
  assert_true(s.contains("--dangerously-skip-permissions"))
  assert_true(s.contains("--mcp-config"))
  assert_true(s.contains("mcp-stdio"))
  assert_true(s.contains("--name"))
  assert_true(s.contains("root"))
}

///|
test "init TL launch command supports codex" {
  let cmd = @workspace.init_tl_agent_command("codex", "/tmp/choir repo")
  let s = cmd.to_string()
  assert_true(s.contains("codex"))
  assert_true(s.contains("--dangerously-bypass-approvals-and-sandbox"))
  assert_true(s.contains("--no-alt-screen"))
  assert_true(s.contains("mcp_servers.choir.command=\"choir\""))
  assert_true(s.contains("mcp-stdio"))
  assert_true(s.contains("--raw-stdio"))
  assert_true(s.contains("--name"))
  assert_true(s.contains("mcp_servers.choir.cwd=\"/tmp/choir repo\""))
  assert_true(s.contains("-C"))
  assert_true(s.contains("/tmp/choir repo"))
  assert_false(s.contains("--mcp-config"))
}

///|
test "init TL launch command supports cursor_agent" {
  let cmd = @workspace.init_tl_agent_command("cursor_agent", "/tmp/choir repo")
  let s = cmd.to_string()
  assert_true(s.contains("agent"))
  assert_true(s.contains("--yolo"))
  assert_true(s.contains("--approve-mcps"))
  assert_true(s.contains("--workspace"))
  assert_true(s.contains("/tmp/choir repo"))
  assert_false(s.contains("--mcp-config"))
}

///|
test "init TL launch command supports agent alias" {
  let cmd = @workspace.init_tl_agent_command("agent", "/tmp/choir repo")
  let s = cmd.to_string()
  assert_true(s.contains("agent"))
  assert_true(s.contains("--yolo"))
  assert_true(s.contains("--approve-mcps"))
  assert_true(s.contains("--workspace"))
  assert_true(s.contains("/tmp/choir repo"))
  assert_false(s.contains("--mcp-config"))
}

///|
test "init parse_tl_type extracts --tl flag" {
  assert_eq(init_parse_tl_type(["choir", "init", "--tl", "codex"]), "codex")
  assert_eq(init_parse_tl_type(["choir", "init"]), "claude")
  assert_eq(
    init_parse_tl_type(["choir", "init", "--recreate", "--tl", "gemini"]),
    "gemini",
  )
  assert_eq(init_parse_tl_type(["choir", "init", "--tl", "codex"]), "codex")
  assert_eq(
    init_parse_tl_type(["choir", "init", "--tl", "agent"]),
    "cursor_agent",
  )
}

///|
fn init_split_words(s : String) -> Array[String] {
  let parts : Array[String] = []
  let trimmed = s.trim().to_string()
  let mut start = 0
  for i = 0; i <= trimmed.length(); i = i + 1 {
    if i == trimmed.length() || trimmed[i] == ' ' {
      if i > start {
        parts.push(trimmed[start:i].to_string())
      }
      start = i + 1
    }
  }
  parts
}

///|
fn init_companion_role(role : String) -> @types.Role {
  match @config.parse_role(role) {
    Ok(parsed) => parsed
    Err(_) => @types.Role::Worker
  }
}

///|
fn init_companion_branch(parent_branch : String, name : String) -> String {
  parent_branch + ".companion." + name
}

///|
fn init_companion_agent_type(command : String) -> @types.AgentType? {
  let parts = init_split_words(command)
  if parts.is_empty() {
    return None
  }
  let first = parts[0]
  if first == "claude" || first.has_suffix("/claude") {
    return Some(@types.AgentType::Claude)
  }
  if first == "gemini" || first.has_suffix("/gemini") {
    return Some(@types.AgentType::Gemini)
  }
  if (first == "moon" || first.has_suffix("/moon")) &&
    parts.length() > 1 &&
    parts[1] == "pilot" {
    return Some(@types.AgentType::MoonPilot)
  }
  if first == "codex" || first.has_suffix("/codex") {
    return Some(@types.AgentType::Codex)
  }
  if first == "agent" || first.has_suffix("/agent") {
    return Some(@types.AgentType::CursorAgent)
  }
  None
}

///|
fn init_companion_commands(
  project_dir : String,
  session : String,
  config : @types.Config,
  current_branch : String,
  companion : @config.CompanionDef,
) -> Array[@workspace.Command] {
  let role = init_companion_role(companion.role)
  let branch = init_companion_branch(current_branch, companion.name)
  let workspace = project_dir + "/.choir/agents/" + companion.name
  let terminal_target = @workspace.local_target_for(
    session,
    companion.name,
    @types.IsolationMode::Worktree,
  )
  let agent_type_opt = init_companion_agent_type(companion.command)
  let agent_type = agent_type_opt.unwrap_or(@types.AgentType::Gemini)
  let spec : @types.SpawnSpec = {
    slug: "companion." + companion.name,
    role,
    agent_type,
    task: companion.task,
    task_contract: None,
    isolation: @types.IsolationMode::Standalone,
    parent_id: "root",
    parent_branch: current_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: Some(branch),
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
  }
  let env_z = @workspace.launch_env_assignments(
    spec, session, workspace, terminal_target,
  )
  let inner = {
    let c = @workspace.agent_launch_command(
      spec,
      workspace,
      command_override=Some(companion.command),
      extra_mcp_servers_json=config.extra_mcp_servers_json,
    )
    { ..c, workdir: None }
  }
  let cmds : Array[@workspace.Command] = [
    @workspace.git_worktree_bootstrap_cleanup_best_effort(
      project_dir, workspace, branch,
    ),
    @workspace.git_worktree_add(workspace, branch, current_branch),
    @workspace.write_spawn_config(
      workspace,
      @workspace.child_config_content(
        role,
        session,
        project_dir,
        config.listen_uds,
        listen_tcp=config.listen_tcp,
        tcp_auth_token=config.tcp_auth_token,
      ),
    ),
    @workspace.write_local_config(
      workspace,
      @workspace.config_local_content(spec, workspace, terminal_target),
    ),
    @workspace.write_leaf_helper_scripts(workspace),
    @workspace.workspace_relative_file_command(
      workspace, ".birth_branch", branch,
    ),
  ]
  if agent_type == @types.AgentType::Gemini {
    cmds.push(@workspace.trust_gemini_folder(workspace))
  }
  if agent_type == @types.AgentType::CursorAgent {
    cmds.push(
      @workspace.write_cursor_mcp_json(
        workspace,
        branch,
        @config.role_to_string(role),
      ),
    )
  }
  cmds.push(
    @workspace.zellij_new_tab(session, companion.name, workspace, env_z, inner),
  )
  cmds
}

///|
fn init_is_choir_source_files(
  moon_mod_content : String,
  main_mbt_content : String,
) -> Bool {
  main_mbt_content != "" &&
  (
    moon_mod_content.contains("\"name\": \"choir\"") ||
    moon_mod_content.contains("\"name\":\"choir\"")
  )
}

///|
fn init_is_choir_source_tree(project_dir : String) -> Bool {
  init_is_choir_source_files(
    @sys.read_file(project_dir + "/moon.mod.json"),
    @sys.read_file(project_dir + "/src/bin/choir/main.mbt"),
  )
}

///|
async fn init_run_or_exit(cmd : @workspace.Command) -> Unit {
  let exit_code = @exec.run(cmd) catch { _ => 1 }
  if exit_code != 0 {
    @sys.exit(exit_code)
  }
}

///|
fn init_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let args = @env.args()
      let recreate = args.contains("--recreate")
      let purge = args.contains("--purge")
      let no_attach = init_no_attach(args)
      let tl_type = init_parse_tl_type(args)
      let project_dir = @env.current_dir().unwrap_or(".")
      let default_session = init_default_terminal_session(project_dir)
      let use_dev = init_is_choir_source_tree(project_dir)

      if use_dev {
        // Rebuild binary before doing anything else so the new server uses fresh code
        init_run_or_exit({
          program: "moon",
          args: ["build", "--target", "native", "--release"],
          workdir: None,
        })
      }

      init_bootstrap_ensure_choir_dir_and_config_if_absent(
        init_config_toml_content(default_session),
      )
      // Set up Claude Code statusline if .claude/settings.json doesn't exist
      init_bootstrap_seed_claude_settings_best_effort()
      let maybe_patch_config = @sys.read_file(".choir/config.toml")
      if maybe_patch_config != "" &&
        !init_config_has_terminal_session(maybe_patch_config) {
        let separator = if maybe_patch_config.has_suffix("\n") {
          ""
        } else {
          "\n"
        }
        let patched = maybe_patch_config +
          separator +
          "terminal_session = \"" +
          default_session +
          "\"\n"
        ignore(@sys.write_file_sync(".choir/config.toml", patched))
      }
      let config_content = @sys.read_file(".choir/config.toml")
      let config = match @config.parse_config(config_content) {
        Ok(cfg) => cfg
        Err(_) => @types.Config::default()
      }
      let current_branch_raw = @exec.capture_stdout("git", [
        "branch", "--show-current",
      ])
      let current_branch_trimmed = current_branch_raw.trim().to_string()
      let current_branch = if current_branch_trimmed == "" ||
        current_branch_trimmed == "HEAD" {
        "main"
      } else {
        current_branch_trimmed
      }
      let session = config.terminal_session

      if recreate {
        let pid_str = @sys.read_file(".choir/server.pid")
        if pid_str != "" {
          @sys.write_stdout("Stopping server (PID \{pid_str})...\n")
          init_kill_server_pid_string(pid_str)
          if purge {
            @sys.init_cleanup_purge_artifacts_native()
          } else {
            @sys.init_cleanup_runtime_artifacts_native()
          }
        }
        @sys.write_stdout("Killing session \{session}...\n")
        ignore(@exec.run(init_kill_session_command(session)) catch { _ => 0 })
      }

      let session_alive = try {
        let (code, output) = @exec.capture_command_merged(
          @workspace.zellij_list_sessions_command(),
        )
        if code != 0 {
          1
        } else if @workspace.zellij_session_exists_in_list_output(
            output, session,
          ) {
          0
        } else {
          1
        }
      } catch {
        _ => 1
      }
      let server_alive = init_server_running_exit_code()
      if session_alive == 0 {
        if no_attach {
          @sys.write_stdout("Session \{session} already exists.\n")
        } else {
          @sys.write_stdout("Attaching to existing session \{session}...\n")
          ignore(
            @exec.run(@workspace.zellij_attach_session(session)) catch {
              _ => 0
            },
          )
        }
        return
      }

      let birth_branch_stdout = @exec.capture_stdout("git", [
        "branch", "--show-current",
      ])
      init_bootstrap_write_root_birth_branch_best_effort(
        project_dir, birth_branch_stdout,
      )

      @sys.write_stdout("Creating session \{session}...\n")
      init_run_or_exit(@workspace.zellij_create_background_session(session))
      let server_tab_exists = init_tab_exists(session, "Server") catch {
        _ => false
      }
      if !server_tab_exists {
        if init_should_launch_server_tab(server_alive == 0) {
          init_run_or_exit(
            @workspace.zellij_new_tab(session, "Server", project_dir, [], {
              program: "choir",
              args: ["serve"],
              workdir: None,
            }),
          )
        } else {
          @sys.write_stdout("Reusing existing server process.\n")
        }
      } else {
        @sys.write_stdout("Reusing existing Server tab.\n")
      }
      let tl_tab_exists = init_tab_exists(session, "TL") catch { _ => false }
      if !tl_tab_exists {
        let tl_agent_type = @workspace.tl_type_agent_type(tl_type)
        let tl_materialization = @workspace.provider_materialization_commands(
          tl_agent_type,
          project_dir,
          project_dir,
          "root",
          @types.Role::TL,
        )
        for cmd in tl_materialization {
          ignore(@exec.run(cmd) catch { _ => 0 })
        }
        init_run_or_exit(
          @workspace.init_tl_zellij_tab_command(
            session, project_dir, tl_type, current_branch,
          ),
        )
      } else {
        @sys.write_stdout("Reusing existing TL tab.\n")
      }
      ignore(
        @exec.run({
          program: "zellij",
          args: ["--session", session, "action", "close-tab-by-id", "0"],
          workdir: None,
        }) catch {
          _ => 0
        },
      )
      ignore(
        @exec.run({
          program: "zellij",
          args: ["--session", session, "action", "go-to-tab-name", "TL"],
          workdir: None,
        }) catch {
          _ => 0
        },
      )

      match config.companions_json {
        Some(json) => {
          let companions = @config.parse_companions_json(json)
          for c in companions {
            for
              cmd in init_companion_commands(
                project_dir, session, config, current_branch, c,
              ) {
              ignore(@exec.run(cmd) catch { _ => 0 })
            }
            @sys.write_stdout("Spawned companion: \{c.name}\n")
          }
        }
        None => ()
      }

      @sys.write_stdout("Waiting for server socket...\n")
      if !@sys.wait_for_socket(config.listen_uds, 60) {
        @sys.write_stdout("Warning: server socket not ready after 30s\n")
      } else {
        @sys.write_stdout("Server ready.\n")
      }

      if no_attach {
        @sys.write_stdout("Session \{session} ready.\n")
      } else {
        @sys.write_stdout("Attaching to session \{session}...\n")
        ignore(
          @exec.run(@workspace.zellij_attach_session(session)) catch {
            _ => 0
          },
        )
      }
    })
  })
}
