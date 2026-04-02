///|
/// Parse a role string into a Role enum.
pub fn parse_role(s : String) -> Result[@types.Role, @types.ChoirError] {
  match s {
    "root" => Ok(@types.Role::Root)
    "tl" => Ok(@types.Role::TL)
    "dev" => Ok(@types.Role::Dev)
    "worker" => Ok(@types.Role::Worker)
    _ => Err(@types.ChoirError::ConfigError("unknown role: " + s))
  }
}

///|
pub fn parse_agent_type(
  s : String,
) -> Result[@types.AgentType, @types.ChoirError] {
  match s {
    "claude" => Ok(@types.AgentType::Claude)
    "gemini" => Ok(@types.AgentType::Gemini)
    "moon_pilot" => Ok(@types.AgentType::MoonPilot)
    "moonpilot" => Ok(@types.AgentType::MoonPilot)
    "codex" => Ok(@types.AgentType::Codex)
    "cursor_agent" => Ok(@types.AgentType::CursorAgent)
    "cursoragent" => Ok(@types.AgentType::CursorAgent)
    "pi" => Ok(@types.AgentType::Pi)
    _ => Err(@types.ChoirError::ConfigError("unknown agent_type: " + s))
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
    @types.AgentType::Codex => "codex"
    @types.AgentType::CursorAgent => "cursor_agent"
    @types.AgentType::Pi => "pi"
  }
}

///|
fn prefer_optional_string(value : String?, fallback : String?) -> String? {
  match value {
    Some(v) => Some(v)
    None => fallback
  }
}

///|
pub(all) struct CompanionDef {
  name : String
  role : String
  command : String
  task : String
} derive(Show, Eq)

///|
pub fn parse_companions_json(s : String) -> Array[CompanionDef] {
  let result : Array[CompanionDef] = []
  let json = @json.parse(s) catch { _ => return result }
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Object(obj) else { continue }
    let name = match obj.get("name") {
      Some(String(v)) => v
      _ => ""
    }
    let role = match obj.get("role") {
      Some(String(v)) => v
      _ => "worker"
    }
    let command = match obj.get("command") {
      Some(String(v)) => v
      _ => ""
    }
    let task = match obj.get("task") {
      Some(String(v)) => v
      _ => ""
    }
    if name != "" && command != "" {
      result.push({ name, role, command, task })
    }
  }
  result
}

///|
pub fn hook_command_path(content : String, hook_key : String) -> String? {
  parse_toml_doc(content).get_optional_nonempty(hook_key)
}

///|
fn parse_optional_bool_toml(raw : String?, default : Bool) -> Bool {
  match raw {
    None => default
    Some(s) => {
      let v = s.trim().to_lower()
      if v == "true" || v == "1" || v == "yes" {
        true
      } else if v == "false" || v == "0" || v == "no" {
        false
      } else {
        default
      }
    }
  }
}

///|
/// Parses project config.toml
pub fn parse_config(
  content : String,
) -> Result[@types.Config, @types.ChoirError] {
  let doc = parse_toml_doc(content)
  let default_cfg = @types.Config::default()

  let default_role = match doc.get("default_role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => role
        Err(e) => return Err(e)
      }
    None => default_cfg.default_role
  }

  let project_dir = doc.get_or("project_dir", default_cfg.project_dir)
  let shell_command = prefer_optional_string(
    doc.get_optional_nonempty("shell_command"),
    default_cfg.shell_command,
  )
  let listen_uds = doc.get_or("listen_uds", default_cfg.listen_uds)
  let listen_tcp = prefer_optional_string(
    doc.get_optional_nonempty("listen_tcp"),
    default_cfg.listen_tcp,
  )
  let tcp_auth_token = prefer_optional_string(
    doc.get_optional_nonempty("tcp_auth_token"),
    default_cfg.tcp_auth_token,
  )
  let otlp_endpoint = prefer_optional_string(
    doc.get_optional_nonempty("otlp_endpoint"),
    default_cfg.otlp_endpoint,
  )
  let agent_id = prefer_optional_string(
    doc.get_optional_nonempty("agent_id"),
    default_cfg.agent_id,
  )
  let extra_mcp_servers_json = prefer_optional_string(
    doc.get_optional_nonempty("extra_mcp_servers_json"),
    default_cfg.extra_mcp_servers_json,
  )
  let companions_json = prefer_optional_string(
    doc.get_optional_nonempty("companions_json"),
    default_cfg.companions_json,
  )
  let plugins_json = prefer_optional_string(
    doc.get_optional_nonempty("plugins_json"),
    default_cfg.plugins_json,
  )
  let terminal_session = match doc.get_optional_nonempty("terminal_session") {
    Some(value) => value
    None => default_cfg.terminal_session
  }
  let pr_review = parse_optional_bool_toml(
    doc.get("pr_review"),
    default_cfg.pr_review,
  )

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
    terminal_session,
    pr_review,
  })
}

///|
fn parse_spawn_depth_value(raw : String) -> Result[Int, @types.ChoirError] {
  let s = raw.trim().to_string()
  if s == "" {
    return Err(@types.ChoirError::ConfigError("spawn_depth cannot be empty"))
  }
  let mut n = 0
  for c in s {
    if c >= '0' && c <= '9' {
      n = n * 10 + (c.to_int() - '0'.to_int())
    } else {
      return Err(@types.ChoirError::ConfigError("invalid spawn_depth: " + raw))
    }
  }
  if n > 1 {
    return Err(@types.ChoirError::ConfigError("spawn_depth must be 0 or 1"))
  }
  Ok(n)
}

///|
/// Parses config.local.toml into the local spawn/session metadata.
pub fn parse_local_config(
  content : String,
) -> Result[@types.LocalConfig, @types.ChoirError] {
  let doc = parse_toml_doc(content)
  let role = match doc.get("role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => Some(role)
        Err(e) => return Err(e)
      }
    None => None
  }
  let agent_id = doc.get_optional_nonempty("agent_id")
  let parent_id = doc.get_optional_nonempty("parent_id")
  let branch = doc.get_optional_nonempty("branch")
  let parent_branch = doc.get_optional_nonempty("parent_branch")
  let workspace = doc.get_optional_nonempty("workspace")
  let terminal_target = match doc.get_optional_nonempty("terminal_target") {
    Some(s) => @types.LocalTarget::parse(s)
    None => None
  }
  let agent_type = match doc.get("agent_type") {
    Some(v) =>
      match parse_agent_type(v) {
        Ok(agent_type) => Some(agent_type)
        Err(e) => return Err(e)
      }
    None => None
  }
  let spawn_depth = match doc.get_optional_nonempty("spawn_depth") {
    Some(v) =>
      match parse_spawn_depth_value(v) {
        Ok(d) => Some(d)
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
    terminal_target,
    agent_type,
    spawn_depth,
  })
}

///|
/// Parses config.local.toml for role-only compatibility.
pub fn parse_config_local(
  content : String,
) -> Result[@types.Role, @types.ChoirError] {
  let local_cfg = match parse_local_config(content) {
    Ok(local_cfg) => local_cfg
    Err(e) => return Err(e)
  }
  match local_cfg.role {
    Some(r) => Ok(r)
    None => Err(@types.ChoirError::ConfigError("missing role in local config"))
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
