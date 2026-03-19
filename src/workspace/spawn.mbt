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
  extra_mcp_servers_json? : String? = None,
) -> Array[Command] {
  let branch = branch_name(spec.parent_branch, spec.slug)
  let workspace = match spec.isolation {
    Worktree => worktree_path(project_dir, spec.slug)
    Inline => project_dir
    Standalone => project_dir + "/.exo/agents/" + spec.slug
  }
  let target = match spec.isolation {
    Worktree => session + ":" + spec.slug
    Inline => session
    Standalone => session + ":" + spec.slug
  }
  let launch_cmd = agent_launch_command(spec, workspace)
  let launch_str = launch_cmd.to_string()
  match spec.isolation {
    Worktree =>
      [
        git_worktree_add(workspace, branch),
        write_local_config(workspace, config_local_content(spec.role)),
        write_mcp_json(
          workspace,
          mcp_json_content(spec.role, spec.slug, extra_mcp_servers_json~),
        ),
        tmux_new_window(session, spec.slug, workspace),
        tmux_send_keys(target, launch_str),
      ]
    Inline =>
      [tmux_split_pane(session, workspace), tmux_send_keys(target, launch_str)]
    Standalone =>
      [
        { program: "git", args: ["init", workspace], workdir: None },
        write_local_config(workspace, config_local_content(spec.role)),
        write_mcp_json(
          workspace,
          mcp_json_content(spec.role, spec.slug, extra_mcp_servers_json~),
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
  extra_mcp_servers_json? : String? = None,
) -> Array[Command] {
  let branch = branch_name(spec.parent_branch, spec.slug)
  let workspace = "$HOME/exo-workspaces/" + branch
  let config_toml = "default_role = \"" +
    role_to_string(spec.role) +
    "\"\nlisten_tcp = \"" +
    tcp_addr +
    "\"\n"
  let mcp_json = mcp_json_content(spec.role, spec.slug, extra_mcp_servers_json~)
  let launch_cmd = agent_launch_command(spec, workspace)
  let agent_str = quote(launch_cmd.program)
  let mut agent_cmd = agent_str
  for arg in launch_cmd.args {
    agent_cmd = agent_cmd + " " + quote(arg)
  }
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
      "/.exo && printf '%s' " +
      quote(config_toml) +
      " > " +
      workspace +
      "/.exo/config.toml",
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
