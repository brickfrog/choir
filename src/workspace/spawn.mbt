///|
fn command_text_for_launch(cmd : Command) -> String {
  { ..cmd, workdir: None }.to_string()
}

///|
fn tl_policy_supervised_shell_script(
  env_exports : String,
  inner : Command,
  post_exit_shell : String,
) -> String {
  let foreground_script = "choir tl-policy-watch --pid $$ & exec " +
    command_text_for_launch(inner)
  env_exports +
  "sh -lc " +
  @sys.shell_quote(foreground_script) +
  "; status=$?;" +
  post_exit_shell
}

///|
fn env_assignment(key : String, value : String) -> String {
  key + "=" + @sys.shell_quote(value)
}

///|
fn export_assignment(key : String, value : String) -> String {
  "export " + key + "=" + @sys.shell_quote(value) + "; "
}

///|
fn export_path_assignment(prefix : String) -> String {
  "export PATH=" + @sys.shell_quote(prefix) + ":$PATH; "
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
  if spec.agent_type == @types.AgentType::Gemini ||
    spec.agent_type == @types.AgentType::Unknown {
    assignments.push(
      env_assignment(
        "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
        workspace + "/.choir/gemini-settings.json",
      ),
    )
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
fn launch_env_exports(
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
    export_path_assignment(workspace + "/.choir/bin"),
    export_assignment("CHOIR_AGENT_ID", agent_id),
    export_assignment("CHOIR_PARENT_ID", spec.parent_id),
    export_assignment("CHOIR_BRANCH", git_branch),
    export_assignment("CHOIR_PARENT_BRANCH", spec.parent_branch),
    export_assignment("CHOIR_WORKSPACE", workspace),
    export_assignment("CHOIR_ROLE", role),
    export_assignment("CHOIR_AGENT_TYPE", agent_type),
    export_assignment("CHOIR_TERMINAL_TARGET", terminal_target.to_string()),
    export_assignment("CHOIR_TERMINAL_SESSION", session),
    export_assignment("CHOIR_SESSION_ID", agent_id),
    export_assignment("CHOIR_PARENT_AGENT", spec.parent_id),
  ]
  if spec.agent_type == @types.AgentType::Gemini ||
    spec.agent_type == @types.AgentType::Unknown {
    assignments.push(
      export_assignment(
        "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
        workspace + "/.choir/gemini-settings.json",
      ),
    )
  }
  match @sys.getenv("TRACEPARENT") {
    Some(value) =>
      if value != "" {
        assignments.push(export_assignment("TRACEPARENT", value))
      }
    None => ()
  }
  assignments.join("")
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
  if spec.agent_type == @types.AgentType::Gemini ||
    spec.agent_type == @types.AgentType::Unknown {
    assignments.push(
      env_pair_raw(
        "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
        workspace + "/.choir/gemini-settings.json",
      ),
    )
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
/// Local `ssh` child: **direct argv** (`ssh`, `-o`, …, `target`, `remote_command`) with no Choir-side
/// `sh -c` wrapper. OpenSSH still delivers `remote_command` as a string executed by the **remote**
/// user's default shell, so `&&`, `cd`, `nohup`, and `$HOME` are remote-shell semantics. That layer
/// is intrinsic to `ssh host <command>` unless the transport changes (e.g. multiple sessions, SFTP,
/// or a non-shell RPC). Untrusted fragments use [`@sys.shell_quote`]; workspace paths under
/// `$HOME/exo-workspaces/` stay unquoted so remote expansion behaves as today.
fn ssh_cmd(target : String, remote_shell : String) -> Command {
  {
    program: "ssh",
    args: ["-o", "StrictHostKeyChecking=no", target, remote_shell],
    workdir: None,
  }
}

///|
pub fn provider_materialization_commands(
  agent_type : @types.AgentType,
  root_project : String,
  workspace : String,
  agent_id : String,
  role : @types.Role,
) -> Array[Command] {
  let cmds : Array[Command] = []
  let role_str = @config.role_to_string(role)
  if agent_type == Gemini || agent_type == Unknown {
    cmds.push(trust_gemini_folder(workspace))
    let ctx_paths = resolve_context_paths(root_project, role_str)
    let wasm_path = root_project + "/.choir/hooks/hook.wasm"
    let wasm_hooks = if @sys.read_file(wasm_path) != "" {
      Some(wasm_path)
    } else {
      None
    }
    cmds.push(
      write_gemini_settings(
        workspace,
        agent_id,
        role_str,
        context_paths=ctx_paths,
        wasm_hooks_path=wasm_hooks,
      ),
    )
  }
  if agent_type == CursorAgent {
    cmds.push(write_cursor_mcp_json(workspace, agent_id, role_str))
  }
  cmds
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
  let provider_cmds = provider_materialization_commands(
    spec.agent_type,
    root_project,
    workspace,
    canonical_agent_id(spec),
    spec.role,
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
      for cmd in provider_cmds {
        cmds.push(cmd)
      }
      let launch_cmds = if spec.role == @types.Role::TL &&
        spec.isolation != @types.IsolationMode::Inline {
        [
          zellij_new_tab_shell(
            session,
            spec.slug,
            workspace,
            tl_policy_supervised_shell_script(
              launch_env_exports(spec, session, workspace, terminal_target),
              launch_cmd,
              " exit \"$status\"",
            ),
          ),
        ]
      } else {
        launch_commands(
          session,
          spec.slug,
          workspace,
          env_for_zellij,
          launch_cmd,
          spec.isolation,
        )
      }
      for cmd in launch_cmds {
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
      cmds.push(write_leaf_helper_scripts(workspace))
      for cmd in provider_cmds {
        cmds.push(cmd)
      }
      let launch_cmds = if spec.role == @types.Role::TL &&
        spec.isolation != @types.IsolationMode::Inline {
        [
          zellij_new_tab_shell(
            session,
            spec.slug,
            workspace,
            tl_policy_supervised_shell_script(
              launch_env_exports(spec, session, workspace, terminal_target),
              launch_cmd,
              " exit \"$status\"",
            ),
          ),
        ]
      } else {
        launch_commands(
          session,
          spec.slug,
          workspace,
          env_for_zellij,
          launch_cmd,
          spec.isolation,
        )
      }
      for cmd in launch_cmds {
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
      for cmd in provider_cmds {
        cmds.push(cmd)
      }
      let launch_cmds = if spec.role == @types.Role::TL &&
        spec.isolation != @types.IsolationMode::Inline {
        [
          zellij_new_tab_shell(
            session,
            spec.slug,
            workspace,
            tl_policy_supervised_shell_script(
              launch_env_exports(spec, session, workspace, terminal_target),
              launch_cmd,
              " exit \"$status\"",
            ),
          ),
        ]
      } else {
        launch_commands(
          session,
          spec.slug,
          workspace,
          env_for_zellij,
          launch_cmd,
          spec.isolation,
        )
      }
      for cmd in launch_cmds {
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
/// Three sequential [`ssh_cmd`] invocations (clone/checkout, write config, background agent). See
/// [`ssh_cmd`] for the remote-shell boundary.
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
/// Suffix appended to the TL agent shell line for `choir init --tl …` zellij tabs.
///
/// After the TL agent exits, print a blank line and `[TL exited]`, then `exec bash -l` so the pane
/// stays usable instead of closing on a dead TTY.
///
/// Why this stays a shell (`sh -lc` below) and is not merged into [`zellij_new_tab_argv`]:
/// - [`Command::to_string`] emits shell-shaped text (`cd … && …`, quoted argv), not a argv array.
/// - Chaining agent exit → echoes → interactive login shell requires shell control operators (`;`,
///   `exec`). Zellij’s `env <prog> <argv…>` tab entry has no “on exit run …” hook.
///
/// A single login-shell script is the minimal wrapper for the TL agent command.
const INIT_TL_POST_EXIT_SHELL_SUFFIX : String = " echo; echo '[TL exited]'; exec bash -l"

///|
/// TL init zellij tab: spawns a login-shell wrapping the TL agent command.
pub fn init_tl_zellij_tab_command(
  session : String,
  project_dir : String,
  tl_type : String,
  branch : String,
) -> Command {
  let inner = zellij_launch_inner_command(
    init_tl_agent_command(tl_type, project_dir),
  )
  let env_exports = export_assignment("CHOIR_AGENT_ID", "root") +
    export_assignment("CHOIR_BRANCH", branch) +
    export_assignment("CHOIR_PARENT_BRANCH", branch) +
    export_assignment("CHOIR_ROLE", "tl") +
    export_assignment("CHOIR_WORKSPACE", project_dir) +
    export_assignment(
      "CHOIR_TERMINAL_TARGET",
      local_target_for(session, "TL", @types.IsolationMode::Worktree).to_string(),
    ) +
    export_assignment("CHOIR_TERMINAL_SESSION", session) +
    export_assignment("CHOIR_SESSION_ID", "root")
  zellij_new_tab_shell(
    session,
    "TL",
    project_dir,
    tl_policy_supervised_shell_script(
      env_exports,
      inner,
      INIT_TL_POST_EXIT_SHELL_SUFFIX,
    ),
  )
}
