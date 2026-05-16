///|
fn tl_policy_usage() -> String {
  "usage: choir tl-policy-watch --pid <pid> [--interval-ms <ms>]"
}

///|
fn tl_policy_resolve_project_dir(project_dir : String) -> String {
  if project_dir.has_prefix("/") {
    project_dir
  } else {
    @env.current_dir().unwrap_or(".") + "/" + project_dir
  }
}

///|
fn tl_policy_current_dir() -> String {
  @env.current_dir().unwrap_or(".")
}

///|
fn tl_policy_load_config() -> @types.Config {
  let content = @sys.read_file(".choir/config.toml")
  match @config.parse_config(content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
}

///|
fn tl_policy_load_local_cfg() -> @types.LocalConfig {
  let local_content = @sys.read_file(".choir/config.local.toml")
  tool_local_cfg_with_env_fallback(
    match @config.parse_local_config(local_content) {
      Ok(cfg) => cfg
      Err(_) => @types.LocalConfig::default()
    },
  )
}

///|
fn tl_policy_agent_id(
  config : @types.Config,
  local_cfg : @types.LocalConfig,
) -> String {
  match local_cfg.agent_id {
    Some(id) => id
    None =>
      match config.agent_id {
        Some(id) => id
        None => "root"
      }
  }
}

///|
async fn tl_policy_status_paths(repo_dir : String) -> Array[String] {
  let cmd : @workspace.Command = {
    program: "git",
    args: ["-C", repo_dir, "status", "--porcelain", "--untracked-files=all"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_merged(cmd)
  if exit_code != 0 {
    return []
  }
  // Use the shared, fixed parser (@policy): it doesn't left-trim porcelain
  // lines before slicing column 3 (the local copy here used to corrupt
  // ` M src/foo.mbt` -> `rc/foo.mbt`) and returns both sides of a rename.
  @policy.git_status_changed_paths(output)
}

///|
fn tl_policy_child_terminal(summary : @phase.ChildLifecycleSummary) -> Bool {
  match summary {
    @phase.ChildLifecycleSummary::Done => true
    @phase.ChildLifecycleSummary::Failed(_) => true
    _ => false
  }
}

///|
fn tl_policy_live_wave_info(lifecycle : @phase.AgentLifecycle?) -> (Bool, Int?) {
  match lifecycle {
    Some(
      {
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, wave~)
        ),
        ..,
      }
    ) => {
      for child in children {
        if !tl_policy_child_terminal(child.summary) {
          return (true, Some(wave))
        }
      }
      (false, Some(wave))
    }
    Some(
      {
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::WaveComplete(wave~, children~)
        ),
        ..,
      }
    ) => {
      for child in children {
        if !tl_policy_child_terminal(child.summary) {
          return (true, Some(wave))
        }
      }
      (false, Some(wave))
    }
    _ => (false, None)
  }
}

///|
fn tl_policy_changed_paths_suffix(paths : Array[String]) -> String {
  if paths.length() == 0 {
    return ""
  }
  let shown : Array[String] = []
  let limit = if paths.length() < 3 { paths.length() } else { 3 }
  for i = 0; i < limit; i = i + 1 {
    shown.push(paths[i])
  }
  let suffix = if paths.length() > limit { ", ..." } else { "" }
  "\nChanged paths: " + shown.join(", ") + suffix
}

///|
fn tl_policy_violation_message(
  agent_id : String,
  reason : String,
  paths : Array[String],
) -> String {
  "policy blocked: " +
  reason +
  " [agent=" +
  agent_id +
  "]" +
  tl_policy_changed_paths_suffix(paths)
}

///|
fn tl_policy_interval_ms(args : Array[String]) -> Int {
  for i = 0; i < args.length() - 1; i = i + 1 {
    if args[i] == "--interval-ms" {
      let parsed = Some(@string.parse_int(args[i + 1])) catch { _ => None }
      match parsed {
        Some(n) => if n > 0 { return n }
        None => ()
      }
    }
  }
  250
}

///|
fn tl_policy_pid_arg(args : Array[String]) -> Int? {
  for i = 0; i < args.length() - 1; i = i + 1 {
    if args[i] == "--pid" {
      return Some(@string.parse_int(args[i + 1])) catch { _ => None }
    }
  }
  None
}

///|
fn tl_policy_changed_paths_key(paths : Array[String]) -> String {
  let sorted = paths.copy()
  sorted.sort()
  sorted.join("\n")
}

///|
async fn tl_policy_watch_loop(
  pid : Int,
  interval_ms : Int,
  agent_id : String,
  project_dir : String,
  repo_dir : String,
  pid_is_alive? : (Int) -> Bool = @sys.pid_is_alive,
  status_paths? : async (String) -> Array[String] = tl_policy_status_paths,
  lifecycle_reader? : (String, String) -> @phase.AgentLifecycle? = @phase.read_lifecycle,
  write_stderr? : (String) -> Unit = @sys.write_stderr,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Unit {
  let mut last_violation_paths_key : String? = None
  for ;; {
    if !pid_is_alive(pid) {
      return
    }
    let changed_paths = status_paths(repo_dir)
    let lifecycle = lifecycle_reader(project_dir, agent_id)
    let (live_wave, wave) = tl_policy_live_wave_info(lifecycle)
    let decision = @policy.decide_tl_parent_branch_write(
      live_wave, wave, changed_paths,
    )
    if decision.is_blocked() {
      let current_paths_key = tl_policy_changed_paths_key(changed_paths)
      let should_log = match last_violation_paths_key {
        Some(previous_paths_key) => previous_paths_key != current_paths_key
        None => true
      }
      if should_log {
        write_stderr(
          tl_policy_violation_message(
            agent_id,
            decision.reason(),
            changed_paths,
          ) +
          "\n",
        )
        last_violation_paths_key = Some(current_paths_key)
      }
    } else {
      last_violation_paths_key = None
    }
    sleep_fn(interval_ms)
  }
}

///|
fn tl_policy_watch_run() -> Unit {
  @async.run_async_main(async fn() {
    let args = @env.args()
    let pid = match tl_policy_pid_arg(args) {
      Some(value) => value
      None => {
        @sys.write_stderr(tl_policy_usage() + "\n")
        @sys.exit(1)
        return
      }
    }
    let interval_ms = tl_policy_interval_ms(args)
    let config = tl_policy_load_config()
    let local_cfg = tl_policy_load_local_cfg()
    let agent_id = tl_policy_agent_id(config, local_cfg)
    let project_dir = tl_policy_resolve_project_dir(config.project_dir)
    let repo_dir = tl_policy_current_dir()
    tl_policy_watch_loop(pid, interval_ms, agent_id, project_dir, repo_dir)
  })
}

///|
test "tl_policy_interval_ms defaults and parses positive values" {
  assert_eq(tl_policy_interval_ms(["choir", "tl-policy-watch"]), 250)
  assert_eq(
    tl_policy_interval_ms(["choir", "tl-policy-watch", "--interval-ms", "75"]),
    75,
  )
}

///|
test "tl_policy_live_wave_info requires a non terminal child" {
  let live = tl_policy_live_wave_info(
    Some({
      agent_id: "root",
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(
          children=[
            {
              child_id: "main.leaf-0",
              slug: "leaf-0",
              branch: "main.leaf-0",
              agent_type: @types.AgentType::Gemini,
              summary: @phase.ChildLifecycleSummary::Working,
            },
          ],
          wave=2,
        ),
      ),
      last_updated_unix_sec: 0L,
    }),
  )
  @debug.assert_eq(live, (true, Some(2)))
  let done = tl_policy_live_wave_info(
    Some({
      agent_id: "root",
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::WaveComplete(wave=2, children=[
          {
            child_id: "main.leaf-0",
            slug: "leaf-0",
            branch: "main.leaf-0",
            agent_type: @types.AgentType::Gemini,
            summary: @phase.ChildLifecycleSummary::Done,
          },
        ]),
      ),
      last_updated_unix_sec: 0L,
    }),
  )
  @debug.assert_eq(done, (false, Some(2)))
}

///|
async test "tl_policy_watch_loop logs violation without terminating watcher" {
  let logs : Array[String] = []
  let sleeps : Array[Int] = []
  let pid_checks : Array[Int] = []
  let status_repos : Array[String] = []
  let lifecycle_inputs : Array[String] = []
  let alive_checks = [true, true, true, false]
  let alive_index = [0]
  let status_calls = [0]
  tl_policy_watch_loop(
    1234,
    250,
    "root",
    "/project",
    "/repo",
    pid_is_alive=fn(pid) {
      pid_checks.push(pid)
      let i = alive_index[0]
      alive_index[0] = i + 1
      if i < alive_checks.length() {
        alive_checks[i]
      } else {
        false
      }
    },
    status_paths=async fn(repo) {
      @async.sleep(0)
      status_repos.push(repo)
      let call = status_calls[0]
      status_calls[0] = call + 1
      if call < 2 {
        ["src/a.mbt"]
      } else {
        ["src/b.mbt"]
      }
    },
    lifecycle_reader=fn(project, agent) {
      lifecycle_inputs.push(project + ":" + agent)
      Some({
        agent_id: "root",
        role: @types.Role::TL,
        process: @phase.ProcessState::Connected,
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(
            children=[
              {
                child_id: "root.leaf-0",
                slug: "leaf-0",
                branch: "root.leaf-0",
                agent_type: @types.AgentType::Codex,
                summary: @phase.ChildLifecycleSummary::Working,
              },
            ],
            wave=7,
          ),
        ),
        last_updated_unix_sec: 0L,
      })
    },
    write_stderr=fn(message) { logs.push(message) },
    sleep_fn=async fn(ms) {
      @async.sleep(0)
      sleeps.push(ms)
    },
  )
  @debug.assert_eq(pid_checks, [1234, 1234, 1234, 1234])
  assert_eq(alive_index[0], 4)
  assert_eq(status_calls[0], 3)
  @debug.assert_eq(status_repos, ["/repo", "/repo", "/repo"])
  @debug.assert_eq(lifecycle_inputs, [
    "/project:root", "/project:root", "/project:root",
  ])
  @debug.assert_eq(sleeps, [250, 250, 250])
  assert_eq(logs.length(), 2)
  assert_true(logs[0].contains("policy blocked:"))
  assert_true(logs[0].contains("Changed paths: src/a.mbt"))
  assert_true(logs[1].contains("Changed paths: src/b.mbt"))
}
