///|
/// Parse a role string into a Role enum.
pub fn parse_role(s : String) -> Result[@types.Role, @types.ExoError] {
  match s {
    "root" => Ok(@types.Role::Root)
    "tl" => Ok(@types.Role::TL)
    "dev" => Ok(@types.Role::Dev)
    "worker" => Ok(@types.Role::Worker)
    _ => Err(@types.ExoError::ConfigError("unknown role: " + s))
  }
}

///|
pub fn parse_agent_type(
  s : String,
) -> Result[@types.AgentType, @types.ExoError] {
  match s {
    "claude" => Ok(@types.AgentType::Claude)
    "gemini" => Ok(@types.AgentType::Gemini)
    "moon_pilot" => Ok(@types.AgentType::MoonPilot)
    "moonpilot" => Ok(@types.AgentType::MoonPilot)
    _ => Err(@types.ExoError::ConfigError("unknown agent_type: " + s))
  }
}

///|
/// Role to its config string representation.
pub fn role_to_string(role : @types.Role) -> String {
  match role {
    @types.Role::Root => "root"
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "worker"
  }
}

///|
pub fn agent_type_to_string(agent_type : @types.AgentType) -> String {
  match agent_type {
    @types.AgentType::Claude => "claude"
    @types.AgentType::Gemini => "gemini"
    @types.AgentType::MoonPilot => "moon_pilot"
  }
}

///|
/// Parses project config.toml
pub fn parse_config(content : String) -> Result[@types.Config, @types.ExoError] {
  let map = parse_toml(content)
  let default_cfg = @types.Config::default()

  let default_role = match map.get("default_role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => role
        Err(e) => return Err(e)
      }
    None => default_cfg.default_role
  }

  let project_dir = match map.get("project_dir") {
    Some(d) => d
    None => default_cfg.project_dir
  }

  let shell_command = match map.get("shell_command") {
    Some(s) => if s == "" { None } else { Some(s) }
    None => default_cfg.shell_command
  }

  let listen_uds = match map.get("listen_uds") {
    Some(u) => u
    None => default_cfg.listen_uds
  }

  let listen_tcp = match map.get("listen_tcp") {
    Some(t) => if t == "" { None } else { Some(t) }
    None => default_cfg.listen_tcp
  }

  let tcp_auth_token = match map.get("tcp_auth_token") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => default_cfg.tcp_auth_token
  }

  let otlp_endpoint = match map.get("otlp_endpoint") {
    Some(e) => if e == "" { None } else { Some(e) }
    None => default_cfg.otlp_endpoint
  }

  let agent_id = match map.get("agent_id") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => default_cfg.agent_id
  }

  let extra_mcp_servers_json = match map.get("extra_mcp_servers_json") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => default_cfg.extra_mcp_servers_json
  }

  let companions_json = match map.get("companions_json") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => default_cfg.companions_json
  }

  let plugins_json = match map.get("plugins_json") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => default_cfg.plugins_json
  }

  let tmux_session = match map.get("tmux_session") {
    Some(s) => if s == "" { default_cfg.tmux_session } else { s }
    None => default_cfg.tmux_session
  }

  Ok({
    default_role,
    project_dir,
    shell_command,
    listen_uds,
    listen_tcp,
    tcp_auth_token,
    otlp_endpoint,
    agent_id,
    extra_mcp_servers_json,
    companions_json,
    plugins_json,
    tmux_session,
  })
}

///|
/// Parses config.local.toml into the local spawn/session metadata.
pub fn parse_local_config(
  content : String,
) -> Result[@types.LocalConfig, @types.ExoError] {
  let map = parse_toml(content)
  let role = match map.get("role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => Some(role)
        Err(e) => return Err(e)
      }
    None => None
  }
  let agent_id = match map.get("agent_id") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let parent_id = match map.get("parent_id") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let branch = match map.get("branch") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let parent_branch = match map.get("parent_branch") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let workspace = match map.get("workspace") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let tmux_target = match map.get("tmux_target") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let agent_type = match map.get("agent_type") {
    Some(v) =>
      match parse_agent_type(v) {
        Ok(agent_type) => Some(agent_type)
        Err(e) => return Err(e)
      }
    None => None
  }
  Ok({
    role,
    agent_id,
    parent_id,
    branch,
    parent_branch,
    workspace,
    tmux_target,
    agent_type,
  })
}

///|
/// Parses config.local.toml for role-only compatibility.
pub fn parse_config_local(
  content : String,
) -> Result[@types.Role, @types.ExoError] {
  let local_cfg = match parse_local_config(content) {
    Ok(local_cfg) => local_cfg
    Err(e) => return Err(e)
  }
  match local_cfg.role {
    Some(r) => Ok(r)
    None => Err(@types.ExoError::ConfigError("missing role in local config"))
  }
}

///|
/// Resolves the role, local overrides project config
pub fn resolve_role(
  local_role : @types.Role?,
  config : @types.Config,
) -> @types.Role {
  match local_role {
    Some(r) => r
    None => config.default_role
  }
}
