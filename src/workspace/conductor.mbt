///|
pub fn agent_pid_file_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/.choir/run/pids/" + @types.sanitize_agent_id(agent_id)
}

///|
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
pub fn conductor_claude_mcp_config_json() -> String {
  "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--name\",\"root\",\"--stderr-append-log\",\".choir/logs/mcp-stdio.stderr.log\"],\"alwaysLoad\":true}}}"
}

///|
pub fn conductor_claude_settings_json() -> String {
  "{\"enabledPlugins\":{\"choir@local\":true}}"
}

///|
pub fn conductor_launch_command(
  project_dir : String,
  lean? : Bool = false,
) -> Command {
  let lean_args : Array[String] = if lean {
    ["--system-prompt", "."]
  } else {
    []
  }
  {
    program: "claude",
    args: [
      "--dangerously-skip-permissions",
      "--tools",
      "",
      "--setting-sources",
      "",
      "--mcp-config",
      conductor_claude_mcp_config_json(),
      "--strict-mcp-config",
      "--plugin-dir",
      project_dir + "/.choir/plugin",
      "--settings",
      project_dir + "/.choir/state/claude-settings.json",
      ..lean_args,
    ],
    workdir: None,
  }
}

///|
pub(all) struct ConductorProcessEnvironment {
  agent_token : String
  workspace : String
  listen_uds : String
}
