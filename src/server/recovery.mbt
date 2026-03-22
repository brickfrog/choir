///|
priv struct OpenPR {
  pr_number : Int
  branch : String
  base : String
  url : String
  created_sec : Int64?
}

///|
#borrow(cmd)
extern "C" fn c_system_recovery(cmd : Bytes) -> Int = "system"

///|
fn string_to_null_terminated_bytes_recovery(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn run_shell_recovery(script : String) -> Unit {
  ignore(
    c_system_recovery(
      string_to_null_terminated_bytes_recovery("sh -c '" + script + "'"),
    ),
  )
}

///|
fn is_leap_year(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn days_in_month(year : Int, month : Int) -> Int {
  match month {
    1 => 31
    2 => if is_leap_year(year) { 29 } else { 28 }
    3 => 31
    4 => 30
    5 => 31
    6 => 30
    7 => 31
    8 => 31
    9 => 30
    10 => 31
    11 => 30
    12 => 31
    _ => 0
  }
}

///|
fn days_from_civil(year : Int, month : Int, day : Int) -> Int64 {
  let adjusted_year = if month <= 2 { year - 1 } else { year }
  let era = if adjusted_year >= 0 {
    adjusted_year / 400
  } else {
    (adjusted_year - 399) / 400
  }
  let year_of_era = adjusted_year - era * 400
  let month_prime = if month > 2 { month - 3 } else { month + 9 }
  let day_of_year = (153 * month_prime + 2) / 5 + day - 1
  let day_of_era = year_of_era * 365 +
    year_of_era / 4 -
    year_of_era / 100 +
    day_of_year
  (era * 146097 + day_of_era - 719468).to_int64()
}

///|
fn parse_digits(s : String, start : Int, len : Int) -> Int? {
  if start < 0 || len <= 0 || start + len > s.length() {
    return None
  }
  let mut res = 0
  for i = start; i < start + len; i = i + 1 {
    let c = s[i]
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

///|
fn find_char(s : String, c : Char, start : Int) -> Int {
  let code = c.to_int().to_uint16()
  for i = start; i < s.length(); i = i + 1 {
    if s[i] == code {
      return i
    }
  }
  -1
}

///|
fn parse_github_time_utc_sec(s : String) -> Int64? {
  if s.length() < 20 {
    return None
  }
  if s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':' {
    return None
  }
  let year = match parse_digits(s, 0, 4) {
    Some(value) => value
    None => return None
  }
  let month = match parse_digits(s, 5, 2) {
    Some(value) => value
    None => return None
  }
  let day = match parse_digits(s, 8, 2) {
    Some(value) => value
    None => return None
  }
  let hour = match parse_digits(s, 11, 2) {
    Some(value) => value
    None => return None
  }
  let minute = match parse_digits(s, 14, 2) {
    Some(value) => value
    None => return None
  }
  let second = match parse_digits(s, 17, 2) {
    Some(value) => value
    None => return None
  }
  if month < 1 || month > 12 {
    return None
  }
  if day < 1 || day > days_in_month(year, month) {
    return None
  }
  if hour > 23 || minute > 59 || second > 59 {
    return None
  }
  let tz_start = 19
  if tz_start >= s.length() {
    return None
  }
  let tz_char = s[tz_start]
  if tz_char == '.' {
    let z_idx = find_char(s, 'Z', tz_start)
    if z_idx == -1 || z_idx != s.length() - 1 {
      return None
    }
  } else if tz_char != 'Z' || tz_start != s.length() - 1 {
    return None
  }
  Some(
    days_from_civil(year, month, day) * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64(),
  )
}

///|
fn split_lines(output : String) -> Array[String] {
  let lines = []
  for raw in output.split("\n") {
    let line = raw.to_string().trim().to_string()
    if line != "" {
      lines.push(line)
    }
  }
  lines
}

///|
fn parse_open_prs(output : String) -> Array[OpenPR] {
  let prs = []
  let json = @json.parse(output) catch { _ => return prs }
  let arr = match json {
    Json::Array(items) => items
    _ => return prs
  }
  for item in arr {
    match item {
      Json::Object(fields) => {
        let number = match fields.get("number") {
          Some(Number(n, ..)) => n.to_int()
          _ => continue
        }
        let branch = match fields.get("headRefName") {
          Some(String(v)) => v
          _ => continue
        }
        let base = match fields.get("baseRefName") {
          Some(String(v)) => v
          _ => continue
        }
        let url = match fields.get("url") {
          Some(String(v)) => v
          _ => continue
        }
        let created_sec = match fields.get("createdAt") {
          Some(String(v)) => parse_github_time_utc_sec(v)
          _ => None
        }
        prs.push({ pr_number: number, branch, base, url, created_sec })
      }
      _ => ()
    }
  }
  prs
}

///|
async fn capture_stdout(
  program : String,
  args : Array[String],
  cwd? : String? = None,
) -> String {
  let (read_end, write_end) = @pipe.pipe() catch { _ => return "" }
  let _exit_code = match cwd {
    Some(dir) =>
      @process.run(program, args, cwd=dir, stdout=write_end) catch {
        _ => -1
      }
    None => @process.run(program, args, stdout=write_end) catch { _ => -1 }
  }
  write_end.close()
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = read_end.read(buf, offset=total, max_len=buf.length() - total)
    if n == 0 {
      break
    }
    total = total + n
  }
  read_end.close()
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
}

///|
fn default_agent_type(role : @types.Role) -> @types.AgentType {
  match role {
    @types.Role::Root => @types.AgentType::Claude
    @types.Role::TL => @types.AgentType::Claude
    @types.Role::Dev => @types.AgentType::Gemini
    @types.Role::Worker => @types.AgentType::Gemini
  }
}

///|
fn window_target_name(target : String) -> String? {
  let mut idx = -1
  for i = 0; i < target.length(); i = i + 1 {
    if target[i] == ':' {
      idx = i
      break
    }
  }
  if idx == -1 || idx + 1 >= target.length() {
    None
  } else {
    Some(target[idx + 1:target.length()].to_string() catch { _ => "" })
  }
}

///|
fn is_window_target_alive(
  target : String?,
  session : String,
  tmux_windows : Array[String],
) -> Bool {
  match target {
    Some(value) =>
      match window_target_name(value) {
        Some(window_name) =>
          value.has_prefix(session + ":") && tmux_windows.contains(window_name)
        None => false
      }
    None => false
  }
}

///|
priv struct ZellijLiveTargets {
  tabs : Array[String]
  panes : Array[String]
}

///|
fn json_value_bool(value : Json?) -> Bool {
  match value {
    Some(True) => true
    _ => false
  }
}

///|
fn json_value_string(value : Json?) -> String {
  match value {
    Some(String(v)) => v
    _ => ""
  }
}

///|
fn push_unique(values : Array[String], value : String) -> Unit {
  if value != "" && not(values.contains(value)) {
    values.push(value)
  }
}

///|
fn parse_zellij_live_targets(output : String) -> ZellijLiveTargets {
  let tabs = []
  let panes = []
  let json = @json.parse(output) catch { _ => return { tabs, panes } }
  let arr = match json {
    Json::Array(items) => items
    _ => return { tabs, panes }
  }
  for item in arr {
    match item {
      Json::Object(fields) => {
        if json_value_bool(fields.get("is_plugin")) ||
          json_value_bool(fields.get("exited")) {
          continue
        }
        push_unique(tabs, json_value_string(fields.get("tab_name")))
        push_unique(panes, json_value_string(fields.get("title")))
      }
      _ => ()
    }
  }
  { tabs, panes }
}

///|
fn is_zellij_target_alive(
  target : String?,
  session : String,
  live : ZellijLiveTargets,
) -> Bool {
  match target {
    Some(value) =>
      match @workspace.parse_local_target(value) {
        Some(
          {
            kind: @workspace.LocalTargetKind::ZellijTab,
            session: target_session,
            name,
          }
        ) => target_session == session && live.tabs.contains(name)
        Some(
          {
            kind: @workspace.LocalTargetKind::ZellijPane,
            session: target_session,
            name,
          }
        ) => target_session == session && live.panes.contains(name)
        _ => false
      }
    None => false
  }
}

///|
fn is_local_target_alive(
  target : String?,
  session : String,
  tmux_windows : Array[String],
  zellij_live : ZellijLiveTargets,
) -> Bool {
  match target {
    Some(value) =>
      match @workspace.parse_local_target(value) {
        Some({ kind: @workspace.LocalTargetKind::ZellijTab, .. })
        | Some({ kind: @workspace.LocalTargetKind::ZellijPane, .. }) =>
          is_zellij_target_alive(target, session, zellij_live)
        _ => is_window_target_alive(target, session, tmux_windows)
      }
    None => false
  }
}

///|
fn recover_agent_from_local_config(
  project_dir : String,
  rel_workspace : String,
  fallback_slug : String,
  session : String,
  tmux_windows : Array[String],
  zellij_live : ZellijLiveTargets,
) -> @types.Agent? {
  let config_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content = @io.read_file(config_path)
  if content == "" {
    return None
  }
  let local_cfg = match @config.parse_local_config(content) {
    Ok(cfg) => cfg
    Err(_) => return None
  }
  let role = local_cfg.role.unwrap_or(@types.Role::TL)
  let agent_id = local_cfg.agent_id.unwrap_or(fallback_slug)
  let branch = local_cfg.branch.unwrap_or(agent_id)
  let workspace = local_cfg.workspace.unwrap_or(rel_workspace)
  let alive = is_local_target_alive(
    local_cfg.terminal_target,
    session,
    tmux_windows,
    zellij_live,
  )
  Some({
    agent_id,
    role,
    agent_type: local_cfg.agent_type.unwrap_or(default_agent_type(role)),
    state: if alive {
      @types.AgentState::Active
    } else {
      @types.AgentState::Done
    },
    parent: local_cfg.parent_id,
    terminal_target: if alive {
      local_cfg.terminal_target
    } else {
      None
    },
    host: @types.Host::Local,
    workspace,
    branch,
  })
}

///|
async fn recover_local_agents(
  state : ServerState,
  session : String,
  tmux_windows : Array[String],
  zellij_live : ZellijLiveTargets,
  dir_name : String,
) -> Unit {
  let project_dir = state.config.project_dir
  let output = capture_stdout(
    "sh",
    ["-c", "ls .choir/" + dir_name + "/ 2>/dev/null"],
    cwd=Some(project_dir),
  )
  for slug in split_lines(output) {
    let rel_workspace = ".choir/" + dir_name + "/" + slug
    match
      recover_agent_from_local_config(
        project_dir, rel_workspace, slug, session, tmux_windows, zellij_live,
      ) {
      Some(agent) =>
        match state.registry.insert(agent) {
          Ok(_) =>
            if not(
                is_local_target_alive(
                  agent.terminal_target,
                  session,
                  tmux_windows,
                  zellij_live,
                ),
              ) {
              ignore(state.registry.set_alive(agent.agent_id, false))
            }
          Err(_) => ()
        }
      None => ()
    }
  }
}

///|
fn find_persisted_tracked_pr(
  persisted : Array[@poller.TrackedPR],
  pr_number : Int,
  branch : String,
) -> @poller.TrackedPR? {
  for tracked in persisted {
    if tracked.pr_number == pr_number && tracked.branch == branch {
      return Some(tracked)
    }
  }
  None
}

///|
async fn recover_open_pr_tracking_with(
  state : ServerState,
  open_prs : Array[OpenPR],
  persisted : Array[@poller.TrackedPR],
  recovered_at : Int64,
  snapshot : async (Int) -> (@poller.ReviewState, String, Bool, String),
) -> Unit {
  for pr in open_prs {
    match state.registry.get(pr.branch) {
      Ok(agent) => {
        let restored = find_persisted_tracked_pr(
          persisted,
          pr.pr_number,
          pr.branch,
        )
        match restored {
          Some(existing) =>
            state.poller.restore({
              ..existing,
              agent_id: agent.agent_id,
              branch: pr.branch,
              parent_branch: pr.base,
              pr_url: pr.url,
            })
          None => {
            let (review, sha, ci_failed, review_bodies) = snapshot(pr.pr_number)
            state.poller.track_recovered(
              pr.pr_number,
              agent.agent_id,
              pr.branch,
              pr.base,
              pr.url,
              match pr.created_sec {
                Some(created_sec) => created_sec
                None => recovered_at
              },
              review,
              review_bodies,
              sha,
              ci_failed,
            )
          }
        }
      }
      Err(_) => ()
    }
  }
}

///|
pub async fn recover_state(state : ServerState, session : String) -> Unit {
  let project_dir = state.config.project_dir
  let tmux_windows = match state.config.terminal_backend {
    @types.TerminalBackend::Tmux =>
      split_lines(
        capture_stdout(
          "tmux",
          ["list-windows", "-t", session, "-F", "#{window_name}"],
          cwd=Some(project_dir),
        ),
      )
    @types.TerminalBackend::Zellij => []
  }
  let zellij_live = match state.config.terminal_backend {
    @types.TerminalBackend::Tmux => { tabs: [], panes: [] }
    @types.TerminalBackend::Zellij =>
      parse_zellij_live_targets(
        capture_stdout(
          "zellij",
          [
            "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
          ],
          cwd=Some(project_dir),
        ),
      )
  }
  recover_local_agents(state, session, tmux_windows, zellij_live, "worktrees")
  recover_local_agents(state, session, tmux_windows, zellij_live, "agents")

  let open_pr_output = capture_stdout(
    "sh",
    [
      "-c", "gh pr list --json number,headRefName,baseRefName,url,createdAt --state open 2>/dev/null",
    ],
    cwd=Some(project_dir),
  )
  let now = @poller.now_sec()
  recover_open_pr_tracking_with(
    state,
    parse_open_prs(open_pr_output),
    @poller.read_state_file(project_dir),
    now,
    @poller.gh_poll_pr,
  )
  ignore(state.poller.write_state_file(project_dir))
}

///|
test "parse_open_prs extracts branch base and url" {
  let prs = parse_open_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/12\",\"createdAt\":\"2026-03-20T01:02:03Z\"},{\"number\":13,\"headRefName\":\"main.subtl.leaf-b\",\"baseRefName\":\"main.subtl\",\"url\":\"https://example.test/pr/13\",\"createdAt\":\"2026-03-21T00:00:00Z\"}]",
  )
  assert_eq(prs.length(), 2)
  assert_eq(prs[0].pr_number, 12)
  assert_eq(prs[0].branch, "main.leaf-a")
  assert_eq(prs[0].base, "main")
  assert_eq(prs[0].url, "https://example.test/pr/12")
  assert_eq(prs[0].created_sec, Some(1773968523L))
  assert_eq(prs[1].pr_number, 13)
  assert_eq(prs[1].branch, "main.subtl.leaf-b")
  assert_eq(prs[1].base, "main.subtl")
  assert_eq(prs[1].url, "https://example.test/pr/13")
  assert_eq(prs[1].created_sec, Some(1774051200L))
}

///|
test "parse_zellij_live_targets collects live tab and pane names" {
  let live = parse_zellij_live_targets(
    (
      #|[
      #|  {"id":7,"tab_id":1,"tab_name":"leaf-a","title":"zellij:tab-bar","is_plugin":true,"exited":false},
      #|  {"id":8,"tab_id":1,"tab_name":"leaf-a","title":"gemini --prompt-interactive","is_plugin":false,"exited":false},
      #|  {"id":9,"tab_id":2,"tab_name":"worker-a","title":"worker-a","is_plugin":false,"exited":true}
      #|]
    ),
  )
  assert_eq(live.tabs, ["leaf-a"])
  assert_eq(live.panes, ["gemini --prompt-interactive"])
}

///|
test "parse_open_prs ignores malformed entries" {
  let prs = parse_open_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\"},{\"number\":\"oops\",\"headRefName\":\"main.leaf-b\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/13\"}]",
  )
  assert_eq(prs.length(), 0)
}

///|
test "parse_github_time_utc_sec handles valid and invalid timestamps" {
  assert_eq(
    parse_github_time_utc_sec("2026-03-20T01:02:03Z"),
    Some(1773968523L),
  )
  assert_eq(
    parse_github_time_utc_sec("2026-03-20T01:02:03.456Z"),
    Some(1773968523L),
  )
  assert_eq(parse_github_time_utc_sec("2026-02-30T01:02:03Z"), None)
  assert_eq(parse_github_time_utc_sec("2026-03-20 01:02:03Z"), None)
}

///|
test "recover_agent_from_local_config restores active agent metadata" {
  let project_dir = "/tmp/choir-recovery-active"
  let rel_workspace = ".choir/worktrees/leaf-a"
  run_shell_recovery(
    "rm -rf " +
    project_dir +
    " && mkdir -p " +
    project_dir +
    "/" +
    rel_workspace +
    "/.choir",
  )
  let local_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content =
    #|role = "dev"
    #|agent_id = "main.leaf-a"
    #|parent_id = "main"
    #|branch = "main.leaf-a"
    #|workspace = ".choir/worktrees/leaf-a"
    #|terminal_target = "howdy:leaf-a"
    #|agent_type = "gemini"
  assert_true(@io.write_file_sync(local_path, content))
  let recovered = recover_agent_from_local_config(
    project_dir,
    rel_workspace,
    "leaf-a",
    "howdy",
    ["leaf-a"],
    { tabs: [], panes: [] },
  )
  match recovered {
    Some(agent) => {
      assert_eq(agent.agent_id, "main.leaf-a")
      assert_eq(agent.parent, Some("main"))
      assert_eq(agent.branch, "main.leaf-a")
      assert_eq(agent.workspace, ".choir/worktrees/leaf-a")
      assert_eq(agent.role, @types.Role::Dev)
      assert_eq(agent.agent_type, @types.AgentType::Gemini)
      assert_eq(agent.state, @types.AgentState::Active)
      assert_eq(agent.terminal_target, Some("howdy:leaf-a"))
    }
    None => fail("expected local config to recover active agent")
  }
  run_shell_recovery("rm -rf " + project_dir)
}

///|
test "recover_agent_from_local_config falls back and clears dead tmux targets" {
  let project_dir = "/tmp/choir-recovery-done"
  let rel_workspace = ".choir/agents/helper"
  run_shell_recovery(
    "rm -rf " +
    project_dir +
    " && mkdir -p " +
    project_dir +
    "/" +
    rel_workspace +
    "/.choir",
  )
  let local_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content =
    #|role = "tl"
    #|terminal_target = "howdy:helper"
  assert_true(@io.write_file_sync(local_path, content))
  let recovered = recover_agent_from_local_config(
    project_dir,
    rel_workspace,
    "helper",
    "howdy",
    [],
    { tabs: [], panes: [] },
  )
  match recovered {
    Some(agent) => {
      assert_eq(agent.agent_id, "helper")
      assert_eq(agent.parent, None)
      assert_eq(agent.branch, "helper")
      assert_eq(agent.workspace, rel_workspace)
      assert_eq(agent.role, @types.Role::TL)
      assert_eq(agent.agent_type, @types.AgentType::Claude)
      assert_eq(agent.state, @types.AgentState::Done)
      assert_eq(agent.terminal_target, None)
    }
    None => fail("expected local config to recover done agent")
  }
  run_shell_recovery("rm -rf " + project_dir)
}

///|
test "recover_agent_from_local_config keeps live zellij tab targets" {
  let project_dir = "/tmp/choir-recovery-zellij-live"
  let rel_workspace = ".choir/worktrees/leaf-z"
  run_shell_recovery(
    "rm -rf " +
    project_dir +
    " && mkdir -p " +
    project_dir +
    "/" +
    rel_workspace +
    "/.choir",
  )
  let local_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content =
    #|role = "dev"
    #|agent_id = "main.leaf-z"
    #|parent_id = "main"
    #|branch = "main.leaf-z"
    #|workspace = ".choir/worktrees/leaf-z"
    #|terminal_target = "zellij-tab:howdy:leaf-z"
    #|agent_type = "gemini"
  assert_true(@io.write_file_sync(local_path, content))
  let recovered = recover_agent_from_local_config(
    project_dir,
    rel_workspace,
    "leaf-z",
    "howdy",
    [],
    { tabs: ["leaf-z"], panes: [] },
  )
  match recovered {
    Some(agent) => {
      assert_eq(agent.state, @types.AgentState::Active)
      assert_eq(agent.terminal_target, Some("zellij-tab:howdy:leaf-z"))
      assert_eq(agent.agent_type, @types.AgentType::Gemini)
    }
    None => fail("expected local config to recover zellij agent")
  }
  run_shell_recovery("rm -rf " + project_dir)
}

///|
async test "recover_open_pr_tracking_with seeds current review snapshot" {
  let state = ServerState::new(@types.Config::default())
  ignore(
    state.registry.insert({
      agent_id: "main.leaf-a",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      state: @types.AgentState::Active,
      parent: Some("main"),
      terminal_target: Some("howdy:leaf-a"),
      host: @types.Host::Local,
      workspace: ".choir/worktrees/leaf-a",
      branch: "main.leaf-a",
    }),
  )
  recover_open_pr_tracking_with(
    state,
    [
      {
        pr_number: 12,
        branch: "main.leaf-a",
        base: "main",
        url: "https://example.test/pr/12",
        created_sec: Some(77L),
      },
    ],
    [],
    123L,
    fn(_pr_number) {
      (
        @poller.ReviewState::ChangesRequested,
        "sha-review-1",
        true,
        "Please add tests",
      )
    },
  )
  match state.poller.get(12) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "main.leaf-a")
      assert_eq(tracked.branch, "main.leaf-a")
      assert_eq(tracked.parent_branch, "main")
      assert_eq(tracked.pr_url, "https://example.test/pr/12")
      assert_eq(tracked.first_seen, 77L)
      assert_eq(
        tracked.last_review_state,
        @poller.ReviewState::ChangesRequested,
      )
      assert_eq(tracked.last_review_bodies, "Please add tests")
      assert_eq(tracked.last_sha, "sha-review-1")
      assert_false(tracked.notified_parent)
      assert_true(tracked.last_ci_failed)
    }
    None => fail("expected recovered tracked PR")
  }
}

///|
async test "recover_open_pr_tracking_with ignores unowned PR branches" {
  let state = ServerState::new(@types.Config::default())
  recover_open_pr_tracking_with(
    state,
    [
      {
        pr_number: 77,
        branch: "main.unknown",
        base: "main",
        url: "https://example.test/pr/77",
        created_sec: Some(11L),
      },
    ],
    [],
    123L,
    fn(_pr_number) { (@poller.ReviewState::Approved, "sha", false, "") },
  )
  assert_eq(state.poller.get(77), None)
}

///|
async test "recover_open_pr_tracking_with prefers persisted poller state" {
  let state = ServerState::new(@types.Config::default())
  ignore(
    state.registry.insert({
      agent_id: "main.leaf-a",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      state: @types.AgentState::Active,
      parent: Some("main"),
      terminal_target: Some("howdy:leaf-a"),
      host: @types.Host::Local,
      workspace: ".choir/worktrees/leaf-a",
      branch: "main.leaf-a",
    }),
  )
  recover_open_pr_tracking_with(
    state,
    [
      {
        pr_number: 12,
        branch: "main.leaf-a",
        base: "main",
        url: "https://example.test/pr/12",
        created_sec: Some(77L),
      },
    ],
    [
      {
        pr_number: 12,
        agent_id: "stale-agent-id",
        branch: "main.leaf-a",
        parent_branch: "stale-base",
        pr_url: "https://example.test/pr/stale",
        first_seen: 55L,
        last_review_state: @poller.ReviewState::ChangesRequested,
        last_review_bodies: "Persisted review comment",
        last_sha: "sha-persisted",
        notified_parent: true,
        last_ci_failed: true,
        last_timeout_at: 0L,
      },
    ],
    123L,
    fn(_pr_number) {
      (@poller.ReviewState::Approved, "sha-live", false, "Should be ignored")
    },
  )
  match state.poller.get(12) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "main.leaf-a")
      assert_eq(tracked.branch, "main.leaf-a")
      assert_eq(tracked.parent_branch, "main")
      assert_eq(tracked.pr_url, "https://example.test/pr/12")
      assert_eq(tracked.first_seen, 55L)
      assert_eq(
        tracked.last_review_state,
        @poller.ReviewState::ChangesRequested,
      )
      assert_eq(tracked.last_review_bodies, "Persisted review comment")
      assert_eq(tracked.last_sha, "sha-persisted")
      assert_true(tracked.notified_parent)
      assert_true(tracked.last_ci_failed)
    }
    None => fail("expected restored tracked PR")
  }
}
