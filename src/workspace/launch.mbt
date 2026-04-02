///|
fn wrap_with_shell(cmd : Command, shell : String) -> Command {
  let parts : Array[String] = []
  let mut start = 0
  for i = 0; i <= shell.length(); i = i + 1 {
    if i == shell.length() || shell[i] == ' ' {
      if i > start {
        parts.push(shell[start:i].to_string())
      }
      start = i + 1
    }
  }
  if parts.is_empty() {
    return cmd
  }
  let program = parts[0]
  let new_args : Array[String] = []
  for i = 1; i < parts.length(); i = i + 1 {
    new_args.push(parts[i])
  }
  new_args.push("--command")
  new_args.push(cmd.program)
  for arg in cmd.args {
    new_args.push(arg)
  }
  { program, args: new_args, workdir: cmd.workdir }
}

///|
pub fn codex_mcp_override_args(
  role : @types.Role,
  agent_id : String,
  workspace_path : String,
) -> Array[String] {
  // Codex MCP stdio: direct `choir` argv (no `sh -lc`). Socket wait and stderr log
  // are handled inside `mcp-stdio` via `--wait-socket-tries` / `--stderr-append-log`.
  let elems : Array[String] = match role {
    @types.Role::TL =>
      [
        "mcp-stdio", "--raw-stdio", "--name", agent_id, "--wait-socket-tries", "300",
        "--stderr-append-log", ".choir/mcp-stdio.stderr.log",
      ]
    _ =>
      [
        "mcp-stdio",
        "--raw-stdio",
        "--role",
        @config.role_to_string(role),
        "--name",
        agent_id,
        "--wait-socket-tries",
        "300",
        "--stderr-append-log",
        ".choir/mcp-stdio.stderr.log",
      ]
  }
  // ~60s max wait: native poll is 200ms/tick (see `choir_wait_for_socket`).
  let args_lit = toml_string_array_literal(elems)
  [
    "-c",
    "mcp_servers.choir.command=\"choir\"",
    "-c",
    "mcp_servers.choir.args=" + args_lit,
    "-c",
    "mcp_servers.choir.cwd=\"" + escape_toml_string(workspace_path) + "\"",
  ]
}

///|
fn claude_mcp_args(
  role : @types.Role,
  agent_id : String,
  extra_mcp_servers_json? : String? = None,
) -> Array[String] {
  [
    "--mcp-config",
    mcp_json_content(role, agent_id, extra_mcp_servers_json~),
    "--strict-mcp-config",
  ]
}

///|
fn split_words(s : String) -> Array[String] {
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
pub fn agent_launch_command(
  spec : @types.SpawnSpec,
  workspace_path : String,
  parent_session_id? : String? = None,
  shell_command? : String? = None,
  command_override? : String? = None,
  extra_mcp_servers_json? : String? = None,
) -> Command {
  let parts = match command_override {
    Some(cmd) => split_words(cmd)
    None => []
  }
  let cmd_program = if parts.is_empty() { None } else { Some(parts[0]) }
  let cmd_extra_args = if parts.length() > 1 {
    let tail = []
    for i = 1; i < parts.length(); i = i + 1 {
      tail.push(parts[i])
    }
    tail
  } else {
    []
  }
  let claude_mcp = claude_mcp_args(
    spec.role,
    canonical_agent_id(spec),
    extra_mcp_servers_json~,
  )
  let cmd = match spec.agent_type {
    Claude => {
      let program = cmd_program.unwrap_or("claude")
      match parent_session_id {
        Some(session_id) =>
          {
            program,
            args: [
              ..cmd_extra_args,
              "--dangerously-skip-permissions",
              ..claude_mcp,
              "--resume",
              session_id,
              "--fork-session",
              spec.task,
            ],
            workdir: Some(workspace_path),
          }
        None =>
          {
            program,
            args: [
              ..cmd_extra_args,
              "--dangerously-skip-permissions",
              ..claude_mcp,
              spec.task,
            ],
            workdir: Some(workspace_path),
          }
      }
    }
    Gemini =>
      {
        program: cmd_program.unwrap_or("gemini"),
        args: [..cmd_extra_args, "--yolo", "--prompt-interactive", spec.task],
        workdir: Some(workspace_path),
      }
    MoonPilot =>
      {
        program: cmd_program.unwrap_or("moon"),
        args: [..cmd_extra_args, "pilot", spec.task],
        workdir: Some(workspace_path),
      }
    Codex =>
      {
        program: cmd_program.unwrap_or("codex"),
        args: [
          ..cmd_extra_args,
          "--dangerously-bypass-approvals-and-sandbox",
          "--no-alt-screen",
          ..codex_mcp_override_args(
            spec.role,
            canonical_agent_id(spec),
            workspace_path,
          ),
          "-C",
          workspace_path,
          spec.task,
        ],
        workdir: Some(workspace_path),
      }
    CursorAgent =>
      {
        program: cmd_program.unwrap_or("agent"),
        args: [
          ..cmd_extra_args,
          "--yolo",
          "--approve-mcps",
          "--workspace",
          workspace_path,
          spec.task,
        ],
        workdir: Some(workspace_path),
      }
    Pi => {
      let runtime_root = pi_runtime_root(
        workspace_path,
        canonical_agent_id(spec),
        spec.isolation,
      )
      let role_str = @config.role_to_string(spec.role)
      {
        program: cmd_program.unwrap_or("pi"),
        args: [
          ..cmd_extra_args,
          "--no-extensions",
          "-e",
          pi_extension_path(runtime_root),
          "--no-skills",
          "--no-prompt-templates",
          "--no-themes",
          "--session-dir",
          pi_session_dir(runtime_root),
          "--tools",
          pi_default_builtin_tools(role_str),
          "--thinking",
          pi_default_thinking_level(role_str),
          "--append-system-prompt",
          pi_append_system_prompt(spec.role),
          spec.task,
        ],
        workdir: Some(workspace_path),
      }
    }
  }
  match shell_command {
    Some(shell) => wrap_with_shell(cmd, shell)
    _ => cmd
  }
}

///|
/// MCP JSON for TL init Claude only; matches legacy `choir init` (`mcp-stdio` + `--name root`, no `--role`).
pub fn init_tl_claude_mcp_config_json() -> String {
  "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--name\",\"root\"]}}}"
}

///|
/// Inner TL agent command for the init zellij tab (no post-exit trailer; that lives only in
/// [`init_tl_zellij_tab_command`]). Non-Pi kinds omit Choir env in the shell script; Pi moves env to
/// zellij `env` argv there while the agent line still comes from [`Command::to_string`].
pub fn init_tl_agent_command(tl_type : String, project_dir : String) -> Command {
  match tl_type {
    "codex" => {
      let args : Array[String] = [
        "--dangerously-bypass-approvals-and-sandbox",
        "--no-alt-screen",
        ..codex_mcp_override_args(@types.Role::TL, "root", project_dir),
        "-C",
        project_dir,
      ]
      { program: "codex", args, workdir: None }
    }
    "gemini" =>
      {
        program: "gemini",
        args: ["--yolo", "--prompt-interactive"],
        workdir: None,
      }
    "cursor_agent" =>
      {
        program: "agent",
        args: ["--yolo", "--approve-mcps", "--workspace", project_dir],
        workdir: None,
      }
    "pi" => {
      let spec : @types.SpawnSpec = {
        slug: "root",
        role: @types.Role::TL,
        agent_type: @types.AgentType::Pi,
        task: "",
        isolation: @types.IsolationMode::Worktree,
        parent_id: "root",
        parent_branch: "",
        reuse_workspace: true,
        workspace_slug: Some("root"),
        reuse_git_branch: Some("root"),
        spawn_depth: 0,
      }
      agent_launch_command(spec, project_dir)
    }
    _ =>
      {
        program: "claude",
        args: [
          "--dangerously-skip-permissions",
          "--mcp-config",
          init_tl_claude_mcp_config_json(),
          "--strict-mcp-config",
        ],
        workdir: None,
      }
  }
}
