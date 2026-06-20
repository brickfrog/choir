///|
fn command_text_for_launch(cmd : Command) -> String {
  { ..cmd, workdir: None }.to_string()
}

///|
fn tl_lifecycle_shell_script(
  env_exports : String,
  inner : Command,
  post_exit_shell : String,
) -> String {
  let foreground_script = "exec " + command_text_for_launch(inner)
  // Diagnostics for choir-eek (TL/root claude process exits unexpectedly):
  //  - A `trap` on this OUTER shell for HUP/TERM logs that a signal arrived
  //    AND keeps the shell alive past it, so the `status=$?` below still
  //    runs and records the agent's exit code. Without the trap, a
  //    pgroup-wide SIGHUP (zellij/pane teardown) kills the shell before it
  //    can log anything. (SIGKILL — e.g. OOM — is uncatchable; that one
  //    only shows up in `dmesg`. SIGINT/Ctrl+C is left untrapped so it stays
  //    a normal interrupt and doesn't spam the log.)
  //  - `exit_log_step` records `exit=<code>` after the agent exits for any
  //    reason (clean exit, harness crash, caught signal).
  // CHOIR_WORKSPACE is exported by `env_exports`; `2>/dev/null` keeps a
  // missing log file/dir from disturbing the rest of the handling.
  let exits_log = "\"$CHOIR_WORKSPACE/.choir/tl-exits.log\""
  let signal_trap = "trap 'printf \"%s [TL wrapper caught signal]\\n\"" +
    " \"$(date -Is)\" >> " +
    exits_log +
    " 2>/dev/null' HUP TERM; "
  let exit_log_step = " printf '%s exit=%s\\n' \"$(date -Is)\" \"$status\"" +
    " >> " +
    exits_log +
    " 2>/dev/null;"
  env_exports +
  signal_trap +
  "sh -lc " +
  @sys.shell_quote(foreground_script) +
  "; status=$?;" +
  exit_log_step +
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
fn absolute_listen_uds(project_dir : String, listen_uds : String) -> String {
  if listen_uds.has_prefix("/") {
    listen_uds
  } else {
    resolved_project_dir(project_dir) + "/" + listen_uds
  }
}

///|
/// Canonical (key, value) list of every non-PATH environment variable that
/// spawned agents receive. Single source of truth for the three serializers
/// below; adding a new CHOIR_* var (or a new conditional) goes here once.
/// PATH is intentionally not included — each serializer merges PATH with its
/// own format (shell vs argv) since the handling differs.
fn shared_env_pairs(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
  listen_uds_env? : String? = None,
  agent_token? : String? = None,
) -> Array[(String, String)] {
  let role = @config.role_to_string(spec.role)
  let agent_id = canonical_agent_id(spec)
  let git_branch = spawn_git_branch(spec)
  let agent_type = @config.agent_type_to_string(spec.agent_type)
  let pairs : Array[(String, String)] = [
    ("CHOIR_AGENT_ID", agent_id),
    ("CHOIR_PARENT_ID", spec.parent_id),
    ("CHOIR_BRANCH", git_branch),
    ("CHOIR_PARENT_BRANCH", spec.parent_branch),
    ("CHOIR_WORKSPACE", workspace),
    ("CHOIR_ROLE", role),
    ("CHOIR_AGENT_TYPE", agent_type),
    ("CHOIR_TERMINAL_TARGET", terminal_target.to_string()),
    ("CHOIR_TERMINAL_SESSION", session),
    ("CHOIR_SESSION_ID", agent_id),
    ("CHOIR_PARENT_AGENT", spec.parent_id),
  ]
  match agent_token {
    Some(token) => if token != "" { pairs.push(("CHOIR_AGENT_TOKEN", token)) }
    None => ()
  }
  match listen_uds_env {
    Some(value) => pairs.push(("CHOIR_LISTEN_UDS", value))
    None => ()
  }
  if spec.agent_type == @types.AgentType::Gemini ||
    spec.agent_type == @types.AgentType::Unknown {
    pairs.push(("HOME", agy_home_path(workspace)))
  }
  match @sys.getenv("TRACEPARENT") {
    Some(value) => if value != "" { pairs.push(("TRACEPARENT", value)) }
    None => ()
  }
  pairs
}

///|
pub fn launch_env_prefix(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
  listen_uds_env? : String? = None,
  agent_token? : String? = None,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(path_assignment(workspace + "/.choir/bin"))
  for
    pair in shared_env_pairs(
      spec,
      session,
      workspace,
      terminal_target,
      listen_uds_env~,
      agent_token~,
    ) {
    let (k, v) = pair
    buf.write_char(' ')
    buf.write_string(env_assignment(k, v))
  }
  buf.write_char(' ')
  buf.to_string()
}

///|
fn launch_env_exports(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
  listen_uds_env? : String? = None,
  agent_token? : String? = None,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(export_path_assignment(workspace + "/.choir/bin"))
  for
    pair in shared_env_pairs(
      spec,
      session,
      workspace,
      terminal_target,
      listen_uds_env~,
      agent_token~,
    ) {
    let (k, v) = pair
    buf.write_string(export_assignment(k, v))
  }
  buf.to_string()
}

///|
/// Environment assignments for [`@workspace.launch_commands`] / zellij `env` argv. PATH is merged in
/// process here (same effect as `PATH=prefix:$PATH` under a login shell).
pub fn launch_env_assignments(
  spec : @types.SpawnSpec,
  session : String,
  workspace : String,
  terminal_target : @types.LocalTarget,
  listen_uds_env? : String? = None,
  agent_token? : String? = None,
) -> Array[String] {
  let result : Array[String] = [
    path_env_merged_for_argv(workspace + "/.choir/bin"),
  ]
  for
    pair in shared_env_pairs(
      spec,
      session,
      workspace,
      terminal_target,
      listen_uds_env~,
      agent_token~,
    ) {
    let (k, v) = pair
    result.push(env_pair_raw(k, v))
  }
  result
}

///|
/// Strip `workdir` so zellij `--cwd` is the sole working-directory seam (matches spawn launch).
pub fn zellij_launch_inner_command(cmd : Command) -> Command {
  { ..cmd, workdir: None }
}

///|
/// The three serializers (launch_env_prefix / launch_env_exports /
/// launch_env_assignments) must agree on which non-PATH keys ship to a
/// spawned agent; the only axis they disagree on is the string shape.
/// Since they all delegate to `shared_env_pairs` now, this invariant holds
/// by construction — the test fences it so a future accidental divergence
/// (e.g. adding a key in only one of the three) is caught.
test "launch env serializers agree on the non-PATH key set" {
  let spec : @types.SpawnSpec = {
    slug: "leaf-a",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: "t",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    wave_id: None,
  }
  let target = @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "leaf-a",
  }
  let listen_uds_env = "/repo/.choir/server.sock"
  let pairs = shared_env_pairs(
    spec,
    "sess",
    "/ws",
    target,
    listen_uds_env=Some(listen_uds_env),
  )
  let expected_keys : Array[String] = []
  for p in pairs {
    let (k, _) = p
    expected_keys.push(k)
  }
  // Prefix serializer: `PATH=... K1='v1' K2='v2' ... ` — split on space.
  let prefix = launch_env_prefix(
    spec,
    "sess",
    "/ws",
    target,
    listen_uds_env=Some(listen_uds_env),
  )
  let prefix_keys : Array[String] = []
  for token in prefix.split(" ") {
    let s = token.to_owned()
    if s == "" || s.has_prefix("PATH=") {
      continue
    }
    match s.split_once("=") {
      Some((k, _)) => prefix_keys.push(k.to_owned())
      None => ()
    }
  }
  @debug.assert_eq(prefix_keys, expected_keys)
  // Exports serializer: `export PATH=...; export K1='v1'; ...` — split on `;`.
  let exports = launch_env_exports(
    spec,
    "sess",
    "/ws",
    target,
    listen_uds_env=Some(listen_uds_env),
  )
  let export_keys : Array[String] = []
  for stmt in exports.split(";") {
    let s = stmt.trim().to_owned()
    if !s.has_prefix("export ") {
      continue
    }
    let rhs = s["export ".length():].to_owned()
    if rhs.has_prefix("PATH=") {
      continue
    }
    match rhs.split_once("=") {
      Some((k, _)) => export_keys.push(k.to_owned())
      None => ()
    }
  }
  @debug.assert_eq(export_keys, expected_keys)
  // Argv serializer: `Array[String]` — first entry is PATH, rest are K=V.
  let argv = launch_env_assignments(
    spec,
    "sess",
    "/ws",
    target,
    listen_uds_env=Some(listen_uds_env),
  )
  let argv_keys : Array[String] = []
  for s in argv {
    if s.has_prefix("PATH=") {
      continue
    }
    match s.split_once("=") {
      Some((k, _)) => argv_keys.push(k.to_owned())
      None => ()
    }
  }
  @debug.assert_eq(argv_keys, expected_keys)
}

///|
test "shared env pairs include spawned agent token when provided" {
  let spec : @types.SpawnSpec = {
    slug: "leaf-token",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "t",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "root",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    wave_id: None,
  }
  let target = @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "leaf-token",
  }
  let pairs = shared_env_pairs(
    spec,
    "sess",
    "/ws",
    target,
    agent_token=Some("spawn-token-a"),
  )
  let mut saw_pair = false
  for pair in pairs {
    let (key, value) = pair
    if key == "CHOIR_AGENT_TOKEN" && value == "spawn-token-a" {
      saw_pair = true
    }
  }
  assert_true(saw_pair)
  assert_true(
    launch_env_assignments(
      spec,
      "sess",
      "/ws",
      target,
      agent_token=Some("spawn-token-a"),
    ).contains("CHOIR_AGENT_TOKEN=spawn-token-a"),
  )
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
priv struct ContractBoundaryHookPlan {
  wasm_hooks_path : String?
  guard_paths : Array[String]
  warning : Command?
}

///|
fn strip_inline_comment(s : String) -> String {
  let mut in_double = false
  let mut in_single = false
  let mut cut = s.length()
  let mut i = 0
  while i < s.length() {
    let c = s[i]
    if c == '"' && !in_single {
      in_double = !in_double
    } else if c == '\'' && !in_double {
      in_single = !in_single
    } else if c == '#' && !in_single && !in_double {
      cut = i
      break
    }
    i = i + 1
  }
  s[0:cut].to_owned().trim().to_owned()
}

///|
fn hooks_enforcement_enabled(config_content : String) -> Bool {
  match @config.parse_toml_doc(config_content).get("hooks_enforcement") {
    Some(raw) => {
      let v = strip_inline_comment(raw).to_lower()
      v == "true" || v == "1" || v == "yes"
    }
    None => false
  }
}

///|
fn task_contract_guard_paths(contract : @types.TaskContract?) -> Array[String] {
  match contract {
    Some(c) => c.guard_paths
    None => []
  }
}

///|
fn executable_on_path(
  name : String,
  getenv : (String) -> String?,
  path_executable : (String) -> Bool,
) -> Bool {
  let path_var = match getenv("PATH") {
    Some(p) => p
    None => "/usr/local/bin:/usr/bin:/bin"
  }
  for raw in path_var.split(":") {
    let dir = raw.trim().to_owned()
    if dir == "" {
      continue
    }
    if path_executable(dir + "/" + name) {
      return true
    }
  }
  false
}

///|
fn extism_on_path_default() -> Bool {
  executable_on_path("extism", @sys.getenv, @sys.path_executable)
}

///|
fn contract_boundary_hook_warning_command(
  agent_id : String,
  missing : Array[String],
) -> Command {
  {
    program: "sh",
    args: [
      "-c",
      "printf '%s\\n' \"$1\" >&2",
      "choir-hooks-warning",
      "choir: warning: hooks_enforcement requested for " +
      agent_id +
      " but contract-boundary hooks are disabled because " +
      missing.join(" and ") +
      " missing; continuing fail-open",
    ],
    workdir: None,
  }
}

///|
fn contract_boundary_hook_plan(
  root_project : String,
  agent_id : String,
  task_contract : @types.TaskContract?,
  project_config_content : String,
  read_file : (String) -> String,
  extism_on_path : () -> Bool,
) -> ContractBoundaryHookPlan {
  let guard_paths = task_contract_guard_paths(task_contract)
  if guard_paths.length() == 0 ||
    !hooks_enforcement_enabled(project_config_content) {
    return { wasm_hooks_path: None, guard_paths: [], warning: None }
  }
  let wasm_path = root_project + "/.choir/hooks/hook.wasm"
  let wasm_present = read_file(wasm_path) != ""
  let extism_present = extism_on_path()
  if wasm_present && extism_present {
    return { wasm_hooks_path: Some(wasm_path), guard_paths, warning: None }
  }
  let missing : Array[String] = []
  if !extism_present {
    missing.push("extism on PATH")
  }
  if !wasm_present {
    missing.push(".choir/hooks/hook.wasm")
  }
  {
    wasm_hooks_path: None,
    guard_paths: [],
    warning: Some(contract_boundary_hook_warning_command(agent_id, missing)),
  }
}

///|
pub fn provider_materialization_commands(
  agent_type : @types.AgentType,
  root_project : String,
  workspace : String,
  agent_id : String,
  role : @types.Role,
  contract_boundary_wasm_hooks_path? : String? = None,
  contract_boundary_guard_paths? : Array[String] = [],
) -> Array[Command] {
  let cmds : Array[Command] = []
  let role_str = @config.role_to_string(role)
  let completion_handoff_enabled = role == @types.Role::Dev ||
    role == @types.Role::Worker
  let contract_boundary_enabled = contract_boundary_wasm_hooks_path is Some(_) &&
    contract_boundary_guard_paths.length() > 0
  if agent_type == Codex &&
    (completion_handoff_enabled || contract_boundary_enabled) {
    cmds.push(
      write_codex_spawn_hooks_config_toml(
        workspace,
        include_completion_handoff=completion_handoff_enabled,
        wasm_hooks_path=contract_boundary_wasm_hooks_path,
        guard_paths=contract_boundary_guard_paths,
      ),
    )
  } else if agent_type == Claude &&
    (completion_handoff_enabled || contract_boundary_enabled) {
    if completion_handoff_enabled {
      cmds.push(write_claude_completion_handoff_hook(workspace))
    }
    cmds.push(
      write_claude_spawn_settings(
        workspace,
        include_completion_handoff=completion_handoff_enabled,
        wasm_hooks_path=contract_boundary_wasm_hooks_path,
        guard_paths=contract_boundary_guard_paths,
      ),
    )
  }
  if completion_handoff_enabled && (agent_type == Codex || agent_type == Claude) {
    cmds.push(write_completion_handoff_attempts_reset(workspace, agent_id))
  }
  if agent_type == Gemini || agent_type == Unknown {
    cmds.push(agy_cache_links(root_project, workspace))
    cmds.push(trust_gemini_folder(workspace))
    let wasm_path = root_project + "/.choir/hooks/hook.wasm"
    let wasm_hooks = match contract_boundary_wasm_hooks_path {
      Some(path) => Some(path)
      None =>
        if @sys.read_file(wasm_path) != "" {
          Some(wasm_path)
        } else {
          None
        }
    }
    cmds.push(write_agy_mcp_config(workspace, agent_id, role_str))
    let agy_guard_paths = match contract_boundary_wasm_hooks_path {
      Some(_) => contract_boundary_guard_paths
      None => []
    }
    cmds.push(
      write_agy_hooks(
        workspace,
        wasm_hooks_path=wasm_hooks,
        guard_paths=agy_guard_paths,
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
  agent_token? : String? = None,
  project_config_content? : String = "",
  read_file? : (String) -> String = @sys.read_file,
  extism_on_path? : () -> Bool = extism_on_path_default,
  model? : String? = None,
  effort? : String? = None,
) -> Array[Command] {
  ignore(listen_tcp)
  ignore(tcp_auth_token)
  let root_project = resolved_project_dir(project_dir)
  let listen_uds_env = absolute_listen_uds(root_project, listen_uds)
  let branch = canonical_agent_id(spec)
  let workspace = spawn_workspace_path(root_project, spec)
  let boundary_hook_plan = if spec.isolation == @types.IsolationMode::Worktree {
    contract_boundary_hook_plan(
      root_project,
      canonical_agent_id(spec),
      spec.task_contract,
      project_config_content,
      read_file,
      extism_on_path,
    )
  } else {
    { wasm_hooks_path: None, guard_paths: [], warning: None }
  }
  let completion_handoff_hooks_enabled = spec.role == @types.Role::Dev ||
    spec.role == @types.Role::Worker
  let boundary_claude_settings_path = match boundary_hook_plan.wasm_hooks_path {
    Some(_) =>
      if spec.agent_type == Claude &&
        boundary_hook_plan.guard_paths.length() > 0 {
        Some(workspace + "/.choir/claude-settings.json")
      } else {
        None
      }
    None => None
  }
  let claude_settings_path = if spec.agent_type == Claude &&
    completion_handoff_hooks_enabled {
    Some(workspace + "/.choir/claude-settings.json")
  } else {
    boundary_claude_settings_path
  }
  let launch_cmd = zellij_launch_inner_command(
    agent_launch_command(
      spec,
      workspace,
      parent_session_id~,
      shell_command~,
      extra_mcp_servers_json~,
      project_dir=root_project,
      claude_settings_path~,
      codex_bypass_hook_trust=boundary_hook_plan.wasm_hooks_path is Some(_) ||
        (spec.agent_type == Codex && completion_handoff_hooks_enabled),
      model~,
      effort~,
    ),
  )
  let terminal_target = local_target_for(session, spec.slug, spec.isolation)
  let env_for_zellij = launch_env_assignments(
    spec,
    session,
    workspace,
    terminal_target,
    listen_uds_env=Some(listen_uds_env),
    agent_token~,
  )
  let provider_cmds = provider_materialization_commands(
    spec.agent_type,
    root_project,
    workspace,
    canonical_agent_id(spec),
    spec.role,
    contract_boundary_wasm_hooks_path=boundary_hook_plan.wasm_hooks_path,
    contract_boundary_guard_paths=boundary_hook_plan.guard_paths,
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
        cmds.push(command_seed_worktree_agent_runtime_gitexclude(workspace))
      }
      cmds.push(write_worktree_config_toml(workspace, project_config_content))
      cmds.push(
        write_local_config(
          workspace,
          config_local_content(
            spec,
            workspace,
            terminal_target,
            project_dir=Some(root_project),
            listen_uds=Some(listen_uds_env),
            terminal_session=Some(session),
          ),
        ),
      )
      cmds.push(write_leaf_helper_scripts(workspace))
      match boundary_hook_plan.warning {
        Some(cmd) => cmds.push(cmd)
        None => ()
      }
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
            tl_lifecycle_shell_script(
              launch_env_exports(
                spec,
                session,
                workspace,
                terminal_target,
                listen_uds_env=Some(listen_uds_env),
                agent_token~,
              ),
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
    Inline | InlineDedicatedTab => {
      let cmds : Array[Command] = []
      cmds.push(
        write_local_config(
          inline_agent_metadata_dir(root_project, canonical_agent_id(spec)),
          config_local_content(
            spec,
            workspace,
            terminal_target,
            project_dir=Some(root_project),
            listen_uds=Some(listen_uds_env),
            terminal_session=Some(session),
          ),
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
            tl_lifecycle_shell_script(
              launch_env_exports(
                spec,
                session,
                workspace,
                terminal_target,
                listen_uds_env=Some(listen_uds_env),
                agent_token~,
              ),
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
        write_local_config(
          workspace,
          config_local_content(
            spec,
            workspace,
            terminal_target,
            project_dir=Some(root_project),
            listen_uds=Some(listen_uds_env),
            terminal_session=Some(session),
          ),
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
            tl_lifecycle_shell_script(
              launch_env_exports(
                spec,
                session,
                workspace,
                terminal_target,
                listen_uds_env=Some(listen_uds_env),
                agent_token~,
              ),
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
  workspace_expr : String,
  agent_branch : String,
) -> String {
  "git clone -b " +
  @sys.shell_quote(parent_branch) +
  " " +
  @sys.shell_quote(repo_url) +
  " " +
  workspace_expr +
  " && cd " +
  workspace_expr +
  " && git checkout -b " +
  @sys.shell_quote(agent_branch)
}

///|
/// Write merged Choir config files under `workspace/.choir/` on the remote host.
fn remote_ssh_write_choir_config_files_script(
  workspace_expr : String,
  config_toml : String,
  local_config_toml : String,
) -> String {
  "mkdir -p " +
  workspace_expr +
  "/.choir && printf '%s' " +
  @sys.shell_quote(config_toml) +
  " > " +
  workspace_expr +
  "/.choir/config.toml && printf '%s' " +
  @sys.shell_quote(local_config_toml) +
  " > " +
  workspace_expr +
  "/.choir/config.local.toml"
}

///|
/// `nohup` agent process with merged stdout/stderr to `/tmp/<slug>.log` (background).
fn remote_ssh_nohup_agent_script(
  workspace_expr : String,
  agent_cmd : String,
  slug : String,
) -> String {
  "cd " +
  workspace_expr +
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
  agent_token? : String? = None,
) -> String {
  launch_env_prefix(spec, "remote", workspace, terminal_target, agent_token~) +
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
  agent_token? : String? = None,
) -> Array[Command] {
  let branch = canonical_agent_id(spec)
  let workspace = "$HOME/exo-workspaces/" + branch
  let workspace_expr = "$HOME/exo-workspaces/" + @sys.shell_quote(branch)
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
  let local_config_toml = config_local_content(
    spec,
    workspace,
    terminal_target,
    project_dir=Some(workspace),
    listen_uds=Some(".choir/server.sock"),
    terminal_session=Some("remote"),
  )
  let launch_cmd = agent_launch_command(
    spec,
    workspace,
    parent_session_id~,
    extra_mcp_servers_json~,
  )
  let agent_cmd = remote_ssh_agent_cmd_line(
    spec,
    workspace,
    terminal_target,
    launch_cmd,
    agent_token~,
  )
  [
    ssh_cmd(
      ssh_target,
      remote_ssh_git_clone_checkout_script(
        spec.parent_branch,
        repo_url,
        workspace_expr,
        branch,
      ),
    ),
    ssh_cmd(
      ssh_target,
      remote_ssh_write_choir_config_files_script(
        workspace_expr, config_toml, local_config_toml,
      ),
    ),
    ssh_cmd(
      ssh_target,
      remote_ssh_nohup_agent_script(workspace_expr, agent_cmd, spec.slug),
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
  lean? : Bool = false,
  root_agent_token? : String? = None,
) -> Command {
  let tl_agent_type = tl_type_agent_type(tl_type)
  let inner = zellij_launch_inner_command(
    init_tl_agent_command(tl_type, project_dir, lean~),
  )
  let tl_home_export = if tl_agent_type == @types.AgentType::Gemini {
    export_assignment("HOME", agy_home_path(project_dir))
  } else {
    ""
  }
  let root_token_export = match root_agent_token {
    Some(token) =>
      if token != "" {
        export_assignment("CHOIR_AGENT_TOKEN", token)
      } else {
        ""
      }
    None => ""
  }
  let env_exports = export_assignment("CHOIR_AGENT_ID", "root") +
    export_assignment("CHOIR_BRANCH", branch) +
    export_assignment("CHOIR_PARENT_BRANCH", branch) +
    export_assignment("CHOIR_ROLE", "tl") +
    export_assignment("CHOIR_WORKSPACE", project_dir) +
    tl_home_export +
    root_token_export +
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
    tl_lifecycle_shell_script(
      env_exports,
      inner,
      INIT_TL_POST_EXIT_SHELL_SUFFIX,
    ),
  )
}
