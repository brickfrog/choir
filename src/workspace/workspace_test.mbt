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
  assert_eq(
    @workspace.parent_branch("main.subtl.leaf-task"),
    Some("main.subtl"),
  )
}

///|
test "parent branch returns none for root branch" {
  assert_eq(@workspace.parent_branch("main"), None)
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
  assert_eq(cmd.args, [
    "worktree", "add", "/path/to/worktree", "-b", "main.test-slug", "main",
  ])
}

///|
test "git_fetch_origin_branch_best_effort runs fetch in project dir" {
  let cmd = @workspace.git_fetch_origin_branch_best_effort("/repo", "main")
  assert_eq(
    cmd.program,
    @workspace.native_git_fetch_origin_branch_best_effort_program,
  )
  assert_eq(cmd.args, ["/repo", "main"])
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
  assert_eq(cmd.args, [
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
  assert_true(script.contains("choir tl-policy-watch --pid"))
  assert_true(script.contains("exec claude"))
  assert_false(script.contains("child_pid=$!"))
  assert_true(script.contains("[TL exited]"))
  assert_true(script.contains("exec bash -l"))
}

///|
test "normalize_tl_type maps agent alias" {
  assert_eq(@workspace.normalize_tl_type("agent"), "cursor_agent")
  assert_eq(@workspace.normalize_tl_type("cursor_agent"), "cursor_agent")
  assert_eq(@workspace.normalize_tl_type("codex"), "codex")
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
  assert_eq(cmd.args, ["NO_COLOR=1", "zellij", "list-sessions"])
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
  assert_eq(cmd.args, [
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
  assert_eq(cmd_claude.workdir, Some("/path"))

  assert_eq(cmd_gemini.program, "gemini")
  assert_eq(cmd_gemini.args, ["--yolo", "--prompt-interactive", "fix bugs"])
  assert_eq(cmd_gemini.workdir, Some("/path"))

  assert_eq(cmd_moon.program, "moon")
  assert_eq(cmd_moon.args, ["pilot", "fix bugs"])
  assert_eq(cmd_moon.workdir, Some("/path"))

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
  assert_eq(cmd_codex.workdir, Some("/path"))

  let spec_cursor = { ..spec_claude, agent_type: @types.AgentType::CursorAgent }
  let cmd_cursor = @workspace.agent_launch_command(spec_cursor, "/path")
  assert_eq(cmd_cursor.program, "agent")
  assert_eq(cmd_cursor.args[0], "--yolo")
  assert_eq(cmd_cursor.args[1], "--approve-mcps")
  assert_eq(cmd_cursor.args[2], "--workspace")
  assert_eq(cmd_cursor.args[3], "/path")
  assert_eq(cmd_cursor.args[4], "fix bugs")
  assert_eq(cmd_cursor.workdir, Some("/path"))
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
  assert_eq(cmd.workdir, Some("/path"))
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
  assert_eq(cmd.workdir, Some("/path"))
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
  // cleanup, fetch parent, git worktree add from origin/<parent>, configs, helpers, zellij
  assert_eq(cmds.length(), 7)
  assert_eq(
    cmds[0].program,
    @workspace.native_worktree_bootstrap_cleanup_program,
  )
  assert_eq(cmds[0].args, [
    "/project", "/project/.choir/worktrees/test-slug", "main.test-slug",
  ])
  assert_eq(
    cmds[1].program,
    @workspace.native_git_fetch_origin_branch_best_effort_program,
  )
  assert_eq(cmds[1].args, ["/project", "main"])
  assert_eq(cmds[2].program, "git")
  assert_eq(cmds[2].args, [
    "worktree", "add", "/project/.choir/worktrees/test-slug", "-b", "main.test-slug",
    "origin/main",
  ])
  assert_eq(cmds[5].program, @workspace.native_leaf_helpers_program)
  assert_eq(cmds[5].args, ["/project/.choir/worktrees/test-slug"])
  assert_eq(cmds[6].program, "zellij")
  assert_eq(cmds[6].args[3], "new-tab")
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
  assert_eq(cmds.length(), 7)
  assert_eq(cmds[3].program, @workspace.native_write_choir_file_program)
  assert_true(cmds[3].args[0].contains("feature-a"))
  assert_eq(cmds[3].args[1], "config.toml")
  assert_true(cmds[3].args[2].contains("default_role = \"dev\""))
  assert_true(
    cmds[3].args[2].contains("listen_uds = \"/proj/.choir/server.sock\""),
  )
  assert_true(cmds[3].args[2].contains("terminal_session = \"exo\""))
  assert_eq(cmds[4].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[4].args[1], "config.local.toml")
  assert_true(cmds[4].args[2].contains("agent_id = \"main.feature-a\""))
  assert_true(cmds[4].args[2].contains("parent_id = \"root\""))
  assert_true(
    cmds[4].args[2].contains("terminal_target = \"zellij-tab:exo:feature-a\""),
  )
  assert_eq(cmds[5].program, @workspace.native_leaf_helpers_program)
  assert_eq(cmds[6].program, "zellij")
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
test "spawn_commands gemini worktree adds trust and settings" {
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
  assert_eq(cmds.length(), 9)
  assert_eq(cmds[6].program, "choir")
  assert_eq(cmds[7].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[7].args[1], "gemini-settings.json")
  assert_eq(cmds[8].program, "zellij")
  assert_eq(cmds[8].args[3], "new-tab")
  assert_true(
    cmds[4].args[2].contains("terminal_target = \"zellij-tab:howdy:feature-z\""),
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
  assert_eq(cmds[3].args, ["/proj/.choir/agents/standalone-task"])
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
  assert_eq(cmds.length(), 9)
  assert_eq(cmds[6].program, "choir")
  assert_eq(cmds[6].args, [
    "trust-gemini-folder", "/project/.choir/worktrees/gemini-slug",
  ])
  assert_eq(cmds[7].program, @workspace.native_write_choir_file_program)
  assert_eq(cmds[7].args[1], "gemini-settings.json")
  assert_true(cmds[7].args[2].contains("mcpServers"))
  assert_true(cmds[7].args[2].contains("main.gemini-slug"))
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
  // cleanup, fetch parent, worktree add from origin/<parent>, configs, helpers, mcp json, zellij
  assert_eq(cmds.length(), 8)
  assert_eq(cmds[6].program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cmds[6].args[1], ".cursor/mcp.json")
  assert_true(cmds[6].args[2].contains("mcpServers"))
  assert_true(cmds[6].args[2].contains("main.feature-c"))
  assert_eq(cmds[7].program, "zellij")
  assert_eq(cmds[7].args[3], "new-tab")
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
    joined.contains(
      "GEMINI_CLI_SYSTEM_SETTINGS_PATH=/proj/.choir/worktrees/feature-a/.choir/gemini-settings.json",
    ),
  )
}

///|
test "write_spawn_config and write_local_config use native choir file commands" {
  let spawn_cmd = @workspace.write_spawn_config("/wt", "a=toml")
  let local_cmd = @workspace.write_local_config("/wt", "b=toml")
  assert_eq(spawn_cmd.program, @workspace.native_write_choir_file_program)
  assert_eq(spawn_cmd.args, ["/wt", "config.toml", "a=toml"])
  assert_eq(local_cmd.program, @workspace.native_write_choir_file_program)
  assert_eq(local_cmd.args, ["/wt", "config.local.toml", "b=toml"])
}

///|
test "write_leaf_helper_scripts uses native leaf helper install command" {
  let cmd = @workspace.write_leaf_helper_scripts("/tmp/wt")
  assert_eq(cmd.program, @workspace.native_leaf_helpers_program)
  assert_eq(cmd.args, ["/tmp/wt"])
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
test "gemini settings and cursor mcp json use native file commands" {
  let gem = @workspace.write_gemini_settings("/wt", "main.leaf", "dev")
  assert_eq(gem.program, @workspace.native_write_choir_file_program)
  assert_eq(gem.args[1], "gemini-settings.json")
  assert_true(gem.args[2].contains("mcpServers"))
  let cur = @workspace.write_cursor_mcp_json("/wt", "main.leaf", "dev")
  assert_eq(cur.program, @workspace.native_write_workspace_rel_file_program)
  assert_eq(cur.args[1], ".cursor/mcp.json")
  assert_true(cur.args[2].contains("\"choir\""))
}

///|
test "provider_materialization_commands emits gemini trust/settings and cursor mcp" {
  let gem = @workspace.provider_materialization_commands(
    @types.AgentType::Gemini,
    "/proj",
    "/proj",
    "root",
    @types.Role::TL,
  )
  assert_eq(gem.length(), 2)
  assert_eq(gem[0].program, "choir")
  assert_eq(gem[1].program, @workspace.native_write_choir_file_program)
  assert_eq(gem[1].args[1], "gemini-settings.json")
  assert_true(gem[1].args[2].contains("\"--name\""))
  assert_true(gem[1].args[2].contains("\"root\""))
  assert_true(gem[1].args[2].contains("\"--role\""))
  assert_true(gem[1].args[2].contains("\"tl\""))

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
    program: "gemini",
    args: ["--prompt-interactive", "Reply with READY and then stop."],
    workdir: None,
  }
  assert_eq(
    cmd.to_string(),
    "gemini '--prompt-interactive' 'Reply with READY and then stop.'",
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
    assert_eq(cmd.workdir, None)
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
test "task_contract_for_agent_workspace falls back when first config lacks task_contract" {
  let project_dir = "/tmp/choir-ws-task-contract-" + @sys.get_pid().to_string()
  let agent_workspace = project_dir + "/alt-workspace"
  let fallback_workspace = @workspace.worktree_path(project_dir, "leaf")
  assert_true(@sys.create_dir_all(agent_workspace))
  assert_true(@sys.create_dir_all(fallback_workspace))
  ignore(
    @sys.write_file_sync(
      agent_workspace + "/config.local.toml",
      (
        #|automerge = true
      ),
    ),
  )
  ignore(
    @sys.write_file_sync(
      fallback_workspace + "/config.local.toml",
      "task_contract_json = \"" +
      escape_workspace_test_toml_string(
        { ..@types.TaskContract::empty(), goal: "restore fallback" }.to_json_string(),
      ) +
      "\"\n",
    ),
  )
  match
    @workspace.task_contract_for_agent_workspace(
      project_dir,
      Some(agent_workspace),
      "leaf",
    ) {
    Some(contract) => assert_eq(contract.goal, "restore fallback")
    None => fail("expected fallback task contract")
  }
}
