///|
priv struct OpenPR {
  pr_number : Int
  branch : String
  base : String
  url : String
  created_sec : Int64?
}

///|
fn parse_github_time_utc_sec(s : String) -> Int64? {
  Some(@tempo.DateTime::parse(s).to_unix_seconds()) catch {
    _ => None
  }
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
  let tmp = "/tmp/choir-recovery-" +
    @env.now().reinterpret_as_int64().to_string() +
    ".tmp"
  let shell_args = StringBuilder::new()
  shell_args.write_string(program)
  for arg in args {
    shell_args.write_string(" '")
    shell_args.write_string(arg)
    shell_args.write_string("'")
  }
  shell_args.write_string(" > '")
  shell_args.write_string(tmp)
  shell_args.write_string("' 2>/dev/null")
  let shell_cmd = shell_args.to_string()
  ignore(
    match cwd {
      Some(dir) =>
        @process.run("sh", ["-c", shell_cmd], cwd=dir) catch {
          _ => -1
        }
      None => @process.run("sh", ["-c", shell_cmd]) catch { _ => -1 }
    },
  )
  let result = @sys.read_file(tmp)
  ignore(@process.run("rm", ["-f", tmp]) catch { _ => -1 })
  result
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
fn is_local_target_alive(
  target : @types.LocalTarget?,
  session : String,
  zellij_live : ZellijLiveTargets,
) -> Bool {
  match target {
    Some({ kind: @types.TargetKind::ZellijTab, session: s, name }) =>
      s == session && zellij_live.tabs.contains(name)
    Some({ kind: @types.TargetKind::ZellijPane, session: s, name }) =>
      s == session && zellij_live.panes.contains(name)
    None => false
  }
}

///|
fn recover_agent_from_local_config(
  project_dir : String,
  rel_workspace : String,
  fallback_slug : String,
  session : String,
  zellij_live : ZellijLiveTargets,
) -> @types.Agent? {
  let config_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content = @sys.read_file(config_path)
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
    spawn_depth: local_cfg.spawn_depth.unwrap_or(0),
  })
}

///|
async fn recover_local_agents(
  state : ServerState,
  session : String,
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
        project_dir, rel_workspace, slug, session, zellij_live,
      ) {
      Some(agent) =>
        match state.register_agent(agent) {
          Ok(_) =>
            if not(
                is_local_target_alive(
                  agent.terminal_target,
                  session,
                  zellij_live,
                ),
              ) {
              ignore(
                state.registry.set_alive(agent.agent_id.to_string(), false),
              )
            }
          Err(_) => ()
        }
      None => ()
    }
  }
}

///|
fn inferred_next_round_from_lifecycle(lifecycle : @phase.DevLifecycle) -> Int {
  match lifecycle {
    @phase.DevLifecycle::ReviewOwned(
      state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
      ..
    ) => round + 1
    @phase.DevLifecycle::ChangesRequested(next_round~, ..) => next_round
    @phase.DevLifecycle::ExitRequestedDeferred(
      state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
      ..
    ) => round + 1
    _ => 1
  }
}

///|
fn recover_dev_lifecycle_for_pr(
  current : @phase.DevLifecycle,
  pr_number : Int,
  pr_url : String,
  review : @poller.ReviewState,
) -> @phase.DevLifecycle {
  let preserve_exit = match current {
    @phase.DevLifecycle::ExitRequestedDeferred(..) => true
    _ => false
  }
  match review {
    @poller.ReviewState::Approved =>
      if preserve_exit {
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        )
      } else {
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        )
      }
    @poller.ReviewState::ChangesRequested =>
      @phase.DevLifecycle::ChangesRequested(
        pr_number~,
        next_round=inferred_next_round_from_lifecycle(current),
      )
    @poller.ReviewState::Commented =>
      match current {
        @phase.DevLifecycle::ReviewOwned(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ExitRequestedDeferred(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(..) =>
          @phase.DevLifecycle::ExitRequestedDeferred(
            pr_number~,
            state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
          )
        _ =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
          )
      }
    @poller.ReviewState::None_ =>
      match current {
        @phase.DevLifecycle::ReviewOwned(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ExitRequestedDeferred(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(pr_number=n, ..) =>
          if n == pr_number {
            @phase.DevLifecycle::ExitRequestedDeferred(
              pr_number~,
              state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
            )
          } else {
            @phase.DevLifecycle::ReviewOwned(
              pr_number~,
              state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
            )
          }
        _ =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
          )
      }
  }
}

///|
fn sync_recovered_pr_lifecycle(
  state : ServerState,
  agent : @types.Agent,
  pr : OpenPR,
  review : @poller.ReviewState,
) -> Unit {
  let lifecycle = state.current_lifecycle(agent.agent_id.to_string())
  let workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) =>
      @phase.WorkflowState::Dev(
        recover_dev_lifecycle_for_pr(dev, pr.pr_number, pr.url, review),
      )
    other => other
  }
  let recovered = {
    ..lifecycle,
    workflow,
    process: @phase.ProcessState::Connected,
  }
  ignore(state.persist_lifecycle(recovered))
  state.sync_parent_child_lifecycle(agent.agent_id.to_string(), recovered)
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
  snapshot : async (Int) -> (
    Bool,
    @poller.ReviewState,
    String,
    Bool,
    String,
    Bool,
  ),
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
          Some(existing) => {
            state.poller.restore({
              ..existing,
              agent_id: agent.agent_id.to_string(),
              branch: pr.branch,
              parent_branch: pr.base,
              pr_url: pr.url,
            })
            sync_recovered_pr_lifecycle(
              state,
              agent,
              pr,
              existing.last_review_state,
            )
          }
          None => {
            let (_, review, sha, ci_failed, review_bodies, _) = snapshot(
              pr.pr_number,
            )
            state.poller.track_recovered(
              pr.pr_number,
              agent.agent_id.to_string(),
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
            sync_recovered_pr_lifecycle(state, agent, pr, review)
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
  let zellij_live = parse_zellij_live_targets(
    capture_stdout(
      "zellij",
      ["--session", session, "action", "list-panes", "--json", "-a", "-t", "-s"],
      cwd=Some(project_dir),
    ),
  )
  recover_local_agents(state, session, zellij_live, "worktrees")
  recover_local_agents(state, session, zellij_live, "agents")

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
