///|
fn command_text_for_launch(cmd : Command) -> String {
  { ..cmd, workdir: None }.to_string()
}

///|
fn env_assignment(key : String, value : String) -> String {
  key + "=" + @sys.shell_quote(value)
}

///|
fn path_assignment(prefix : String) -> String {
  "PATH=" + @sys.shell_quote(prefix) + ":$PATH"
}

///|
fn path_env_merged_for_argv(bin_prefix : String) -> String {
  let tail = match @sys.getenv("PATH") {
    Some(p) => p
    None => "/usr/local/bin:/usr/bin:/bin"
  }
  "PATH=" + bin_prefix + ":" + tail
}

///|
fn env_pair_raw(key : String, value : String) -> String {
  key + "=" + value
}

///|
fn resolved_project_dir(project_dir : String) -> String {
  if project_dir.has_prefix("/") {
    project_dir
  } else {
    @env.current_dir().unwrap_or(".") + "/" + project_dir
  }
}

///|
pub fn launch_env_prefix(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
) -> String {
  let role = @config.role_to_string(spec.role)
  let agent_id = canonical_agent_id(spec)
  let git_branch = spawn_git_branch(spec)
  let agent_type = @config.agent_type_to_string(spec.agent_type)
  let assignments : Array[String] = [
    path_assignment(workspace + "/.choir/bin"),
    env_assignment("CHOIR_AGENT_ID", agent_id),
    env_assignment("CHOIR_PARENT_ID", spec.parent_id),
    env_assignment("CHOIR_BRANCH", git_branch),
    env_assignment("CHOIR_PARENT_BRANCH", spec.parent_branch),
    env_assignment("CHOIR_WORKSPACE", workspace),
    env_assignment("CHOIR_ROLE", role),
    env_assignment("CHOIR_AGENT_TYPE", agent_type),
    env_assignment("CHOIR_TERMINAL_TARGET", terminal_target.to_string()),
    env_assignment("CHOIR_TERMINAL_SESSION", session),
    env_assignment("CHOIR_SESSION_ID", agent_id),
    env_assignment("CHOIR_PARENT_AGENT", spec.parent_id),
  ]
  if spec.agent_type == @types.AgentType::Gemini {
    assignments.push(
      env_assignment(
        "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
        workspace + "/.choir/gemini-settings.json",
      ),
    )
  }
  if spec.agent_type == @types.AgentType::Pi {
    let runtime_root = pi_runtime_root(workspace, agent_id, spec.isolation)
    assignments.push(
      env_assignment("PI_CODING_AGENT_DIR", pi_agent_dir(runtime_root)),
    )
    assignments.push(env_assignment("PI_SKIP_VERSION_CHECK", "1"))
  }
  match @sys.getenv("TRACEPARENT") {
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
/// Environment assignments for [`@workspace.launch_commands`] / zellij `env` argv. PATH is merged in
/// process here (same effect as `PATH=prefix:$PATH` under a login shell).
pub fn launch_env_assignments(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
) -> Array[String] {
  let role = @config.role_to_string(spec.role)
  let agent_id = canonical_agent_id(spec)
  let git_branch = spawn_git_branch(spec)
  let agent_type = @config.agent_type_to_string(spec.agent_type)
  let assignments : Array[String] = [
    path_env_merged_for_argv(workspace + "/.choir/bin"),
    env_pair_raw("CHOIR_AGENT_ID", agent_id),
    env_pair_raw("CHOIR_PARENT_ID", spec.parent_id),
    env_pair_raw("CHOIR_BRANCH", git_branch),
    env_pair_raw("CHOIR_PARENT_BRANCH", spec.parent_branch),
    env_pair_raw("CHOIR_WORKSPACE", workspace),
    env_pair_raw("CHOIR_ROLE", role),
    env_pair_raw("CHOIR_AGENT_TYPE", agent_type),
    env_pair_raw("CHOIR_TERMINAL_TARGET", terminal_target.to_string()),
    env_pair_raw("CHOIR_TERMINAL_SESSION", session),
    env_pair_raw("CHOIR_SESSION_ID", agent_id),
    env_pair_raw("CHOIR_PARENT_AGENT", spec.parent_id),
  ]
  if spec.agent_type == @types.AgentType::Gemini {
    assignments.push(
      env_pair_raw(
        "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
        workspace + "/.choir/gemini-settings.json",
      ),
    )
  }
  if spec.agent_type == @types.AgentType::Pi {
    let runtime_root = pi_runtime_root(workspace, agent_id, spec.isolation)
    assignments.push(
      env_pair_raw("PI_CODING_AGENT_DIR", pi_agent_dir(runtime_root)),
    )
    assignments.push(env_pair_raw("PI_SKIP_VERSION_CHECK", "1"))
  }
  match @sys.getenv("TRACEPARENT") {
    Some(value) =>
      if value != "" {
        assignments.push(env_pair_raw("TRACEPARENT", value))
      }
    None => ()
  }
  assignments
}

///|
/// Strip `workdir` so zellij `--cwd` is the sole working-directory seam (matches spawn launch).
pub fn zellij_launch_inner_command(cmd : Command) -> Command {
  { ..cmd, workdir: None }
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
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> Array[Command] {
  let root_project = resolved_project_dir(project_dir)
  let branch = canonical_agent_id(spec)
  let workspace = match spec.isolation {
    Worktree => worktree_path(root_project, spawn_workspace_dir_slug(spec))
    Inline => root_project
    Standalone => root_project + "/.choir/agents/" + spec.slug
  }
  let launch_cmd = zellij_launch_inner_command(
    agent_launch_command(
      spec,
      workspace,
      parent_session_id~,
      shell_command~,
      extra_mcp_servers_json~,
    ),
  )
  let terminal_target = local_target_for(session, spec.slug, spec.isolation)
  let env_for_zellij = launch_env_assignments(
    spec, session, workspace, terminal_target,
  )
  match spec.isolation {
    Worktree => {
      let cmds : Array[Command] = []
      if !spec.reuse_workspace {
        cmds.push(
          git_worktree_bootstrap_cleanup_best_effort(
            root_project, workspace, branch,
          ),
        )
        cmds.push(
          git_fetch_origin_branch_best_effort(root_project, spec.parent_branch),
        )
        cmds.push(
          git_worktree_add(workspace, branch, "origin/" + spec.parent_branch),
        )
      }
      cmds.push(
        write_spawn_config(
          workspace,
          child_config_content(
            spec.role,
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
      cmds.push(write_leaf_helper_scripts(workspace))
      if spec.agent_type == Pi {
        let runtime_root = pi_runtime_root(
          workspace,
          canonical_agent_id(spec),
          spec.isolation,
        )
        cmds.push(write_pi_runtime_dirs(runtime_root))
        cmds.push(seed_pi_auth(runtime_root, root_project))
        cmds.push(write_pi_extension(workspace, runtime_root))
      }
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
        let ctx_paths = resolve_context_paths(
          root_project,
          @config.role_to_string(spec.role),
        )
        let wasm_path = root_project + "/.choir/hooks/hook.wasm"
        let wasm_hooks = if @sys.read_file(wasm_path) != "" {
          Some(wasm_path)
        } else {
          None
        }
        cmds.push(
          write_gemini_settings(
            workspace,
            canonical_agent_id(spec),
            @config.role_to_string(spec.role),
            context_paths=ctx_paths,
            wasm_hooks_path=wasm_hooks,
          ),
        )
      }
      if spec.agent_type == CursorAgent {
        cmds.push(
          write_cursor_mcp_json(
            workspace,
            canonical_agent_id(spec),
            @config.role_to_string(spec.role),
          ),
        )
      }
      for
        cmd in launch_commands(
          session,
          spec.slug,
          workspace,
          env_for_zellij,
          launch_cmd,
          spec.isolation,
        ) {
        cmds.push(cmd)
      }
      cmds
    }
    Inline => {
      let cmds : Array[Command] = []
      cmds.push(
        write_local_config(
          inline_agent_metadata_dir(root_project, canonical_agent_id(spec)),
          config_local_content(spec, workspace, terminal_target),
        ),
      )
      if spec.agent_type == Pi {
        let runtime_root = pi_runtime_root(
          workspace,
          canonical_agent_id(spec),
          spec.isolation,
        )
        cmds.push(write_pi_runtime_dirs(runtime_root))
        cmds.push(seed_pi_auth(runtime_root, root_project))
        cmds.push(write_pi_extension(workspace, runtime_root))
      }
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
      }
      for
        cmd in launch_commands(
          session,
          spec.slug,
          workspace,
          env_for_zellij,
          launch_cmd,
          spec.isolation,
        ) {
        cmds.push(cmd)
      }
      cmds
    }
    Standalone => {
      let cmds : Array[Command] = [
        { program: "git", args: ["init", workspace], workdir: None },
      ]
      cmds.push(
        write_spawn_config(
          workspace,
          child_config_content(
            spec.role,
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
      cmds.push(write_leaf_helper_scripts(workspace))
      if spec.agent_type == Pi {
        let runtime_root = pi_runtime_root(
          workspace,
          canonical_agent_id(spec),
          spec.isolation,
        )
        cmds.push(write_pi_runtime_dirs(runtime_root))
        cmds.push(seed_pi_auth(runtime_root, root_project))
        cmds.push(write_pi_extension(workspace, runtime_root))
      }
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
        let ctx_paths = resolve_context_paths(
          root_project,
          @config.role_to_string(spec.role),
        )
        let wasm_path = root_project + "/.choir/hooks/hook.wasm"
        let wasm_hooks = if @sys.read_file(wasm_path) != "" {
          Some(wasm_path)
        } else {
          None
        }
        cmds.push(
          write_gemini_settings(
            workspace,
            canonical_agent_id(spec),
            @config.role_to_string(spec.role),
            context_paths=ctx_paths,
            wasm_hooks_path=wasm_hooks,
          ),
        )
      }
      if spec.agent_type == CursorAgent {
        cmds.push(
          write_cursor_mcp_json(
            workspace,
            canonical_agent_id(spec),
            @config.role_to_string(spec.role),
          ),
        )
      }
      for
        cmd in launch_commands(
          session,
          spec.slug,
          workspace,
          env_for_zellij,
          launch_cmd,
          spec.isolation,
        ) {
        cmds.push(cmd)
      }
      cmds
    }
  }
}

///|
/// Remote `ssh ... <shell>` clone + branch checkout. `workspace` is left unquoted so a path
/// like `$HOME/exo-workspaces/...` expands on the remote shell.
fn remote_ssh_git_clone_checkout_script(
  parent_branch : String,
  repo_url : String,
  workspace : String,
  agent_branch : String,
) -> String {
  "git clone -b " +
  @sys.shell_quote(parent_branch) +
  " " +
  @sys.shell_quote(repo_url) +
  " " +
  workspace +
  " && cd " +
  workspace +
  " && git checkout -b " +
  @sys.shell_quote(agent_branch)
}

///|
/// Write merged Choir config files under `workspace/.choir/` on the remote host.
fn remote_ssh_write_choir_config_files_script(
  workspace : String,
  config_toml : String,
  local_config_toml : String,
) -> String {
  "mkdir -p " +
  workspace +
  "/.choir && printf '%s' " +
  @sys.shell_quote(config_toml) +
  " > " +
  workspace +
  "/.choir/config.toml && printf '%s' " +
  @sys.shell_quote(local_config_toml) +
  " > " +
  workspace +
  "/.choir/config.local.toml"
}

///|
/// `nohup` agent process with merged stdout/stderr to `/tmp/<slug>.log` (background).
fn remote_ssh_nohup_agent_script(
  workspace : String,
  agent_cmd : String,
  slug : String,
) -> String {
  "cd " +
  workspace +
  " && nohup " +
  agent_cmd +
  " > /tmp/" +
  @sys.shell_quote(slug) +
  ".log 2>&1 &"
}

///|
/// Build the foreground agent command line (env prefix + quoted argv) for remote `nohup`.
fn remote_ssh_agent_cmd_line(
  spec : @types.SpawnSpec,
  workspace : String,
  terminal_target : @types.LocalTarget,
  launch_cmd : Command,
) -> String {
  launch_env_prefix(spec, "remote", workspace, terminal_target) +
  command_text_for_launch(launch_cmd)
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
  let terminal_target = @types.LocalTarget::{
    kind: ZellijPane,
    session: "remote",
    name: spec.slug,
  }
  let config_toml = child_config_content(
    spec.role,
    "remote",
    workspace,
    ".choir/server.sock",
    listen_tcp=Some(tcp_addr),
  )
  let local_config_toml = config_local_content(spec, workspace, terminal_target)
  let launch_cmd = agent_launch_command(
    spec,
    workspace,
    parent_session_id~,
    extra_mcp_servers_json~,
  )
  let agent_cmd = remote_ssh_agent_cmd_line(
    spec, workspace, terminal_target, launch_cmd,
  )
  [
    ssh_cmd(
      ssh_target,
      remote_ssh_git_clone_checkout_script(
        spec.parent_branch,
        repo_url,
        workspace,
        branch,
      ),
    ),
    ssh_cmd(
      ssh_target,
      remote_ssh_write_choir_config_files_script(
        workspace, config_toml, local_config_toml,
      ),
    ),
    ssh_cmd(
      ssh_target,
      remote_ssh_nohup_agent_script(workspace, agent_cmd, spec.slug),
    ),
  ]
}

///|
const INIT_TL_POST_EXIT_SHELL_SUFFIX : String = "; echo; echo '[TL exited]'; exec bash -l"

///|
/// TL init zellij tab: Pi injects Choir env via `env` argv (same as [`launch_env_assignments`]); other
/// TL kinds keep legacy no-env shell body. A single `sh -lc` remains only for the agent sequence plus
/// post-exit interactive shell.
pub fn init_tl_zellij_tab_command(
  session : String,
  project_dir : String,
  tl_type : String,
) -> Command {
  let inner = zellij_launch_inner_command(
    init_tl_agent_command(tl_type, project_dir),
  )
  let script = inner.to_string() + INIT_TL_POST_EXIT_SHELL_SUFFIX
  let env_assignments = if tl_type == "pi" {
    let spec : @types.SpawnSpec = {
      slug: "root",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Pi,
      task: "",
      isolation: Worktree,
      parent_id: "root",
      parent_branch: "",
      reuse_workspace: true,
      workspace_slug: Some("root"),
      reuse_git_branch: Some("root"),
      spawn_depth: 0,
    }
    let terminal_target = local_target_for(session, "TL", Worktree)
    launch_env_assignments(spec, session, project_dir, terminal_target)
  } else {
    []
  }
  zellij_new_tab(session, "TL", project_dir, env_assignments, {
    program: "sh",
    args: ["-lc", script],
    workdir: None,
  })
}
