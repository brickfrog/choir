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
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main.subtl",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
test "zellij_new_tab args" {
  let cmd = @workspace.zellij_new_tab(
    "howdy", "leaf-a", "/path/to/worktree", "echo READY",
  )
  assert_eq(cmd.program, "zellij")
  assert_eq(cmd.args, [
    "--session", "howdy", "action", "new-tab", "--name", "leaf-a", "--cwd", "/path/to/worktree",
    "--", "sh", "-lc", "echo READY",
  ])
}

///|
test "zellij_session_exists matches exact session names" {
  let cmd = @workspace.zellij_session_exists("choir")
  assert_eq(cmd.program, "sh")
  assert_true(cmd.args[1].contains("sed -E"))
  assert_true(cmd.args[1].contains("awk -v target=\"$1\""))
  assert_true(cmd.args[1].contains("$0 !~ /\\(EXITED/"))
  assert_eq(cmd.args[3], "choir")
}

///|
test "agent_launch_command for each AgentType" {
  let spec_claude = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
  assert_true(cmd_codex.args[3].contains("mcp_servers.choir.command"))
  assert_eq(cmd_codex.args[4], "-c")
  assert_true(
    cmd_codex.args[5].contains("mcp-stdio --role dev --name 'main.test-slug'"),
  )
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
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
test "agent_launch_command supports Claude fork_session" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 1,
  }
  let target = match @types.LocalTarget::parse("zellij-tab:choir:subtl-0") {
    Some(t) => t
    None => fail("expected target")
  }
  let content = @workspace.config_local_content(spec, "/tmp/wt", target)
  assert_true(content.contains("role = \"tl\""))
  assert_true(content.contains("spawn_depth = 1"))
}

///|
test "spawn_commands for worktree mode returns zellij tab" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  // cleanup, git worktree add, config.toml, config.local.toml, helpers, zellij new-tab
  assert_eq(cmds.length(), 6)
  assert_eq(cmds[0].program, "sh")
  assert_true(cmds[0].args[1].contains("git worktree remove --force"))
  assert_eq(cmds[1].program, "git")
  assert_eq(cmds[4].program, "sh")
  assert_true(cmds[4].args[1].contains("choir leaf-tool"))
  assert_eq(cmds[5].program, "zellij")
  assert_eq(cmds[5].args[3], "new-tab")
}

///|
test "spawn_commands worktree config write content" {
  let spec = @types.SpawnSpec::{
    slug: "feature-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "do something",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  assert_eq(cmds.length(), 6)
  assert_eq(cmds[2].program, "sh")
  assert_true(cmds[2].args[3].contains("feature-a"))
  assert_true(cmds[2].args[4].contains("default_role = \"dev\""))
  assert_true(
    cmds[2].args[4].contains("listen_uds = \"/proj/.choir/server.sock\""),
  )
  assert_true(cmds[2].args[4].contains("terminal_session = \"exo\""))
  assert_eq(cmds[3].program, "sh")
  assert_true(cmds[3].args[4].contains("agent_id = \"main.feature-a\""))
  assert_true(cmds[3].args[4].contains("parent_id = \"root\""))
  assert_true(
    cmds[3].args[4].contains("terminal_target = \"zellij-tab:exo:feature-a\""),
  )
  assert_eq(cmds[4].program, "sh")
  assert_eq(cmds[5].program, "zellij")
}

///|
test "spawn_commands gemini worktree adds trust and settings" {
  let spec = @types.SpawnSpec::{
    slug: "feature-z",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do something",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "howdy")
  assert_eq(cmds.length(), 8)
  assert_eq(cmds[5].program, "choir")
  assert_eq(cmds[6].program, "sh")
  assert_eq(cmds[7].program, "zellij")
  assert_eq(cmds[7].args[3], "new-tab")
  assert_true(
    cmds[3].args[4].contains("terminal_target = \"zellij-tab:howdy:feature-z\""),
  )
}

///|
test "spawn_commands standalone includes config writes" {
  let spec = @types.SpawnSpec::{
    slug: "standalone-task",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "do something",
    isolation: @types.IsolationMode::Standalone,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  // git init, config.toml, config.local.toml, helpers, zellij new-tab
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[1].program, "sh")
  assert_true(
    cmds[1].args[4].contains("listen_uds = \"/proj/.choir/server.sock\""),
  )
  assert_true(
    cmds[2].args[4].contains(
      "workspace = \"/proj/.choir/agents/standalone-task\"",
    ),
  )
  assert_eq(cmds[3].program, "sh")
  assert_true(cmds[3].args[1].contains("task_create"))
}

///|
test "spawn_commands adds Gemini trust bootstrap" {
  let spec = @types.SpawnSpec::{
    slug: "gemini-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "fix bugs",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  assert_eq(cmds.length(), 8)
  assert_eq(cmds[5].program, "choir")
  assert_eq(cmds[5].args, [
    "trust-gemini-folder", "/project/.choir/worktrees/gemini-slug",
  ])
  assert_eq(cmds[6].program, "sh")
  assert_true(cmds[6].args[1].contains(".choir/gemini-settings.json"))
  assert_true(cmds[6].args[4].contains("mcpServers"))
  assert_true(cmds[6].args[4].contains("main.gemini-slug"))
}

///|
test "spawn_commands cursor_agent worktree adds mcp json" {
  let spec = @types.SpawnSpec::{
    slug: "feature-c",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "do something",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "howdy")
  // cleanup, worktree add, config.toml, config.local.toml, helpers, .cursor/mcp.json, zellij new-tab
  assert_eq(cmds.length(), 7)
  assert_eq(cmds[5].program, "sh")
  assert_true(cmds[5].args[1].contains(".cursor"))
  assert_true(cmds[5].args[4].contains("mcpServers"))
  assert_true(cmds[5].args[4].contains("main.feature-c"))
  assert_eq(cmds[6].program, "zellij")
  assert_eq(cmds[6].args[3], "new-tab")
}

///|
test "spawn_commands for inline mode uses zellij run" {
  let spec = @types.SpawnSpec::{
    slug: "worker-a",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::MoonPilot,
    task: "reply READY",
    isolation: @types.IsolationMode::Inline,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "howdy")
  assert_eq(cmds.length(), 1)
  assert_eq(cmds[0].program, "zellij")
  assert_eq(cmds[0].args[0], "--session")
  assert_eq(cmds[0].args[1], "howdy")
  assert_eq(cmds[0].args[2], "run")
  assert_eq(cmds[0].args[4], "worker-a")
  assert_true(
    cmds[0].args[10].contains(
      "CHOIR_TERMINAL_TARGET='zellij-pane:howdy:worker-a'",
    ),
  )
}

///|
test "spawn_commands launch text contains env vars" {
  let spec = @types.SpawnSpec::{
    slug: "feature-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do something",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  // Last command is zellij new-tab, launch string is in the sh -lc arg
  let last = cmds[cmds.length() - 1]
  assert_eq(last.program, "zellij")
  assert_eq(last.args[3], "new-tab")
  let launch_str = last.args[last.args.length() - 1]
  assert_true(launch_str.contains("CHOIR_AGENT_ID='main.feature-a'"))
  assert_true(
    launch_str.contains("CHOIR_TERMINAL_TARGET='zellij-tab:exo:feature-a'"),
  )
  assert_true(launch_str.contains("CHOIR_PARENT_AGENT='root'"))
  assert_true(
    launch_str.contains(
      "GEMINI_CLI_SYSTEM_SETTINGS_PATH='/proj/.choir/worktrees/feature-a/.choir/gemini-settings.json'",
    ),
  )
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
test "remote_spawn_commands produces 4 ssh commands" {
  let spec = @types.SpawnSpec::{
    slug: "remote-worker",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "implement feature Y",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
  assert_true(cmds[1].args[3].contains("config.toml"))
  assert_true(cmds[1].args[3].contains("10.0.0.1:9100"))
  assert_true(cmds[2].args[3].contains("claude"))
  assert_true(cmds[2].args[3].contains("CHOIR_AGENT_ID='main.remote-worker'"))
  assert_true(cmds[2].args[3].contains("CHOIR_PARENT_AGENT='root'"))
}

///|
test "validate_reuse_spawn_spec rejects missing reuse_git_branch" {
  let spec = @types.SpawnSpec::{
    slug: "n",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "t",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: true,
    workspace_slug: Some("old"),
    reuse_git_branch: None,
    spawn_depth: 0,
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
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: true,
    workspace_slug: Some("salvage"),
    reuse_git_branch: Some("main.salvage"),
    spawn_depth: 0,
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[0].program, "sh")
  assert_false(cmds[0].args[1].contains("git worktree remove"))
}

///|
test "spawn_git_branch honors reuse_git_branch" {
  let spec = @types.SpawnSpec::{
    slug: "replacement",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::CursorAgent,
    task: "t",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: true,
    workspace_slug: Some("s"),
    reuse_git_branch: Some("main.original"),
    spawn_depth: 0,
  }
  assert_eq(@workspace.spawn_git_branch(spec), "main.original")
}
