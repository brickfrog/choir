///|
pub(all) struct ZellijLiveTargets {
  tabs : Array[String]
  panes : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct OpenPR {
  pr_number : Int
  branch : String
  base : String
  url : String
  created_sec : Int64?
} derive(Debug, Eq)

///|
pub(all) enum KnownPRState {
  Open
  Merged
  Closed
} derive(Debug, Eq)

///|
pub impl Show for KnownPRState with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub(all) struct KnownPR {
  pr_number : Int
  branch : String
  base : String
  url : String
  created_sec : Int64?
  state : KnownPRState
} derive(Debug, Eq)

///|
pub(all) struct LocalAgentSnapshot {
  slug : String
  dir_name : String
  agent : @types.Agent?
} derive(Debug)

///|
/// Live zellij tab/pane names used to decide whether agent terminal targets are still attached.
pub(all) struct RecoveryPanesSnapshot {
  live : ZellijLiveTargets
} derive(Debug)

///|
/// GitHub review/CI row for a PR, collected by the host before reconciliation (replaces inline `gh_poll` in planning).
pub(all) struct RecoveryPrPollRow {
  review : @poller.ReviewState
  sha : String
  ci_rollup : @poller.CiRollupStatus
  review_bodies : String
  copilot_issue_comment_seen : Bool
} derive(Debug, Eq)

///|
pub(all) struct RecoveryPrsSnapshot {
  open_prs : Array[OpenPR]
  /// Entries for open PRs that need fresh GitHub state (no matching persisted track row, and a reconcilable local agent).
  polls : Map[Int, RecoveryPrPollRow]
  /// Targeted status lookups for known tracked PRs or known agent branches that are no longer open.
  resolved_prs : Array[KnownPR]
} derive(Debug)

///|
pub(all) struct RecoveryFilesSnapshot {
  local_agents : Array[LocalAgentSnapshot]
  persisted_tracked_prs : Array[@poller.TrackedPR]
} derive(Debug)

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
    ci_rollup~ : @poller.CiRollupStatus,
    copilot_issue_comment_seen~ : Bool,
    created_at~ : Int64
  )
  SyncLifecycle(agent_id~ : String, pr~ : OpenPR, review~ : @poller.ReviewState)
  FinalizeMergedAgent(
    agent_id~ : String,
    pr_number~ : Int,
    branch~ : String,
    parent_branch~ : String,
    pr_url~ : String
  )
  FinalizeOfflineAgent(agent_id~ : String)
} derive(Debug)

///|
/// Result of one [`build_agent_recovery_actions`] pass; [`discover_recovery_input`] stores it so [`plan_recovery`] does not repeat that work.
pub(all) struct PrebuiltAgentPhase {
  recovered_agents : Array[@types.Agent]
  agent_stage_actions : Array[RecoveryAction]
} derive(Debug)

///|
/// Fully materialized recovery input: host adapters populate each snapshot; `plan_recovery` stays pure.
pub(all) struct RecoveryReconcileInput {
  panes : RecoveryPanesSnapshot
  prs : RecoveryPrsSnapshot
  files : RecoveryFilesSnapshot
  recovered_at : Int64
  /// `Some` when built by [`discover_recovery_input`] (reuses agent phase in [`plan_recovery`]).
  prebuilt_agent_phase : PrebuiltAgentPhase?
} derive(Debug)

///|
pub(all) struct RecoveryPlan {
  actions : Array[RecoveryAction]
} derive(Debug)

///|
pub(all) struct RecoveryProvider {
  zellij_live : async (String, String) -> ZellijLiveTargets
  open_prs : async (String) -> Array[OpenPR]
  find_prs_by_head : async (String, String) -> Array[OpenPR]
  find_prs_by_head_any : async (String, String) -> Array[KnownPR]
  find_pr_by_number : async (String, Int) -> KnownPR?
  list_agent_containers : async (String) -> Array[String]
  list_agents_in_container : async (String, String) -> Array[String]
  read_agent_config : async (String, String, String) -> String
  get_agent_relative_workspace : (String, String) -> String
  list_lifecycle_ids : async (String) -> Array[String]
  read_lifecycle_content : async (String, String) -> String
  read_poller_state : async (String) -> Array[@poller.TrackedPR]
  write_poller_state : async (String, Array[@poller.TrackedPR]) -> Unit
  gh_poll_pr : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
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
pub fn parse_open_prs(output : String) -> Array[OpenPR] raise {
  let prs = []
  let json = @json.parse(output)
  let arr = match json {
    Json::Array(items) => items
    _ =>
      raise @types.ChoirError::validation_error("open PRs is not a JSON array")
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
fn known_pr_state_from_fields(fields : Map[String, Json]) -> KnownPRState {
  let merged_at = match fields.get("mergedAt") {
    Some(String(v)) => v.trim().to_string()
    _ => ""
  }
  if merged_at != "" {
    return KnownPRState::Merged
  }
  match fields.get("state") {
    Some(String("OPEN")) => KnownPRState::Open
    Some(String(_)) => KnownPRState::Closed
    _ => KnownPRState::Closed
  }
}

///|
fn known_pr_from_fields(fields : Map[String, Json]) -> KnownPR? {
  let pr_number = match fields.get("number") {
    Some(Number(n, ..)) => n.to_int()
    _ => return None
  }
  let branch = match fields.get("headRefName") {
    Some(String(v)) => v
    _ => return None
  }
  let base = match fields.get("baseRefName") {
    Some(String(v)) => v
    _ => return None
  }
  let url = match fields.get("url") {
    Some(String(v)) => v
    _ => return None
  }
  let created_sec = match fields.get("createdAt") {
    Some(String(v)) => parse_github_time_utc_sec(v)
    _ => None
  }
  Some({
    pr_number,
    branch,
    base,
    url,
    created_sec,
    state: known_pr_state_from_fields(fields),
  })
}

///|
pub fn parse_known_prs(output : String) -> Array[KnownPR] raise {
  let prs = []
  let json = @json.parse(output)
  let arr = match json {
    Json::Array(items) => items
    _ =>
      raise @types.ChoirError::validation_error("known PRs is not a JSON array")
  }
  for item in arr {
    match item {
      Json::Object(fields) =>
        match known_pr_from_fields(fields) {
          Some(pr) => prs.push(pr)
          None => ()
        }
      _ => ()
    }
  }
  prs
}

///|
pub fn parse_known_pr(output : String) -> KnownPR raise {
  let json = @json.parse(output)
  match json {
    Json::Object(fields) =>
      match known_pr_from_fields(fields) {
        Some(pr) => pr
        None =>
          raise @types.ChoirError::validation_error("invalid known PR object")
      }
    _ => raise @types.ChoirError::validation_error("known PR is not an object")
  }
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
        "gh",
        [
          "pr", "list", "--state", "open", "--json", "number,headRefName,baseRefName,url,createdAt",
        ],
        Some(project_dir),
      )
      if open_pr_output == "" {
        return []
      }
      parse_open_prs(open_pr_output) catch {
        e => {
          @sys.write_stderr(
            "gh parse_open_prs open error (returning empty): " +
            @types.choir_error_message_from_caught(e) +
            "\n",
          )
          []
        }
      }
    },
    find_prs_by_head: async fn(project_dir, branch) {
      let output = capture(
        "gh",
        [
          "pr", "list", "--head", branch, "--state", "open", "--json", "number,headRefName,baseRefName,url,createdAt",
        ],
        Some(project_dir),
      )
      if output == "" {
        return []
      }
      parse_open_prs(output) catch {
        e => {
          @sys.write_stderr(
            "gh parse_open_prs head error (returning empty): " +
            @types.choir_error_message_from_caught(e) +
            "\n",
          )
          []
        }
      }
    },
    find_prs_by_head_any: async fn(project_dir, branch) {
      let output = capture(
        "gh",
        [
          "pr", "list", "--head", branch, "--state", "all", "--json", "number,headRefName,baseRefName,url,state,mergedAt,createdAt",
        ],
        Some(project_dir),
      )
      if output == "" {
        return []
      }
      parse_known_prs(output) catch {
        e => {
          @sys.write_stderr(
            "gh parse_known_prs error (returning empty): " +
            @types.choir_error_message_from_caught(e) +
            "\n",
          )
          []
        }
      }
    },
    find_pr_by_number: async fn(project_dir, pr_number) {
      let output = capture(
        "gh",
        [
          "pr",
          "view",
          pr_number.to_string(),
          "--json",
          "number,headRefName,baseRefName,url,state,mergedAt,createdAt",
        ],
        Some(project_dir),
      )
      if output == "" {
        return None
      }
      Some(parse_known_pr(output)) catch {
        _ => None
      }
    },
    list_agent_containers: fn(_project_dir) {
      ["worktrees", "agents", "inline"]
    },
    list_agents_in_container: async fn(project_dir, container) {
      let rel = ".choir/" + container
      if !@sys.path_entry_exists(project_dir + "/" + rel) {
        return []
      }
      let output = capture("ls", ["-1", rel], Some(project_dir))
      split_lines(output)
    },
    read_agent_config: async fn(project_dir, container, slug) {
      let rel = ".choir/" + container + "/" + slug + "/.choir/config.local.toml"
      if !@sys.path_exists(project_dir + "/" + rel) {
        return ""
      }
      capture("cat", [rel], Some(project_dir))
    },
    get_agent_relative_workspace: fn(container, slug) {
      ".choir/" + container + "/" + slug
    },
    list_lifecycle_ids: async fn(project_dir) {
      if !@sys.path_entry_exists(project_dir + "/.choir/kv") {
        return []
      }
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
      let rel = ".choir/kv/lifecycle--" + id
      if !@sys.path_exists(project_dir + "/" + rel) {
        return ""
      }
      capture("cat", [rel], Some(project_dir))
    },
    read_poller_state: async fn(project_dir) {
      if !@sys.path_exists(project_dir + "/.choir/poller_state.json") {
        return []
      }
      let content = capture(
        "cat",
        [".choir/poller_state.json"],
        Some(project_dir),
      )
      if content == "" {
        return []
      }
      @poller.parse_tracked_prs_json(content) catch {
        e => {
          // Quarantine the corrupt file for operator inspection, then
          // fall back to empty tracked-PR state. The daemon rebuilds
          // poller state from GitHub on the next tick.
          let quarantine = project_dir +
            "/.choir/poller_state.json.corrupt-" +
            @env.now().reinterpret_as_int64().to_string()
          ignore(@sys.write_file_atomic(quarantine, content))
          ignore(
            @sys.delete_file_sync(project_dir + "/.choir/poller_state.json"),
          )
          @sys.write_stderr(
            "poller_state.json parse error (quarantined to " +
            quarantine +
            ", returning empty): " +
            @types.choir_error_message_from_caught(e) +
            "\n",
          )
          []
        }
      }
    },
    write_poller_state: async fn(project_dir, tracked) {
      @async.sleep(0)
      let buf = StringBuilder::new()
      buf.write_char('[')
      let entries = []
      for t in tracked {
        entries.push(t.to_json())
      }
      buf.write_string(entries.join(","))
      buf.write_char(']')
      let content = buf.to_string()
      ignore(@sys.create_dir_all(project_dir + "/.choir"))
      ignore(
        @sys.write_file_atomic(
          project_dir + "/.choir/poller_state.json",
          content,
        ),
      )
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
fn open_pr_contains(
  open_prs : Array[OpenPR],
  pr_number : Int,
  branch : String,
) -> Bool {
  for pr in open_prs {
    if pr.pr_number == pr_number && pr.branch == branch {
      return true
    }
  }
  false
}

///|
fn open_pr_branch_exists(open_prs : Array[OpenPR], branch : String) -> Bool {
  for pr in open_prs {
    if pr.branch == branch {
      return true
    }
  }
  false
}

///|
fn resolved_prs_contains(
  resolved_prs : Array[KnownPR],
  pr_number : Int,
) -> Bool {
  for pr in resolved_prs {
    if pr.pr_number == pr_number {
      return true
    }
  }
  false
}

///|
fn resolved_prs_contains_branch(
  resolved_prs : Array[KnownPR],
  branch : String,
) -> Bool {
  for pr in resolved_prs {
    if pr.branch == branch {
      return true
    }
  }
  false
}

///|
fn known_pr_sort_key(pr : KnownPR) -> Int64 {
  match pr.created_sec {
    Some(ts) => ts
    None => pr.pr_number.to_int64()
  }
}

///|
fn known_pr_priority(state : KnownPRState) -> Int {
  match state {
    KnownPRState::Merged => 2
    KnownPRState::Open => 1
    KnownPRState::Closed => 0
  }
}

///|
fn preferred_known_pr(left : KnownPR, right : KnownPR) -> KnownPR {
  let left_priority = known_pr_priority(left.state)
  let right_priority = known_pr_priority(right.state)
  if right_priority > left_priority {
    return right
  }
  if right_priority < left_priority {
    return left
  }
  if known_pr_sort_key(right) > known_pr_sort_key(left) {
    right
  } else {
    left
  }
}

///|
fn best_known_pr_for_branch(prs : Array[KnownPR]) -> KnownPR? {
  let mut best : KnownPR? = None
  for pr in prs {
    best = match best {
      Some(current) => Some(preferred_known_pr(current, pr))
      None => Some(pr)
    }
  }
  best
}

///|
fn preferred_agent_id_for_known_pr(
  recovered_agents : Array[@types.Agent],
  persisted_tracked_prs : Array[@poller.TrackedPR],
  pr : KnownPR,
) -> String? {
  let restored = find_persisted_tracked_pr(
    persisted_tracked_prs,
    pr.pr_number,
    pr.branch,
  )
  match
    find_registered_agent_for_branch_in_list(
      recovered_agents,
      pr.branch,
      preferred_agent_id=restored.map(fn(tracked) { tracked.agent_id }),
    ) {
    Some(agent) => Some(agent.agent_id.to_string())
    None => restored.map(fn(tracked) { tracked.agent_id })
  }
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
fn build_agent_recovery_actions(
  session : String,
  live : ZellijLiveTargets,
  local_agents : Array[LocalAgentSnapshot],
) -> (Array[@types.Agent], Array[RecoveryAction]) {
  let actions = []
  let recovered_agents = []
  for local_agent in local_agents {
    match local_agent.agent {
      Some(agent) => {
        let alive = is_local_target_alive(agent.terminal_target, session, live)
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
  (recovered_agents, actions)
}

///|
/// Maps [`RecoveryProvider::gh_poll_pr`] output into [`RecoveryPrPollRow`].
/// Ignores `poll_ok` (gh parse / exit quality) and `pr_is_open` (used in full poller, not recovery planning).
fn recovery_pr_poll_row_from_gh_tuple(
  tuple : (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
) -> RecoveryPrPollRow {
  let (poll_ok, review, sha, ci_rollup, review_bodies, pr_is_open, copilot_seen) = tuple
  ignore(poll_ok)
  ignore(pr_is_open)
  {
    review,
    sha,
    ci_rollup,
    review_bodies,
    copilot_issue_comment_seen: copilot_seen,
  }
}

///|
/// When `prs.polls` has no row (caller omission or discover gap), still emit TrackNewPR using conservative defaults so reconciliation does not drop the PR.
fn recovery_pr_poll_row_fallback() -> RecoveryPrPollRow {
  {
    review: @poller.ReviewState::None_,
    sha: "",
    ci_rollup: @poller.CiRollupStatus::Unknown,
    review_bodies: "",
    copilot_issue_comment_seen: false,
  }
}

///|
pub fn plan_recovery(
  session : String,
  input : RecoveryReconcileInput,
) -> RecoveryPlan {
  let (recovered_agents, actions) = match input.prebuilt_agent_phase {
    Some(phase) => (phase.recovered_agents, phase.agent_stage_actions)
    None =>
      build_agent_recovery_actions(
        session,
        input.panes.live,
        input.files.local_agents,
      )
  }

  // 2. Open PRs
  for pr in input.prs.open_prs {
    let restored = find_persisted_tracked_pr(
      input.files.persisted_tracked_prs,
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
            let row = match input.prs.polls.get(pr.pr_number) {
              Some(r) => r
              None => recovery_pr_poll_row_fallback()
            }
            actions.push(
              RecoveryAction::TrackNewPR(
                pr_number=pr.pr_number,
                agent_id=agent.agent_id.to_string(),
                branch=pr.branch,
                parent_branch=pr.base,
                pr_url=pr.url,
                review=row.review,
                review_bodies=row.review_bodies,
                sha=row.sha,
                ci_rollup=row.ci_rollup,
                copilot_issue_comment_seen=row.copilot_issue_comment_seen,
                created_at=match pr.created_sec {
                  Some(created_sec) => created_sec
                  None => input.recovered_at
                },
              ),
            )
            actions.push(
              RecoveryAction::SyncLifecycle(
                agent_id=agent.agent_id.to_string(),
                pr~,
                review=row.review,
              ),
            )
          }
        }
      None =>
        match restored {
          Some(existing) =>
            actions.push(
              RecoveryAction::RestorePRTracking({
                ..existing,
                branch: pr.branch,
                parent_branch: pr.base,
                pr_url: pr.url,
              }),
            )
          None => {
            let row = match input.prs.polls.get(pr.pr_number) {
              Some(r) => r
              None => recovery_pr_poll_row_fallback()
            }
            actions.push(
              RecoveryAction::TrackNewPR(
                pr_number=pr.pr_number,
                agent_id="orphan:pr:" + pr.pr_number.to_string(),
                branch=pr.branch,
                parent_branch=pr.base,
                pr_url=pr.url,
                review=row.review,
                review_bodies=row.review_bodies,
                sha=row.sha,
                ci_rollup=row.ci_rollup,
                copilot_issue_comment_seen=row.copilot_issue_comment_seen,
                created_at=match pr.created_sec {
                  Some(created_sec) => created_sec
                  None => input.recovered_at
                },
              ),
            )
          }
        }
    }
  }

  for pr in input.prs.resolved_prs {
    if pr.state != KnownPRState::Merged {
      continue
    }
    match
      preferred_agent_id_for_known_pr(
        recovered_agents,
        input.files.persisted_tracked_prs,
        pr,
      ) {
      Some(agent_id) =>
        actions.push(
          RecoveryAction::FinalizeMergedAgent(
            agent_id~,
            pr_number=pr.pr_number,
            branch=pr.branch,
            parent_branch=pr.base,
            pr_url=pr.url,
          ),
        )
      None => ()
    }
  }

  { actions, }
}

///|
pub async fn discover_recovery_input(
  provider : RecoveryProvider,
  project_dir : String,
  session : String,
) -> RecoveryReconcileInput {
  // Recovery snapshot start (before any zellij/gh/fs polling); used as `created_at` fallback in `plan_recovery`.
  let recovered_at = @poller.now_sec()
  let live = (provider.zellij_live)(project_dir, session)
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
  let prebuilt = build_agent_recovery_actions(session, live, local_agents)
  let recovered_preview = prebuilt.0
  let prebuilt_phase : PrebuiltAgentPhase = {
    recovered_agents: prebuilt.0,
    agent_stage_actions: prebuilt.1,
  }
  let polls : Map[Int, RecoveryPrPollRow] = Map::new()
  let resolved_prs : Array[KnownPR] = []
  for pr in open_prs {
    match
      find_persisted_tracked_pr(persisted_tracked_prs, pr.pr_number, pr.branch) {
      Some(_) => ()
      None =>
        match
          find_registered_agent_for_branch_in_list(
            recovered_preview,
            pr.branch,
            preferred_agent_id=None,
          ) {
          Some(_) => {
            let poll_tuple = (provider.gh_poll_pr)(pr.pr_number, false)
            polls.set(
              pr.pr_number,
              recovery_pr_poll_row_from_gh_tuple(poll_tuple),
            )
          }
          None => ()
        }
    }
  }
  for tracked in persisted_tracked_prs {
    if open_pr_contains(open_prs, tracked.pr_number, tracked.branch) {
      continue
    }
    match (provider.find_pr_by_number)(project_dir, tracked.pr_number) {
      Some(pr) =>
        if !resolved_prs_contains(resolved_prs, pr.pr_number) {
          resolved_prs.push(pr)
        }
      None => ()
    }
  }
  for agent in recovered_preview {
    if agent.role != @types.Role::Dev || agent.branch.trim() == "" {
      continue
    }
    if resolved_prs_contains_branch(resolved_prs, agent.branch) {
      continue
    }
    if open_pr_branch_exists(open_prs, agent.branch) {
      continue
    }
    match
      best_known_pr_for_branch(
        (provider.find_prs_by_head_any)(project_dir, agent.branch),
      ) {
      Some(pr) =>
        if pr.state != KnownPRState::Open &&
          !resolved_prs_contains(resolved_prs, pr.pr_number) {
          resolved_prs.push(pr)
        }
      None => ()
    }
  }
  {
    panes: { live, },
    prs: { open_prs, polls, resolved_prs },
    files: { local_agents, persisted_tracked_prs },
    recovered_at,
    prebuilt_agent_phase: Some(prebuilt_phase),
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
