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
fn write_prompt_file(
  project_dir : String,
  slug : String,
  prompt : String,
) -> String {
  let ts = @env.now().reinterpret_as_int64()
  let path = project_dir +
    "/.choir/tmp/prompt-" +
    ts.to_string() +
    "-" +
    slug +
    ".txt"
  ignore(@sys.write_file_sync(path, prompt))
  if path.has_prefix("/") {
    path
  } else {
    @env.current_dir().unwrap_or(".") + "/" + path
  }
}

///|
fn replace_placeholder(
  s : String,
  placeholder : String,
  replacement : String,
) -> String {
  let idx = match s.find(placeholder) {
    Some(i) => i
    None => return s
  }
  let before = s[:idx].to_string()
  let after = s[idx + placeholder.length():].to_string()
  before + replacement + after
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
    @env.current_dir().unwrap_or(".") + "/" + project_dir
  }
}

///|
fn launch_env_prefix(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
) -> String {
  let role = role_to_string(spec.role)
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
  let prompt_path = write_prompt_file(root_project, spec.slug, spec.task)
  let launch_cmd = agent_launch_command(
    { ..spec, task: "__PROMPT_PLACEHOLDER__" },
    workspace,
    parent_session_id~,
    shell_command~,
    extra_mcp_servers_json~,
  )
  let terminal_target = local_target_for(session, spec.slug, spec.isolation)
  let prompt_ref = "\"$(cat " + quote(prompt_path) + ")\""
  let raw_launch = command_text_for_launch(launch_cmd)
  let launch_with_prompt = replace_placeholder(
    raw_launch, "'__PROMPT_PLACEHOLDER__'", prompt_ref,
  )
  let launch_str = launch_env_prefix(spec, session, workspace, terminal_target) +
    launch_with_prompt
  match spec.isolation {
    Worktree => {
      let cmds : Array[Command] = []
      if not(spec.reuse_workspace) {
        cmds.push({
          program: "sh",
          args: [
            "-c", "git worktree remove --force \"$1\" 2>/dev/null || true; rm -rf \"$1\"; git branch -D \"$2\" 2>/dev/null || true",
            "sh", workspace, branch,
          ],
          workdir: None,
        })
        cmds.push(git_worktree_add(workspace, branch))
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
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
        let ctx_paths = resolve_context_paths(
          root_project,
          role_to_string(spec.role),
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
            role_to_string(spec.role),
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
            role_to_string(spec.role),
          ),
        )
      }
      for
        cmd in launch_commands(
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
    Inline => {
      let cmds : Array[Command] = []
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
      }
      for
        cmd in launch_commands(
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
      if spec.agent_type == Gemini {
        cmds.push(trust_gemini_folder(workspace))
        let ctx_paths = resolve_context_paths(
          root_project,
          role_to_string(spec.role),
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
            role_to_string(spec.role),
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
            role_to_string(spec.role),
          ),
        )
      }
      for
        cmd in launch_commands(
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
  let launch_cmd = agent_launch_command(
    spec,
    workspace,
    parent_session_id~,
    extra_mcp_servers_json~,
  )
  let agent_cmd = launch_env_prefix(spec, "remote", workspace, @types.LocalTarget::{
      kind: ZellijPane,
      session: "remote",
      name: spec.slug,
    }) +
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
