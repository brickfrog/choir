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
/// Construct the .mcp.json content for a child worktree.
pub fn mcp_json_content(role : @types.Role, agent_name : String) -> String {
  let role_str = match role {
    @types.Role::Root => "root"
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "worker"
  }
  "{\"mcpServers\":{\"exomonad\":{\"type\":\"stdio\",\"command\":\"exomonad\",\"args\":[\"mcp-stdio\",\"--role\",\"" +
  role_str +
  "\",\"--name\",\"" +
  agent_name +
  "\"]}}}"
}
