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
  let role_args = match role {
    @types.Role::TL => ""
    _ => " --role " + @config.role_to_string(role)
  }
  let cmd = "i=0; while [ ! -S .choir/server.sock ] && [ \"$i\" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done; " +
    "exec choir mcp-stdio" +
    role_args +
    " --raw-stdio" +
    " --name " +
    @sys.shell_quote(agent_id) +
    " 2>> .choir/mcp-stdio.stderr.log"
  [
    "-c",
    "mcp_servers.choir.command=\"sh\"",
    "-c",
    "mcp_servers.choir.args=[\"-lc\", \"" + escape_toml_string(cmd) + "\"]",
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
