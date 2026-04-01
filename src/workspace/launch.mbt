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
fn codex_mcp_override_args(
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
pub fn agent_launch_command(
  spec : @types.SpawnSpec,
  workspace_path : String,
  parent_session_id? : String? = None,
  shell_command? : String? = None,
  extra_mcp_servers_json? : String? = None,
) -> Command {
  let claude_mcp = claude_mcp_args(
    spec.role,
    canonical_agent_id(spec),
    extra_mcp_servers_json~,
  )
  let cmd = match spec.agent_type {
    Claude =>
      match parent_session_id {
        Some(session_id) =>
          {
            program: "claude",
            args: [
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
            program: "claude",
            args: ["--dangerously-skip-permissions", ..claude_mcp, spec.task],
            workdir: Some(workspace_path),
          }
      }
    Gemini =>
      {
        program: "gemini",
        args: ["--yolo", "--prompt-interactive", spec.task],
        workdir: Some(workspace_path),
      }
    MoonPilot =>
      {
        program: "moon",
        args: ["pilot", spec.task],
        workdir: Some(workspace_path),
      }
    Codex =>
      {
        program: "codex",
        args: [
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
        program: "agent",
        args: [
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
        program: "pi",
        args: [
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
