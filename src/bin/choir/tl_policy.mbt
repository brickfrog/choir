///|
fn tl_policy_usage() -> String {
  "usage: choir <tl-policy-watch --pid <pid> [--interval-ms <ms>]|tl-parent-override <on|off>>"
}

///|
fn tl_policy_override_key(agent_id : String) -> String {
  "tl-parent-override--" + @types.sanitize_agent_id(agent_id)
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
fn trim_wrapped_double_quotes(s : String) -> String {
  let trimmed = s.trim().to_string()
  if trimmed.length() >= 2 &&
    trimmed[0] == '"' &&
    trimmed[trimmed.length() - 1] == '"' {
    trimmed[1:trimmed.length() - 1].to_string()
  } else {
    trimmed
  }
}

///|
fn git_status_changed_path(line : String) -> String {
  if line.length() < 4 {
    return ""
  }
  let body = line[3:].trim().to_string()
  if body == "" {
    return ""
  }
  let path = match body.split_once(" -> ") {
    Some((_, to)) => to.to_string()
    None => body
  }
  trim_wrapped_double_quotes(path)
}

///|
fn git_status_changed_paths(output : String) -> Array[String] {
  let paths : Array[String] = []
  for raw_line in output.split("\n") {
    let line = raw_line.trim().to_string()
    if line == "" {
      continue
    }
    let path = git_status_changed_path(line)
    if path != "" {
      paths.push(path)
    }
  }
  paths
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
  git_status_changed_paths(output)
}

///|
fn tl_policy_override_enabled(project_dir : String, agent_id : String) -> Bool {
  let path = project_dir + "/.choir/kv/" + tl_policy_override_key(agent_id)
  let content = @sys.read_file(path).trim().to_lower()
  content == "1" || content == "true" || content == "on" || content == "yes"
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
    for ;; {
      if !@sys.pid_is_alive(pid) {
        return
      }
      let changed_paths = tl_policy_status_paths(repo_dir)
      let lifecycle = @phase.read_lifecycle(project_dir, agent_id)
      let (live_wave, wave) = tl_policy_live_wave_info(lifecycle)
      let override_enabled = tl_policy_override_enabled(project_dir, agent_id)
      let decision = @policy.decide_tl_parent_branch_write(
        live_wave, wave, changed_paths, override_enabled,
      )
      if decision.is_blocked() {
        @sys.write_stderr(
          tl_policy_violation_message(
            agent_id,
            decision.reason(),
            changed_paths,
          ) +
          "\n",
        )
        @sys.kill_pid_best_effort(pid)
        return
      }
      @async.sleep(interval_ms)
    }
  })
}

///|
fn tl_parent_override_run() -> Unit {
  let args = @env.args()
  let mode = if args.length() >= 3 { args[2].trim().to_lower() } else { "" }
  if mode != "on" && mode != "off" {
    @sys.write_stderr(tl_policy_usage() + "\n")
    @sys.exit(1)
    return
  }
  let config = tl_policy_load_config()
  let local_cfg = tl_policy_load_local_cfg()
  let agent_id = tl_policy_agent_id(config, local_cfg)
  let project_dir = tl_policy_resolve_project_dir(config.project_dir)
  let path = project_dir + "/.choir/kv/" + tl_policy_override_key(agent_id)
  if mode == "on" {
    ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
    if !@sys.write_file_atomic(path, "1\n") {
      @sys.write_stderr("failed to write override file\n")
      @sys.exit(1)
      return
    }
    @sys.write_stdout(
      "TL parent-branch override enabled for " + agent_id + "\n",
    )
  } else {
    ignore(@sys.delete_file_sync(path))
    @sys.write_stdout(
      "TL parent-branch override cleared for " + agent_id + "\n",
    )
  }
}

///|
test "git_status_changed_path parses plain and rename lines" {
  assert_eq(git_status_changed_path(" M src/main.mbt"), "src/main.mbt")
  assert_eq(git_status_changed_path("R  old.md -> docs/new.md"), "docs/new.md")
  assert_eq(
    git_status_changed_path("?? \"notes with space.md\""),
    "notes with space.md",
  )
}

///|
test "tl_policy_override_key sanitizes agent id" {
  assert_eq(
    tl_policy_override_key("main/tl.1"),
    "tl-parent-override--main_tl.1",
  )
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
    }),
  )
  assert_eq(live, (true, Some(2)))
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
    }),
  )
  assert_eq(done, (false, Some(2)))
}
