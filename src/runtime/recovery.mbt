///|
pub(all) struct ZellijLiveTargets {
  tabs : Array[String]
  panes : Array[String]
} derive(Show, Eq)

///|
pub(all) struct OpenPR {
  pr_number : Int
  branch : String
  base : String
  url : String
  created_sec : Int64?
} derive(Show, Eq)

///|
pub(all) struct LocalAgentSnapshot {
  slug : String
  dir_name : String
  agent : @types.Agent?
} derive(Show)

///|
pub(all) struct RecoverySnapshot {
  zellij_live : ZellijLiveTargets
  open_prs : Array[OpenPR]
  local_agents : Array[LocalAgentSnapshot]
  persisted_tracked_prs : Array[@poller.TrackedPR]
  recovered_at : Int64
} derive(Show)

///|
pub(all) enum RecoveryAction {
  RegisterAgent(@types.Agent, Bool)
  RestorePRTracking(@poller.TrackedPR)
  TrackNewPR(
    pr_number~ : Int,
    agent_id~ : String,
    branch~ : String,
    parent_branch~ : String,
    pr_url~ : String,
    review~ : @poller.ReviewState,
    review_bodies~ : String,
    sha~ : String,
    ci_failed~ : Bool,
    created_at~ : Int64
  )
  SyncLifecycle(agent_id~ : String, pr~ : OpenPR, review~ : @poller.ReviewState)
  FinalizeOfflineAgent(agent_id~ : String)
} derive(Show)

///|
pub(all) struct RecoveryPlan {
  actions : Array[RecoveryAction]
} derive(Show)

///|
pub(all) struct RecoveryProvider {
  zellij_live : async (String, String) -> ZellijLiveTargets
  open_prs : async (String) -> Array[OpenPR]
  find_prs_by_head : async (String, String) -> Array[OpenPR]
  list_agent_containers : async (String) -> Array[String]
  list_agents_in_container : async (String, String) -> Array[String]
  read_agent_config : async (String, String, String) -> String
  get_agent_relative_workspace : (String, String) -> String
  list_lifecycle_ids : async (String) -> Array[String]
  read_lifecycle_content : async (String, String) -> String
  read_poller_state : async (String) -> Array[@poller.TrackedPR]
  write_poller_state : async (String, Array[@poller.TrackedPR]) -> Unit
  gh_poll_pr : async (Int) -> (
    Bool,
    @poller.ReviewState,
    String,
    Bool,
    String,
    Bool,
  )
}

///|
pub async fn find_pr_for_branch_in_provider(
  provider : RecoveryProvider,
  project_dir : String,
  branch : String,
) -> (Int, String)? {
  if branch.trim() == "" {
    return None
  }
  let prs = (provider.find_prs_by_head)(project_dir, branch)
  if prs.length() > 0 {
    Some((prs[0].pr_number, prs[0].url))
  } else {
    None
  }
}

///|
pub async fn find_agent_for_pr_in_lifecycle(
  provider : RecoveryProvider,
  project_dir : String,
  pr_number : Int,
) -> String? {
  let ids = (provider.list_lifecycle_ids)(project_dir)
  let needle = "\"pr_number\":" + pr_number.to_string()
  for id in ids {
    let content = (provider.read_lifecycle_content)(project_dir, id)
    if content == "" || !content.contains(needle) {
      continue
    }
    let json = @json.parse(content) catch { _ => continue }
    let obj = match json {
      Object(m) => m
      _ => continue
    }
    match obj.get("agent_id") {
      Some(String(id)) => return Some(id)
      _ => ()
    }
  }
  None
}

///|
pub fn parse_github_time_utc_sec(s : String) -> Int64? {
  Some(@tempo.DateTime::parse(s).to_unix_seconds()) catch {
    _ => None
  }
}

///|
pub fn parse_open_prs(output : String) -> Array[OpenPR] {
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
  if value != "" && !values.contains(value) {
    values.push(value)
  }
}

///|
pub fn default_agent_type(role : @types.Role) -> @types.AgentType {
  match role {
    @types.Role::Root => @types.AgentType::Claude
    @types.Role::TL => @types.AgentType::Claude
    @types.Role::Dev => @types.AgentType::Gemini
    @types.Role::Worker => @types.AgentType::Gemini
  }
}

///|
pub fn parse_agent_from_config(
  content : String,
  rel_workspace : String,
  fallback_slug : String,
) -> @types.Agent? {
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
  Some({
    agent_id: @types.AgentId(agent_id),
    role,
    agent_type: local_cfg.agent_type.unwrap_or(default_agent_type(role)),
    state: @types.AgentState::Active, // Initial assumption; caller reconciles with zellij
    parent: local_cfg.parent_id,
    terminal_target: local_cfg.terminal_target,
    host: @types.Host::Local,
    workspace,
    branch,
    spawn_depth: local_cfg.spawn_depth.unwrap_or(0),
  })
}

///|
pub fn is_local_target_alive(
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
pub fn inferred_next_round_from_lifecycle(
  lifecycle : @phase.DevLifecycle,
) -> Int {
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
pub fn recover_dev_lifecycle_for_pr(
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
pub fn make_shell_recovery_provider(
  capture : async (String, Array[String], String?) -> String,
) -> RecoveryProvider {
  {
    zellij_live: async fn(project_dir, session) {
      parse_zellij_live_targets(
        capture(
          "zellij",
          [
            "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
          ],
          Some(project_dir),
        ),
      )
    },
    open_prs: async fn(project_dir) {
      let open_pr_output = capture(
        "sh",
        [
          "-c", "gh pr list --json number,headRefName,baseRefName,url,createdAt --state open 2>/dev/null",
        ],
        Some(project_dir),
      )
      parse_open_prs(open_pr_output)
    },
    find_prs_by_head: async fn(project_dir, branch) {
      let output = capture(
        "gh",
        [
          "pr", "list", "--head", branch, "--state", "open", "--json", "number,headRefName,baseRefName,url,createdAt",
        ],
        Some(project_dir),
      )
      parse_open_prs(output)
    },
    list_agent_containers: fn(_project_dir) {
      ["worktrees", "agents", "inline"]
    },
    list_agents_in_container: async fn(project_dir, container) {
      let output = capture(
        "ls",
        ["-1", ".choir/" + container],
        Some(project_dir),
      )
      split_lines(output)
    },
    read_agent_config: async fn(project_dir, container, slug) {
      capture(
        "cat",
        [".choir/" + container + "/" + slug + "/.choir/config.local.toml"],
        Some(project_dir),
      )
    },
    get_agent_relative_workspace: fn(container, slug) {
      ".choir/" + container + "/" + slug
    },
    list_lifecycle_ids: async fn(project_dir) {
      let output = capture(
        "find",
        [".choir/kv", "-maxdepth", "1", "-type", "f", "-name", "lifecycle--*"],
        Some(project_dir),
      )
      let paths = split_lines(output)
      let ids = []
      let prefix = "lifecycle--"
      for path in paths {
        let parts = path.split("/")
        let filenames = []
        for part in parts {
          filenames.push(part)
        }
        if filenames.length() == 0 {
          continue
        }
        let filename = filenames[filenames.length() - 1].to_string()
        if filename.has_prefix(prefix) && filename.length() > prefix.length() {
          ids.push(filename[prefix.length():].to_string())
        }
      }
      ids
    },
    read_lifecycle_content: async fn(project_dir, id) {
      capture("cat", [".choir/kv/lifecycle--" + id], Some(project_dir))
    },
    read_poller_state: async fn(project_dir) {
      let content = capture(
        "cat",
        [".choir/poller_state.json"],
        Some(project_dir),
      )
      @poller.parse_tracked_prs_json(content)
    },
    write_poller_state: async fn(project_dir, tracked) {
      let buf = StringBuilder::new()
      buf.write_char('[')
      let entries = []
      for t in tracked {
        entries.push(t.to_json())
      }
      buf.write_string(entries.join(","))
      buf.write_char(']')
      let content = buf.to_string()
      let path = project_dir + "/.choir/poller_state.json"
      let script = "mkdir -p \"$(dirname " +
        @exec.quote(path) +
        ")\" && printf '%s' " +
        @exec.quote(content) +
        " > " +
        @exec.quote(path)
      ignore(@sys.system("sh -c " + @exec.quote(script)))
    },
    gh_poll_pr: @poller.gh_poll_pr,
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
fn find_registered_agent_for_branch_in_list(
  agents : Array[@types.Agent],
  branch : String,
  preferred_agent_id? : String? = None,
) -> @types.Agent? {
  match preferred_agent_id {
    Some(agent_id) =>
      for agent in agents {
        if agent.agent_id.to_string() == agent_id {
          return Some(agent)
        }
      }
    None => ()
  }
  for agent in agents {
    if agent.branch == branch || agent.agent_id.to_string() == branch {
      return Some(agent)
    }
  }
  None
}

///|
pub async fn plan_recovery(
  session : String,
  snapshot : RecoverySnapshot,
  gh_poll : async (Int) -> (
    Bool,
    @poller.ReviewState,
    String,
    Bool,
    String,
    Bool,
  ),
) -> RecoveryPlan {
  let actions = []
  let recovered_agents = []

  // 1. Local agents
  for local_agent in snapshot.local_agents {
    match local_agent.agent {
      Some(agent) => {
        let alive = is_local_target_alive(
          agent.terminal_target,
          session,
          snapshot.zellij_live,
        )
        let recovered = if alive {
          agent
        } else {
          { ..agent, state: @types.AgentState::Done, terminal_target: None }
        }
        recovered_agents.push(recovered)
        actions.push(RecoveryAction::RegisterAgent(recovered, alive))
        if !alive {
          actions.push(
            RecoveryAction::FinalizeOfflineAgent(
              agent_id=agent.agent_id.to_string(),
            ),
          )
        }
      }
      None => ()
    }
  }

  // 2. Open PRs
  for pr in snapshot.open_prs {
    let restored = find_persisted_tracked_pr(
      snapshot.persisted_tracked_prs,
      pr.pr_number,
      pr.branch,
    )
    match
      find_registered_agent_for_branch_in_list(
        recovered_agents,
        pr.branch,
        preferred_agent_id=restored.map(fn(tracked) { tracked.agent_id }),
      ) {
      Some(agent) =>
        match restored {
          Some(existing) => {
            actions.push(
              RecoveryAction::RestorePRTracking({
                ..existing,
                agent_id: agent.agent_id.to_string(),
                branch: pr.branch,
                parent_branch: pr.base,
                pr_url: pr.url,
              }),
            )
            actions.push(
              RecoveryAction::SyncLifecycle(
                agent_id=agent.agent_id.to_string(),
                pr~,
                review=existing.last_review_state,
              ),
            )
          }
          None => {
            let (_, review, sha, ci_failed, review_bodies, _) = gh_poll(
              pr.pr_number,
            )
            actions.push(
              RecoveryAction::TrackNewPR(
                pr_number=pr.pr_number,
                agent_id=agent.agent_id.to_string(),
                branch=pr.branch,
                parent_branch=pr.base,
                pr_url=pr.url,
                review~,
                review_bodies~,
                sha~,
                ci_failed~,
                created_at=match pr.created_sec {
                  Some(created_sec) => created_sec
                  None => snapshot.recovered_at
                },
              ),
            )
            actions.push(
              RecoveryAction::SyncLifecycle(
                agent_id=agent.agent_id.to_string(),
                pr~,
                review~,
              ),
            )
          }
        }
      None => ()
    }
  }

  { actions, }
}

///|
pub async fn discover_recovery_snapshot(
  provider : RecoveryProvider,
  project_dir : String,
  session : String,
) -> RecoverySnapshot {
  let zellij_live = (provider.zellij_live)(project_dir, session)
  let open_prs = (provider.open_prs)(project_dir)
  let persisted_tracked_prs = (provider.read_poller_state)(project_dir)
  let local_agents = []
  for dir_name in (provider.list_agent_containers)(project_dir) {
    let slugs = (provider.list_agents_in_container)(project_dir, dir_name)
    for slug in slugs {
      let content = (provider.read_agent_config)(project_dir, dir_name, slug)
      let agent = parse_agent_from_config(
        content,
        (provider.get_agent_relative_workspace)(dir_name, slug),
        slug,
      )
      local_agents.push(LocalAgentSnapshot::{ slug, dir_name, agent })
    }
  }
  {
    zellij_live,
    open_prs,
    local_agents,
    persisted_tracked_prs,
    recovered_at: @poller.now_sec(),
  }
}

///|
pub fn split_lines(output : String) -> Array[String] {
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
pub fn parse_zellij_live_targets(output : String) -> ZellijLiveTargets {
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
