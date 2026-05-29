///|
fn init_no_attach(args : Array[String]) -> Bool {
  args.contains("--no-attach")
}

///|
fn init_kill_session_command(session : String) -> @workspace.Command {
  @workspace.zellij_kill_session(session)
}

///|
async fn init_tab_exists(session : String, tab_name : String) -> Bool {
  try {
    let (code, output) = @exec.capture_command_merged(
      @workspace.zellij_query_tab_names_command(session),
    )
    if code != 0 {
      false
    } else {
      @workspace.zellij_tab_name_exists_in_query_output(output, tab_name)
    }
  } catch {
    _ => false
  }
}

///|
fn init_parse_server_pid_line(s : String) -> Int? {
  Some(@string.parse_int(s.trim().to_owned())) catch {
    _ => None
  }
}

///|
fn init_kill_server_pid_string(pid_str : String) -> Unit {
  match init_parse_server_pid_line(pid_str) {
    Some(pid) => @sys.kill_server_pid_sequence_best_effort(pid)
    None => ()
  }
}

///|
/// Exit code compatible with former `sh -c '...kill -0...'`: 0 when `.choir/server.pid` parses to a
/// live PID, else non-zero.
fn init_server_running_exit_code() -> Int {
  let raw = @sys.read_file(".choir/server.pid")
  match init_parse_server_pid_line(raw) {
    Some(pid) => if @sys.pid_is_alive(pid) { 0 } else { 1 }
    None => 1
  }
}

///|
fn init_should_launch_server_tab(server_alive : Bool) -> Bool {
  !server_alive
}

///|
fn init_server_socket_wait_tries() -> Int {
  // `choir init` is a foreground flow with the user watching the terminal, so
  // keep the pre-TL socket wait to about 20s and warn before launching anyway.
  100
}

///|
fn init_server_socket_wait_budget_seconds(tries : Int) -> Int {
  tries * 200 / 1000
}

///|
fn init_wait_for_server_socket_before_tl(
  listen_uds : String,
  wait_for_socket? : (String, Int) -> Bool = fn(path, tries) {
    @sys.wait_for_socket(path, tries)
  },
  write_stdout? : (String) -> Unit = fn(msg) { @sys.write_stdout(msg) },
) -> Unit {
  let tries = init_server_socket_wait_tries()
  write_stdout("Waiting for server socket...\n")
  if wait_for_socket(listen_uds, tries) {
    write_stdout("Server ready.\n")
  } else {
    write_stdout(
      "Warning: server socket not ready after \{init_server_socket_wait_budget_seconds(tries)}s; launching TL anyway.\n",
    )
  }
}

///|
/// Relative paths and prefixes removed by `choir init --recreate`.
fn init_runtime_cleanup_paths() -> Array[String] {
  [
    ".choir/server.pid", ".choir/server.sock", ".choir/run_id", ".choir/kv/lifecycle--",
    ".choir/kv/children--", ".choir/kv/phase-dev--", ".choir/kv/phase-tl--", ".choir/kv/pending-wave--",
    ".choir/outbox/", ".choir/waves/", ".choir/inline/",
  ]
}

///|
fn init_runtime_cleanup_kv_prefixes() -> Array[String] {
  ["lifecycle--", "children--", "phase-dev--", "phase-tl--", "pending-wave--"]
}

///|
fn init_runtime_cleanup_recursive_dirs() -> Array[String] {
  [".choir/outbox", ".choir/waves", ".choir/inline"]
}

///|
fn init_cleanup_kv_prefixes(prefixes : Array[String]) -> Unit {
  let kv_dir = ".choir/kv"
  for name in @sys.list_dir(kv_dir) {
    let mut should_delete = false
    for prefix in prefixes {
      if name.has_prefix(prefix) {
        should_delete = true
      }
    }
    if should_delete {
      ignore(@sys.delete_file_sync(kv_dir + "/" + name))
    }
  }
}

///|
fn init_reap_orphan_mcp_stdio_bridges(
  list_orphans? : () -> Array[Int] = fn() {
    @sys.list_orphan_choir_mcp_stdio_pids()
  },
  kill_pid? : (Int) -> Unit = fn(pid) { @sys.kill_pid_best_effort(pid) },
) -> Unit {
  let orphans = list_orphans()
  for pid in orphans {
    kill_pid(pid)
  }
  if orphans.length() > 0 {
    @moontrace.info("reaped orphan mcp-stdio bridges", fields=[
      @moontrace.field("count", orphans.length()),
    ])
  }
}

///|
/// Restricted to the literal supervisor tab names choir always creates
/// (Server, TL). Leaf-branch tabs are NOT matched here because any
/// heuristic "has a dot + safe chars" matcher false-positives on common
/// user tabs (v1.0.0, package.json, notes.md, my.feature.branch) and any
/// "-N suffix" matcher also misses real choir tabs whose slugs end in
/// arbitrary text (auto-rescue-pr-400-w2fix). Proper leaf-branch
/// tracking is via a persistent registry — tracked in a follow-up bead.
fn init_is_choir_managed_zellij_tab_name(name : String) -> Bool {
  name == "Server" || name == "TL"
}

///|
async fn init_list_zellij_tabs(session : String) -> Array[String] {
  try {
    let (code, output) = @exec.capture_command_merged(
      @workspace.zellij_query_tab_names_command(session),
    )
    if code == 0 {
      @workspace.zellij_tab_names_in_query_output(output)
    } else {
      []
    }
  } catch {
    _ => []
  }
}

///|
async fn init_close_zellij_tab(session : String, tab : String) -> Unit {
  ignore(
    @exec.run(
      @workspace.local_close_target(@workspace.zellij_tab_target(session, tab)),
    ) catch {
      _ => 0
    },
  )
}

///|
async fn init_reap_stale_zellij_tabs(
  session : String,
  list_tabs? : async (String) -> Array[String] = init_list_zellij_tabs,
  close_tab? : async (String, String) -> Unit = init_close_zellij_tab,
) -> Unit {
  for tab in list_tabs(session) {
    if init_is_choir_managed_zellij_tab_name(tab) {
      close_tab(session, tab)
    }
  }
}

///|
fn init_cleanup_recreate_artifacts(
  reap_orphans? : () -> Unit = fn() { init_reap_orphan_mcp_stdio_bridges() },
  cleanup_runtime? : () -> Unit = fn() {
    @sys.init_cleanup_runtime_artifacts_native()
  },
  cleanup_kv_prefixes? : (Array[String]) -> Unit = fn(prefixes) {
    init_cleanup_kv_prefixes(prefixes)
  },
  rm_rf? : (String) -> Bool = fn(path) { @sys.rm_rf(path) },
) -> Unit {
  reap_orphans()
  cleanup_runtime()
  cleanup_kv_prefixes(init_runtime_cleanup_kv_prefixes())
  for dir in init_runtime_cleanup_recursive_dirs() {
    ignore(rm_rf(dir))
  }
}

///|
/// Markers for purge-only cleanup (mirrors native `choir_init_cleanup_purge_artifacts`).
fn init_purge_cleanup_marker_substrings() -> Array[String] {
  [
    ".choir/worktrees", ".choir/inline", ".choir/outbox", ".choir/waves", ".choir/poller_state.json",
    "lifecycle--", "children--", "phase-dev--", "phase-tl--", "pending-wave--",
  ]
}

///|
test "init session lifecycle commands use zellij" {
  let list_cmd = @workspace.zellij_list_sessions_command()
  assert_eq(list_cmd.program, "env")
  @debug.assert_eq(list_cmd.args, ["NO_COLOR=1", "zellij", "list-sessions"])

  let tab_q = @workspace.zellij_query_tab_names_command("choir")
  assert_eq(tab_q.program, "env")
  @debug.assert_eq(tab_q.args, [
    "NO_COLOR=1", "zellij", "--session", "choir", "action", "query-tab-names",
  ])

  let kill = init_kill_session_command("choir")
  @debug.assert_eq(kill.args, ["delete-session", "--force", "choir"])
}

///|
test "cleanup paths separate runtime restart from purge" {
  let rt = init_runtime_cleanup_paths()
  assert_true(rt.length() >= 11)
  for p in rt {
    assert_false(p.contains("worktrees"))
    assert_false(p.contains("poller"))
  }
  assert_true(rt.contains(".choir/kv/lifecycle--"))
  assert_true(rt.contains(".choir/kv/children--"))
  assert_true(rt.contains(".choir/kv/phase-dev--"))
  assert_true(rt.contains(".choir/kv/phase-tl--"))
  assert_true(rt.contains(".choir/kv/pending-wave--"))
  assert_true(rt.contains(".choir/outbox/"))
  assert_true(rt.contains(".choir/waves/"))
  assert_true(rt.contains(".choir/inline/"))
  let purge = init_purge_cleanup_marker_substrings()
  assert_true(purge.length() >= 4)
  let mut has_wt = false
  let mut has_poller = false
  for m in purge {
    if m == ".choir/worktrees" {
      has_wt = true
    }
    if m == ".choir/poller_state.json" {
      has_poller = true
    }
  }
  assert_true(has_wt)
  assert_true(has_poller)
}

///|
test "init_configure_git_hooks_path_when_githooks_present" {
  let project_dir = "/tmp/project-hooks-present"
  let cmd = init_compute_git_hooks_path_setup(
    project_dir,
    file_exists=fn(path) { path == project_dir + "/.githooks/pre-commit" },
    git_config_get=fn(_) { "" },
  )
  match cmd {
    Some(cmd) => {
      assert_eq(cmd.program, "git")
      @debug.assert_eq(cmd.args, [
        "config", "--local", "core.hooksPath", ".githooks",
      ])
      @debug.assert_eq(cmd.workdir, Some(project_dir))
    }
    None => assert_true(false)
  }

  let absent = init_compute_git_hooks_path_setup(
    project_dir,
    file_exists=fn(_path) { false },
    git_config_get=fn(_) { "" },
  )
  @debug.assert_eq(absent, None)
}

///|
test "init_skip_hooks_path_when_already_set" {
  let project_dir = "/tmp/project-hooks-present"
  @debug.assert_eq(
    init_compute_git_hooks_path_setup(
      project_dir,
      file_exists=fn(path) { path == project_dir + "/.githooks/pre-commit" },
      git_config_get=fn(_) { ".githooks\n" },
    ),
    None,
  )
}

///|
test "init server cleanup commands separate runtime restart from purge" {
  @debug.assert_eq(init_parse_server_pid_line("123"), Some(123))
  @debug.assert_eq(init_parse_server_pid_line(" 42 \n"), Some(42))
  @debug.assert_eq(init_parse_server_pid_line(""), None)
  @debug.assert_eq(init_parse_server_pid_line("12a"), None)
  assert_true(@sys.pid_is_alive(@sys.get_pid()))
  assert_true(init_should_launch_server_tab(false))
  assert_false(init_should_launch_server_tab(true))
  let rt = init_runtime_cleanup_paths()
  assert_true(rt.length() >= 11)
  for p in rt {
    assert_false(p.contains("worktrees"))
    assert_false(p.contains("poller"))
  }
  let purge = init_purge_cleanup_marker_substrings()
  let mut has_inline = false
  for m in purge {
    if m == ".choir/inline" {
      has_inline = true
    }
  }
  assert_true(has_inline)
}

///|
test "init orphan mcp-stdio reaper kills listed pids and cleanup invokes once" {
  let killed : Array[Int] = []
  init_reap_orphan_mcp_stdio_bridges(list_orphans=fn() { [301, 302, 303] }, kill_pid=fn(
    pid,
  ) {
    killed.push(pid)
  })
  @debug.assert_eq(killed, [301, 302, 303])

  let events : Array[String] = []
  init_cleanup_recreate_artifacts(
    reap_orphans=fn() { events.push("reap") },
    cleanup_runtime=fn() { events.push("runtime") },
    cleanup_kv_prefixes=fn(prefixes) {
      events.push("kv:" + prefixes.length().to_string())
    },
    rm_rf=fn(path) {
      events.push("rm:" + path)
      true
    },
  )
  let mut reap_count = 0
  for event in events {
    if event == "reap" {
      reap_count = reap_count + 1
    }
  }
  assert_eq(reap_count, 1)
  assert_true(events.contains("runtime"))
  assert_true(events.any(fn(event) { event.has_prefix("kv:") }))
  assert_true(events.contains("rm:.choir/outbox"))
  assert_true(events.contains("rm:.choir/waves"))
  assert_true(events.contains("rm:.choir/inline"))
}

///|
async test "init reaps stale choir Server/TL tabs and leaves everything else alone" {
  let closed : Array[String] = []
  let listed : Array[String] = []
  init_reap_stale_zellij_tabs(
    "choir",
    list_tabs=async fn(session) {
      @async.sleep(0)
      listed.push(session)
      // Mix of (a) literal choir tabs that must be reaped, (b) common user
      // tab names that the previous heuristic matcher false-positived on
      // (v1.0.0, package.json, my.feature.branch, README.md, notes.md),
      // and (c) leaf-branch slugs which are explicitly NOT reaped under
      // the literal-only matcher pending the registry-based follow-up.
      [
        "Server", "TL", "v1.0.0", "package.json", "my.feature.branch", "README.md",
        "notes.md", "feature-x.leaf-0", "auto-rescue-pr-400-w2fix", "unrelated-user-tab",
      ]
    },
    close_tab=async fn(session, tab) {
      @async.sleep(0)
      closed.push(session + ":" + tab)
    },
  )
  @debug.assert_eq(listed, ["choir"])
  @debug.assert_eq(closed, ["choir:Server", "choir:TL"])
}

///|
test "init choir zellij tab matcher only matches literal Server and TL" {
  assert_true(init_is_choir_managed_zellij_tab_name("Server"))
  assert_true(init_is_choir_managed_zellij_tab_name("TL"))
  // Common user tab names that the prior dotted-slug heuristic accepted —
  // all must be rejected to prevent close-tab from firing against them.
  assert_false(init_is_choir_managed_zellij_tab_name("v1.0.0"))
  assert_false(init_is_choir_managed_zellij_tab_name("package.json"))
  assert_false(init_is_choir_managed_zellij_tab_name("my.feature.branch"))
  assert_false(init_is_choir_managed_zellij_tab_name("README.md"))
  assert_false(init_is_choir_managed_zellij_tab_name("notes.md"))
  // Leaf-branch slug shapes — explicitly NOT closed under the literal-only
  // matcher; tracked via persistent registry in a follow-up bead.
  assert_false(init_is_choir_managed_zellij_tab_name("feature-x.leaf-0"))
  assert_false(
    init_is_choir_managed_zellij_tab_name("auto-rescue-pr-400-w2fix"),
  )
  assert_false(init_is_choir_managed_zellij_tab_name("unrelated-user-tab"))
}

///|
test "init waits for server socket before TL launch" {
  let events : Array[String] = []
  events.push("server-tab")
  init_wait_for_server_socket_before_tl(
    ".choir/server.sock",
    wait_for_socket=fn(path, tries) {
      events.push("wait:" + path + ":" + tries.to_string())
      true
    },
    write_stdout=fn(_) {  },
  )
  events.push("tl-tab")
  @debug.assert_eq(events, [
    "server-tab", "wait:.choir/server.sock:100", "tl-tab",
  ])
}

///|
test "init_wait_timeout_warns_and_proceeds" {
  let events : Array[String] = []
  let output : Array[String] = []
  events.push("server-tab")
  init_wait_for_server_socket_before_tl(
    ".choir/server.sock",
    wait_for_socket=fn(path, tries) {
      events.push("wait:" + path + ":" + tries.to_string())
      false
    },
    write_stdout=fn(msg) { output.push(msg) },
  )
  events.push("tl-tab")
  @debug.assert_eq(events, [
    "server-tab", "wait:.choir/server.sock:100", "tl-tab",
  ])
  @debug.assert_eq(output, [
    "Waiting for server socket...\n", "Warning: server socket not ready after 20s; launching TL anyway.\n",
  ])
}

///|
fn init_default_terminal_session(project_dir : String) -> String {
  let mut end = project_dir.length()
  while end > 1 && project_dir[end - 1] == '/' {
    end = end - 1
  }
  let trimmed = project_dir[:end].to_owned()
  let base = if trimmed == "" {
    "project"
  } else {
    let mut last_slash = -1
    for i = 0; i < trimmed.length(); i = i + 1 {
      if trimmed[i] == '/' {
        last_slash = i
      }
    }
    if last_slash < 0 || last_slash + 1 >= trimmed.length() {
      trimmed
    } else {
      trimmed[last_slash + 1:].to_owned()
    }
  }
  let buf = StringBuilder::new()
  for c in base {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' {
      buf.write_char(c)
    } else {
      buf.write_char('-')
    }
  }
  let normalized_raw = buf.to_string()
  let mut start = 0
  let mut finish = normalized_raw.length()
  while start < finish && normalized_raw[start] == '-' {
    start = start + 1
  }
  while finish > start && normalized_raw[finish - 1] == '-' {
    finish = finish - 1
  }
  let suffix = normalized_raw[start:finish].to_owned()
  let normalized = if suffix == "" { "project" } else { suffix }
  "choir-" + normalized
}

///|
fn init_config_toml_content(default_session : String) -> String {
  "default_role = \"tl\"\n" +
  "project_dir = \".\"\n" +
  "listen_uds = \".choir/server.sock\"\n" +
  "terminal_session = \"" +
  default_session +
  "\"\n" +
  "worker_no_handoff_prod_sec = 120\n" +
  "worker_no_handoff_escalate_sec = 120\n" +
  "auto_pull_after_integration = true\n" +
  "auto_rebuild_after_pull = false\n" +
  "auto_reload_after_rebuild = false\n" +
  "\n" +
  "[pr_policy]\n" +
  "require_integration_audit = true\n" +
  "\n" +
  "# [pricing.codex]\n" +
  "# rate_in = 0.0\n" +
  "# rate_out = 0.0\n"
}

///|
fn init_config_has_terminal_session(content : String) -> Bool {
  content.contains("terminal_session")
}

///|
/// `--lean` on `choir init` makes the TL's own Claude session skip Claude
/// Code's default system prompt (via `--system-prompt .`). Only affects
/// the Claude TL; Gemini/Codex/Cursor ignore it. One-shot per init
/// invocation — re-run `choir init --recreate --lean` to change the TL's
/// mode.
fn init_parse_lean_flag(args : Array[String]) -> Bool {
  args.contains("--lean")
}

///|
fn init_parse_tl_type(args : Array[String]) -> String {
  for i = 0; i < args.length() - 1; i = i + 1 {
    if args[i] == "--tl" {
      return @workspace.normalize_tl_type(args[i + 1])
    }
  }
  "claude"
}

///|
test "init TL launch command defaults to claude" {
  let cmd = @workspace.init_tl_agent_command("claude", ".")
  let s = cmd.to_string()
  assert_true(s.contains("claude"))
  assert_true(s.contains("--dangerously-skip-permissions"))
  assert_true(s.contains("--mcp-config"))
  assert_true(s.contains("mcp-stdio"))
  assert_true(s.contains("--name"))
  assert_true(s.contains("root"))
  assert_true(s.contains("--stderr-append-log"))
  assert_true(s.contains(".choir/mcp-stdio.stderr.log"))
}

///|
test "init TL launch command supports codex" {
  let cmd = @workspace.init_tl_agent_command("codex", "/tmp/choir repo")
  let s = cmd.to_string()
  assert_true(s.contains("codex"))
  assert_true(s.contains("--dangerously-bypass-approvals-and-sandbox"))
  assert_true(s.contains("--no-alt-screen"))
  assert_true(s.contains("mcp_servers.choir.command=\"choir\""))
  assert_true(s.contains("mcp-stdio"))
  assert_true(s.contains("--raw-stdio"))
  assert_true(s.contains("--name"))
  assert_true(s.contains("mcp_servers.choir.cwd=\"/tmp/choir repo\""))
  assert_true(s.contains("-C"))
  assert_true(s.contains("/tmp/choir repo"))
  assert_false(s.contains("--mcp-config"))
}

///|
test "init TL launch command supports cursor_agent" {
  let cmd = @workspace.init_tl_agent_command("cursor_agent", "/tmp/choir repo")
  let s = cmd.to_string()
  assert_true(s.contains("agent"))
  assert_true(s.contains("--yolo"))
  assert_true(s.contains("--approve-mcps"))
  assert_true(s.contains("--workspace"))
  assert_true(s.contains("/tmp/choir repo"))
  assert_false(s.contains("--mcp-config"))
}

///|
test "init TL launch command supports agent alias" {
  let cmd = @workspace.init_tl_agent_command("agent", "/tmp/choir repo")
  let s = cmd.to_string()
  assert_true(s.contains("agent"))
  assert_true(s.contains("--yolo"))
  assert_true(s.contains("--approve-mcps"))
  assert_true(s.contains("--workspace"))
  assert_true(s.contains("/tmp/choir repo"))
  assert_false(s.contains("--mcp-config"))
}

///|
test "init parse_lean_flag detects --lean" {
  assert_true(init_parse_lean_flag(["choir", "init", "--lean"]))
  assert_true(init_parse_lean_flag(["choir", "init", "--recreate", "--lean"]))
  assert_false(init_parse_lean_flag(["choir", "init"]))
  assert_false(init_parse_lean_flag(["choir", "init", "--recreate"]))
}

///|
test "init TL launch command adds --system-prompt . when lean" {
  let cmd = @workspace.init_tl_agent_command("claude", ".", lean=true)
  let s = cmd.to_string()
  assert_true(s.contains("--system-prompt"))
  assert_true(s.contains("claude"))
  assert_true(s.contains("--dangerously-skip-permissions"))
}

///|
test "init TL launch command omits --system-prompt by default" {
  let cmd = @workspace.init_tl_agent_command("claude", ".")
  let s = cmd.to_string()
  assert_false(s.contains("--system-prompt"))
}

///|
test "init TL launch command ignores lean for non-claude agents" {
  let cmd_codex = @workspace.init_tl_agent_command("codex", ".", lean=true)
  assert_false(cmd_codex.to_string().contains("--system-prompt"))
  let cmd_gemini = @workspace.init_tl_agent_command("gemini", ".", lean=true)
  assert_false(cmd_gemini.to_string().contains("--system-prompt"))
}

///|
test "init parse_tl_type extracts --tl flag" {
  assert_eq(init_parse_tl_type(["choir", "init", "--tl", "codex"]), "codex")
  assert_eq(init_parse_tl_type(["choir", "init"]), "claude")
  assert_eq(
    init_parse_tl_type(["choir", "init", "--recreate", "--tl", "gemini"]),
    "gemini",
  )
  assert_eq(init_parse_tl_type(["choir", "init", "--tl", "codex"]), "codex")
  assert_eq(
    init_parse_tl_type(["choir", "init", "--tl", "agent"]),
    "cursor_agent",
  )
}

///|
fn init_split_words(s : String) -> Array[String] {
  let parts : Array[String] = []
  let trimmed = s.trim().to_owned()
  let mut start = 0
  for i = 0; i <= trimmed.length(); i = i + 1 {
    if i == trimmed.length() || trimmed[i] == ' ' {
      if i > start {
        parts.push(trimmed[start:i].to_owned())
      }
      start = i + 1
    }
  }
  parts
}

///|
fn init_companion_role(role : String) -> @types.Role {
  match @config.parse_role(role) {
    Ok(parsed) => parsed
    Err(_) => @types.Role::Worker
  }
}

///|
fn init_companion_branch(parent_branch : String, name : String) -> String {
  parent_branch + ".companion." + name
}

///|
fn init_companion_agent_type(command : String) -> @types.AgentType? {
  let parts = init_split_words(command)
  if parts.is_empty() {
    return None
  }
  let first = parts[0]
  if first == "claude" || first.has_suffix("/claude") {
    return Some(@types.AgentType::Claude)
  }
  if first == "gemini" || first.has_suffix("/gemini") {
    return Some(@types.AgentType::Gemini)
  }
  if (first == "moon" || first.has_suffix("/moon")) &&
    parts.length() > 1 &&
    parts[1] == "pilot" {
    return Some(@types.AgentType::MoonPilot)
  }
  if first == "codex" || first.has_suffix("/codex") {
    return Some(@types.AgentType::Codex)
  }
  if first == "agent" || first.has_suffix("/agent") {
    return Some(@types.AgentType::CursorAgent)
  }
  None
}

///|
fn init_companion_commands(
  project_dir : String,
  session : String,
  config : @types.Config,
  current_branch : String,
  companion : @config.CompanionDef,
) -> Array[@workspace.Command] {
  let role = init_companion_role(companion.role)
  let branch = init_companion_branch(current_branch, companion.name)
  let workspace = project_dir + "/.choir/agents/" + companion.name
  let terminal_target = @workspace.local_target_for(
    session,
    companion.name,
    @types.IsolationMode::Worktree,
  )
  let agent_type_opt = init_companion_agent_type(companion.command)
  let agent_type = agent_type_opt.unwrap_or(@types.AgentType::Gemini)
  let spec : @types.SpawnSpec = {
    slug: "companion." + companion.name,
    role,
    agent_type,
    task: companion.task,
    task_contract: None,
    isolation: @types.IsolationMode::Standalone,
    parent_id: "root",
    parent_branch: current_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: Some(branch),
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    wave_id: None,
  }
  let env_z = @workspace.launch_env_assignments(
    spec, session, workspace, terminal_target,
  )
  let inner = {
    let c = @workspace.agent_launch_command(
      spec,
      workspace,
      command_override=Some(companion.command),
      extra_mcp_servers_json=config.extra_mcp_servers_json,
      // Route codex stderr to <project>/.choir/codex-<agent>.stderr.log so
      // the disconnect-warning tail reader (which uses project_dir) sees it.
      // Default would be workspace_path which puts it under
      // <project>/.choir/agents/<name>/.choir/codex-... — captured but
      // never read.
      project_dir~,
    )
    { ..c, workdir: None }
  }
  let cmds : Array[@workspace.Command] = [
    @workspace.git_worktree_bootstrap_cleanup_best_effort(
      project_dir, workspace, branch,
    ),
    @workspace.git_worktree_add(workspace, branch, current_branch),
    @workspace.command_seed_worktree_agent_runtime_gitexclude(workspace),
    @workspace.write_spawn_config(
      workspace,
      @workspace.child_config_content(
        role,
        session,
        project_dir,
        config.listen_uds,
        listen_tcp=config.listen_tcp,
        tcp_auth_token=config.tcp_auth_token,
      ),
    ),
    @workspace.write_local_config(
      workspace,
      @workspace.config_local_content(spec, workspace, terminal_target),
    ),
    @workspace.write_leaf_helper_scripts(workspace),
    @workspace.workspace_relative_file_command(
      workspace, ".birth_branch", branch,
    ),
  ]
  if agent_type == @types.AgentType::Gemini {
    cmds.push(@workspace.trust_gemini_folder(workspace))
  }
  if agent_type == @types.AgentType::CursorAgent {
    cmds.push(
      @workspace.write_cursor_mcp_json(
        workspace,
        branch,
        @config.role_to_string(role),
      ),
    )
  }
  cmds.push(
    @workspace.zellij_new_tab(session, companion.name, workspace, env_z, inner),
  )
  cmds
}

///|
fn init_is_choir_source_files(
  moon_mod_content : String,
  main_mbt_content : String,
) -> Bool {
  main_mbt_content != "" &&
  (
    moon_mod_content.contains("\"name\": \"choir\"") ||
    moon_mod_content.contains("\"name\":\"choir\"")
  )
}

///|
fn init_is_choir_source_tree(project_dir : String) -> Bool {
  init_is_choir_source_files(
    @sys.read_file(project_dir + "/moon.mod.json"),
    @sys.read_file(project_dir + "/src/bin/choir/main.mbt"),
  )
}

///|
fn init_compute_git_hooks_path_setup(
  project_dir : String,
  file_exists? : (String) -> Bool = fn(path) { @sys.path_exists(path) },
  git_config_get? : (String) -> String = fn(_project_dir) { "" },
) -> @workspace.Command? {
  if !file_exists(project_dir + "/.githooks/pre-commit") {
    return None
  }
  if git_config_get(project_dir).trim().to_owned() == ".githooks" {
    return None
  }
  Some({
    program: "git",
    args: ["config", "--local", "core.hooksPath", ".githooks"],
    workdir: Some(project_dir),
  })
}

///|
async fn init_run_or_exit(cmd : @workspace.Command) -> Unit {
  let exit_code = @exec.run(cmd) catch { _ => 1 }
  if exit_code != 0 {
    @sys.exit(exit_code)
  }
}

///|
async fn init_run_or_warn(cmd : @workspace.Command) -> Unit {
  let exit_code = @exec.run(cmd) catch { _ => 1 }
  if exit_code != 0 {
    @sys.write_stderr(
      "warning: failed to configure git core.hooksPath; using default hooks path\n",
    )
  } else {
    @sys.write_stdout("→ configured git core.hooksPath = .githooks\n")
  }
}

///|
fn init_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let args = @env.args()
      let recreate = args.contains("--recreate")
      let purge = args.contains("--purge")
      let no_attach = init_no_attach(args)
      let tl_type = init_parse_tl_type(args)
      let lean = init_parse_lean_flag(args)
      let project_dir = @env.current_dir().unwrap_or(".")
      let default_session = init_default_terminal_session(project_dir)
      let use_dev = init_is_choir_source_tree(project_dir)

      if use_dev {
        // Rebuild binary before doing anything else so the new server uses fresh code
        init_run_or_exit({
          program: "moon",
          args: ["build", "--target", "native", "--release"],
          workdir: None,
        })
      }

      init_bootstrap_ensure_choir_dir_and_config_if_absent(
        init_config_toml_content(default_session),
      )
      let current_hooks_path = @exec.capture_stdout("git", [
          "config", "--local", "--get", "core.hooksPath",
        ])
        .trim()
        .to_owned()
      ignore(
        match
          init_compute_git_hooks_path_setup(
            project_dir,
            file_exists=fn(path) { @sys.path_exists(path) },
            git_config_get=fn(_) { current_hooks_path },
          ) {
          Some(cmd) => ignore(init_run_or_warn(cmd))
          None => ()
        },
      )
      let home = match @sys.getenv("HOME") {
        Some(h) => if h == "" { "" } else { h }
        None => ""
      }
      match @prompts.materialize_default_prompts(project_dir) {
        Ok(_) => ()
        Err(e) =>
          @sys.write_stderr(
            "warning: failed to materialize .choir/prompts: " +
            e.message() +
            "\n",
          )
      }
      match synthesize_plugin_dir(project_dir, home) {
        Ok(_) => ()
        Err(e) =>
          @sys.write_stderr(
            "warning: failed to synthesize .choir/plugin: " + e.message() + "\n",
          )
      }
      ignore(
        @sys.write_file_sync(
          ".choir/claude-settings.json",
          @workspace.init_tl_claude_settings_json(),
        ),
      )
      let maybe_patch_config = @sys.read_file(".choir/config.toml")
      if maybe_patch_config != "" &&
        !init_config_has_terminal_session(maybe_patch_config) {
        let separator = if maybe_patch_config.has_suffix("\n") {
          ""
        } else {
          "\n"
        }
        let patched = maybe_patch_config +
          separator +
          "terminal_session = \"" +
          default_session +
          "\"\n"
        ignore(@sys.write_file_sync(".choir/config.toml", patched))
      }
      let config_content = @sys.read_file(".choir/config.toml")
      let local_content = @sys.read_file(".choir/config.local.toml")
      let config = match
        @config.parse_config(config_content, local_content=Some(local_content)) {
        Ok(cfg) => cfg
        Err(_) => @types.Config::default()
      }
      let current_branch_raw = @exec.capture_stdout("git", [
        "branch", "--show-current",
      ])
      let current_branch_trimmed = current_branch_raw.trim().to_owned()
      let current_branch = if current_branch_trimmed == "" ||
        current_branch_trimmed == "HEAD" {
        "main"
      } else {
        current_branch_trimmed
      }
      let session = config.terminal_session

      if !recreate {
        init_reap_orphan_mcp_stdio_bridges()
      }

      if recreate {
        let pid_str = @sys.read_file(".choir/server.pid")
        if pid_str != "" {
          @sys.write_stdout("Stopping server (PID \{pid_str})...\n")
          init_kill_server_pid_string(pid_str)
        }
        if purge {
          init_reap_orphan_mcp_stdio_bridges()
          @sys.init_cleanup_purge_artifacts_native()
        } else {
          init_cleanup_recreate_artifacts()
        }
        @sys.write_stdout("Killing session \{session}...\n")
        ignore(@exec.run(init_kill_session_command(session)) catch { _ => 0 })
      }

      let session_alive = try {
        let (code, output) = @exec.capture_command_merged(
          @workspace.zellij_list_sessions_command(),
        )
        if code != 0 {
          1
        } else if @workspace.zellij_session_exists_in_list_output(
            output, session,
          ) {
          0
        } else {
          1
        }
      } catch {
        _ => 1
      }
      let server_alive = init_server_running_exit_code()
      if session_alive == 0 {
        if no_attach {
          @sys.write_stdout("Session \{session} already exists.\n")
        } else {
          @sys.write_stdout("Attaching to existing session \{session}...\n")
          ignore(
            @exec.run(@workspace.zellij_attach_session(session)) catch {
              _ => 0
            },
          )
        }
        return
      }

      let birth_branch_stdout = @exec.capture_stdout("git", [
        "branch", "--show-current",
      ])
      init_bootstrap_write_root_birth_branch_best_effort(
        project_dir, birth_branch_stdout,
      )

      @sys.write_stdout("Creating session \{session}...\n")
      init_run_or_exit(@workspace.zellij_create_background_session(session))
      if !recreate {
        // AUDIT: control reaches here only when the session was ABSENT
        // from `zellij list-sessions` (the `session_alive != 0` branch
        // above; the `session_alive == 0` branch above ends with
        // `return` after `zellij_attach_session` and never runs this
        // reap). The just-issued
        // `zellij_create_background_session` either creates a fresh
        // empty session or — when zellij's resurrection cache still
        // holds a stored session of this name — resurrects it with its
        // old Server/TL tabs. The reap catches that second case. With
        // resurrection disabled (or no cached session of this name) the
        // tab list comes back empty and the reap is a defensive no-op.
        // Cheap to run unconditionally. End-to-end "resurrection + reap"
        // verification is operator-driven: after `choir init`,
        // `zellij --session <session> action query-tab-names` should NOT
        // list `Server` or `TL` from the prior boot (a fresh init creates
        // them as new tabs, which is expected). The reap runs inside
        // `choir init`, not `choir serve`, so `.choir/serve.log` is not
        // the right observable for this leaf.
        init_reap_stale_zellij_tabs(session)
      }
      let server_tab_exists = init_tab_exists(session, "Server") catch {
        _ => false
      }
      if !server_tab_exists {
        if init_should_launch_server_tab(server_alive == 0) {
          init_run_or_exit(
            @workspace.zellij_new_tab(session, "Server", project_dir, [], {
              program: "choir",
              args: ["serve"],
              workdir: None,
            }),
          )
        } else {
          @sys.write_stdout("Reusing existing server process.\n")
        }
      } else {
        @sys.write_stdout("Reusing existing Server tab.\n")
      }
      init_wait_for_server_socket_before_tl(config.listen_uds)
      let tl_tab_exists = init_tab_exists(session, "TL") catch { _ => false }
      if !tl_tab_exists {
        let tl_agent_type = @workspace.tl_type_agent_type(tl_type)
        let tl_materialization = @workspace.provider_materialization_commands(
          tl_agent_type,
          project_dir,
          project_dir,
          "root",
          @types.Role::TL,
        )
        for cmd in tl_materialization {
          ignore(@exec.run(cmd) catch { _ => 0 })
        }
        init_run_or_exit(
          @workspace.init_tl_zellij_tab_command(
            session,
            project_dir,
            tl_type,
            current_branch,
            lean~,
          ),
        )
      } else {
        @sys.write_stdout("Reusing existing TL tab.\n")
      }
      // Drop the empty default tab (id 0) that `zellij_create_background_session`
      // creates before we add the named "Server"/"TL" tabs. This is reached only
      // after a *fresh* session creation — the `session_alive == 0` branch above
      // returns early — so tab 0 is always that empty default here, never a live
      // TL/Server tab. (Do not remove again under a "don't close TL tab" guard:
      // see choir-eek — that guard applies to teardown paths, not this one.)
      ignore(
        @exec.run({
          program: "zellij",
          args: ["--session", session, "action", "close-tab-by-id", "0"],
          workdir: None,
        }) catch {
          _ => 0
        },
      )
      ignore(
        @exec.run({
          program: "zellij",
          args: ["--session", session, "action", "go-to-tab-name", "TL"],
          workdir: None,
        }) catch {
          _ => 0
        },
      )

      match config.companions_json {
        Some(json) => {
          let companions = @config.parse_companions_json(json)
          for c in companions {
            for
              cmd in init_companion_commands(
                project_dir, session, config, current_branch, c,
              ) {
              ignore(@exec.run(cmd) catch { _ => 0 })
            }
            @sys.write_stdout("Spawned companion: \{c.name}\n")
          }
        }
        None => ()
      }

      if no_attach {
        @sys.write_stdout("Session \{session} ready.\n")
      } else {
        @sys.write_stdout("Attaching to session \{session}...\n")
        ignore(
          @exec.run(@workspace.zellij_attach_session(session)) catch {
            _ => 0
          },
        )
      }
    })
  })
}
