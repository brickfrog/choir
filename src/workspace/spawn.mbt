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
fn command_text_for_launch(cmd : Command) -> String {
  { ..cmd, workdir: None }.to_string()
}

///|
fn env_assignment(key : String, value : String) -> String {
  key + "=" + quote(value)
}

///|
fn path_assignment(prefix : String) -> String {
  "PATH=" + quote(prefix) + ":$PATH"
}

///|
fn resolved_project_dir(project_dir : String) -> String {
  if project_dir.has_prefix("/") {
    project_dir
  } else {
    @io.getcwd() + "/" + project_dir
  }
}

///|
fn launch_env_prefix(
  spec : @types.SpawnSpec,
  terminal_backend : @types.TerminalBackend,
  session : String,
  workspace : String,
  terminal_target : String,
) -> String {
  let role = role_to_string(spec.role)
  let agent_id = canonical_agent_id(spec)
  let agent_type = @config.agent_type_to_string(spec.agent_type)
  let terminal_backend_str = @config.terminal_backend_to_string(
    terminal_backend,
  )
  let assignments : Array[String] = [
    path_assignment(workspace + "/.choir/bin"),
    env_assignment("CHOIR_AGENT_ID", agent_id),
    env_assignment("CHOIR_PARENT_ID", spec.parent_id),
    env_assignment("CHOIR_BRANCH", agent_id),
    env_assignment("CHOIR_PARENT_BRANCH", spec.parent_branch),
    env_assignment("CHOIR_WORKSPACE", workspace),
    env_assignment("CHOIR_ROLE", role),
    env_assignment("CHOIR_AGENT_TYPE", agent_type),
    env_assignment("CHOIR_TMUX_TARGET", terminal_target),
    env_assignment("CHOIR_TMUX_SESSION", session),
    env_assignment("CHOIR_TERMINAL_BACKEND", terminal_backend_str),
    env_assignment("CHOIR_TERMINAL_TARGET", terminal_target),
    env_assignment("CHOIR_TERMINAL_SESSION", session),
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
  terminal_backend? : @types.TerminalBackend = @types.TerminalBackend::Tmux,
  parent_session_id? : String? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> Array[Command] {
  let root_project = resolved_project_dir(project_dir)
  let branch = canonical_agent_id(spec)
  let workspace = match spec.isolation {
    Worktree => worktree_path(root_project, spec.slug)
    Inline => root_project
    Standalone => root_project + "/.choir/agents/" + spec.slug
  }
  let launch_cmd = agent_launch_command(
    spec,
    workspace,
    parent_session_id~,
    shell_command~,
  )
  let terminal_target = local_target_for(
    terminal_backend,
    session,
    spec.slug,
    spec.isolation,
  )
  let launch_str = launch_env_prefix(
      spec, terminal_backend, session, workspace, terminal_target,
    ) +
    command_text_for_launch(launch_cmd)
  match spec.isolation {
    Worktree => {
      let cmds : Array[Command] = [git_worktree_add(workspace, branch)]
      cmds.push(
        write_spawn_config(
          workspace,
          child_config_content(
            spec.role,
            terminal_backend,
            session,
            root_project,
            listen_uds,
            listen_tcp~,
            tcp_auth_token~,
          ),
        ),
      )
      cmds.push(
        write_local_config(
          workspace,
          config_local_content(spec, workspace, terminal_target),
        ),
      )
      cmds.push(
        write_mcp_json(
          workspace,
          mcp_json_content(spec.role, branch, extra_mcp_servers_json~),
        ),
      )
      cmds.push(write_leaf_helper_scripts(workspace))
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
      }
      for
        cmd in launch_commands(
          terminal_backend,
          session,
          spec.slug,
          workspace,
          launch_str,
          spec.isolation,
        ) {
        cmds.push(cmd)
      }
      cmds
    }
    Inline =>
      launch_commands(
        terminal_backend,
        session,
        spec.slug,
        workspace,
        launch_str,
        spec.isolation,
      )
    Standalone => {
      let cmds : Array[Command] = [
        { program: "git", args: ["init", workspace], workdir: None },
      ]
      cmds.push(
        write_spawn_config(
          workspace,
          child_config_content(
            spec.role,
            terminal_backend,
            session,
            root_project,
            listen_uds,
            listen_tcp~,
            tcp_auth_token~,
          ),
        ),
      )
      cmds.push(
        write_local_config(
          workspace,
          config_local_content(spec, workspace, terminal_target),
        ),
      )
      cmds.push(
        write_mcp_json(
          workspace,
          mcp_json_content(spec.role, branch, extra_mcp_servers_json~),
        ),
      )
      cmds.push(write_leaf_helper_scripts(workspace))
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
      }
      for
        cmd in launch_commands(
          terminal_backend,
          session,
          spec.slug,
          workspace,
          launch_str,
          spec.isolation,
        ) {
        cmds.push(cmd)
      }
      cmds
    }
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
      @types.TerminalBackend::Tmux,
      "remote",
      workspace,
      "remote:" + spec.slug,
    ) +
    command_text_for_launch(launch_cmd)
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
