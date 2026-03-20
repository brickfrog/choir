///|
/// Construct the worktree path for an agent slug.
pub fn worktree_path(project_dir : String, slug : String) -> String {
  project_dir + "/.choir/worktrees/" + slug
}

///|
/// Construct the branch name from parent branch and slug.
pub fn branch_name(parent_branch : String, slug : String) -> String {
  parent_branch + "." + slug
}

///|
pub fn parent_branch(branch : String) -> String? {
  let mut last_dot = -1
  for i = 0; i < branch.length(); i = i + 1 {
    if branch[i] == '.' {
      last_dot = i
    }
  }
  if last_dot <= 0 {
    None
  } else {
    Some(branch[:last_dot].to_string() catch { _ => "" })
  }
}

///|
pub fn canonical_agent_id(spec : @types.SpawnSpec) -> String {
  branch_name(spec.parent_branch, spec.slug)
}

///|
fn escape_toml_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn resolve_child_path(project_dir : String, path : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    project_dir + "/" + path
  }
}

///|
pub fn child_config_content(
  role : @types.Role,
  terminal_backend : @types.TerminalBackend,
  terminal_session : String,
  project_dir : String,
  listen_uds : String,
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> String {
  let role_str = @config.role_to_string(role)
  let terminal_backend_str = @config.terminal_backend_to_string(
    terminal_backend,
  )
  let buf = StringBuilder::new()
  buf.write_string("default_role = \"")
  buf.write_string(escape_toml_string(role_str))
  buf.write_string("\"\nproject_dir = \"")
  buf.write_string(escape_toml_string(project_dir))
  buf.write_string("\"\nlisten_uds = \"")
  buf.write_string(
    escape_toml_string(resolve_child_path(project_dir, listen_uds)),
  )
  buf.write_string("\"\nterminal_session = \"")
  buf.write_string(escape_toml_string(terminal_session))
  buf.write_string("\"\nterminal_backend = \"")
  buf.write_string(escape_toml_string(terminal_backend_str))
  buf.write_string("\"\n")
  match listen_tcp {
    Some(addr) => {
      buf.write_string("listen_tcp = \"")
      buf.write_string(escape_toml_string(addr))
      buf.write_string("\"\n")
    }
    None => ()
  }
  match tcp_auth_token {
    Some(token) => {
      buf.write_string("tcp_auth_token = \"")
      buf.write_string(escape_toml_string(token))
      buf.write_string("\"\n")
    }
    None => ()
  }
  buf.to_string()
}

///|
/// Construct the config.local.toml content for a spawned agent.
pub fn config_local_content(
  spec : @types.SpawnSpec,
  workspace : String,
  terminal_target : String,
) -> String {
  let role_str = @config.role_to_string(spec.role)
  let agent_type_str = @config.agent_type_to_string(spec.agent_type)
  let agent_id = canonical_agent_id(spec)
  "role = \"" +
  role_str +
  "\"\nagent_id = \"" +
  agent_id +
  "\"\nparent_id = \"" +
  spec.parent_id +
  "\"\nbranch = \"" +
  agent_id +
  "\"\nparent_branch = \"" +
  spec.parent_branch +
  "\"\nworkspace = \"" +
  workspace +
  "\"\nagent_type = \"" +
  agent_type_str +
  "\"\nterminal_target = \"" +
  terminal_target +
  "\"\n"
}

///|
fn strip_json_object_braces(s : String) -> String? {
  let trimmed = s.trim().to_string()
  if trimmed.length() < 2 {
    return None
  }
  if trimmed[0] != '{' || trimmed[trimmed.length() - 1] != '}' {
    return None
  }
  Some(trimmed[1:trimmed.length() - 1].to_string() catch { _ => "" })
}

///|
/// Construct the .mcp.json content for a child worktree.
pub fn mcp_json_content(
  role : @types.Role,
  agent_id : String,
  extra_mcp_servers_json? : String? = None,
) -> String {
  let role_str = match role {
    @types.Role::Root => "root"
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "worker"
  }
  let base = "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--role\",\"" +
    role_str +
    "\",\"--name\",\"" +
    agent_id +
    "\"]}}"
  match extra_mcp_servers_json {
    Some(extra) =>
      match strip_json_object_braces(extra) {
        Some(inner) =>
          if inner.trim() == "" {
            base + "}"
          } else {
            base + "," + inner + "}"
          }
        None => base + "}"
      }
    None => base + "}"
  }
}
