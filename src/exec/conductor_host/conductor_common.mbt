///|
fn conductor_claude_mcp_server_json(choir_executable : String) -> Json {
  {
    "type": "stdio".to_json(),
    "command": choir_executable.to_json(),
    "args": [
      "mcp-stdio", "--name", "root", "--channel", "--stderr-append-log", ".choir/logs/mcp-stdio.stderr.log",
    ].to_json(),
    "alwaysLoad": true.to_json(),
  }.to_json()
}

///|
pub fn conductor_claude_mcp_config_json(choir_executable : String) -> String {
  {
    "mcpServers": {
      "choir": conductor_claude_mcp_server_json(choir_executable),
    }.to_json(),
  }
  .to_json()
  .stringify(indent=0)
}

///|
pub fn conductor_claude_project_mcp_config_json(
  existing : String,
  choir_executable : String,
) -> Result[String, @types.ChoirError] {
  let parsed = if existing.trim() == "" {
    let empty : Map[String, Json] = Map([])
    { "mcpServers": empty.to_json() }.to_json()
  } else {
    @json.parse(existing) catch {
      _ =>
        return Err(
          @types.ChoirError::validation_error(
            "project .mcp.json is not valid JSON",
          ),
        )
    }
  }
  guard parsed is Object(root) else {
    return Err(
      @types.ChoirError::validation_error(
        "project .mcp.json is not a JSON object",
      ),
    )
  }
  let servers : Map[String, Json] = match root.get("mcpServers") {
    Some(Object(value)) => value
    None => Map([])
    Some(_) =>
      return Err(
        @types.ChoirError::validation_error(
          "project .mcp.json mcpServers is not an object",
        ),
      )
  }
  servers.set("choir", conductor_claude_mcp_server_json(choir_executable))
  root.set("mcpServers", servers.to_json())
  Ok(root.to_json().stringify(indent=2) + "\n")
}

///|
pub fn conductor_claude_settings_json(choir_executable : String) -> String {
  {
    "enabledMcpjsonServers": ["choir"].to_json(),
    "statusLine": {
      "type": "command".to_json(),
      "command": (@process_host.quote(choir_executable) +
      " conductor-statusline").to_json(),
      "padding": (0 : Int).to_json(),
    }.to_json(),
    "hooks": {
      "Stop": [
        {
          "hooks": [
            {
              "type": "command".to_json(),
              "command": choir_executable.to_json(),
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
pub fn conductor_claude_allowed_tools() -> String {
  [
    "mcp__choir__goal_submit", "mcp__choir__goal_status", "mcp__choir__goal_cancel",
    "mcp__choir__goal_steer", "mcp__choir__goal_attach", "mcp__choir__goal_answer",
    "mcp__choir__task_list", "mcp__choir__task_get", "mcp__choir__task_create", "mcp__choir__task_update",
  ].join(",")
}

///|
pub fn conductor_launch_command(
  project_dir : String,
  choir_executable : String,
  lean? : Bool = false,
) -> @process_host.Command {
  let lean_args : Array[String] = if lean {
    ["--system-prompt", "."]
  } else {
    []
  }
  // Every flag here must also appear in @harness.conductor_surface_flags(),
  // which is what qualification checks against the installed CLI. The coupling
  // is asserted by test rather than by indexing into the manifest, so the two
  // cannot drift and reordering the manifest cannot silently change the launch.
  {
    program: "claude",
    args: [
      "--dangerously-skip-permissions",
      "--allowedTools",
      conductor_claude_allowed_tools(),
      "--setting-sources",
      "project",
      "--mcp-config",
      conductor_claude_mcp_config_json(choir_executable),
      "--strict-mcp-config",
      "--append-system-prompt-file",
      project_dir + "/.choir/state/conductor-prompt.md",
      "--settings",
      project_dir + "/.choir/state/claude-settings.json",
      "--dangerously-load-development-channels",
      "server:choir",
      ..lean_args,
    ],
    workdir: None,
  }
}

///|
