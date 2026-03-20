///|
fn quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\'')
  for c in s {
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
fn role_to_string(role : @types.Role) -> String {
  match role {
    Root => "root"
    TL => "tl"
    Dev => "dev"
    Worker => "worker"
  }
}

///|
fn command_text_for_tmux(cmd : Command) -> String {
  { ..cmd, workdir: None }.to_string()
}

///|
fn env_assignment(key : String, value : String) -> String {
  key + "=" + quote(value)
}

///|
fn launch_env_prefix(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  tmux_target : String,
) -> String {
  let role = role_to_string(spec.role)
  let agent_id = canonical_agent_id(spec)
  let agent_type = @config.agent_type_to_string(spec.agent_type)
  let assignments : Array[String] = [
    env_assignment("CHOIR_AGENT_ID", agent_id),
    env_assignment("CHOIR_PARENT_ID", spec.parent_id),
    env_assignment("CHOIR_BRANCH", agent_id),
    env_assignment("CHOIR_PARENT_BRANCH", spec.parent_branch),
    env_assignment("CHOIR_WORKSPACE", workspace),
    env_assignment("CHOIR_ROLE", role),
    env_assignment("CHOIR_AGENT_TYPE", agent_type),
    env_assignment("CHOIR_TMUX_TARGET", tmux_target),
    env_assignment("CHOIR_TMUX_SESSION", session),
    env_assignment("EXOMONAD_AGENT_ID", agent_id),
    env_assignment("EXOMONAD_SESSION_ID", agent_id),
    env_assignment("EXOMONAD_ROLE", role),
    env_assignment("EXOMONAD_PARENT_AGENT", spec.parent_id),
  ]
  match @io.getenv("TRACEPARENT") {
    Some(value) =>
      if value != "" {
        assignments.push(env_assignment("TRACEPARENT", value))
      }
    None => ()
  }
  let buf = StringBuilder::new()
  for i = 0; i < assignments.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(' ')
    }
    buf.write_string(assignments[i])
  }
  if assignments.length() == 0 {
    ""
  } else {
    buf.to_string() + " "
  }
}

///|
fn ssh_cmd(target : String, remote_shell : String) -> Command {
  {
    program: "ssh",
    args: ["-o", "StrictHostKeyChecking=no", target, remote_shell],
    workdir: None,
  }
}

///|
pub fn spawn_commands(
  spec : @types.SpawnSpec,
  project_dir : String,
  session : String,
  parent_session_id? : String? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
) -> Array[Command] {
  let branch = canonical_agent_id(spec)
  let workspace = match spec.isolation {
    Worktree => worktree_path(project_dir, spec.slug)
    Inline => project_dir
    Standalone => project_dir + "/.choir/agents/" + spec.slug
  }
  let target = match spec.isolation {
    Worktree => session + ":" + spec.slug
    Inline => session
    Standalone => session + ":" + spec.slug
  }
  let launch_cmd = agent_launch_command(
    spec,
    workspace,
    parent_session_id~,
    shell_command~,
  )
  let tmux_target = match spec.isolation {
    Worktree => session + ":" + spec.slug
    Inline => session
    Standalone => session + ":" + spec.slug
  }
  let launch_str = launch_env_prefix(spec, session, workspace, tmux_target) +
    command_text_for_tmux(launch_cmd)
  match spec.isolation {
    Worktree =>
      [
        git_worktree_add(workspace, branch),
        write_local_config(
          workspace,
          config_local_content(spec, workspace, tmux_target),
        ),
        write_mcp_json(
          workspace,
          mcp_json_content(spec.role, branch, extra_mcp_servers_json~),
        ),
        tmux_new_window(session, spec.slug, workspace),
        tmux_send_keys(target, launch_str),
      ]
    Inline =>
      [tmux_split_pane(session, workspace), tmux_send_keys(target, launch_str)]
    Standalone =>
      [
        { program: "git", args: ["init", workspace], workdir: None },
        write_local_config(
          workspace,
          config_local_content(spec, workspace, tmux_target),
        ),
        write_mcp_json(
          workspace,
          mcp_json_content(spec.role, branch, extra_mcp_servers_json~),
        ),
        tmux_new_window(session, spec.slug, workspace),
        tmux_send_keys(target, launch_str),
      ]
  }
}

///|
pub fn remote_spawn_commands(
  spec : @types.SpawnSpec,
  ssh_target : String,
  repo_url : String,
  tcp_addr : String,
  parent_session_id? : String? = None,
  extra_mcp_servers_json? : String? = None,
) -> Array[Command] {
  let branch = canonical_agent_id(spec)
  let workspace = "$HOME/exo-workspaces/" + branch
  let config_toml = "default_role = \"" +
    role_to_string(spec.role) +
    "\"\nlisten_tcp = \"" +
    tcp_addr +
    "\"\nagent_id = \"" +
    branch +
    "\"\nparent_id = \"" +
    spec.parent_id +
    "\"\nbranch = \"" +
    branch +
    "\"\nparent_branch = \"" +
    spec.parent_branch +
    "\"\nworkspace = \"" +
    workspace +
    "\"\nagent_type = \"" +
    @config.agent_type_to_string(spec.agent_type) +
    "\"\n"
  let mcp_json = mcp_json_content(spec.role, branch, extra_mcp_servers_json~)
  let launch_cmd = agent_launch_command(spec, workspace, parent_session_id~)
  let agent_cmd = launch_env_prefix(
      spec,
      "remote",
      workspace,
      "remote:" + spec.slug,
    ) +
    command_text_for_tmux(launch_cmd)
  [
    ssh_cmd(
      ssh_target,
      "git clone -b " +
      quote(spec.parent_branch) +
      " " +
      quote(repo_url) +
      " " +
      workspace +
      " && cd " +
      workspace +
      " && git checkout -b " +
      quote(branch),
    ),
    ssh_cmd(
      ssh_target,
      "mkdir -p " +
      workspace +
      "/.choir && printf '%s' " +
      quote(config_toml) +
      " > " +
      workspace +
      "/.choir/config.toml",
    ),
    ssh_cmd(
      ssh_target,
      "printf '%s' " + quote(mcp_json) + " > " + workspace + "/.mcp.json",
    ),
    ssh_cmd(
      ssh_target,
      "cd " +
      workspace +
      " && nohup " +
      agent_cmd +
      " > /tmp/" +
      quote(spec.slug) +
      ".log 2>&1 &",
    ),
  ]
}
