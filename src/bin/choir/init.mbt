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
fn init_server_tab_command(
  session : String,
  project_dir : String,
  server_env_assignment : String,
) -> @workspace.Command {
  @workspace.zellij_new_tab(
    session,
    "Server",
    project_dir,
    [server_env_assignment],
    { program: "choir", args: ["serve"], workdir: None },
  )
}

///|
fn init_server_tab_launch_plan(
  session : String,
  project_dir : String,
  recreate : Bool,
  server_tab_exists : Bool,
  server_alive : Bool,
  server_env_assignment : String,
) -> Array[@workspace.Command] {
  let cmds : Array[@workspace.Command] = []
  if recreate {
    if server_tab_exists {
      cmds.push(
        @workspace.local_close_target(
          @workspace.zellij_tab_target(session, "Server"),
        ),
      )
    }
    cmds.push(
      init_server_tab_command(session, project_dir, server_env_assignment),
    )
    return cmds
  }
  if !server_tab_exists && init_should_launch_server_tab(server_alive) {
    cmds.push(
      init_server_tab_command(session, project_dir, server_env_assignment),
    )
  }
  cmds
}

///|
priv enum InitRootLaunchGuard {
  Proceed
  Abort(String)
} derive(Debug, Eq)

///|
fn init_stale_server_without_tab_message() -> String {
  "choir init: a server process is running without a managed Server tab; run `choir init --recreate` to restart the server and TL with a matching root credential."
}

///|
fn init_root_launch_guard(
  recreate : Bool,
  server_tab_exists : Bool,
  server_alive : Bool,
  tl_tab_exists : Bool,
) -> InitRootLaunchGuard {
  if !recreate && !server_tab_exists && server_alive && !tl_tab_exists {
    InitRootLaunchGuard::Abort(init_stale_server_without_tab_message())
  } else {
    InitRootLaunchGuard::Proceed
  }
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
  [".choir/server.pid", ".choir/server.sock", ".choir/run_id"]
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
  cleanup_runtime? : () -> Unit = fn() {
    @sys.init_cleanup_runtime_artifacts_native()
  },
  cleanup_kv_prefixes? : (Array[String]) -> Unit = fn(_prefixes) { () },
  rm_rf? : (String) -> Bool = fn(_path) { true },
) -> Unit {
  ignore(cleanup_kv_prefixes)
  ignore(rm_rf)
  cleanup_runtime()
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
  @debug.assert_eq(rt, [
    ".choir/server.pid", ".choir/server.sock", ".choir/run_id",
  ])
  for p in rt {
    assert_false(p.contains("worktrees"))
    assert_false(p.contains("poller"))
    assert_false(p.contains("lifecycle--"))
    assert_false(p.contains("children--"))
    assert_false(p.contains("phase-dev--"))
    assert_false(p.contains("phase-tl--"))
    assert_false(p.contains("pending-wave--"))
    assert_false(p.contains("outbox"))
    assert_false(p.contains("waves"))
    assert_false(p.contains("inline"))
  }
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
test "recreate cleanup preserves recovery state while purge markers remain destructive" {
  let rt = init_runtime_cleanup_paths()
  assert_true(rt.contains(".choir/server.pid"))
  assert_true(rt.contains(".choir/server.sock"))
  assert_true(rt.contains(".choir/run_id"))
  assert_false(rt.contains(".choir/kv/lifecycle--"))
  assert_false(rt.contains(".choir/kv/children--"))
  assert_false(rt.contains(".choir/kv/phase-dev--"))
  assert_false(rt.contains(".choir/kv/phase-tl--"))
  assert_false(rt.contains(".choir/kv/pending-wave--"))
  assert_false(rt.contains(".choir/outbox/"))
  assert_false(rt.contains(".choir/waves/"))
  assert_false(rt.contains(".choir/inline/"))

  let purge = init_purge_cleanup_marker_substrings()
  assert_true(purge.contains(".choir/inline"))
  assert_true(purge.contains(".choir/outbox"))
  assert_true(purge.contains(".choir/waves"))
  assert_true(purge.contains("lifecycle--"))
  assert_true(purge.contains("children--"))
  assert_true(purge.contains("phase-dev--"))
  assert_true(purge.contains("phase-tl--"))
  assert_true(purge.contains("pending-wave--"))
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
  @debug.assert_eq(rt, [
    ".choir/server.pid", ".choir/server.sock", ".choir/run_id",
  ])
  for p in rt {
    assert_false(p.contains("worktrees"))
    assert_false(p.contains("poller"))
    assert_false(p.contains("lifecycle--"))
    assert_false(p.contains("pending-wave--"))
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
test "init recreate cleanup covers only runtime markers" {
  let events : Array[String] = []
  init_cleanup_recreate_artifacts(
    cleanup_runtime=fn() { events.push("runtime") },
    cleanup_kv_prefixes=fn(prefixes) {
      events.push("kv:" + prefixes.length().to_string())
    },
    rm_rf=fn(path) {
      events.push("rm:" + path)
      true
    },
  )
  @debug.assert_eq(events, ["runtime"])
}

///|
test "init stale server process without Server tab aborts before fresh TL launch" {
  let decision = init_root_launch_guard(false, false, true, false)
  match decision {
    InitRootLaunchGuard::Abort(message) => {
      assert_true(message.contains("server process is running"))
      assert_true(message.contains("managed Server tab"))
      assert_true(message.contains("choir init --recreate"))
      assert_false(message.contains("CHOIR_AGENT_TOKEN"))
      assert_false(message.contains("CHOIR_ROOT_AGENT_TOKEN"))
    }
    InitRootLaunchGuard::Proceed =>
      fail("expected stale server process to abort before TL launch")
  }
  @debug.assert_eq(
    init_root_launch_guard(false, false, false, false),
    InitRootLaunchGuard::Proceed,
  )
  @debug.assert_eq(
    init_root_launch_guard(true, false, true, false),
    InitRootLaunchGuard::Proceed,
  )
  @debug.assert_eq(
    init_root_launch_guard(false, false, true, true),
    InitRootLaunchGuard::Proceed,
  )
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
fn init_config_toml_content() -> String {
  "worker_no_handoff_idle_sec = 120\n" +
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
test "init config.toml scaffold omits machine local fields" {
  let content = init_config_toml_content()
  assert_false(content.contains("default_role"))
  assert_false(content.contains("project_dir"))
  assert_false(content.contains("listen_uds"))
  assert_false(content.contains("terminal_session"))
  assert_true(content.contains("worker_no_handoff_idle_sec = 120"))
  assert_true(content.contains("[pr_policy]"))
}

///|
fn init_toml_escape_string(s : String) -> String {
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
fn init_local_config_has_terminal_session(content : String) -> Bool {
  match @config.parse_local_config(content) {
    Ok(local_cfg) =>
      match local_cfg.terminal_session {
        Some(_) => true
        None => false
      }
    Err(_) => content.contains("terminal_session")
  }
}

///|
fn init_local_config_with_terminal_session(
  content : String,
  default_session : String,
) -> String {
  if init_local_config_has_terminal_session(content) {
    content
  } else {
    let separator = if content == "" || content.has_suffix("\n") {
      ""
    } else {
      "\n"
    }
    content +
    separator +
    "terminal_session = \"" +
    init_toml_escape_string(default_session) +
    "\"\n"
  }
}

///|
fn init_ensure_local_terminal_session(
  default_session : String,
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
  write_file? : (String, String) -> Bool = fn(path, content) {
    @sys.write_file_sync(path, content)
  },
) -> Unit {
  let local_content = read_file(".choir/config.local.toml")
  if !init_local_config_has_terminal_session(local_content) {
    ignore(
      write_file(
        ".choir/config.local.toml",
        init_local_config_with_terminal_session(local_content, default_session),
      ),
    )
  }
}

///|
test "init persists terminal_session in local config without touching portable config" {
  let portable_config = "[project]\nverify_cmd = \"moon check --target native && moon test --target native\"\n"
  let local_config = "default_role = \"dev\"\nproject_dir = \"/repo\"\nlisten_uds = \"/repo/.choir/server.sock\""
  let reads : Array[String] = []
  let write_paths : Array[String] = []
  let write_bodies : Array[String] = []
  init_ensure_local_terminal_session(
    "choir-repo",
    read_file=fn(path) {
      reads.push(path)
      if path == ".choir/config.toml" {
        portable_config
      } else if path == ".choir/config.local.toml" {
        local_config
      } else {
        ""
      }
    },
    write_file=fn(path, body) {
      write_paths.push(path)
      write_bodies.push(body)
      true
    },
  )
  @debug.assert_eq(reads, [".choir/config.local.toml"])
  @debug.assert_eq(write_paths, [".choir/config.local.toml"])
  assert_false(write_paths.contains(".choir/config.toml"))
  assert_eq(write_bodies.length(), 1)
  let updated = write_bodies[0]
  @debug.assert_eq(
    updated,
    local_config + "\nterminal_session = \"choir-repo\"\n",
  )
  let cfg = @config.parse_config(portable_config, local_content=Some(updated)).unwrap()
  assert_eq(cfg.terminal_session, "choir-repo")
  @debug.assert_eq(
    cfg.project.verify_cmd,
    Some("moon check --target native && moon test --target native"),
  )
}

///|
test "init local terminal_session persistence is idempotent" {
  let writes : Array[String] = []
  init_ensure_local_terminal_session(
    "choir-repo",
    read_file=fn(path) {
      if path == ".choir/config.local.toml" {
        "role = \"dev\"\nterminal_session = \"existing\"\n"
      } else {
        ""
      }
    },
    write_file=fn(path, _body) {
      writes.push(path)
      true
    },
  )
  @debug.assert_eq(writes, [])
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
struct InitRootConnectionAuth {
  server_boot_token : String
  server_env_assignment : String
  tl_agent_token : String
} derive(Debug, Eq)

///|
async fn init_mint_root_connection_auth(
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[InitRootConnectionAuth, @types.ChoirError] {
  let token = match @tools.mint_spawn_agent_token(capture, None) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  Ok({
    server_boot_token: token,
    server_env_assignment: "CHOIR_ROOT_AGENT_TOKEN=" + token,
    tl_agent_token: token,
  })
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
async test "init root auth mints once and threads same token to server record and TL env" {
  let root_token = "00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f"
  let captured : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    captured.push(cmd)
    (0, root_token + "\n")
  }
  let auth = match init_mint_root_connection_auth(capture) {
    Ok(value) => value
    Err(e) => {
      fail("expected root auth mint: " + e.message())
      return
    }
  }
  @debug.assert_eq(captured, [@tools.spawn_agent_token_command()])
  assert_eq(auth.server_boot_token, root_token)
  assert_eq(auth.server_env_assignment, "CHOIR_ROOT_AGENT_TOKEN=" + root_token)
  assert_eq(auth.tl_agent_token, root_token)

  let project_dir = serve_test_project_dir("init-root-auth")
  ignore(@sys.rm_rf(project_dir))
  ignore(@sys.create_dir_all(project_dir))
  let state = @server.ServerState::new(
    {
      ..@types.Config::default(),
      project_dir,
      terminal_session: "init-root-auth",
    },
    @server.make_hermetic_recovery_provider(),
  )
  serve_record_boot_root_credential(state, auth.server_boot_token)
  match state.registry.credential_for_agent("root") {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::Root)
      assert_eq(credential.token, auth.tl_agent_token)
    }
    None => fail("expected root boot credential")
  }

  let tl_cmd = @workspace.init_tl_zellij_tab_command(
    "init-root-auth",
    project_dir,
    "claude",
    "main",
    root_agent_token=Some(auth.tl_agent_token),
  )
  assert_true(
    tl_cmd.args[11].contains("CHOIR_AGENT_TOKEN='" + root_token + "'"),
  )
  assert_false(tl_cmd.to_string().contains("root credential not provisioned"))
  let register_result = serve_handle_request_line(
    state,
    serve_test_register_line("root", "root", root_token, project_dir),
    true,
  )
  serve_assert_register_ok(state, register_result, "root", @types.Role::Root)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "init recreate replaces Server tab with same root token carried to TL" {
  let root_token = "recreate-root-token"
  let auth = InitRootConnectionAuth::{
    server_boot_token: root_token,
    server_env_assignment: "CHOIR_ROOT_AGENT_TOKEN=" + root_token,
    tl_agent_token: root_token,
  }
  let commands = init_server_tab_launch_plan(
    "howdy",
    "/proj",
    true,
    true,
    true,
    auth.server_env_assignment,
  )
  assert_eq(commands.length(), 2)
  assert_true(commands[0].to_string().contains("Server"))
  assert_true(commands[0].to_string().contains("close"))
  assert_eq(commands[1].program, "zellij")
  @debug.assert_eq(commands[1].args[0:9], [
    "--session", "howdy", "action", "new-tab", "--name", "Server", "--cwd", "/proj",
    "--",
  ])
  assert_true(commands[1].args.contains("env"))
  assert_true(commands[1].args.contains("CHOIR_ROOT_AGENT_TOKEN=" + root_token))
  assert_true(commands[1].args.contains("choir"))
  assert_true(commands[1].args.contains("serve"))

  let tl_cmd = @workspace.init_tl_zellij_tab_command(
    "howdy",
    "/proj",
    "claude",
    "main",
    root_agent_token=Some(auth.tl_agent_token),
  )
  assert_true(
    tl_cmd.args[11].contains("CHOIR_AGENT_TOKEN='" + root_token + "'"),
  )
  assert_false(tl_cmd.to_string().contains("CHOIR_ROOT_AGENT_TOKEN"))
}

///|
test "init non-recreate still reuses existing Server tab" {
  let commands = init_server_tab_launch_plan(
    "howdy", "/proj", false, true, true, "CHOIR_ROOT_AGENT_TOKEN=plain-init-token",
  )
  @debug.assert_eq(commands, [])
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
  let listen_uds_abs = if config.listen_uds.has_prefix("/") {
    config.listen_uds
  } else {
    project_dir + "/" + config.listen_uds
  }
  let env_z = @workspace.launch_env_assignments(
    spec,
    session,
    workspace,
    terminal_target,
    listen_uds_env=Some(listen_uds_abs),
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
    @workspace.write_local_config(
      workspace,
      @workspace.config_local_content(
        spec,
        workspace,
        terminal_target,
        project_dir=Some(project_dir),
        listen_uds=Some(listen_uds_abs),
        terminal_session=Some(session),
      ),
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
test "init companion commands write connection metadata only to local config" {
  let companion : @config.CompanionDef = {
    name: "monitor",
    role: "worker",
    command: "claude",
    task: "watch the build",
  }
  let cmds = init_companion_commands(
    "/proj",
    "exo",
    @types.Config::default(),
    "main",
    companion,
  )
  let local_bodies : Array[String] = []
  for cmd in cmds {
    if cmd.program == @workspace.native_write_choir_file_program &&
      cmd.args.length() >= 2 {
      if cmd.args[1] == "config.toml" {
        fail("init companion spawn must not write tracked config.toml")
      }
      if cmd.args[1] == "config.local.toml" {
        local_bodies.push(cmd.args[2])
      }
    }
  }
  @debug.assert_eq(local_bodies.length(), 1)
  let local_cfg = @config.parse_local_config(local_bodies[0]).unwrap()
  @debug.assert_eq(local_cfg.default_role, Some(@types.Role::Worker))
  @debug.assert_eq(local_cfg.project_dir, Some("/proj"))
  @debug.assert_eq(local_cfg.listen_uds, Some("/proj/.choir/server.sock"))
  @debug.assert_eq(local_cfg.terminal_session, Some("exo"))
}

///|
fn init_is_choir_source_files(
  moon_mod_content : String,
  main_mbt_content : String,
) -> Bool {
  main_mbt_content != "" &&
  init_moon_mod_has_string_assignment(moon_mod_content, "name", "choir")
}

///|
fn init_moon_mod_line_string_value(line : String, key : String) -> String? {
  let trimmed = line.trim().to_owned()
  if !trimmed.has_prefix(key) {
    return None
  }
  let rest = trimmed[key.length():].trim().to_owned()
  if !rest.has_prefix("=") {
    return None
  }
  let value_and_suffix = rest[1:].trim().to_owned()
  if !value_and_suffix.has_prefix("\"") {
    return None
  }
  let after_open = value_and_suffix[1:].to_owned()
  if !after_open.contains("\"") {
    return None
  }
  let mut value = ""
  let mut saw_value = false
  for part in after_open.split("\"") {
    if !saw_value {
      value = part.to_owned()
      saw_value = true
    }
  }
  let suffix_start = value.length() + 2
  let suffix = value_and_suffix[suffix_start:].trim().to_owned()
  if suffix == "" || suffix.has_prefix("//") {
    return Some(value)
  }
  None
}

///|
fn init_moon_mod_has_string_assignment(
  content : String,
  key : String,
  value : String,
) -> Bool {
  for raw in content.split("\n") {
    match init_moon_mod_line_string_value(raw.to_owned(), key) {
      Some(found) => if found == value { return true }
      None => ()
    }
  }
  false
}

///|
test "init source detection accepts moon.mod DSL manifest" {
  let main_mbt = "fn main() -> Unit { () }\n"
  let manifests = [
    "name = \"choir\"\n\nversion = \"0.1.0\"\n", "  name = \"choir\"\n\n  version = \"0.1.0\"\n",
    "name = \"choir\" // source tree\nversion = \"0.1.0\" // release\n", "\tname\t=\t\"choir\"\n\n\tversion\t=\t\"0.1.0\" // release\n",
  ]
  for manifest in manifests {
    @debug.assert_eq(init_is_choir_source_files(manifest, main_mbt), true)
  }
}

///|
test "moon.mod assignment parser accepts indented and commented version lines" {
  @debug.assert_eq(
    init_moon_mod_has_string_assignment(
      "  version = \"0.1.0\"\n", "version", "0.1.0",
    ),
    true,
  )
  @debug.assert_eq(
    init_moon_mod_has_string_assignment(
      "version = \"0.1.0\" // release\n", "version", "0.1.0",
    ),
    true,
  )
}

///|
test "moon.mod assignment parser rejects newline-spanning quoted values" {
  @debug.assert_eq(
    init_moon_mod_has_string_assignment(
      "version = \"0.1.0\n\"\n", "version", "0.1.0",
    ),
    false,
  )
}

///|
test "moon.mod assignment parser preserves comment markers inside quotes" {
  @debug.assert_eq(
    init_moon_mod_has_string_assignment(
      "name = \"choir//dev\"\n", "name", "choir//dev",
    ),
    true,
  )
  @debug.assert_eq(
    init_moon_mod_has_string_assignment(
      "name = \"choir//dev\"\n", "name", "choir",
    ),
    false,
  )
}

///|
test "init source detection rejects extra tokens after manifest name" {
  @debug.assert_eq(
    init_moon_mod_line_string_value("name = \"choir\" \"extra\"", "name"),
    None,
  )
  @debug.assert_eq(
    init_is_choir_source_files(
      "name = \"choir\" \"extra\"\nversion = \"0.1.0\"\n", "fn main() -> Unit { () }\n",
    ),
    false,
  )
}

///|
fn init_is_choir_source_tree(project_dir : String) -> Bool {
  init_is_choir_source_files(
    @sys.read_file(project_dir + "/moon.mod"),
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
        init_config_toml_content(),
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
      init_ensure_local_terminal_session(default_session)
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

      if recreate {
        let pid_str = @sys.read_file(".choir/server.pid")
        if pid_str != "" {
          @sys.write_stdout("Stopping server (PID \{pid_str})...\n")
          init_kill_server_pid_string(pid_str)
        }
        if purge {
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
      if session_alive == 0 && !recreate {
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

      if session_alive != 0 && !recreate && server_alive == 0 {
        match init_root_launch_guard(recreate, false, true, false) {
          InitRootLaunchGuard::Abort(message) => {
            @sys.write_stderr(message + "\n")
            @sys.exit(1)
            return
          }
          InitRootLaunchGuard::Proceed => ()
        }
      }

      let root_auth = match
        init_mint_root_connection_auth(@exec.capture_command_merged) {
        Ok(value) => value
        Err(_) => {
          @sys.write_stderr("choir init: failed to mint root credential\n")
          @sys.exit(1)
          return
        }
      }

      let birth_branch_stdout = @exec.capture_stdout("git", [
        "branch", "--show-current",
      ])
      init_bootstrap_write_root_birth_branch_best_effort(
        project_dir, birth_branch_stdout,
      )

      let created_session = session_alive != 0
      if created_session {
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
      }
      let server_tab_exists = init_tab_exists(session, "Server") catch {
        _ => false
      }
      let tl_tab_exists = init_tab_exists(session, "TL") catch { _ => false }
      match
        init_root_launch_guard(
          recreate,
          server_tab_exists,
          server_alive == 0,
          tl_tab_exists,
        ) {
        InitRootLaunchGuard::Abort(message) => {
          @sys.write_stderr(message + "\n")
          @sys.exit(1)
          return
        }
        InitRootLaunchGuard::Proceed => ()
      }
      let server_launch_plan = init_server_tab_launch_plan(
        session,
        project_dir,
        recreate,
        server_tab_exists,
        server_alive == 0,
        root_auth.server_env_assignment,
      )
      if server_launch_plan.length() > 0 {
        for cmd in server_launch_plan {
          init_run_or_exit(cmd)
        }
      } else if !server_tab_exists {
        @sys.write_stdout("Reusing existing server process.\n")
      } else {
        @sys.write_stdout("Reusing existing Server tab.\n")
      }
      init_wait_for_server_socket_before_tl(config.listen_uds)
      if recreate && tl_tab_exists {
        init_run_or_exit(
          @workspace.local_close_target(
            @workspace.zellij_tab_target(session, "TL"),
          ),
        )
      }
      if recreate || !tl_tab_exists {
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
            root_agent_token=Some(root_auth.tl_agent_token),
          ),
        )
      } else {
        @sys.write_stdout("Reusing existing TL tab.\n")
      }
      // Drop the empty default tab (id 0) only when this invocation created a
      // fresh background session before adding the named "Server"/"TL" tabs. If
      // `--recreate` is still looking at an already-live session after cleanup,
      // `created_session` is false and tab 0 is not assumed to be disposable.
      // (Do not remove again under a "don't close TL tab" guard: see choir-eek
      // — that guard applies to teardown paths, not this one.)
      if created_session {
        ignore(
          @exec.run({
            program: "zellij",
            args: ["--session", session, "action", "close-tab-by-id", "0"],
            workdir: None,
          }) catch {
            _ => 0
          },
        )
      }
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
