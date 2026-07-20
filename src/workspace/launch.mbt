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
  ".choir/logs/codex-" + agent_id.replace(old="/", new="-") + ".stderr.log"
}

///|
pub fn codex_stderr_log_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/" + codex_stderr_log_relpath(agent_id)
}

///|
pub fn agy_stderr_log_relpath(agent_id : String) -> String {
  ".choir/logs/agy-" + @types.sanitize_agent_id(agent_id) + ".stderr.log"
}

///|
pub fn agy_stderr_log_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/" + agy_stderr_log_relpath(agent_id)
}

///|
pub fn agent_pid_file_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/.choir/run/pids/" + @types.sanitize_agent_id(agent_id)
}

///|
/// Pure parse of an agent pidfile body (see [`agent_pid_file_path`]): the
/// recorded setsid process-group id. Returns `None` for missing/empty,
/// non-numeric, or unsafe (<= 1) values so callers never signal pgid 0/1 or
/// a negative group.
pub fn parse_agent_pgid(content : String) -> Int? {
  let raw = content.trim().to_owned()
  if raw == "" {
    return None
  }
  let parsed = Some(@string.parse_int(raw)) catch { _ => None }
  match parsed {
    Some(pgid) => if pgid > 1 { Some(pgid) } else { None }
    None => None
  }
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
  let quoted_stderr = shell_escape(stderr_path)
  let wrapped = "mkdir -p \"$(dirname " +
    quoted_stderr +
    ")\" && " +
    quoted_args.join(" ") +
    " 2>" +
    quoted_stderr
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
  let pid_dir = project_dir + "/.choir/run/pids"
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
        "--stderr-append-log", ".choir/logs/mcp-stdio.stderr.log",
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
        ".choir/logs/mcp-stdio.stderr.log",
      ]
  }
  let args_lit = toml_string_array_literal(elems)
  // codex's MCP stdio launcher builds each server's environment from scratch
  // (`env_clear()` + a DEFAULT_ENV_VARS whitelist in rmcp-client's
  // `create_env_for_mcp_server`; `shell_environment_policy` only governs
  // shell/exec tools, not MCP), so `choir mcp-stdio` never inherits CHOIR_*
  // ambiently (choir-ghl9). `env_vars` is codex's names-only forward
  // list: values come from codex's own environment at spawn time and never
  // ride this argv (argv leaks into ps/proc; the token is a secret). Identity
  // and the socket path come from the per-leaf .choir/config.local.toml in
  // `cwd` plus the --role/--name args above, so the token is the only
  // env-sourced input registration needs.
  let env_vars_lit = toml_string_array_literal(["CHOIR_AGENT_TOKEN"])
  let args = [
    "-c",
    "mcp_servers.choir.command=\"choir\"",
    "-c",
    "mcp_servers.choir.args=" + args_lit,
    "-c",
    "mcp_servers.choir.env_vars=" + env_vars_lit,
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
pub fn agy_binary_name() -> String {
  "agy"
}

///|
pub fn resolve_agent_model(
  config : @types.Config,
  agent_type : @types.AgentType,
  role : @types.Role,
  model_override : String?,
) -> String? {
  match model_override {
    Some(model) => Some(model)
    None =>
      match config.model.get(agent_type.to_wire_string()) {
        Some(entry) => {
          let role_model = match role {
            @types.Role::Dev => entry.dev
            @types.Role::Worker => entry.worker
            @types.Role::TL => entry.tl
          }
          match role_model {
            Some(model) => Some(model)
            None => entry.default
          }
        }
        None => None
      }
  }
}

///|
pub fn resolve_agent_model_from_config_content(
  config_content : String,
  agent_type : @types.AgentType,
  role : @types.Role,
  model_override : String?,
) -> String? {
  match model_override {
    Some(model) => Some(model)
    None =>
      match @config.parse_config(config_content) {
        Ok(config) => resolve_agent_model(config, agent_type, role, None)
        Err(_) => None
      }
  }
}

///|
pub fn resolve_agent_effort(
  config : @types.Config,
  agent_type : @types.AgentType,
  role : @types.Role,
  effort_override : String?,
) -> String? {
  match effort_override {
    Some(effort) => Some(effort)
    None =>
      match config.effort.get(agent_type.to_wire_string()) {
        Some(entry) => {
          let role_effort = match role {
            @types.Role::Dev => entry.dev
            @types.Role::Worker => entry.worker
            @types.Role::TL => entry.tl
          }
          match role_effort {
            Some(effort) => Some(effort)
            None => entry.default
          }
        }
        None => None
      }
  }
}

///|
pub fn resolve_agent_effort_from_config_content(
  config_content : String,
  agent_type : @types.AgentType,
  role : @types.Role,
  effort_override : String?,
) -> String? {
  match effort_override {
    Some(effort) => Some(effort)
    None =>
      match @config.parse_config(config_content) {
        Ok(config) => resolve_agent_effort(config, agent_type, role, None)
        Err(_) => None
      }
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
  conductor_mode? : Bool = false,
  lean? : Bool = false,
  project_dir? : String = workspace_path,
  claude_settings_path? : String? = None,
  codex_bypass_hook_trust? : Bool = false,
  model? : String? = None,
  effort? : String? = None,
) -> Command {
  let semble_for_role = role == @types.Role::Dev || role == @types.Role::Worker
  let claude_mcp = if conductor_mode {
    ["--mcp-config", conductor_claude_mcp_config_json(), "--strict-mcp-config"]
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
  // `--model <value>` is the verified flag form for codex, claude, agy
  // (gemini), and cursor `agent` alike.
  let model_args : Array[String] = match model {
    Some(value) => ["--model", value]
    None => []
  }
  let cmd = match agent_type {
    Claude => {
      let program = cmd_program.unwrap_or("claude")
      let claude_task_args : Array[String] = if conductor_mode {
        task_args
      } else {
        match task {
          Some(t) => if semble_for_role { [semble_task(t)] } else { [t] }
          None => []
        }
      }
      if conductor_mode {
        let plugin_dir = workspace_path + "/.choir/plugin"
        let settings_path = workspace_path +
          "/.choir/state/claude-settings.json"
        let lean_args : Array[String] = if lean {
          ["--system-prompt", "."]
        } else {
          []
        }
        {
          program,
          args: [
            ..cmd_extra_args, "--dangerously-skip-permissions", "--tools", "", "--setting-sources",
            "", ..claude_mcp, "--plugin-dir", plugin_dir, "--settings", settings_path,
            ..lean_args,
          ],
          workdir: Some(workspace_path),
        }
      } else {
        let settings_args : Array[String] = match claude_settings_path {
          Some(path) => ["--settings", path]
          None => []
        }
        match parent_session_id {
          Some(session_id) =>
            {
              program,
              args: [
                ..cmd_extra_args, "--dangerously-skip-permissions", ..claude_mcp,
                ..settings_args, ..model_args, "--resume", session_id, "--fork-session",
                ..claude_task_args,
              ],
              workdir: Some(workspace_path),
            }
          None =>
            {
              program,
              args: [
                ..cmd_extra_args, "--dangerously-skip-permissions", ..claude_mcp,
                ..settings_args, ..model_args, ..claude_task_args,
              ],
              workdir: Some(workspace_path),
            }
        }
      }
    }
    Gemini =>
      wrap_with_stderr_redirect(
        {
          program: cmd_program.unwrap_or(agy_binary_name()),
          args: [
            ..cmd_extra_args, "--dangerously-skip-permissions", "--prompt-interactive",
            ..model_args, ..task_args,
          ],
          workdir: Some(workspace_path),
        },
        agy_stderr_log_path(project_dir, agent_id),
      )
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
      let hook_trust_args = if codex_bypass_hook_trust {
        ["--dangerously-bypass-hook-trust"]
      } else {
        []
      }
      let effort_args = match effort {
        Some(value) => ["-c", "model_reasoning_effort=" + value]
        None => []
      }
      wrap_with_stderr_redirect(
        {
          program: cmd_program.unwrap_or("codex"),
          args: [
            ..cmd_extra_args,
            "--dangerously-bypass-approvals-and-sandbox",
            ..hook_trust_args,
            ..model_args,
            ..effort_args,
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
          ..cmd_extra_args, "--yolo", "--approve-mcps", ..model_args, "--workspace",
          workspace_path, ..task_args,
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
  claude_settings_path? : String? = None,
  codex_bypass_hook_trust? : Bool = false,
  model? : String? = None,
  effort? : String? = None,
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
    claude_settings_path~,
    codex_bypass_hook_trust~,
    model~,
    effort~,
  )
  match shell_command {
    Some(shell) => wrap_with_shell(cmd, shell)
    _ => cmd
  }
}

///|
/// MCP JSON for the Claude Conductor. Optional research and indexing services
/// are admitted separately after their own evaluation.
pub fn conductor_claude_mcp_config_json() -> String {
  "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--name\",\"root\",\"--stderr-append-log\",\".choir/logs/mcp-stdio.stderr.log\"],\"alwaysLoad\":true}}}"
}

///|
/// Claude settings JSON for the Conductor — status line + plugin enablement.
/// MCP registration stays separate via `--mcp-config` / `--strict-mcp-config`.
pub fn conductor_claude_settings_json() -> String {
  "{\"enabledPlugins\":{\"choir@local\":true}}"
}

///|
/// Launch the supported interactive Conductor directly on the host.
pub fn conductor_launch_command(
  agent_type : @types.AgentType,
  project_dir : String,
  lean? : Bool = false,
) -> Command {
  let cmd = provider_launch_command(
    agent_type,
    @types.Role::TL,
    "root",
    project_dir,
    conductor_mode=true,
    lean~,
  )
  { ..cmd, workdir: None }
}

///|
pub(all) struct ConductorProcessEnvironment {
  agent_token : String
  agent_id : String
  role : @types.Role
  workspace : String
  listen_uds : String
  session_id : String
}
