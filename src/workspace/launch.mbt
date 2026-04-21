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
pub fn normalize_tl_type(tl_type : String) -> String {
  match tl_type.trim().to_lower() {
    "agent" => "cursor_agent"
    other => other.to_string()
  }
}

///|
pub fn tl_type_agent_type(tl_type : String) -> @types.AgentType {
  match normalize_tl_type(tl_type) {
    "claude" => @types.AgentType::Claude
    "gemini" => @types.AgentType::Gemini
    "moon_pilot" => @types.AgentType::MoonPilot
    "moonpilot" => @types.AgentType::MoonPilot
    "codex" => @types.AgentType::Codex
    "cursor_agent" => @types.AgentType::CursorAgent
    "cursoragent" => @types.AgentType::CursorAgent
    _ => @types.AgentType::Claude
  }
}

///|
fn provider_launch_command(
  agent_type : @types.AgentType,
  role : @types.Role,
  agent_id : String,
  workspace_path : String,
  task? : String? = None,
  parent_session_id? : String? = None,
  cmd_program? : String? = None,
  cmd_extra_args? : Array[String] = [],
  extra_mcp_servers_json? : String? = None,
  tl_init_mode? : Bool = false,
  lean? : Bool = false,
) -> Command {
  let claude_mcp = if tl_init_mode {
    ["--mcp-config", init_tl_claude_mcp_config_json(), "--strict-mcp-config"]
  } else {
    claude_mcp_args(role, agent_id, extra_mcp_servers_json~)
  }
  let task_args = match task {
    Some(t) => [t]
    None => []
  }
  match agent_type {
    Claude => {
      let program = cmd_program.unwrap_or("claude")
      if tl_init_mode {
        let plugin_dir = workspace_path + "/.choir/plugin"
        let settings_path = workspace_path + "/.choir/claude-settings.json"
        let lean_args : Array[String] = if lean {
          ["--system-prompt", "."]
        } else {
          []
        }
        {
          program,
          args: [
            ..cmd_extra_args, "--dangerously-skip-permissions", ..claude_mcp, "--plugin-dir",
            plugin_dir, "--settings", settings_path, ..lean_args,
          ],
          workdir: Some(workspace_path),
        }
      } else {
        match parent_session_id {
          Some(session_id) =>
            {
              program,
              args: [
                ..cmd_extra_args, "--dangerously-skip-permissions", ..claude_mcp,
                "--resume", session_id, "--fork-session", ..task_args,
              ],
              workdir: Some(workspace_path),
            }
          None =>
            {
              program,
              args: [
                ..cmd_extra_args, "--dangerously-skip-permissions", ..claude_mcp,
                ..task_args,
              ],
              workdir: Some(workspace_path),
            }
        }
      }
    }
    Gemini =>
      {
        program: cmd_program.unwrap_or("gemini"),
        args: [..cmd_extra_args, "--yolo", "--prompt-interactive", ..task_args],
        workdir: Some(workspace_path),
      }
    MoonPilot =>
      {
        program: cmd_program.unwrap_or("moon"),
        args: [..cmd_extra_args, "pilot", ..task_args],
        workdir: Some(workspace_path),
      }
    Codex =>
      {
        program: cmd_program.unwrap_or("codex"),
        args: [
          ..cmd_extra_args,
          "--dangerously-bypass-approvals-and-sandbox",
          "--no-alt-screen",
          ..codex_mcp_override_args(role, agent_id, workspace_path),
          "-C",
          workspace_path,
          ..task_args,
        ],
        workdir: Some(workspace_path),
      }
    CursorAgent =>
      {
        program: cmd_program.unwrap_or("agent"),
        args: [
          ..cmd_extra_args, "--yolo", "--approve-mcps", "--workspace", workspace_path,
          ..task_args,
        ],
        workdir: Some(workspace_path),
      }
    Unknown =>
      {
        program: cmd_program.unwrap_or("gemini"),
        args: [..cmd_extra_args, "--yolo", "--prompt-interactive", ..task_args],
        workdir: Some(workspace_path),
      }
  }
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
  let cmd = provider_launch_command(
    spec.agent_type,
    spec.role,
    canonical_agent_id(spec),
    workspace_path,
    task=Some(spec.task),
    parent_session_id~,
    cmd_program~,
    cmd_extra_args~,
    extra_mcp_servers_json~,
  )
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
/// Claude settings JSON for TL init — statusLine + plugin enablement.
/// MCP registration stays separate via `--mcp-config` / `--strict-mcp-config`.
pub fn init_tl_claude_settings_json() -> String {
  "{\"statusLine\":{\"type\":\"command\",\"command\":\"choir statusline\"},\"enabledPlugins\":{\"choir@local\":true}}"
}

///|
/// Inner TL agent command for the init zellij tab (no post-exit trailer; that lives only in
/// [`init_tl_zellij_tab_command`]).
pub fn init_tl_agent_command(
  tl_type : String,
  project_dir : String,
  lean? : Bool = false,
) -> Command {
  let cmd = provider_launch_command(
    tl_type_agent_type(tl_type),
    @types.Role::TL,
    "root",
    project_dir,
    tl_init_mode=true,
    lean~,
  )
  { ..cmd, workdir: None }
}
