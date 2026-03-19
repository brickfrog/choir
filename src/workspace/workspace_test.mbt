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
  assert_eq(cmd_claude.args, ["-p", "fix bugs"])
  assert_eq(cmd_claude.workdir, Some("/path"))

  assert_eq(cmd_gemini.program, "gemini")
  assert_eq(cmd_gemini.args, ["-p", "fix bugs"])
  assert_eq(cmd_gemini.workdir, Some("/path"))

  assert_eq(cmd_moon.program, "moon")
  assert_eq(cmd_moon.args, ["pilot", "-p", "fix bugs"])
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
  assert_eq(cmd.args, ["develop", "--command", "claude", "-p", "fix bugs"])
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
  assert_eq(cmd.args, ["-p", "fix bugs"])
}

///|
test "spawn_commands for worktree mode returns 5 commands" {
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
  // git worktree add, write config.local.toml, write .mcp.json, tmux new-window, tmux send-keys
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[1].program, "sh")
  assert_eq(cmds[2].program, "sh")
  assert_eq(cmds[3].program, "tmux")
  assert_eq(cmds[4].program, "tmux")
  assert_eq(cmds[3].args[0], "new-window")
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
  assert_eq(cmds.length(), 5)
  // config.local.toml write: positional args — $1=worktree_path, $2=content
  assert_eq(cmds[1].program, "sh")
  assert_true(cmds[1].args[3].contains("feature-a")) // worktree path
  assert_true(cmds[1].args[4].contains("dev")) // role content
  // .mcp.json write: positional args — $1=worktree_path, $2=json
  assert_eq(cmds[2].program, "sh")
  assert_true(cmds[2].args[3].contains("feature-a")) // worktree path
  assert_true(cmds[2].args[4].contains("--role")) // mcp json has role arg
  assert_true(cmds[2].args[4].contains("feature-a")) // mcp json has name arg
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
  // git init, write config.local.toml, write .mcp.json, tmux new-window, tmux send-keys
  assert_eq(cmds.length(), 5)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[1].program, "sh")
  assert_true(cmds[1].args[4].contains("dev"))
  assert_eq(cmds[2].program, "sh")
  assert_true(cmds[2].args[4].contains("--role"))
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
test "Command::to_string output" {
  let cmd1 = @workspace.Command::{
    program: "git",
    args: ["status"],
    workdir: None,
  }
  assert_eq(cmd1.to_string(), "git status")

  let cmd2 = @workspace.Command::{
    program: "claude",
    args: ["-p", "hello"],
    workdir: Some("/path"),
  }
  assert_eq(cmd2.to_string(), "cd /path && claude -p hello")
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
}
