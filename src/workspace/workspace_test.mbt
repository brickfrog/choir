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
  }
  assert_eq(@workspace.canonical_agent_id(spec), "main.subtl.leaf-task")
}

///|
test "git_worktree_add args" {
  let cmd = @workspace.git_worktree_add("/path/to/worktree", "main.test-slug")
  assert_eq(cmd.program, "git")
  assert_eq(cmd.args, [
    "worktree", "add", "/path/to/worktree", "-b", "main.test-slug",
  ])
}

///|
test "tmux_new_window args" {
  let cmd = @workspace.tmux_new_window(
    "my-session", "test-slug", "/path/to/worktree",
  )
  assert_eq(cmd.program, "tmux")
  assert_eq(cmd.args, [
    "new-window", "-t", "my-session", "-n", "test-slug", "-c", "/path/to/worktree",
  ])
}

///|
test "tmux_send_keys args" {
  let cmd = @workspace.tmux_send_keys("my-session:test-slug", "echo hello")
  assert_eq(cmd.program, "tmux")
  assert_eq(cmd.args, [
    "send-keys", "-t", "my-session:test-slug", "echo hello", "C-m",
  ])
}

///|
test "parse_local_target supports zellij targets" {
  match @workspace.parse_local_target("zellij-tab:howdy:leaf-a") {
    Some(target) => {
      assert_eq(target.kind, @workspace.LocalTargetKind::ZellijTab)
      assert_eq(target.session, "howdy")
      assert_eq(target.name, "leaf-a")
    }
    None => fail("expected zellij tab target")
  }
  match @workspace.parse_local_target("zellij-pane:howdy:worker-a") {
    Some(target) => {
      assert_eq(target.kind, @workspace.LocalTargetKind::ZellijPane)
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
  assert_true(cmd.args[1].contains("awk '{print $1}'"))
  assert_true(cmd.args[1].contains("grep -Fx -- \"$1\""))
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
  }
  let spec_gemini = { ..spec_claude, agent_type: @types.AgentType::Gemini }
  let spec_moon = { ..spec_claude, agent_type: @types.AgentType::MoonPilot }

  let cmd_claude = @workspace.agent_launch_command(spec_claude, "/path")
  let cmd_gemini = @workspace.agent_launch_command(spec_gemini, "/path")
  let cmd_moon = @workspace.agent_launch_command(spec_moon, "/path")

  assert_eq(cmd_claude.program, "claude")
  assert_eq(cmd_claude.args, ["--dangerously-skip-permissions", "fix bugs"])
  assert_eq(cmd_claude.workdir, Some("/path"))

  assert_eq(cmd_gemini.program, "gemini")
  assert_eq(cmd_gemini.args, ["--prompt-interactive", "fix bugs"])
  assert_eq(cmd_gemini.workdir, Some("/path"))

  assert_eq(cmd_moon.program, "moon")
  assert_eq(cmd_moon.args, ["pilot", "fix bugs"])
  assert_eq(cmd_moon.workdir, Some("/path"))
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
  }
  let cmd = @workspace.agent_launch_command(
    spec,
    "/path",
    shell_command=Some("nix develop"),
  )
  assert_eq(cmd.program, "nix")
  assert_eq(cmd.args, [
    "develop", "--command", "claude", "--dangerously-skip-permissions", "fix bugs",
  ])
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
  }
  let cmd = @workspace.agent_launch_command(spec, "/path", shell_command=None)
  assert_eq(cmd.program, "claude")
  assert_eq(cmd.args, ["--dangerously-skip-permissions", "fix bugs"])
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
  }
  let cmd = @workspace.agent_launch_command(
    spec,
    "/path",
    parent_session_id=Some("session-123"),
  )
  assert_eq(cmd.program, "claude")
  assert_eq(cmd.args, [
    "--dangerously-skip-permissions", "--resume", "session-123", "--fork-session",
    "fix bugs",
  ])
}

///|
test "child_config_content resolves socket path into spawned worktree config" {
  let content = @workspace.child_config_content(
    @types.Role::Dev,
    @types.TerminalBackend::Zellij,
    "choir-test",
    "/project",
    ".choir/server.sock",
    tcp_auth_token=Some("abc123"),
  )
  assert_true(content.contains("default_role = \"dev\""))
  assert_true(content.contains("project_dir = \"/project\""))
  assert_true(content.contains("listen_uds = \"/project/.choir/server.sock\""))
  assert_true(content.contains("terminal_session = \"choir-test\""))
  assert_true(content.contains("terminal_backend = \"zellij\""))
  assert_true(content.contains("tcp_auth_token = \"abc123\""))
}

///|
test "spawn_commands for worktree mode returns helper and config commands" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  // git worktree add, write config.toml, write config.local.toml, write .mcp.json, write helpers, tmux new-window, tmux send-keys
  assert_eq(cmds.length(), 7)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[1].program, "sh")
  assert_eq(cmds[2].program, "sh")
  assert_eq(cmds[3].program, "sh")
  assert_eq(cmds[4].program, "sh")
  assert_eq(cmds[5].program, "tmux")
  assert_eq(cmds[6].program, "tmux")
  assert_eq(cmds[5].args[0], "new-window")
  assert_true(cmds[4].args[1].contains("choir leaf-tool"))
  assert_true(cmds[4].args[1].contains("notify_parent"))
  assert_true(cmds[6].args[3].contains(".choir/bin"))
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
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  assert_eq(cmds.length(), 7)
  // config.toml write: positional args — $1=worktree_path, $2=content
  assert_eq(cmds[1].program, "sh")
  assert_true(cmds[1].args[3].contains("feature-a")) // worktree path
  assert_true(cmds[1].args[4].contains("default_role = \"dev\""))
  assert_true(
    cmds[1].args[4].contains("listen_uds = \"/proj/.choir/server.sock\""),
  )
  assert_true(cmds[1].args[4].contains("terminal_session = \"exo\""))
  assert_true(cmds[1].args[4].contains("terminal_backend = \"tmux\""))
  // config.local.toml write: positional args — $1=worktree_path, $2=content
  assert_eq(cmds[2].program, "sh")
  assert_true(cmds[2].args[3].contains("feature-a")) // worktree path
  assert_true(cmds[2].args[4].contains("dev")) // role content
  assert_true(cmds[2].args[4].contains("agent_id = \"main.feature-a\""))
  assert_true(cmds[2].args[4].contains("parent_id = \"root\""))
  assert_true(cmds[2].args[4].contains("terminal_target = \"exo:feature-a\""))
  // .mcp.json write: positional args — $1=worktree_path, $2=json
  assert_eq(cmds[3].program, "sh")
  assert_true(cmds[3].args[3].contains("feature-a")) // worktree path
  assert_true(cmds[3].args[4].contains("--role")) // mcp json has role arg
  assert_true(cmds[3].args[4].contains("main.feature-a")) // canonical agent id
  assert_true(cmds[6].args[3].contains("PATH="))
}

///|
test "spawn_commands for zellij worktree uses new tab target" {
  let spec = @types.SpawnSpec::{
    slug: "feature-z",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do something",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
  }
  let cmds = @workspace.spawn_commands(
    spec,
    "/proj",
    "howdy",
    terminal_backend=@types.TerminalBackend::Zellij,
  )
  assert_eq(cmds.length(), 7)
  assert_eq(cmds[5].program, "choir")
  assert_eq(cmds[6].program, "zellij")
  assert_eq(cmds[6].args[0], "--session")
  assert_eq(cmds[6].args[1], "howdy")
  assert_eq(cmds[6].args[2], "action")
  assert_eq(cmds[6].args[3], "new-tab")
  assert_true(
    cmds[2].args[4].contains("terminal_target = \"zellij-tab:howdy:feature-z\""),
  )
  assert_true(
    cmds[6].args[11].contains(
      "CHOIR_TERMINAL_TARGET='zellij-tab:howdy:feature-z'",
    ),
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
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  // git init, write config.toml, write config.local.toml, write .mcp.json, write helpers, tmux new-window, tmux send-keys
  assert_eq(cmds.length(), 7)
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
  assert_true(cmds[3].args[4].contains("--role"))
  assert_true(cmds[4].args[1].contains("task_create"))
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
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  assert_eq(cmds.length(), 8)
  assert_eq(cmds[5].program, "choir")
  assert_eq(cmds[5].args, [
    "trust-gemini-folder", "/project/.choir/worktrees/gemini-slug",
  ])
}

///|
test "spawn_commands for inline mode skips git worktree" {
  let spec = @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: "fix bugs",
    isolation: @types.IsolationMode::Inline,
    parent_id: "main",
    parent_branch: "main",
  }
  let cmds = @workspace.spawn_commands(spec, "/project", "session")
  assert_eq(cmds.length(), 2)
  assert_eq(cmds[0].program, "tmux")
  assert_eq(cmds[0].args[0], "split-window")
  assert_eq(cmds[1].program, "tmux")
}

///|
test "spawn_commands for zellij inline uses named pane" {
  let spec = @types.SpawnSpec::{
    slug: "worker-a",
    role: @types.Role::Worker,
    agent_type: @types.AgentType::MoonPilot,
    task: "reply READY",
    isolation: @types.IsolationMode::Inline,
    parent_id: "root",
    parent_branch: "main",
  }
  let cmds = @workspace.spawn_commands(
    spec,
    "/project",
    "howdy",
    terminal_backend=@types.TerminalBackend::Zellij,
  )
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
test "spawn_commands launch text does not duplicate workdir cd" {
  let spec = @types.SpawnSpec::{
    slug: "feature-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "do something",
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
  }
  let cmds = @workspace.spawn_commands(spec, "/proj", "exo")
  assert_eq(cmds[7].program, "tmux")
  assert_eq(cmds[7].args[0], "send-keys")
  assert_eq(cmds[7].args[1], "-t")
  assert_eq(cmds[7].args[2], "exo:feature-a")
  assert_true(cmds[7].args[3].contains("CHOIR_AGENT_ID='main.feature-a'"))
  assert_true(cmds[7].args[3].contains("CHOIR_TERMINAL_TARGET='exo:feature-a'"))
  assert_true(cmds[7].args[3].contains("EXOMONAD_PARENT_AGENT='root'"))
  assert_true(
    cmds[7].args[3].contains("gemini '--prompt-interactive' 'do something'"),
  )
  assert_eq(cmds[7].args[4], "C-m")
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
    args: ["--dangerously-skip-permissions", "hello"],
    workdir: Some("/path"),
  }
  assert_eq(
    cmd2.to_string(),
    "cd '/path' && claude '--dangerously-skip-permissions' 'hello'",
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
  }
  let cmds = @workspace.remote_spawn_commands(
    spec, "user@remote-host", "git@github.com:org/repo.git", "10.0.0.1:9100",
  )
  assert_eq(cmds.length(), 4)
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
  assert_true(cmds[2].args[3].contains(".mcp.json"))
  assert_true(cmds[3].args[3].contains("claude"))
  assert_true(cmds[3].args[3].contains("CHOIR_AGENT_ID='main.remote-worker'"))
  assert_true(cmds[3].args[3].contains("EXOMONAD_PARENT_AGENT='root'"))
}
