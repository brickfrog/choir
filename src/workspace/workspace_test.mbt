///|
test "worktree path construction" {
  let path = @workspace.worktree_path("/home/user/project", "feature-a")
  assert_eq(path, "/home/user/project/.choir/worktrees/feature-a")
}

///|
test "branch name construction" {
  let branch = @workspace.branch_name("main", "feature-a")
  assert_eq(branch, "main.feature-a")
}

///|
test "nested branch name" {
  let branch = @workspace.branch_name("main.subtl", "leaf-task")
  assert_eq(branch, "main.subtl.leaf-task")
}

///|
test "inline agent metadata dir sanitizes agent id" {
  let path = @workspace.inline_agent_metadata_dir("/repo", "feature/x.worker")
  assert_eq(path, "/repo/.choir/inline/feature_x.worker")
}

///|
test "parent branch extracts from nested branch" {
  @debug.assert_eq(
    @workspace.parent_branch("main.subtl.leaf-task"),
    Some("main.subtl"),
  )
}

///|
test "parent branch returns none for root branch" {
  @debug.assert_eq(@workspace.parent_branch("main"), None)
}

///|
test "canonical agent id uses parent branch and slug" {
  let spec = @types.SpawnSpec::{
    slug: "leaf-task",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main.subtl",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  assert_eq(@workspace.canonical_agent_id(spec), "main.subtl.leaf-task")
}

///|
test "git_worktree_add args" {
  let cmd = @workspace.git_worktree_add(
    "/path/to/worktree", "main.test-slug", "main",
  )
  assert_eq(cmd.program, "git")
  @debug.assert_eq(cmd.args, [
    "worktree", "add", "/path/to/worktree", "-b", "main.test-slug", "main",
  ])
}

///|
test "agent_runtime_gitexclude_snippet lists agent runtime dirs" {
  let s = @workspace.agent_runtime_gitexclude_snippet()
  assert_true(s.contains(".cursor/"))
  assert_true(s.contains(".codex/"))
  assert_true(s.contains(".gemini/"))
  assert_true(s.contains(".antigravitycli/"))
  assert_true(s.contains(".choir/agy-home/"))
  assert_false(s.contains(".claude/"))
  assert_true(s.contains("# choir: agent-runtime junk"))
}

///|
test "git_fetch_origin_branch_best_effort runs fetch in project dir" {
  let cmd = @workspace.git_fetch_origin_branch_best_effort("/repo", "main")
  assert_eq(
    cmd.program,
    @workspace.native_git_fetch_origin_branch_best_effort_program,
  )
  @debug.assert_eq(cmd.args, ["/repo", "main"])
}

///|
test "parse_local_target supports zellij targets" {
  match @types.LocalTarget::parse("zellij-tab:howdy:leaf-a") {
    Some(target) => {
      assert_eq(target.kind, @types.TargetKind::ZellijTab)
      assert_eq(target.session, "howdy")
      assert_eq(target.name, "leaf-a")
    }
    None => fail("expected zellij tab target")
  }
  match @types.LocalTarget::parse("zellij-pane:howdy:worker-a") {
    Some(target) => {
      assert_eq(target.kind, @types.TargetKind::ZellijPane)
      assert_eq(target.session, "howdy")
      assert_eq(target.name, "worker-a")
    }
    None => fail("expected zellij pane target")
  }
}

///|
test "zellij_new_tab uses env argv without sh -lc" {
  let cmd = @workspace.zellij_new_tab(
    "howdy",
    "leaf-a",
    "/path/to/worktree",
    [],
    { program: "echo", args: ["READY"], workdir: None },
  )
  assert_eq(cmd.program, "zellij")
  @debug.assert_eq(cmd.args, [
    "--session", "howdy", "action", "new-tab", "--name", "leaf-a", "--cwd", "/path/to/worktree",
    "--", "env", "echo", "READY",
  ])
}

///|
test "zellij_new_tab_shell keeps sh -lc for script launches" {
  let cmd = @workspace.zellij_new_tab_shell(
    "howdy", "TL", "/proj", "claude; echo done",
  )
  assert_eq(cmd.args[9], "sh")
  assert_eq(cmd.args[10], "-lc")
  assert_eq(cmd.args[11], "claude; echo done")
}

///|
test "init_tl_zellij_tab_command wraps TL with policy watcher shell" {
  let cmd = @workspace.init_tl_zellij_tab_command(
    "howdy", "/proj", "claude", "main",
  )
  assert_eq(cmd.program, "zellij")
  assert_eq(cmd.args[9], "sh")
  assert_eq(cmd.args[10], "-lc")
  let script = cmd.args[11]
  assert_true(script.contains("claude"))
  assert_true(script.contains("CHOIR_AGENT_ID='root'"))
  assert_true(script.contains("CHOIR_BRANCH='main'"))
  assert_false(script.contains("HOME="))
  assert_true(script.contains("choir tl-policy-watch --pid"))
  assert_true(script.contains("exec claude"))
  assert_false(script.contains("child_pid=$!"))
  assert_true(script.contains("[TL exited]"))
  assert_true(script.contains("exec bash -l"))
  // Every TL exit appends its timestamped exit code to .choir/tl-exits.log
  // so a silent harness crash is still diagnosable (choir-eek); a HUP/TERM
  // trap keeps the outer shell alive past those signals so the exit code is
  // still recorded.
  assert_true(script.contains(".choir/tl-exits.log"))
  assert_true(script.contains("exit=%s"))
  assert_true(script.contains("trap "))
  assert_true(script.contains("HUP TERM"))
  assert_true(script.contains("[TL wrapper caught signal]"))
}

///|
test "init_tl_zellij_tab_command exports HOME only for gemini TL" {
  let gemini = @workspace.init_tl_zellij_tab_command(
    "howdy", "/proj", "gemini", "main",
  )
  let gemini_script = gemini.args[11]
  assert_true(gemini_script.contains("HOME='/proj/.choir/agy-home'"))
  assert_true(gemini_script.contains("CHOIR_AGENT_ID='root'"))

  let claude = @workspace.init_tl_zellij_tab_command(
    "howdy", "/proj", "claude", "main",
  )
  let claude_script = claude.args[11]
  assert_false(claude_script.contains("HOME='/proj/.choir/agy-home'"))
  assert_false(claude_script.contains("HOME="))
}

///|
test "normalize_tl_type maps agent alias" {
  assert_eq(@workspace.normalize_tl_type("agent"), "cursor_agent")
  assert_eq(@workspace.normalize_tl_type("cursor_agent"), "cursor_agent")
  assert_eq(@workspace.normalize_tl_type("codex"), "codex")
}

///|
test "agy_binary_name resolves agy only" {
  assert_eq(@workspace.agy_binary_name(), "agy")
}

///|
test "init_tl_agent_command supports agent alias for cursor" {
  let cmd = @workspace.init_tl_agent_command("agent", "/repo")
  assert_eq(cmd.program, "agent")
  assert_eq(cmd.args[0], "--yolo")
  assert_eq(cmd.args[1], "--approve-mcps")
  assert_eq(cmd.args[2], "--workspace")
  assert_eq(cmd.args[3], "/repo")
}

///|
test "zellij_list_sessions_command uses env argv without shell" {
  let cmd = @workspace.zellij_list_sessions_command()
  assert_eq(cmd.program, "env")
  @debug.assert_eq(cmd.args, ["NO_COLOR=1", "zellij", "list-sessions"])
}

///|
test "zellij_session_exists_in_list_output matches active session first field" {
  assert_true(
    @workspace.zellij_session_exists_in_list_output(
      "choir (attached)\n", "choir",
    ),
  )
  assert_false(
    @workspace.zellij_session_exists_in_list_output("choir (EXITED)\n", "choir"),
  )
  assert_false(
    @workspace.zellij_session_exists_in_list_output(
      "choir-extra (attached)\n", "choir",
    ),
  )
  assert_true(
    @workspace.zellij_session_exists_in_list_output(
      "other\nchoir (attached)\n", "choir",
    ),
  )
}

///|
test "zellij_session_exists_in_list_output strips ansi" {
  let esc = "\u{1b}[32m"
  let reset = "\u{1b}[0m"
  let line = esc + "choir" + reset + " (attached)\n"
  assert_true(@workspace.zellij_session_exists_in_list_output(line, "choir"))
}

///|
test "zellij_query_tab_names_command uses env argv without shell" {
  let cmd = @workspace.zellij_query_tab_names_command("my-session")
  assert_eq(cmd.program, "env")
  @debug.assert_eq(cmd.args, [
    "NO_COLOR=1", "zellij", "--session", "my-session", "action", "query-tab-names",
  ])
}

///|
test "zellij_tab_name_exists_in_query_output matches exact line only" {
  assert_true(@workspace.zellij_tab_name_exists_in_query_output("TL\n", "TL"))
  assert_true(
    @workspace.zellij_tab_name_exists_in_query_output("Server\nTL\n", "TL"),
  )
  assert_false(
    @workspace.zellij_tab_name_exists_in_query_output("TL-2\n", "TL"),
  )
  assert_false(@workspace.zellij_tab_name_exists_in_query_output("", "TL"))
}

///|
test "zellij_tab_name_exists_in_query_output strips ansi" {
  let esc = "\u{1b}[32m"
  let reset = "\u{1b}[0m"
  let out = "Server\n" + esc + "TL" + reset + "\n"
  assert_true(@workspace.zellij_tab_name_exists_in_query_output(out, "TL"))
}

///|
test "agent_launch_command for each AgentType" {
  let spec_claude = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let spec_gemini = { ..spec_claude, agent_type: @types.AgentType::Gemini }
  let spec_moon = { ..spec_claude, agent_type: @types.AgentType::MoonPilot }
  let spec_codex = { ..spec_claude, agent_type: @types.AgentType::Codex }

  let cmd_claude = @workspace.agent_launch_command(spec_claude, "/path")
  let cmd_gemini = @workspace.agent_launch_command(spec_gemini, "/path")
  let cmd_moon = @workspace.agent_launch_command(spec_moon, "/path")
  let cmd_codex = @workspace.agent_launch_command(spec_codex, "/path")

  assert_eq(cmd_claude.program, "claude")
  assert_eq(cmd_claude.args[0], "--dangerously-skip-permissions")
  assert_eq(cmd_claude.args[1], "--mcp-config")
  assert_true(cmd_claude.args[2].contains("\"mcpServers\""))
  assert_true(cmd_claude.args[2].contains("\"--role\",\"dev\""))
  assert_true(cmd_claude.args[2].contains("\"--name\",\"main.test-slug\""))
  assert_eq(cmd_claude.args[3], "--strict-mcp-config")
  assert_eq(cmd_claude.args[4], "fix bugs")
  @debug.assert_eq(cmd_claude.workdir, Some("/path"))

  assert_eq(cmd_gemini.program, "agy")
  @debug.assert_eq(cmd_gemini.args, [
    "--dangerously-skip-permissions", "--prompt-interactive", "fix bugs",
  ])
  @debug.assert_eq(cmd_gemini.workdir, Some("/path"))

  assert_eq(cmd_moon.program, "moon")
  @debug.assert_eq(cmd_moon.args, ["pilot", "fix bugs"])
  @debug.assert_eq(cmd_moon.workdir, Some("/path"))

  assert_eq(cmd_codex.program, "codex")
  assert_eq(cmd_codex.args[0], "--dangerously-bypass-approvals-and-sandbox")
  assert_eq(cmd_codex.args[1], "--no-alt-screen")
  assert_eq(cmd_codex.args[2], "-c")
  assert_true(cmd_codex.args[3].contains("mcp_servers.choir.command=\"choir\""))
  assert_eq(cmd_codex.args[4], "-c")
  assert_true(cmd_codex.args[5].contains("\"mcp-stdio\""))
  assert_true(cmd_codex.args[5].contains("\"--raw-stdio\""))
  assert_true(cmd_codex.args[5].contains("\"--role\""))
  assert_true(cmd_codex.args[5].contains("\"dev\""))
  assert_true(cmd_codex.args[5].contains("\"--name\""))
  assert_true(cmd_codex.args[5].contains("\"main.test-slug\""))
  assert_true(cmd_codex.args[5].contains("\"--wait-socket-tries\""))
  assert_true(cmd_codex.args[5].contains("\"300\""))
  assert_true(cmd_codex.args[5].contains("\"--stderr-append-log\""))
  assert_false(cmd_codex.args[5].contains("-lc"))
  assert_eq(cmd_codex.args[6], "-c")
  assert_true(cmd_codex.args[7].contains("mcp_servers.choir.cwd=\"/path\""))
  assert_eq(cmd_codex.args[8], "-C")
  assert_eq(cmd_codex.args[9], "/path")
  assert_eq(cmd_codex.args[10], "fix bugs")
  @debug.assert_eq(cmd_codex.workdir, Some("/path"))

  let spec_cursor = { ..spec_claude, agent_type: @types.AgentType::CursorAgent }
  let cmd_cursor = @workspace.agent_launch_command(spec_cursor, "/path")
  assert_eq(cmd_cursor.program, "agent")
  assert_eq(cmd_cursor.args[0], "--yolo")
  assert_eq(cmd_cursor.args[1], "--approve-mcps")
  assert_eq(cmd_cursor.args[2], "--workspace")
  assert_eq(cmd_cursor.args[3], "/path")
  assert_eq(cmd_cursor.args[4], "fix bugs")
  @debug.assert_eq(cmd_cursor.workdir, Some("/path"))
}

///|
test "agent_launch_command wraps with shell_command" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmd = @workspace.agent_launch_command(
    spec,
    "/path",
    shell_command=Some("nix develop"),
  )
  assert_eq(cmd.program, "nix")
  assert_eq(cmd.args[0], "develop")
  assert_eq(cmd.args[1], "--command")
  assert_eq(cmd.args[2], "claude")
  assert_eq(cmd.args[3], "--dangerously-skip-permissions")
  assert_eq(cmd.args[4], "--mcp-config")
  assert_true(cmd.args[5].contains("\"mcpServers\""))
  assert_eq(cmd.args[6], "--strict-mcp-config")
  assert_eq(cmd.args[7], "fix bugs")
  @debug.assert_eq(cmd.workdir, Some("/path"))
}

///|
test "agent_launch_command no wrap when shell_command is None" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmd = @workspace.agent_launch_command(spec, "/path", shell_command=None)
  assert_eq(cmd.program, "claude")
  assert_eq(cmd.args[0], "--dangerously-skip-permissions")
  assert_eq(cmd.args[1], "--mcp-config")
  assert_true(cmd.args[2].contains("\"mcpServers\""))
  assert_eq(cmd.args[3], "--strict-mcp-config")
  assert_eq(cmd.args[4], "fix bugs")
}

///|
test "codex_mcp_override_args is argv-shaped Toml without sh" {
  let args = @workspace.codex_mcp_override_args(
    @types.Role::TL,
    "root",
    "/proj",
  )
  assert_true(args[1].contains("command=\"choir\""))
  assert_true(args[3].contains("\"mcp-stdio\""))
  assert_false(args[3].contains("\"sh\""))
  assert_false(args[3].contains("-lc"))
}

///|
test "agent_launch_command supports command_override" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmd = @workspace.agent_launch_command(
    spec,
    "/path",
    command_override=Some("my-gemini --flag"),
  )
  assert_eq(cmd.program, "my-gemini")
  assert_eq(cmd.args[0], "--flag")
  @debug.assert_eq(cmd.workdir, Some("/path"))
}

///|
test "agent_launch_command always uses agy for agy-backed types" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let gemini = @workspace.agent_launch_command(spec, "/path")
  assert_eq(gemini.program, "agy")
  let unknown = @workspace.agent_launch_command(
    { ..spec, agent_type: @types.AgentType::Unknown },
    "/path",
  )
  assert_eq(unknown.program, "agy")
}

///|
test "agent_launch_command supports Claude fork_session" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmd = @workspace.agent_launch_command(
    spec,
    "/path",
    parent_session_id=Some("session-123"),
  )
  assert_eq(cmd.program, "claude")
  assert_eq(cmd.args[0], "--dangerously-skip-permissions")
  assert_eq(cmd.args[1], "--mcp-config")
  assert_true(cmd.args[2].contains("\"mcpServers\""))
  assert_eq(cmd.args[3], "--strict-mcp-config")
  assert_eq(cmd.args[4], "--resume")
  assert_eq(cmd.args[5], "session-123")
  assert_eq(cmd.args[6], "--fork-session")
  assert_eq(cmd.args[7], "fix bugs")
}

///|
test "child_config_content resolves socket path into spawned worktree config" {
  let content = @workspace.child_config_content(
    @types.Role::Dev,
    "choir-test",
    "/project",
    ".choir/server.sock",
    tcp_auth_token=Some("abc123"),
  )
  assert_true(content.contains("default_role = \"dev\""))
  assert_true(content.contains("project_dir = \"/project\""))
  assert_true(content.contains("listen_uds = \"/project/.choir/server.sock\""))
  assert_true(content.contains("terminal_session = \"choir-test\""))
  assert_true(content.contains("tcp_auth_token = \"abc123\""))
}

///|
test "config_local_content includes spawn_depth" {
  let spec = @types.SpawnSpec::{
    slug: "subtl-0",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    task: "plan",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 1,
    automerge: Some(true),
    review_mode: None,
    wave_id: None,
  }
  let target = match @types.LocalTarget::parse("zellij-tab:choir:subtl-0") {
    Some(t) => t
    None => fail("expected target")
  }
  let content = @workspace.config_local_content(spec, "/tmp/wt", target)
  assert_true(content.contains("role = \"tl\""))
  assert_true(content.contains("spawn_depth = 1"))
  assert_true(content.contains("automerge = true"))
}

///|
test "config_local_content emits review_mode override" {
  let spec = @types.SpawnSpec::{
    slug: "leaf-0",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: Some(@types.ReviewMode::Iterative),
    wave_id: None,
  }
  let target = match @types.LocalTarget::parse("zellij-tab:choir:leaf-0") {
    Some(t) => t
    None => fail("expected target")
  }
  let content = @workspace.config_local_content(spec, "/tmp/wt", target)
  assert_true(content.contains("review_mode = \"iterative\""))
}

///|
test "review_mode_for_agent_workspace reads local config override" {
  let root = "/tmp/choir-workspace-review-mode-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let workdir = root + "/.choir/worktrees/leaf-0"
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(workdir + "/.choir"))
  @debug.assert_eq(
    @workspace.review_mode_for_agent_workspace(root, Some(workdir), "leaf-0"),
    @types.Config::default().review_mode,
  )
  assert_true(
    @sys.write_file_sync(
      workdir + "/.choir/config.local.toml",
      "review_mode = \"single_pass\"\n",
    ),
  )
  @debug.assert_eq(
    @workspace.review_mode_for_agent_workspace(root, Some(workdir), "leaf-0"),
    @types.ReviewMode::SinglePass,
  )
  ignore(@sys.rm_rf(root))
}

///|
test "review_mode_for_agent_workspace reads inline agent metadata when agent id supplied" {
  let root = "/tmp/choir-workspace-inline-review-mode-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let agent_id = "main.inline-leaf"
  let metadata_dir = @workspace.inline_agent_metadata_dir(root, agent_id)
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(metadata_dir + "/.choir"))
  assert_true(
    @sys.write_file_sync(
      metadata_dir + "/.choir/config.local.toml",
      "review_mode = \"single_pass\"\n",
    ),
  )
  @debug.assert_eq(
    @workspace.review_mode_for_agent_workspace(root, Some(root), "inline-leaf"),
    @types.Config::default().review_mode,
  )
  @debug.assert_eq(
    @workspace.review_mode_for_agent_workspace(
      root,
      Some(root),
      "inline-leaf",
      agent_id=Some(agent_id),
    ),
    @types.ReviewMode::SinglePass,
  )
  ignore(@sys.rm_rf(root))
}

///|
test "review_mode_for_agent_workspace prefers inline metadata over workspace config" {
  let root = "/tmp/choir-workspace-inline-review-mode-order-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let agent_id = "main.inline-shadow"
  let workdir = root + "/workspace"
  let metadata_dir = @workspace.inline_agent_metadata_dir(root, agent_id)
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(workdir + "/.choir"))
  assert_true(@sys.create_dir_all(metadata_dir + "/.choir"))
  assert_true(
    @sys.write_file_sync(
      workdir + "/.choir/config.local.toml",
      "review_mode = \"iterative\"\n",
    ),
  )
  assert_true(
    @sys.write_file_sync(
      metadata_dir + "/.choir/config.local.toml",
      "review_mode = \"single_pass\"\n",
    ),
  )
  @debug.assert_eq(
    @workspace.review_mode_for_agent_workspace(
      root,
      Some(workdir),
      "inline-shadow",
      agent_id=Some(agent_id),
      global_review_mode=@types.ReviewMode::Iterative,
    ),
    @types.ReviewMode::SinglePass,
  )
  ignore(@sys.rm_rf(root))
}

///|
test "config_local_content emits wave_id when present" {
  let spec = @types.SpawnSpec::{
    slug: "leaf-0",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: Some("wv-demo"),
  }
  let target = match @types.LocalTarget::parse("zellij-tab:choir:leaf-0") {
    Some(t) => t
    None => fail("expected target")
  }
  let content = @workspace.config_local_content(spec, "/tmp/wt", target)
  assert_true(content.contains("wave_id = \"wv-demo\""))
}

///|
test "config_local_content persists task_contract_json when present" {
  let spec = @types.SpawnSpec::{
    slug: "leaf-0",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "ship feature",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "ship feature",
      verify: ["moon test --target native"],
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let target = match @types.LocalTarget::parse("zellij-tab:choir:leaf-0") {
    Some(t) => t
    None => fail("expected target")
  }
  let content = @workspace.config_local_content(spec, "/tmp/wt", target)
  assert_true(content.contains("task_contract_json = "))
  assert_true(content.contains("moon test --target native"))
}

///|
test "spawn_commands for worktree mode returns zellij tab" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  // cleanup, fetch parent, git worktree add, seed info/exclude, configs, helpers, zellij
  assert_eq(cmds.length(), 8)
  assert_eq(
    cmds[0].program,
    @workspace.native_worktree_bootstrap_cleanup_program,
  )
  @debug.assert_eq(cmds[0].args, [
    "/project", "/project/.choir/worktrees/test-slug", "main.test-slug",
  ])
  assert_eq(
    cmds[1].program,
    @workspace.native_git_fetch_origin_branch_best_effort_program,
  )
  @debug.assert_eq(cmds[1].args, ["/project", "main"])
  assert_eq(cmds[2].program, "git")
  @debug.assert_eq(cmds[2].args, [
    "worktree", "add", "/project/.choir/worktrees/test-slug", "-b", "main.test-slug",
    "origin/main",
  ])
  assert_eq(
    cmds[3].program,
    @workspace.native_worktree_seed_agent_runtime_gitexclude_program,
  )
  assert_eq(cmds[3].args[0], "/project/.choir/worktrees/test-slug")
  assert_true(cmds[3].args[1].contains(".cursor/"))
  assert_eq(cmds[6].program, @workspace.native_leaf_helpers_program)
  @debug.assert_eq(cmds[6].args, ["/project/.choir/worktrees/test-slug"])
  assert_eq(cmds[7].program, "zellij")
  assert_eq(cmds[7].args[3], "new-tab")
}

///|
test "spawn_commands worktree config write content" {
  let spec = @types.SpawnSpec::{
    slug: "feature-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "do something",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  assert_eq(cmds.length(), 8)
  assert_eq(cmds[4].program, @workspace.native_write_choir_file_program)
  assert_true(cmds[4].args[0].contains("feature-a"))
  assert_eq(cmds[4].args[1], "config.toml")
  assert_true(cmds[4].args[2].contains("default_role = \"dev\""))
  assert_true(
    cmds[4].args[2].contains("listen_uds = \"/proj/.choir/server.sock\""),
  )
  assert_true(cmds[4].args[2].contains("terminal_session = \"exo\""))
  assert_eq(cmds[5].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[5].args[1], "config.local.toml")
  assert_true(cmds[5].args[2].contains("agent_id = \"main.feature-a\""))
  assert_true(cmds[5].args[2].contains("parent_id = \"root\""))
  assert_true(
    cmds[5].args[2].contains("terminal_target = \"zellij-tab:exo:feature-a\""),
  )
  assert_eq(cmds[6].program, @workspace.native_leaf_helpers_program)
  assert_eq(cmds[7].program, "zellij")
}

///|
test "spawn_commands wraps TL worktree launch with policy watcher shell" {
  let spec = @types.SpawnSpec::{
    slug: "subtl-a",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    task: "plan work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 1,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  let last = cmds[cmds.length() - 1]
  assert_eq(last.program, "zellij")
  assert_eq(last.args[9], "sh")
  assert_eq(last.args[10], "-lc")
  let script = last.args[11]
  assert_true(script.contains("CHOIR_AGENT_ID='main.subtl-a'"))
  assert_true(script.contains("CHOIR_ROLE='tl'"))
  assert_true(script.contains("choir tl-policy-watch --pid"))
  assert_true(script.contains("exec claude"))
  assert_false(script.contains("child_pid=$!"))
}

///|
test "spawn_commands gemini worktree adds agy bootstrap and config" {
  let spec = @types.SpawnSpec::{
    slug: "feature-z",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do something",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "howdy")
  assert_eq(cmds.length(), 12)
  assert_eq(cmds[7].program, @workspace.native_agy_cache_links_program)
  assert_eq(cmds[8].program, "env")
  assert_eq(
    cmds[8].args[0],
    "HOME=/proj/.choir/worktrees/feature-z/.choir/agy-home",
  )
  assert_eq(cmds[9].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cmds[9].args[1], ".choir/agy-home/.gemini/config/mcp_config.json")
  assert_eq(
    cmds[10].program,
    @workspace.native_write_workspace_rel_file_program,
  )
  assert_eq(cmds[10].args[1], ".choir/agy-home/.gemini/config/hooks.json")
  assert_eq(cmds[11].program, "zellij")
  assert_eq(cmds[11].args[3], "new-tab")
  assert_true(
    cmds[5].args[2].contains("terminal_target = \"zellij-tab:howdy:feature-z\""),
  )
}

///|
test "spawn_commands standalone includes config writes" {
  let spec = @types.SpawnSpec::{
    slug: "standalone-task",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "do something",
    task_contract: None,
    isolation: @types.IsolationMode::Standalone,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  // git init, config.toml, config.local.toml, helpers, zellij new-tab
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[1].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[1].args[1], "config.toml")
  assert_true(
    cmds[1].args[2].contains("listen_uds = \"/proj/.choir/server.sock\""),
  )
  assert_eq(cmds[2].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[2].args[1], "config.local.toml")
  assert_true(
    cmds[2].args[2].contains(
      "workspace = \"/proj/.choir/agents/standalone-task\"",
    ),
  )
  assert_eq(cmds[3].program, @workspace.native_leaf_helpers_program)
  @debug.assert_eq(cmds[3].args, ["/proj/.choir/agents/standalone-task"])
}

///|
test "spawn_commands adds Gemini trust bootstrap" {
  let spec = @types.SpawnSpec::{
    slug: "gemini-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "fix bugs",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  assert_eq(cmds.length(), 12)
  assert_eq(cmds[7].program, @workspace.native_agy_cache_links_program)
  @debug.assert_eq(cmds[7].args, [
    "/project", "/project/.choir/worktrees/gemini-slug",
  ])
  assert_eq(cmds[8].program, "env")
  @debug.assert_eq(cmds[8].args, [
    "HOME=/project/.choir/worktrees/gemini-slug/.choir/agy-home", "choir", "trust-gemini-folder",
    "/project/.choir/worktrees/gemini-slug",
  ])
  assert_eq(cmds[9].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cmds[9].args[1], ".choir/agy-home/.gemini/config/mcp_config.json")
  assert_true(cmds[9].args[2].contains("mcpServers"))
  assert_true(cmds[9].args[2].contains("main.gemini-slug"))
  assert_eq(
    cmds[10].program,
    @workspace.native_write_workspace_rel_file_program,
  )
  assert_eq(cmds[10].args[1], ".choir/agy-home/.gemini/config/hooks.json")
}

///|
test "spawn_commands cursor_agent worktree adds mcp json" {
  let spec = @types.SpawnSpec::{
    slug: "feature-c",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "do something",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "howdy")
  // cleanup, fetch, worktree add, seed exclude, configs, helpers, mcp json, zellij
  assert_eq(cmds.length(), 9)
  assert_eq(cmds[7].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cmds[7].args[1], ".cursor/mcp.json")
  assert_true(cmds[7].args[2].contains("mcpServers"))
  assert_true(cmds[7].args[2].contains("main.feature-c"))
  assert_eq(cmds[8].program, "zellij")
  assert_eq(cmds[8].args[3], "new-tab")
}

///|
test "spawn_commands for inline mode writes metadata and uses zellij run" {
  let spec = @types.SpawnSpec::{
    slug: "worker-a",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::MoonPilot,
    task: "reply READY",
    task_contract: None,
    isolation: @types.IsolationMode::Inline,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "howdy")
  assert_eq(cmds.length(), 3)
  assert_eq(cmds[0].program, @workspace.native_write_choir_file_program)
  assert_true(cmds[0].args[0].contains("/project/.choir/inline/main.worker-a"))
  assert_true(cmds[0].args[2].contains("agent_id = \"main.worker-a\""))
  assert_eq(cmds[1].program, @workspace.native_leaf_helpers_program)
  assert_eq(cmds[2].program, "zellij")
  assert_eq(cmds[2].args[0], "--session")
  assert_eq(cmds[2].args[1], "howdy")
  assert_eq(cmds[2].args[2], "run")
  assert_eq(cmds[2].args[4], "worker-a")
  let zargs = cmds[2].args
  let mut found_terminal = false
  for i = 0; i < zargs.length(); i = i + 1 {
    if zargs[i].contains("CHOIR_TERMINAL_TARGET=") &&
      zargs[i].contains("zellij-pane:howdy:worker-a") {
      found_terminal = true
      break
    }
  }
  assert_true(found_terminal)
}

///|
test "spawn_commands launch text contains env vars" {
  let spec = @types.SpawnSpec::{
    slug: "feature-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do something",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  // Last command is zellij new-tab; env + argv follow `-- env`
  let last = cmds[cmds.length() - 1]
  assert_eq(last.program, "zellij")
  assert_eq(last.args[3], "new-tab")
  assert_eq(last.args[8], "--")
  assert_eq(last.args[9], "env")
  let mut joined = ""
  for i = 10; i < last.args.length(); i = i + 1 {
    joined = joined + last.args[i]
  }
  assert_true(joined.contains("CHOIR_AGENT_ID=main.feature-a"))
  assert_true(joined.contains("CHOIR_TERMINAL_TARGET=zellij-tab:exo:feature-a"))
  assert_true(joined.contains("CHOIR_PARENT_AGENT=root"))
  assert_true(
    joined.contains("HOME=/proj/.choir/worktrees/feature-a/.choir/agy-home"),
  )
  assert_false(joined.contains("GEMINI_CLI_SYSTEM_SETTINGS_PATH"))
}

///|
test "write_spawn_config and write_local_config use native choir file commands" {
  let spawn_cmd = @workspace.write_spawn_config("/wt", "a=toml")
  let local_cmd = @workspace.write_local_config("/wt", "b=toml")
  assert_eq(spawn_cmd.program, @workspace.native_write_choir_file_program)
  @debug.assert_eq(spawn_cmd.args, ["/wt", "config.toml", "a=toml"])
  assert_eq(local_cmd.program, @workspace.native_write_choir_file_program)
  @debug.assert_eq(local_cmd.args, ["/wt", "config.local.toml", "b=toml"])
}

///|
test "write_leaf_helper_scripts uses native leaf helper install command" {
  let cmd = @workspace.write_leaf_helper_scripts("/tmp/wt")
  assert_eq(cmd.program, @workspace.native_leaf_helpers_program)
  @debug.assert_eq(cmd.args, ["/tmp/wt"])
}

///|
test "run_native_leaf_helpers_command ignores foreign programs" {
  assert_eq(
    @workspace.run_native_leaf_helpers_command({
      program: "sh",
      args: ["/tmp"],
      workdir: None,
    }),
    -1,
  )
}

///|
test "run_native_agy_cache_links_command is idempotent and preserves shared cache" {
  let dir = "/tmp/choir-agy-cache-links-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  let worktree = project + "/.choir/worktrees/leaf"
  let second_worktree = project + "/.choir/worktrees/second-leaf"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(worktree))
  assert_true(@sys.create_dir_all(second_worktree))
  let shared_playwright = project + "/.choir/agy-shared-cache/ms-playwright-go"
  let shared_version = shared_playwright + "/1.57.0"
  let shared_bin = project + "/.choir/agy-shared-cache/antigravity-cli-bin"
  assert_true(@sys.create_dir_all(shared_version + "/package"))
  assert_true(@sys.create_dir_all(shared_bin))
  assert_true(@sys.write_file_sync(shared_version + "/node", "node"))
  assert_true(
    @sys.write_file_sync(shared_version + "/package/package.json", "{}"),
  )
  assert_true(@sys.write_file_sync(shared_bin + "/webm_encoder", "webm"))

  let cmd = @workspace.agy_cache_links(project, worktree)
  assert_eq(cmd.program, @workspace.native_agy_cache_links_program)
  assert_eq(@workspace.run_native_agy_cache_links_command(cmd), 0)

  let home = worktree + "/.choir/agy-home"
  let second_home = second_worktree + "/.choir/agy-home"
  let playwright_link = home + "/.cache/ms-playwright-go"
  let second_playwright_link = second_home + "/.cache/ms-playwright-go"
  let bin_link = home + "/.gemini/antigravity-cli/bin"
  let second_bin_link = second_home + "/.gemini/antigravity-cli/bin"
  assert_true(
    @sys.write_file_sync(shared_playwright + "/sentinel.txt", "shared"),
  )
  assert_true(@sys.write_file_sync(shared_bin + "/agy-sentinel", "bin"))
  assert_eq(@sys.read_file(playwright_link + "/sentinel.txt"), "shared")
  assert_eq(@sys.read_file(bin_link + "/agy-sentinel"), "bin")
  let settings_raw = @sys.read_file(home + "/.gemini/settings.json")
  let settings_json = @json.parse(settings_raw) catch {
    _ => fail("invalid .gemini/settings.json")
  }
  guard settings_json is Object(settings) else {
    fail(".gemini/settings.json root is not object")
  }
  guard settings.get("ui") is Some(Object(ui)) else {
    fail("ui section missing")
  }
  guard ui.get("theme") is Some(theme) else { fail("theme missing") }
  @debug.assert_eq(theme, "ANSI".to_json())
  guard settings.get("security") is Some(Object(security)) else {
    fail("security section missing")
  }
  guard security.get("auth") is Some(Object(auth)) else {
    fail("security.auth missing")
  }
  guard auth.get("selectedType") is Some(selected_type) else {
    fail("selectedType missing")
  }
  @debug.assert_eq(selected_type, "oauth-personal".to_json())
  assert_true(
    @sys.write_file_sync(home + "/.gemini/settings.json", "{\"security\":{}}"),
  )
  assert_eq(@workspace.run_native_agy_cache_links_command(cmd), 0)
  assert_eq(
    @sys.read_file(home + "/.gemini/settings.json"),
    "{\"security\":{}}",
  )
  assert_eq(@sys.read_file(playwright_link + "/sentinel.txt"), "shared")
  assert_eq(@sys.read_file(bin_link + "/agy-sentinel"), "bin")
  let second_cmd = @workspace.agy_cache_links(project, second_worktree)
  assert_eq(@workspace.run_native_agy_cache_links_command(second_cmd), 0)
  assert_eq(@sys.read_file(second_playwright_link + "/sentinel.txt"), "shared")
  assert_eq(@sys.read_file(second_bin_link + "/agy-sentinel"), "bin")
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_cache_links_command links existing shared cache without marker" {
  let dir = "/tmp/choir-agy-cache-adopt-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  let worktree = project + "/.choir/worktrees/leaf"
  let shared_root = project + "/.choir/agy-shared-cache"
  let shared_playwright = shared_root + "/ms-playwright-go"
  let shared_version = shared_playwright + "/1.57.0"
  let shared_bin = shared_root + "/antigravity-cli-bin"
  let shared_extra = shared_root + "/preexisting"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(worktree))
  assert_true(@sys.create_dir_all(shared_version + "/package"))
  assert_true(@sys.create_dir_all(shared_bin))
  assert_true(@sys.create_dir_all(shared_extra))
  assert_true(@sys.write_file_sync(shared_version + "/node", "node"))
  assert_true(
    @sys.write_file_sync(shared_version + "/package/package.json", "{}"),
  )
  assert_true(@sys.write_file_sync(shared_bin + "/webm_encoder", "webm"))
  assert_true(@sys.write_file_sync(shared_playwright + "/sentinel.txt", "keep"))
  assert_true(@sys.write_file_sync(shared_extra + "/sentinel.txt", "keep-root"))

  let cmd = @workspace.agy_cache_links(project, worktree)
  assert_eq(
    @workspace.run_native_agy_cache_links_command(cmd, write_stderr=fn(_) { () }),
    0,
  )

  let home = worktree + "/.choir/agy-home"
  assert_true(@sys.path_entry_exists(shared_bin))
  assert_eq(
    @sys.read_file(home + "/.cache/ms-playwright-go/sentinel.txt"),
    "keep",
  )
  assert_eq(@sys.read_file(shared_extra + "/sentinel.txt"), "keep-root")
  assert_true(@sys.path_entry_exists(home + "/.gemini/antigravity-cli/bin"))
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_cache_links_command warns when shared cache is absent" {
  let dir = "/tmp/choir-agy-cache-absent-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  let worktree = project + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(worktree))

  let cmd = @workspace.agy_cache_links(project, worktree)
  let warnings : Array[String] = []
  assert_eq(
    @workspace.run_native_agy_cache_links_command(cmd, write_stderr=fn(msg) {
      warnings.push(msg)
    }),
    0,
  )
  assert_true(warnings.join("\n").contains("warning"))
  assert_true(warnings.join("\n").contains("not populated"))

  let home = worktree + "/.choir/agy-home"
  assert_false(@sys.path_entry_exists(home + "/.cache/ms-playwright-go"))
  assert_false(@sys.path_entry_exists(home + "/.gemini/antigravity-cli/bin"))
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_cache_links_command warns on invalid shared cache" {
  let dir = "/tmp/choir-agy-cache-invalid-shared-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  let worktree = project + "/.choir/worktrees/leaf"
  let shared_root = project + "/.choir/agy-shared-cache"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(worktree))
  assert_true(@sys.create_dir_all(shared_root + "/ms-playwright-go"))
  assert_true(@sys.create_dir_all(shared_root + "/antigravity-cli-bin"))

  let cmd = @workspace.agy_cache_links(project, worktree)
  let warnings : Array[String] = []
  assert_eq(
    @workspace.run_native_agy_cache_links_command(cmd, write_stderr=fn(msg) {
      warnings.push(msg)
    }),
    0,
  )
  assert_true(warnings.join("\n").contains("warning"))
  assert_true(warnings.join("\n").contains("not populated"))

  let home = worktree + "/.choir/agy-home"
  assert_false(@sys.path_entry_exists(home + "/.cache/ms-playwright-go"))
  assert_false(@sys.path_entry_exists(home + "/.gemini/antigravity-cli/bin"))
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_shared_cache_seed_if_needed skips bootstrap when cache is populated" {
  let dir = "/tmp/choir-agy-cache-seed-warm-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  let shared_root = project + "/.choir/agy-shared-cache"
  let shared_playwright = shared_root + "/ms-playwright-go"
  let shared_version = shared_playwright + "/1.57.0"
  let shared_bin = shared_root + "/antigravity-cli-bin"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(shared_version + "/package"))
  assert_true(@sys.create_dir_all(shared_bin))
  assert_true(@sys.write_file_sync(shared_version + "/node", "node"))
  assert_true(
    @sys.write_file_sync(shared_version + "/package/package.json", "{}"),
  )
  assert_true(@sys.write_file_sync(shared_bin + "/webm_encoder", "webm"))

  let bootstrap_called : Array[Bool] = [false]
  let status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(_) {
      bootstrap_called[0] = true
      (1, "unexpected bootstrap")
    },
  )

  assert_eq(status, 0)
  assert_false(bootstrap_called[0])
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_shared_cache_seed_if_needed bootstraps and validates cold cache" {
  let dir = "/tmp/choir-agy-cache-seed-cold-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  let shared_root = project + "/.choir/agy-shared-cache"
  let shared_playwright = shared_root + "/ms-playwright-go"
  let shared_version = shared_playwright + "/1.57.0"
  let shared_bin = shared_root + "/antigravity-cli-bin"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(project))

  let bootstrap_called : Array[Bool] = [false]
  let bootstrap_program : Array[String] = []
  let bootstrap_args : Array[String] = []
  let bootstrap_workdir : Array[String] = []
  let status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(cmd) {
      bootstrap_called[0] = true
      bootstrap_program.push(cmd.program)
      for arg in cmd.args {
        bootstrap_args.push(arg)
      }
      match cmd.workdir {
        Some(dir) => bootstrap_workdir.push(dir)
        None => ()
      }
      ignore(@sys.create_dir_all(shared_version + "/package"))
      ignore(@sys.create_dir_all(shared_bin))
      ignore(@sys.write_file_sync(shared_version + "/node", "node"))
      ignore(
        @sys.write_file_sync(shared_version + "/package/package.json", "{}"),
      )
      ignore(@sys.write_file_sync(shared_bin + "/webm_encoder", "webm"))
      (0, "")
    },
  )

  assert_eq(status, 0)
  assert_true(bootstrap_called[0])
  @debug.assert_eq(bootstrap_program, ["env"])
  assert_true(
    bootstrap_args.contains("HOME=" + project + "/.choir/agy-shared-cache/home"),
  )
  assert_true(bootstrap_args.contains("agy"))
  @debug.assert_eq(bootstrap_workdir, [project])
  assert_true(
    @sys.path_entry_exists(
      project + "/.choir/agy-shared-cache/home/.cache/ms-playwright-go",
    ),
  )
  assert_true(
    @sys.path_entry_exists(
      project + "/.choir/agy-shared-cache/home/.gemini/antigravity-cli/bin",
    ),
  )
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_shared_cache_seed_if_needed resolves relative project cache paths" {
  let project = "relative-project"
  let existing : Array[String] = []
  let sized_paths : Array[String] = []
  let symlink_targets : Array[String] = []
  let symlink_links : Array[String] = []
  let bootstrap_homes : Array[String] = []
  let bootstrap_workdirs : Array[String] = []
  let bootstrap_calls : Array[String] = []
  let remember_path = fn(path : String) {
    if !existing.contains(path) {
      existing.push(path)
    }
  }
  let remember_file = fn(path : String) {
    remember_path(path)
    if !sized_paths.contains(path) {
      sized_paths.push(path)
    }
  }

  let status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(cmd) {
      bootstrap_calls.push(cmd.program)
      bootstrap_homes.push(cmd.args[0])
      match cmd.workdir {
        Some(dir) => bootstrap_workdirs.push(dir)
        None => ()
      }
      let shared_playwright = symlink_targets[0]
      let shared_bin = symlink_targets[1]
      let shared_version = shared_playwright + "/1.57.0"
      remember_path(shared_version)
      remember_path(shared_version + "/package")
      remember_file(shared_version + "/node")
      remember_file(shared_version + "/package/package.json")
      remember_file(shared_bin + "/webm_encoder")
      (0, "")
    },
    path_entry_exists=fn(path) { existing.contains(path) },
    list_dir=fn(path) {
      if symlink_targets.length() > 0 && path == symlink_targets[0] {
        ["1.57.0"]
      } else {
        []
      }
    },
    file_size=fn(path) { if sized_paths.contains(path) { 4 } else { 0 } },
    create_dir_all=fn(path) {
      remember_path(path)
      true
    },
    rm_rf=fn(_) { true },
    symlink_force=fn(target, link) {
      symlink_targets.push(target)
      symlink_links.push(link)
      remember_path(link)
      true
    },
    write_stderr=fn(_) { () },
  )

  assert_eq(status, 0)
  assert_eq(symlink_targets.length(), 2)
  assert_eq(symlink_links.length(), 2)
  assert_true(symlink_targets[0].has_prefix("/"))
  assert_true(symlink_targets[1].has_prefix("/"))
  assert_true(symlink_links[0].has_prefix("/"))
  assert_true(symlink_links[1].has_prefix("/"))
  assert_true(
    symlink_targets[0].has_suffix(
      "/relative-project/.choir/agy-shared-cache/ms-playwright-go",
    ),
  )
  assert_true(
    symlink_targets[1].has_suffix(
      "/relative-project/.choir/agy-shared-cache/antigravity-cli-bin",
    ),
  )
  @debug.assert_eq(bootstrap_calls, ["env"])
  @debug.assert_eq(bootstrap_homes, [
    "HOME=" + symlink_targets[0].replace(old="/ms-playwright-go", new="/home"),
  ])
  assert_eq(bootstrap_workdirs.length(), 1)
  assert_true(bootstrap_workdirs[0].has_prefix("/"))
  assert_true(bootstrap_workdirs[0].has_suffix("/relative-project"))

  let warm_status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(_) {
      bootstrap_calls.push("unexpected")
      (1, "unexpected bootstrap")
    },
    path_entry_exists=fn(path) { existing.contains(path) },
    list_dir=fn(path) {
      if symlink_targets.length() > 0 && path == symlink_targets[0] {
        ["1.57.0"]
      } else {
        []
      }
    },
    file_size=fn(path) { if sized_paths.contains(path) { 4 } else { 0 } },
    create_dir_all=fn(path) {
      remember_path(path)
      true
    },
    rm_rf=fn(_) { true },
    symlink_force=fn(target, link) {
      symlink_targets.push(target)
      symlink_links.push(link)
      true
    },
    write_stderr=fn(_) { () },
  )

  assert_eq(warm_status, 0)
  @debug.assert_eq(bootstrap_calls, ["env"])
  assert_eq(symlink_targets.length(), 2)
  assert_eq(symlink_links.length(), 2)
}

///|
test "agy_shared_cache_cold_bootstrap_exec only matches the agy bootstrap" {
  let cmd = @workspace.agy_shared_cache_cold_bootstrap("/tmp/choir-project")
  let exec = @workspace.agy_shared_cache_cold_bootstrap_exec(cmd)
  @debug.assert_eq(
    exec,
    Some({ home: "/tmp/choir-project/.choir/agy-shared-cache/home" }),
  )
  let non_agy = @workspace.Command::{
    program: "env",
    args: [
      "HOME=/tmp/choir-project/.choir/agy-shared-cache/home", "not-agy", "--dangerously-skip-permissions",
      "--print", "Reply READY.",
    ],
    workdir: Some("/tmp/choir-project"),
  }
  @debug.assert_eq(
    @workspace.agy_shared_cache_cold_bootstrap_exec(non_agy),
    None,
  )
}

///|
test "run_native_agy_shared_cache_seed_if_needed warns and returns bootstrap failure" {
  let dir = "/tmp/choir-agy-cache-seed-bootstrap-fail-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(project))
  let warnings : Array[String] = []

  let status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(_) { (42, "bootstrap stderr") },
    write_stderr=fn(msg) { warnings.push(msg) },
  )

  assert_eq(status, 42)
  let rendered = warnings.join("\n")
  assert_true(rendered.contains("cold-bootstrap"))
  assert_true(rendered.contains("exit 42"))
  assert_true(rendered.contains("bootstrap stderr"))
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_shared_cache_seed_if_needed normalizes negative bootstrap failure" {
  let dir = "/tmp/choir-agy-cache-seed-bootstrap-negative-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(project))
  let warnings : Array[String] = []

  let status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(_) { (-1, "spawn failed") },
    write_stderr=fn(msg) { warnings.push(msg) },
  )

  assert_eq(status, 1)
  let rendered = warnings.join("\n")
  assert_true(rendered.contains("cold-bootstrap"))
  assert_true(rendered.contains("exit 1"))
  assert_true(rendered.contains("spawn failed"))
  ignore(@sys.rm_rf(dir))
}

///|
test "run_native_agy_shared_cache_seed_if_needed warns and returns revalidate failure" {
  let dir = "/tmp/choir-agy-cache-seed-revalidate-fail-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let project = dir + "/project"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(project))
  let warnings : Array[String] = []

  let status = @workspace.run_native_agy_shared_cache_seed_if_needed_command_with_runner(
    @workspace.agy_shared_cache_seed_if_needed(project),
    fn(_) { (0, "") },
    write_stderr=fn(msg) { warnings.push(msg) },
  )

  assert_eq(status, 1)
  let rendered = warnings.join("\n")
  assert_true(rendered.contains("re-validate"))
  assert_true(rendered.contains("exit 1"))
  assert_true(rendered.contains("shared cache"))
  ignore(@sys.rm_rf(dir))
}

///|
test "gh_shim_script_body hard-blocks gh pr create and passes other subcommands through" {
  // Smoke-only: this asserts the body is non-empty and shell-y. The real
  // behavioral coverage lives in `tests/gh_shim_smoke.sh`, which exec-tests
  // every forbidden subcommand in ~50ms — far cheaper than a `moon test -p`
  // workspace rebuild every time a shim string changes.
  let body = @workspace.gh_shim_script_body()
  assert_true(body.has_prefix("#!/bin/sh"))
  assert_true(body.contains("for d in $PATH"))
  assert_true(body.contains("exec \"$d/gh\""))
}

///|
test "bash_bounded_script_body wraps bash in a timeout" {
  let body = @workspace.bash_bounded_script_body()
  assert_true(body.has_prefix("#!/bin/sh"))
  assert_true(body.contains("exec timeout 60s bash \"$@\""))
}

///|
test "choir_lint_wrapper_script_body delegates to native lint command" {
  let body = @workspace.choir_lint_wrapper_script_body()
  assert_true(body.has_prefix("#!/bin/sh"))
  assert_true(body.contains("cd \"$project_dir\""))
  assert_true(
    body.contains("exec moon run src/bin/choir_lint --target native -- \"$@\""),
  )
  assert_false(body.contains("_build/native"))
}

///|
test "run_native_leaf_helpers_command installs leaf bin shims alongside leaf-tool" {
  let dir = "/tmp/choir-gh-shim-install-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let bin_dir = dir + "/.choir/bin"
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(dir))
  let rc = @workspace.run_native_leaf_helpers_command({
    program: @workspace.native_leaf_helpers_program,
    args: [dir],
    workdir: None,
  })
  assert_eq(rc, 0)
  // gh shim exists and matches the canonical body.
  let gh_path = bin_dir + "/gh"
  assert_true(@sys.path_exists(gh_path))
  assert_eq(@sys.read_file(gh_path), @workspace.gh_shim_script_body())
  let gh_bounded_path = bin_dir + "/gh-bounded"
  assert_true(@sys.path_exists(gh_bounded_path))
  assert_eq(
    @sys.read_file(gh_bounded_path),
    @workspace.gh_bounded_script_body(),
  )
  assert_eq(@sys.system("test -x " + @sys.shell_quote(gh_bounded_path)), 0)
  let bash_bounded_path = bin_dir + "/bash-bounded"
  assert_true(@sys.path_exists(bash_bounded_path))
  assert_eq(
    @sys.read_file(bash_bounded_path),
    @workspace.bash_bounded_script_body(),
  )
  assert_eq(@sys.system("test -x " + @sys.shell_quote(bash_bounded_path)), 0)
  let choir_lint_path = bin_dir + "/choir_lint"
  assert_true(@sys.path_exists(choir_lint_path))
  assert_eq(
    @sys.read_file(choir_lint_path),
    @workspace.choir_lint_wrapper_script_body(),
  )
  assert_eq(@sys.system("test -x " + @sys.shell_quote(choir_lint_path)), 0)
  // Leaf-tool symlinks still installed -- shim is additive, not a replacement.
  assert_true(@sys.path_exists(bin_dir + "/file_pr"))
  assert_true(@sys.path_exists(bin_dir + "/resolve_my_review_threads"))
  assert_true(@sys.path_exists(bin_dir + "/request_review"))
  assert_true(@sys.path_exists(bin_dir + "/choir-leaf-tool"))
  ignore(@sys.rm_rf(dir))
}

///|
test "agy mcp config and cursor mcp json use native file commands" {
  let agy = @workspace.write_agy_mcp_config("/wt", "main.leaf", "dev")
  assert_eq(agy.program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(agy.args[0], "/wt")
  assert_eq(agy.args[1], ".choir/agy-home/.gemini/config/mcp_config.json")
  let parsed = @json.parse(agy.args[2]) catch {
    _ => fail("invalid agy mcp JSON")
  }
  guard parsed is Object(top) else { fail("expected agy mcp object") }
  guard top.get("mcpServers") is Some(Object(servers)) else {
    fail("mcpServers missing")
  }
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("choir mcp missing")
  }
  @debug.assert_eq(choir.get("type"), Some("stdio".to_json()))
  @debug.assert_eq(choir.get("command"), Some("choir".to_json()))
  @debug.assert_eq(choir.get("cwd"), Some("/wt".to_json()))
  @debug.assert_eq(choir.get("alwaysLoad"), Some(true.to_json()))
  guard choir.get("args") is Some(Array(args)) else {
    fail("choir mcp args missing")
  }
  @debug.assert_eq(args[0], "mcp-stdio".to_json())
  assert_true(args.contains("--role".to_json()))
  assert_true(args.contains("dev".to_json()))
  assert_true(args.contains("--name".to_json()))
  assert_true(args.contains("main.leaf".to_json()))

  let hooks = @workspace.write_agy_hooks(
    "/wt",
    wasm_hooks_path=Some("/hooks/hook.wasm"),
  )
  assert_eq(hooks.program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(hooks.args[1], ".choir/agy-home/.gemini/config/hooks.json")
  assert_true(hooks.args[2].contains("\"PreInvocation\""))
  assert_true(hooks.args[2].contains("\"PostInvocation\""))
  assert_true(hooks.args[2].contains("\"PreToolUse\""))
  assert_true(hooks.args[2].contains("\"Stop\""))
  assert_false(hooks.args[2].contains("\"matcher\""))
  let hooks_json = @json.parse(hooks.args[2]) catch {
    _ => fail("invalid agy hooks JSON")
  }
  guard hooks_json is Object(hooks_root) else {
    fail("agy hooks json root missing")
  }
  guard hooks_root.get("choir") is None else {
    fail("agy hooks must not be nested under choir")
  }
  guard hooks_root.get("PreInvocation") is Some(Array(pre_invocation)) else {
    fail("agy PreInvocation hook missing")
  }
  guard hooks_root.get("PostInvocation") is Some(Array(post_invocation)) else {
    fail("agy PostInvocation hook missing")
  }
  guard hooks_root.get("PreToolUse") is Some(Array(pre_tool_use)) else {
    fail("agy PreToolUse hook missing")
  }
  guard hooks_root.get("Stop") is Some(Array(stop_hooks)) else {
    fail("agy Stop hook missing")
  }
  assert_eq(pre_invocation.length(), 1)
  assert_eq(post_invocation.length(), 1)
  assert_eq(pre_tool_use.length(), 1)
  assert_eq(stop_hooks.length(), 1)
  guard pre_invocation[0] is Object(pre_hook) else {
    fail("PreInvocation hook object missing")
  }
  guard post_invocation[0] is Object(post_hook) else {
    fail("PostInvocation hook object missing")
  }
  guard pre_tool_use[0] is Object(pre_tool_hook) else {
    fail("PreToolUse hook object missing")
  }
  guard stop_hooks[0] is Object(stop_hook) else {
    fail("Stop hook object missing")
  }
  @debug.assert_eq(pre_hook.get("type"), Some("command".to_json()))
  @debug.assert_eq(
    pre_hook.get("command"),
    Some("extism call '/hooks/hook.wasm' before_model --wasi".to_json()),
  )
  @debug.assert_eq(pre_hook.get("timeout"), Some(Int::to_json(60)))
  @debug.assert_eq(post_hook.get("type"), Some("command".to_json()))
  @debug.assert_eq(
    post_hook.get("command"),
    Some("extism call '/hooks/hook.wasm' after_model --wasi".to_json()),
  )
  @debug.assert_eq(post_hook.get("timeout"), Some(Int::to_json(60)))
  @debug.assert_eq(pre_tool_hook.get("type"), Some("command".to_json()))
  @debug.assert_eq(
    pre_tool_hook.get("command"),
    Some("extism call '/hooks/hook.wasm' pre_tool_use --wasi".to_json()),
  )
  @debug.assert_eq(pre_tool_hook.get("timeout"), Some(Int::to_json(60)))
  @debug.assert_eq(stop_hook.get("type"), Some("command".to_json()))
  @debug.assert_eq(
    stop_hook.get("command"),
    Some("choir hook worker-exit --runtime gemini".to_json()),
  )
  @debug.assert_eq(stop_hook.get("timeout"), Some(Int::to_json(60)))
  @debug.assert_eq(pre_hook.get("stdin"), None)
  @debug.assert_eq(post_hook.get("stdin"), None)
  @debug.assert_eq(pre_tool_hook.get("stdin"), None)
  @debug.assert_eq(stop_hook.get("stdin"), None)

  let cur = @workspace.write_cursor_mcp_json("/wt", "main.leaf", "dev")
  assert_eq(cur.program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cur.args[1], ".cursor/mcp.json")
  assert_true(cur.args[2].contains("\"choir\""))
}

///|
test "provider_materialization_commands emits agy bootstrap/config and cursor mcp" {
  let gem = @workspace.provider_materialization_commands(
    @types.AgentType::Gemini,
    "/proj",
    "/proj",
    "root",
    @types.Role::TL,
  )
  assert_eq(gem.length(), 4)
  assert_eq(gem[0].program, @workspace.native_agy_cache_links_program)
  assert_eq(gem[1].program, "env")
  assert_eq(gem[2].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(gem[2].args[1], ".choir/agy-home/.gemini/config/mcp_config.json")
  assert_true(gem[2].args[2].contains("\"--name\""))
  assert_true(gem[2].args[2].contains("\"root\""))
  assert_true(gem[2].args[2].contains("\"--role\""))
  assert_true(gem[2].args[2].contains("\"tl\""))
  assert_eq(gem[3].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(gem[3].args[1], ".choir/agy-home/.gemini/config/hooks.json")

  let cur = @workspace.provider_materialization_commands(
    @types.AgentType::CursorAgent,
    "/proj",
    "/proj",
    "root",
    @types.Role::TL,
  )
  assert_eq(cur.length(), 1)
  assert_eq(cur[0].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cur[0].args[1], ".cursor/mcp.json")
  assert_true(cur[0].args[2].contains("\"--name\""))
  assert_true(cur[0].args[2].contains("\"root\""))
  assert_true(cur[0].args[2].contains("\"--role\""))
  assert_true(cur[0].args[2].contains("\"tl\""))
}

///|
test "Command::to_string output" {
  let cmd1 = @workspace.Command::{
    program: "git",
    args: ["status"],
    workdir: None,
  }
  assert_eq(cmd1.to_string(), "git 'status'")

  let cmd2 = @workspace.Command::{
    program: "claude",
    args: [
      "--dangerously-skip-permissions", "--mcp-config", "{\"mcpServers\":{}}", "--strict-mcp-config",
      "hello",
    ],
    workdir: Some("/path"),
  }
  assert_eq(
    cmd2.to_string(),
    "cd '/path' && claude '--dangerously-skip-permissions' '--mcp-config' '{\"mcpServers\":{}}' '--strict-mcp-config' 'hello'",
  )
}

///|
test "Command::to_string quotes spaced args" {
  let cmd = @workspace.Command::{
    program: "agy",
    args: [
      "--dangerously-skip-permissions", "--prompt-interactive", "Reply with READY and then stop.",
    ],
    workdir: None,
  }
  assert_eq(
    cmd.to_string(),
    "agy '--dangerously-skip-permissions' '--prompt-interactive' 'Reply with READY and then stop.'",
  )
}

///|
test "mcp_json_content merges extra servers" {
  let json = @workspace.mcp_json_content(
    @types.Role::Dev,
    "agent-a",
    extra_mcp_servers_json=Some(
      "{\"notebook\":{\"type\":\"stdio\",\"command\":\"node\"}}",
    ),
  )
  assert_true(json.contains("\"choir\""))
  assert_true(json.contains("\"notebook\""))
  assert_true(json.contains("\"agent-a\""))
  assert_true(json.contains("\"--stderr-append-log\""))
  assert_true(json.contains("\".choir/mcp-stdio-agent-a.stderr.log\""))
}

///|
test "mcp_json_content sets alwaysLoad on the choir MCP entry" {
  // Claude Code's tool-search deferral was a measurable round-trip cost on
  // every fork_wave / file_pr / merge_pr first-use. `alwaysLoad: true` opts
  // out. Other agent runtimes ignore the unknown key.
  let json = @workspace.mcp_json_content(@types.Role::Dev, "agent-a")
  assert_true(json.contains("\"alwaysLoad\":true"))
}

///|
test "mcp_json_content uses a per-agent stderr append log" {
  let json = @workspace.mcp_json_content(
    @types.Role::Dev,
    "feature/mcp-startup-race.leaf-a",
  )
  assert_true(json.contains("\"--stderr-append-log\""))
  assert_true(
    json.contains(
      "\".choir/mcp-stdio-feature_mcp-startup-race.leaf-a.stderr.log\"",
    ),
  )
}

///|
test "init_tl_claude_mcp_config_json sets alwaysLoad on the choir MCP entry" {
  let json = @workspace.init_tl_claude_mcp_config_json()
  assert_true(json.contains("\"alwaysLoad\":true"))
  assert_true(json.contains("\"choir\""))
  assert_true(json.contains("\"--stderr-append-log\""))
  assert_true(json.contains("\".choir/mcp-stdio.stderr.log\""))
}

///|
test "remote_spawn_commands produces 3 ssh commands and includes spawn_depth" {
  let spec = @types.SpawnSpec::{
    slug: "remote-worker",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "implement feature Y",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 1,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.remote_spawn_commands(
    spec, "user@remote-host", "git@github.com:org/repo.git", "10.0.0.1:9100",
  )
  assert_eq(cmds.length(), 3)
  for cmd in cmds {
    assert_eq(cmd.program, "ssh")
    assert_true(cmd.args.length() >= 3)
    assert_eq(cmd.args[0], "-o")
    assert_eq(cmd.args[1], "StrictHostKeyChecking=no")
    assert_eq(cmd.args[2], "user@remote-host")
  }
  assert_true(cmds[0].args[3].contains("git clone"))
  assert_true(cmds[0].args[3].contains("main.remote-worker"))

  // config write command
  let config_cmd = cmds[1].args[3]
  assert_true(config_cmd.contains("config.toml"))
  assert_true(config_cmd.contains("config.local.toml"))
  assert_true(config_cmd.contains("10.0.0.1:9100"))
  assert_true(config_cmd.contains("spawn_depth = 1"))
  assert_true(
    config_cmd.contains(
      "terminal_target = \"zellij-pane:remote:remote-worker\"",
    ),
  )

  // launch command
  assert_true(cmds[2].args[3].contains("claude"))
  assert_true(cmds[2].args[3].contains("CHOIR_AGENT_ID='main.remote-worker'"))
  assert_true(cmds[2].args[3].contains("CHOIR_PARENT_AGENT='root'"))
}

///|
test "remote_spawn_commands passes extra MCP servers into launch command" {
  let spec = @types.SpawnSpec::{
    slug: "remote-worker",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "implement feature Y",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.remote_spawn_commands(
    spec,
    "user@remote-host",
    "git@github.com:org/repo.git",
    "10.0.0.1:9100",
    extra_mcp_servers_json=Some(
      "{\"notebook\":{\"type\":\"stdio\",\"command\":\"node\"}}",
    ),
  )
  assert_true(cmds[2].args[3].contains("\"notebook\""))
}

///|
test "remote_spawn_commands local side is direct ssh argv (no local shell wrapper)" {
  let spec = @types.SpawnSpec::{
    slug: "remote-worker",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "t",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.remote_spawn_commands(
    spec, "user@host", "git@github.com:org/r.git", "127.0.0.1:9",
  )
  assert_eq(cmds.length(), 3)
  for cmd in cmds {
    assert_eq(cmd.program, "ssh")
    @debug.assert_eq(cmd.workdir, None)
    assert_eq(cmd.args.length(), 4)
    assert_eq(cmd.args[0], "-o")
    assert_eq(cmd.args[1], "StrictHostKeyChecking=no")
    assert_eq(cmd.args[2], "user@host")
  }
}

///|
test "validate_reuse_spawn_spec rejects missing reuse_git_branch" {
  let spec = @types.SpawnSpec::{
    slug: "n",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "t",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: true,
    workspace_slug: Some("old"),
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  match @workspace.validate_reuse_spawn_spec(spec) {
    Ok(_) => fail("expected validation error")
    Err(_) => ()
  }
}

///|
test "spawn_commands worktree reuse skips destructive bootstrap" {
  let spec = @types.SpawnSpec::{
    slug: "replacement",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "continue",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: true,
    workspace_slug: Some("salvage"),
    reuse_git_branch: Some("main.salvage"),
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[0].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[0].args[1], "config.toml")
}

///|
test "spawn_git_branch honors reuse_git_branch" {
  let spec = @types.SpawnSpec::{
    slug: "replacement",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "t",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: true,
    workspace_slug: Some("s"),
    reuse_git_branch: Some("main.original"),
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  assert_eq(@workspace.spawn_git_branch(spec), "main.original")
}

///|
fn escape_workspace_test_toml_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
test "task_contract_for_agent finds inline worker metadata" {
  let project_dir = "/tmp/choir-ws-inline-task-contract-" +
    @sys.get_pid().to_string()
  let agent_id = "main.worker-a"
  let metadata_dir = @workspace.inline_agent_metadata_dir(project_dir, agent_id)
  assert_true(@sys.create_dir_all(metadata_dir + "/.choir"))
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "read bead",
    beads_issue_id: Some("choir-beads-live-smoke"),
  }
  ignore(
    @sys.write_file_sync(
      metadata_dir + "/.choir/config.local.toml",
      "task_contract_json = \"" +
      escape_workspace_test_toml_string(contract.to_json_string()) +
      "\"\n",
    ),
  )
  let agent : @types.Agent = {
    agent_id,
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Codex,
    parent: Some("main"),
    workspace: project_dir,
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  match @workspace.task_contract_for_agent(project_dir, agent) {
    Some(parsed) => {
      assert_eq(parsed.goal, "read bead")
      @debug.assert_eq(parsed.beads_issue_id, Some("choir-beads-live-smoke"))
    }
    None => fail("expected inline task contract")
  }
  @debug.assert_eq(
    @workspace.beads_issue_id_for_agent(project_dir, agent),
    Some("choir-beads-live-smoke"),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
test "zellij_create_background_session passes --layout for choir session" {
  let cmd = @workspace.zellij_create_background_session("choir")
  @debug.assert_eq(cmd.program, "zellij")
  @debug.assert_eq(cmd.args, [
    "--layout", "zjbar", "attach", "--create-background", "choir",
  ])
}
