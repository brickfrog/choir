///|
/// Construct the worktree path for an agent slug.
pub fn worktree_path(project_dir : String, slug : String) -> String {
  project_dir + "/.exo/worktrees/" + slug
}

///|
/// Construct the branch name from parent branch and slug.
pub fn branch_name(parent_branch : String, slug : String) -> String {
  parent_branch + "." + slug
}

///|
/// Construct the config.local.toml content for a worktree.
pub fn config_local_content(role : @types.Role) -> String {
  let role_str = match role {
    @types.Role::Root => "root"
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "worker"
  }
  "role = \"" + role_str + "\"\n"
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
  agent_name : String,
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
    agent_name +
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
