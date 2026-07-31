///|
/// The two supported invocations share one capability and filesystem profile.
/// Qualification changes only the transport shape needed to capture a bounded
/// startup trace; callers cannot append arbitrary Claude arguments.
pub(all) enum ClaudeConductorLaunchMode {
  ClaudeConductorInteractive
  ClaudeConductorQualification
} derive(Debug, Eq)

///|
/// Host-owned inputs to the Claude Conductor boundary. Sandbox paths, tools,
/// settings sources, and environment keys are deliberately not configurable.
pub(all) struct NativeClaudeConductorConfig {
  project_dir : String
  claude_executable : String
  choir_executable : String
  credential_file : String
  daemon_socket : String
  environment : @process_host.ConductorProcessEnvironment
  prompt : String
  lean : Bool
}

///|
fn conductor_claude_tool_names() -> Array[String] {
  ["Read", "Glob", "Grep"]
}

///|
fn conductor_claude_mcp_tool_names() -> Array[String] {
  @mcp.conductor_tool_names().map(fn(name) { "mcp__choir__" + name })
}

///|
pub fn conductor_claude_allowed_tools() -> Array[String] {
  ["Read(//workspace/**)", "Glob", "Grep", ..conductor_claude_mcp_tool_names()]
}

///|
fn conductor_claude_denied_reads() -> Array[String] {
  [
    "Read(//runtime/**)", "Read(//run/**)", "Read(//proc/**)", "Read(//tmp/**)",
    "Read(//dev/**)", "Read(//usr/**)", "Read(//etc/**)", "Read(//bin/**)", "Read(//sbin/**)",
    "Read(//lib/**)", "Read(//lib32/**)", "Read(//lib64/**)", "Read(//choir)", "Read(//choir-claude)",
    "Read(//choir.sock)",
  ]
}

///|
fn conductor_claude_mcp_server_json() -> Json {
  {
    "type": "stdio".to_json(),
    "command": "/choir".to_json(),
    "args": [
      "mcp-stdio", "--name", "root", "--channel", "--stderr-append-log", "/runtime/mcp-stdio.stderr.log",
    ].to_json(),
    "alwaysLoad": true.to_json(),
  }.to_json()
}

///|
pub fn conductor_claude_mcp_config_json() -> String {
  { "mcpServers": { "choir": conductor_claude_mcp_server_json() }.to_json() }
  .to_json()
  .stringify(indent=0)
}

///|
pub fn conductor_claude_settings_json() -> String {
  {
    "enabledMcpjsonServers": ["choir"].to_json(),
    "permissions": {
      "allow": conductor_claude_allowed_tools().to_json(),
      "deny": conductor_claude_denied_reads().to_json(),
    }.to_json(),
    "statusLine": {
      "type": "command".to_json(),
      "command": "/choir conductor-statusline".to_json(),
      "padding": (0 : Int).to_json(),
    }.to_json(),
    "hooks": {
      "Stop": [
        {
          "hooks": [
            {
              "type": "command".to_json(),
              "command": "/choir".to_json(),
              "args": ["conductor-stop"].to_json(),
              "timeout": (5 : Int).to_json(),
            }.to_json(),
          ].to_json(),
        }.to_json(),
      ].to_json(),
    }.to_json(),
  }
  .to_json()
  .stringify(indent=0)
}

///|
fn conductor_claude_args(
  config : NativeClaudeConductorConfig,
  mode : ClaudeConductorLaunchMode,
) -> Array[String] {
  let args : Array[String] = []
  match mode {
    ClaudeConductorInteractive => ()
    ClaudeConductorQualification =>
      for
        argument in [
          "-p", "--input-format", "text", "--output-format", "stream-json", "--verbose",
          "--no-session-persistence",
        ] {
        args.push(argument)
      }
  }
  for
    argument in [
      "--tools",
      conductor_claude_tool_names().join(","),
      "--permission-mode",
      "dontAsk",
      "--allowedTools",
      conductor_claude_allowed_tools().join(","),
      "--setting-sources",
      "",
      "--mcp-config",
      conductor_claude_mcp_config_json(),
      "--strict-mcp-config",
      "--append-system-prompt",
      config.prompt,
      "--settings",
      conductor_claude_settings_json(),
      "--no-chrome",
      "--dangerously-load-development-channels",
      "server:choir",
    ] {
    args.push(argument)
  }
  if config.lean {
    args.push("--system-prompt")
    args.push(".")
  }
  args
}

///|
fn conductor_config_path_is_absolute(path : String) -> Bool {
  path.has_prefix("/") && path != "/"
}

///|
pub fn native_claude_conductor_command(
  config : NativeClaudeConductorConfig,
  mode : ClaudeConductorLaunchMode,
) -> Result[@process_host.Command, @types.ChoirError] {
  for
    path in [
      config.project_dir,
      config.claude_executable,
      config.choir_executable,
      config.credential_file,
      config.daemon_socket,
    ] {
    if !conductor_config_path_is_absolute(path) {
      return Err(
        @types.ChoirError::validation_error(
          "Claude Conductor boundary requires canonical absolute host paths",
        ),
      )
    }
  }
  if config.prompt.trim() == "" {
    return Err(
      @types.ChoirError::validation_error(
        "Claude Conductor prompt must not be empty",
      ),
    )
  }
  let args : Array[String] = [
    "--die-with-parent", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
    "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc", "/etc",
  ]
  for path in ["/bin", "/sbin", "/lib", "/lib32", "/lib64"] {
    args.push("--ro-bind-try")
    args.push(path)
    args.push(path)
  }
  for
    argument in [
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--tmpfs",
      "/tmp",
      "--tmpfs",
      "/runtime",
      "--dir",
      "/run",
      "--dir",
      "/run/systemd",
      "--dir",
      "/run/systemd/resolve",
      "--ro-bind",
      "/run/systemd/resolve/stub-resolv.conf",
      "/run/systemd/resolve/stub-resolv.conf",
      "--dir",
      "/runtime/home",
      "--dir",
      "/runtime/home/.claude",
      "--ro-bind",
      config.credential_file,
      "/runtime/home/.claude/.credentials.json",
      "--ro-bind",
      config.project_dir,
      "/workspace",
      "--ro-bind",
      config.claude_executable,
      "/choir-claude",
      "--ro-bind",
      config.choir_executable,
      "/choir",
      "--ro-bind",
      config.daemon_socket,
      "/choir.sock",
      "--chdir",
      "/workspace",
      "--",
      "/choir-claude",
    ] {
    args.push(argument)
  }
  for argument in conductor_claude_args(config, mode) {
    args.push(argument)
  }
  Ok({ program: "/usr/bin/bwrap", args, workdir: Some(config.project_dir) })
}

///|
pub fn native_claude_conductor_environment(
  config : NativeClaudeConductorConfig,
) -> Map[String, String] {
  let environment = @process_host.conductor_process_environment_variables({
    ..config.environment,
    workspace: "/workspace",
    listen_uds: "/choir.sock",
  })
  environment["HOME"] = "/runtime/home"
  environment["TMPDIR"] = "/tmp"
  environment["PATH"] = "/usr/bin:/bin"
  environment["LANG"] = "C.UTF-8"
  environment["LC_ALL"] = "C.UTF-8"
  environment["TERM"] = "xterm-256color"
  environment["COLORTERM"] = "truecolor"
  environment["COLUMNS"] = "200"
  environment["NO_COLOR"] = "1"
  environment
}
