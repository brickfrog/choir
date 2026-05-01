///|
/// Construct the worktree path for an agent slug.
pub fn worktree_path(project_dir : String, slug : String) -> String {
  project_dir + "/.choir/worktrees/" + slug
}

///|
/// Construct the branch name from parent branch and slug.
pub fn branch_name(parent_branch : String, slug : String) -> String {
  if parent_branch == "" {
    slug
  } else {
    parent_branch + "." + slug
  }
}

///|
/// Construct the metadata directory for an inline agent.
pub fn inline_agent_metadata_dir(
  project_dir : String,
  agent_id : String,
) -> String {
  project_dir + "/.choir/inline/" + @types.sanitize_agent_id(agent_id)
}

///|
pub fn parent_branch(branch : String) -> String? {
  let last_dot = match branch.rev_find(".") {
    Some(i) => i
    None => -1
  }
  if last_dot <= 0 {
    None
  } else {
    Some(branch[:last_dot].to_owned())
  }
}

///|
pub fn canonical_agent_id(spec : @types.SpawnSpec) -> String {
  branch_name(spec.parent_branch, spec.slug)
}

///|
/// Git branch for commits / `CHOIR_BRANCH`, honoring `reuse_git_branch` when reusing a worktree.
pub fn spawn_git_branch(spec : @types.SpawnSpec) -> String {
  if spec.reuse_workspace {
    match spec.reuse_git_branch {
      Some(b) => if b != "" { b } else { canonical_agent_id(spec) }
      None => canonical_agent_id(spec)
    }
  } else {
    canonical_agent_id(spec)
  }
}

///|
/// Worktree directory slug under `.choir/worktrees/` (may differ from `spec.slug` during rescue).
pub fn spawn_workspace_dir_slug(spec : @types.SpawnSpec) -> String {
  if spec.reuse_workspace {
    match spec.workspace_slug {
      Some(s) => if s != "" { s } else { spec.slug }
      None => spec.slug
    }
  } else {
    spec.slug
  }
}

///|
pub fn validate_reuse_spawn_spec(
  spec : @types.SpawnSpec,
) -> Result[Unit, String] {
  if !spec.reuse_workspace {
    return Ok(())
  }
  match spec.workspace_slug {
    Some(s) =>
      if s == "" {
        return Err("reuse_workspace requires non-empty workspace_slug")
      }
    None => return Err("reuse_workspace requires workspace_slug")
  }
  match spec.reuse_git_branch {
    Some(b) =>
      if b == "" {
        return Err("reuse_workspace requires non-empty reuse_git_branch")
      }
    None => return Err("reuse_workspace requires reuse_git_branch")
  }
  Ok(())
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
/// TOML inline array of double-quoted strings for `-c mcp_servers...` fragments.
fn toml_string_array_literal(elems : Array[String]) -> String {
  let buf = StringBuilder::new()
  buf.write_char('[')
  for i = 0; i < elems.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_char('"')
    buf.write_string(escape_toml_string(elems[i]))
    buf.write_char('"')
  }
  buf.write_char(']')
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
  terminal_session : String,
  project_dir : String,
  listen_uds : String,
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> String {
  let role_str = @config.role_to_string(role)
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
  terminal_target : @types.LocalTarget,
) -> String {
  let role_str = @config.role_to_string(spec.role)
  let agent_type_str = @config.agent_type_to_string(spec.agent_type)
  let agent_id = canonical_agent_id(spec)
  let git_branch = spawn_git_branch(spec)
  let task_contract_line = match spec.task_contract {
    Some(contract) =>
      "\ntask_contract_json = \"" +
      escape_toml_string(contract.to_json_string()) +
      "\"\n"
    None => "\n"
  }
  let automerge_line = match spec.automerge {
    Some(enabled) =>
      "\nautomerge = " + (if enabled { "true" } else { "false" }) + "\n"
    None => ""
  }
  let review_mode_line = match spec.review_mode {
    Some(mode) =>
      "\nreview_mode = \"" +
      escape_toml_string(@config.review_mode_to_string(mode)) +
      "\"\n"
    None => ""
  }
  let wave_id_line = match spec.wave_id {
    Some(id) => "\nwave_id = \"" + escape_toml_string(id) + "\"\n"
    None => ""
  }
  "role = \"" +
  escape_toml_string(role_str) +
  "\"\nagent_id = \"" +
  escape_toml_string(agent_id) +
  "\"\nparent_id = \"" +
  escape_toml_string(spec.parent_id) +
  "\"\nbranch = \"" +
  escape_toml_string(git_branch) +
  "\"\nparent_branch = \"" +
  escape_toml_string(spec.parent_branch) +
  "\"\nworkspace = \"" +
  escape_toml_string(workspace) +
  "\"\nagent_type = \"" +
  escape_toml_string(agent_type_str) +
  "\"\nterminal_target = \"" +
  escape_toml_string(terminal_target.to_string()) +
  "\"\nspawn_depth = " +
  spec.spawn_depth.to_string() +
  automerge_line +
  review_mode_line +
  wave_id_line +
  task_contract_line
}

///|
fn strip_json_object_braces(s : String) -> String? {
  let trimmed = s.trim().to_owned()
  if trimmed.length() < 2 {
    return None
  }
  if trimmed[0] != '{' || trimmed[trimmed.length() - 1] != '}' {
    return None
  }
  Some(trimmed[1:trimmed.length() - 1].to_owned())
}

///|
fn local_config_candidate_paths_for_agent_workspace(
  project_dir : String,
  agent_workspace : String?,
  agent_slug : String,
) -> Array[String] {
  let candidate_paths : Array[String] = []
  match agent_workspace {
    Some(w) =>
      if w != "" {
        candidate_paths.push(w + "/.choir/config.local.toml")
      }
    None => ()
  }
  let fallback_path = worktree_path(project_dir, agent_slug) +
    "/.choir/config.local.toml"
  if !candidate_paths.contains(fallback_path) {
    candidate_paths.push(fallback_path)
  }
  candidate_paths
}

///|
/// Read the task contract for an agent from its config.local.toml.
pub fn task_contract_for_agent_workspace(
  project_dir : String,
  agent_workspace : String?,
  agent_slug : String,
) -> @types.TaskContract? {
  for
    path in local_config_candidate_paths_for_agent_workspace(
      project_dir, agent_workspace, agent_slug,
    ) {
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    match @config.parse_local_config(content) {
      Ok(local_cfg) =>
        match local_cfg.task_contract {
          Some(contract) => return Some(contract)
          None => ()
        }
      Err(_) => ()
    }
  }
  None
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
  // `alwaysLoad: true` is Claude-Code-specific. Cursor / Gemini / Codex ignore
  // unknown MCP-entry keys, so it's safe to ship in the shared `.mcp.json` —
  // claude leaves get their orchestration tools resolved up-front, others are
  // unaffected.
  let base = "{\"mcpServers\":{\"choir\":{\"type\":\"stdio\",\"command\":\"choir\",\"args\":[\"mcp-stdio\",\"--role\",\"" +
    role_str +
    "\",\"--name\",\"" +
    agent_id +
    "\"],\"alwaysLoad\":true}}"
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
