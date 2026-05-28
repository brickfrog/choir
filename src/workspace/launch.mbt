///|
fn wrap_with_shell(cmd : Command, shell : String) -> Command {
  let parts : Array[String] = []
  let mut start = 0
  for i = 0; i <= shell.length(); i = i + 1 {
    if i == shell.length() || shell[i] == ' ' {
      if i > start {
        parts.push(shell[start:i].to_owned())
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
/// POSIX single-quote quoting for embedding in bash -c script bodies.
fn shell_escape(raw : String) -> String {
  @sys.shell_quote(raw)
}

///|
pub fn codex_stderr_log_relpath(agent_id : String) -> String {
  ".choir/codex-" + agent_id.replace(old="/", new="-") + ".stderr.log"
}

///|
pub fn codex_stderr_log_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/" + codex_stderr_log_relpath(agent_id)
}

///|
pub fn agent_pid_file_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/.choir/pids/" + @types.sanitize_agent_id(agent_id)
}

///|
/// Wrap a command so its stderr is REDIRECTED (truncate-on-open `2>`, not
/// append `2>>`) to `stderr_path`. Truncate-on-open bounds the on-disk
/// stderr to a single run's output, so the disconnect-warning tail reader
/// never has to deal with multi-run accretion. Operators tailing the file
/// live still see the current run; the previous run is overwritten the
/// moment a new agent is spawned with the same id.
fn wrap_with_stderr_redirect(cmd : Command, stderr_path : String) -> Command {
  let quoted_args : Array[String] = []
  quoted_args.push(shell_escape(cmd.program))
  for arg in cmd.args {
    quoted_args.push(shell_escape(arg))
  }
  let wrapped = quoted_args.join(" ") + " 2>" + shell_escape(stderr_path)
  { program: "bash", args: ["-c", wrapped], workdir: cmd.workdir }
}

///|
/// Wrap a spawned agent command in `setsid` + `bash -c` and ensure the shell trap
/// sends `SIGTERM` to the whole process group when the agent exits.
fn wrap_with_setsid_and_pgroup_cleanup(
  cmd : Command,
  agent_id : String,
  project_dir : String,
) -> Command {
  let quoted_args : Array[String] = []
  quoted_args.push(shell_escape(cmd.program))
  for arg in cmd.args {
    quoted_args.push(shell_escape(arg))
  }
  let pid_path = agent_pid_file_path(project_dir, agent_id)
  let pid_dir = project_dir + "/.choir/pids"
  let wrapped = "mkdir -p " +
    shell_escape(pid_dir) +
    " && printf '%s' \"$$\" > " +
    shell_escape(pid_path) +
    "; trap 'kill -TERM -- -$$ 2>/dev/null' EXIT HUP TERM INT; " +
    quoted_args.join(" ")
  { program: "setsid", args: ["bash", "-c", wrapped], workdir: cmd.workdir }
}

///|
pub fn codex_mcp_override_args(
  role : @types.Role,
  agent_id : String,
  workspace_path : String,
  semble_pilot? : Bool = false,
) -> Array[String] {
  // Codex MCP stdio: direct `choir` argv (no `sh -lc`). Socket wait and stderr log
  // are handled inside `mcp-stdio` via `--wait-socket-tries` / `--stderr-append-log`.
  // Codex starts the MCP process during its own CLI initialization, so give
  // each socket wait a wider ~60s budget than direct `choir mcp-stdio`.
  let codex_wait_socket_tries = "300"
  let elems : Array[String] = match role {
    @types.Role::TL =>
      [
        "mcp-stdio", "--raw-stdio", "--name", agent_id, "--wait-socket-tries", codex_wait_socket_tries,
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
        codex_wait_socket_tries,
        "--stderr-append-log",
        ".choir/mcp-stdio.stderr.log",
      ]
  }
  let args_lit = toml_string_array_literal(elems)
  let args = [
    "-c",
    "mcp_servers.choir.command=\"choir\"",
    "-c",
    "mcp_servers.choir.args=" + args_lit,
    "-c",
    "mcp_servers.choir.cwd=\"" + escape_toml_string(workspace_path) + "\"",
  ]
  if semble_pilot {
    let semble_args = toml_string_array_literal([
      "tool", "run", "--from", "semble[mcp]", "semble",
    ])
    args.push("-c")
    args.push("mcp_servers.semble.command=\"uv\"")
    args.push("-c")
    args.push("mcp_servers.semble.args=" + semble_args)
    args.push("-c")
    args.push(
      "mcp_servers.semble.cwd=\"" + escape_toml_string(workspace_path) + "\"",
    )
  }
  args
}

///|
fn semble_task(task : String) -> String {
  let directive =
    #|## Codebase exploration
    #|
    #|A `semble` MCP search tool is available. Prefer it over `grep -r` / `find` for any codebase exploration that isn't an exact-string lookup. Use grep only when you have a literal symbol/string to find; use semble for any "where does this concept live" / "how is X used" / "find files related to Y" question.
    #|
    #|
  directive + task
}

///|
fn claude_mcp_args(
  role : @types.Role,
  agent_id : String,
  extra_mcp_servers_json? : String? = None,
  semble_pilot? : Bool = false,
) -> Array[String] {
  [
    "--mcp-config",
    mcp_json_content(role, agent_id, extra_mcp_servers_json~, semble_pilot~),
    "--strict-mcp-config",
  ]
}

///|
fn split_words(s : String) -> Array[String] {
  let parts : Array[String] = []
  let trimmed = s.trim().to_owned()
  let mut start = 0
  for i = 0; i <= trimmed.length(); i = i + 1 {
    if i == trimmed.length() || trimmed[i] == ' ' {
      if i > start {
        parts.push(trimmed[start:i].to_owned())
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
    other => other.to_owned()
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
pub fn agy_binary_name() -> String {
  "agy"
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
  project_dir? : String = workspace_path,
) -> Command {
  let semble_for_role = role == @types.Role::Dev || role == @types.Role::Worker
  let claude_mcp = if tl_init_mode {
    ["--mcp-config", init_tl_claude_mcp_config_json(), "--strict-mcp-config"]
  } else {
    claude_mcp_args(
      role,
      agent_id,
      extra_mcp_servers_json~,
      semble_pilot=semble_for_role,
    )
  }
  let task_args = match task {
    Some(t) => [t]
    None => []
  }
  let cmd = match agent_type {
    Claude => {
      let program = cmd_program.unwrap_or("claude")
      let claude_task_args : Array[String] = if tl_init_mode {
        task_args
      } else {
        match task {
          Some(t) => if semble_for_role { [semble_task(t)] } else { [t] }
          None => []
        }
      }
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
                "--resume", session_id, "--fork-session", ..claude_task_args,
              ],
              workdir: Some(workspace_path),
            }
          None =>
            {
              program,
              args: [
                ..cmd_extra_args, "--dangerously-skip-permissions", ..claude_mcp,
                ..claude_task_args,
              ],
              workdir: Some(workspace_path),
            }
        }
      }
    }
    Gemini =>
      {
        program: cmd_program.unwrap_or(agy_binary_name()),
        args: [
          ..cmd_extra_args, "--dangerously-skip-permissions", "--prompt-interactive",
          ..task_args,
        ],
        workdir: Some(workspace_path),
      }
    MoonPilot =>
      {
        program: cmd_program.unwrap_or("moon"),
        args: [..cmd_extra_args, "pilot", ..task_args],
        workdir: Some(workspace_path),
      }
    Codex => {
      let codex_task_args = match task {
        Some(t) => if role == @types.Role::Dev { [semble_task(t)] } else { [t] }
        None => []
      }
      wrap_with_stderr_redirect(
        {
          program: cmd_program.unwrap_or("codex"),
          args: [
            ..cmd_extra_args,
            "--dangerously-bypass-approvals-and-sandbox",
            "--no-alt-screen",
            ..codex_mcp_override_args(
              role,
              agent_id,
              workspace_path,
              semble_pilot=role == @types.Role::Dev,
            ),
            "-C",
            workspace_path,
            ..codex_task_args,
          ],
          workdir: Some(workspace_path),
        },
        codex_stderr_log_path(project_dir, agent_id),
      )
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
        program: cmd_program.unwrap_or(agy_binary_name()),
        args: [
          ..cmd_extra_args, "--dangerously-skip-permissions", "--prompt-interactive",
          ..task_args,
        ],
        workdir: Some(workspace_path),
      }
  }
  wrap_with_setsid_and_pgroup_cleanup(cmd, agent_id, project_dir)
}

///|
pub fn agent_launch_command(
  spec : @types.SpawnSpec,
  workspace_path : String,
  parent_session_id? : String? = None,
  shell_command? : String? = None,
  command_override? : String? = None,
  extra_mcp_servers_json? : String? = None,
  project_dir? : String = workspace_path,
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
    project_dir~,
  )
  match shell_command {
    Some(shell) => wrap_with_shell(cmd, shell)
    _ => cmd
  }
}

///|
/// MCP JSON for TL init Claude only; matches legacy `choir init` (`mcp-stdio` + `--name root`, no `--role`).
/// `alwaysLoad: true` keeps choir's orchestration tools out of Claude Code's
/// tool-search deferral so the TL doesn't pay a ToolSearch round-trip on first
/// use of every fork_wave / file_pr / merge_pr / wave_state call.
pub fn init_tl_claude_mcp_config_json() -> String {
  "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--name\",\"root\",\"--stderr-append-log\",\".choir/mcp-stdio.stderr.log\"],\"alwaysLoad\":true},\"semble\":{\"type\":\"stdio\",\"command\":\"uv\",\"args\":[\"tool\",\"run\",\"--from\",\"semble[mcp]\",\"semble\"]}}}"
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
