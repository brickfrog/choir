///|
/// Parse a role string into a Role enum.
pub fn parse_role(s : String) -> Result[@types.Role, @types.ChoirError] {
  @types.Role::try_parse_wire(s)
}

///|
pub fn parse_agent_type(
  s : String,
) -> Result[@types.AgentType, @types.ChoirError] {
  @types.AgentType::try_parse_wire(s)
}

///|
/// Role to its wire/config string representation.
pub fn role_to_string(role : @types.Role) -> String {
  role.to_wire_string()
}

///|
pub fn agent_type_to_string(agent_type : @types.AgentType) -> String {
  agent_type.to_wire_string()
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
/// Drop TOML inline comments (`# ...`) when not inside single- or double-quoted spans.
fn strip_toml_inline_comment(s : String) -> String {
  let mut in_double = false
  let mut in_single = false
  let mut cut = s.length()
  let mut i = 0
  while i < s.length() {
    let c = s[i]
    if c == '"' && !in_single {
      in_double = !in_double
    } else if c == '\'' && !in_double {
      in_single = !in_single
    } else if c == '#' && !in_single && !in_double {
      cut = i
      break
    }
    i = i + 1
  }
  s[0:cut].to_string().trim().to_string()
}

///|
fn parse_bool_config_value(raw : String) -> Result[Bool, String] {
  let v = strip_toml_inline_comment(raw).to_lower()
  if v == "true" || v == "1" || v == "yes" {
    Ok(true)
  } else if v == "false" || v == "0" || v == "no" {
    Ok(false)
  } else if v == "" {
    Err("empty value")
  } else {
    Err("invalid boolean (expected true/false/1/0/yes/no): " + raw)
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
  let pr_review = match doc.get("pr_review") {
    None => default_cfg.pr_review
    Some(raw) =>
      match parse_bool_config_value(raw) {
        Ok(b) => b
        Err(msg) =>
          return Err(@types.ChoirError::config_error("pr_review: " + msg))
      }
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
    terminal_session,
    pr_review,
  })
}

///|
fn parse_spawn_depth_value(raw : String) -> Result[Int, @types.ChoirError] {
  let s = raw.trim().to_string()
  let n_opt = Some(@strconv.parse_int(s)) catch { _ => None }
  match n_opt {
    Some(n) => {
      if n < 0 || n > 1 {
        return Err(
          @types.ChoirError::config_error("spawn_depth must be 0 or 1"),
        )
      }
      Ok(n)
    }
    None => {
      if s == "" {
        return Err(
          @types.ChoirError::config_error("spawn_depth cannot be empty"),
        )
      }
      Err(@types.ChoirError::config_error("invalid spawn_depth: " + raw))
    }
  }
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
    None => Err(@types.ChoirError::config_error("missing role in local config"))
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
