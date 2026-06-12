///|
/// Daemon-side bead summary cache: lazily refreshed (TTL below) with a
/// staleness timestamp surfaced in the snapshot. Deliberately not a sync
/// engine — two `bd` list calls, parsed and cached.
pub(all) struct TuiBeadsCache {
  mut taken_at_ms : Int64?
  mut summaries : Array[@types.TuiBeadSummary]
  mut refresh_in_flight : Bool
}

///|
pub fn TuiBeadsCache::new() -> TuiBeadsCache {
  { taken_at_ms: None, summaries: [], refresh_in_flight: false }
}

///|
pub let tui_beads_cache_ttl_ms : Int64 = 30_000L

///|
fn tui_run_started_at_unix(run_id : String) -> Int64? {
  let mut first = ""
  for segment in run_id.split("-") {
    first = segment.to_owned()
    break
  }
  if first == "" {
    return None
  }
  let parsed = @string.parse_int(first) catch { _ => return None }
  if parsed > 0 {
    Some(parsed.to_int64())
  } else {
    None
  }
}

///|
fn tui_supervisor_agent(registry : @registry.AgentRegistry) -> @types.Agent? {
  let mut fallback : @types.Agent? = None
  for agent in registry.list() {
    if agent.role == @types.Role::Root {
      return Some(agent)
    }
    if agent.role == @types.Role::TL && agent.parent is None && fallback is None {
      fallback = Some(agent)
    }
  }
  fallback
}

///|
fn tui_supervisor_wave(lifecycle : @phase.AgentLifecycle?) -> Int? {
  match lifecycle {
    Some(
      {
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(wave~, ..)
        ),
        ..,
      }
    )
    | Some(
      {
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::WaveComplete(wave~, ..)
        ),
        ..,
      }
    ) => Some(wave)
    _ => None
  }
}

///|
fn tui_sorted_tracked_prs(
  poller_state : @poller.PollerState,
) -> Array[@poller.TrackedPR] {
  let prs : Array[@poller.TrackedPR] = []
  for tracked in poller_state.tracked.values() {
    prs.push(tracked)
  }
  // Insertion sort by PR number: tracked sets are small and Map iteration
  // order is not meaningful for an ordered queue view.
  for i = 1; i < prs.length(); i = i + 1 {
    let current = prs[i]
    let mut j = i - 1
    while j >= 0 && prs[j].pr_number > current.pr_number {
      prs[j + 1] = prs[j]
      j = j - 1
    }
    prs[j + 1] = current
  }
  prs
}

///|
fn tui_copilot_skipped_reason(
  reviewer : @types.Reviewer,
  skip_copilot_on_feature_branch : Bool,
  parent_branch : String,
  default_branch : String,
) -> String? {
  match reviewer {
    @types.Reviewer::None => return None
    @types.Reviewer::Copilot | @types.Reviewer::Named(_) => ()
  }
  let parent = parent_branch.trim().to_owned()
  let default = default_branch.trim().to_owned()
  if skip_copilot_on_feature_branch &&
    parent != "" &&
    default != "" &&
    parent != default {
    Some("skipped (feature br " + parent + ")")
  } else {
    None
  }
}

///|
fn tui_review_state(state : @poller.ReviewState) -> @types.TuiReviewState {
  match state {
    @poller.ReviewState::None_ => @types.TuiReviewState::ReviewNone
    @poller.ReviewState::Approved => @types.TuiReviewState::ReviewApproved
    @poller.ReviewState::ChangesRequested =>
      @types.TuiReviewState::ReviewChangesRequested
    @poller.ReviewState::Commented => @types.TuiReviewState::ReviewCommented
  }
}

///|
fn tui_ci_rollup(rollup : @poller.CiRollupStatus) -> @types.TuiCiRollup {
  match rollup {
    @poller.CiRollupStatus::Unknown => @types.TuiCiRollup::CiUnknown
    @poller.CiRollupStatus::NoChecks => @types.TuiCiRollup::CiNoChecks
    @poller.CiRollupStatus::InProgress => @types.TuiCiRollup::CiInProgress
    @poller.CiRollupStatus::Success => @types.TuiCiRollup::CiSuccess
    @poller.CiRollupStatus::Failure => @types.TuiCiRollup::CiFailure
  }
}

///|
fn tui_mergeable(mergeable : @poller.Mergeable) -> @types.TuiMergeable {
  match mergeable {
    @poller.Mergeable::Mergeable => @types.TuiMergeable::TuiMergeable
    @poller.Mergeable::Conflicting => @types.TuiMergeable::TuiConflicting
    @poller.Mergeable::Unknown => @types.TuiMergeable::TuiMergeableUnknown
  }
}

///|
fn tui_merge_state_status(
  status : @poller.MergeStateStatus,
) -> @types.TuiMergeStateStatus {
  match status {
    @poller.MergeStateStatus::Clean =>
      @types.TuiMergeStateStatus::MergeStateClean
    @poller.MergeStateStatus::Unstable =>
      @types.TuiMergeStateStatus::MergeStateUnstable
    @poller.MergeStateStatus::Blocked =>
      @types.TuiMergeStateStatus::MergeStateBlocked
    @poller.MergeStateStatus::HasHooks =>
      @types.TuiMergeStateStatus::MergeStateHasHooks
    @poller.MergeStateStatus::Behind =>
      @types.TuiMergeStateStatus::MergeStateBehind
    @poller.MergeStateStatus::Unknown =>
      @types.TuiMergeStateStatus::MergeStateUnknown
    @poller.MergeStateStatus::Dirty =>
      @types.TuiMergeStateStatus::MergeStateDirty
  }
}

///|
fn ServerState::tui_snapshot_pr(
  self : ServerState,
  tracked : @poller.TrackedPR,
  default_branch : String,
) -> @types.TuiSnapshotPr {
  let unresolved_threads : Int? = if tracked.unresolved_thread_ids_fetched {
    Some(tracked.unresolved_thread_ids.length())
  } else {
    None
  }
  let task_contract = @types.task_contract_with_normalized_verify(
    self.task_contract_for_agent(tracked.agent_id),
    self.config.moon_verify_target,
  )
  let verify_results = match task_contract {
    Some(contract) =>
      @evidence.verify_results_for_required_at_head_with_ci(
        self.config.project_dir,
        tracked.agent_id,
        contract.verify,
        tracked.last_sha,
        @types.task_contract_verify_satisfied_by_ci(contract),
        ci_rollup=@poller.evaluation_ci_rollup_from_snapshot(
          tracked.last_ci_rollup,
        ),
      )
    None => []
  }
  let reviewer = self.config.pr_policy.reviewer
  let skip_copilot = self.config.pr_policy.skip_copilot_on_feature_branch
  // Same blocking rule as the agent-facing wave_state: a missing task
  // contract blocks the gate for everything except root's own PR.
  let merge_gate_ready = if task_contract is None && tracked.agent_id != "root" {
    false
  } else {
    match
      @poller.merge_policy_decision_for_tracked_pr(
        tracked,
        unresolved_threads,
        task_contract~,
        review_mode=tracked.review_mode,
        verify_results~,
        reviewer~,
        skip_copilot_on_feature_branch=skip_copilot,
        default_branch~,
      ) {
      @policy.MergeDecision::MergeNow(_) => true
      _ => false
    }
  }
  {
    pr_number: tracked.pr_number,
    agent_id: tracked.agent_id,
    branch: tracked.branch,
    parent_branch: tracked.parent_branch,
    pr_url: tracked.pr_url,
    review_state: tui_review_state(tracked.last_review_state),
    ci_rollup: tui_ci_rollup(tracked.last_ci_rollup),
    mergeable: tui_mergeable(tracked.mergeable),
    merge_state_status: tui_merge_state_status(tracked.merge_state_status),
    unresolved_threads,
    merged_at_unix: tracked.merged_at_unix,
    copilot_issue_comment_seen: tracked.copilot_issue_comment_seen,
    copilot_skipped_reason: tui_copilot_skipped_reason(
      reviewer,
      skip_copilot,
      tracked.parent_branch,
      default_branch,
    ),
    merge_gate_ready,
    consecutive_failures: tracked.consecutive_failures,
    backoff_until: tracked.backoff_until,
    fixes_pushed_at: tracked.fixes_pushed_at,
  }
}

///|
/// Assemble the canonical snapshot from in-memory ServerState. Zero network
/// I/O by construction: PR review/CI fields come from the poller's tracked
/// state (as fresh as the last tick — `prs_as_of_ms`), unresolved thread
/// counts from the poller's cached thread refs, bead summaries from the
/// daemon-side cache, and the recent event slice from the journal ring.
pub fn ServerState::build_tui_snapshot(
  self : ServerState,
  now_ms : Int64,
  lifecycle_reader? : ((String) -> @phase.AgentLifecycle?)? = None,
  default_branch? : String = "",
) -> @types.TuiSnapshot {
  let project_dir = self.config.project_dir
  let read_lifecycle = match lifecycle_reader {
    Some(f) => f
    None =>
      fn(agent_id : String) { @phase.read_lifecycle(project_dir, agent_id) }
  }
  let agents : Array[@types.TuiSnapshotAgent] = []
  for agent in self.registry.list() {
    let agent_id = agent.agent_id.to_string()
    let lifecycle = read_lifecycle(agent_id)
    let (lifecycle_label, lifecycle_updated_unix) = match lifecycle {
      Some(lc) => (lc.workflow_label(), Some(lc.last_updated_unix_sec))
      None =>
        (
          @phase.workflow_state_label(@phase.default_workflow_state(agent.role)),
          None,
        )
    }
    let beads_issue_id = match self.task_contract_for_agent(agent_id) {
      Some(contract) => contract.beads_issue_id
      None => @workspace.beads_issue_id_for_agent(project_dir, agent)
    }
    agents.push({
      agent_id,
      role: agent.role,
      agent_type: agent.agent_type,
      parent: agent.parent,
      workspace: agent.workspace,
      branch: agent.branch,
      terminal_target: match agent.terminal_target {
        Some(target) => Some(target.to_string())
        None => None
      },
      state: agent.state,
      spawn_depth: agent.spawn_depth,
      alive: self.registry.is_alive(agent_id).unwrap_or(false),
      lifecycle: lifecycle_label,
      lifecycle_updated_unix,
      tdd_phase: self.leaf_tdd_phase_for_agent(agent_id),
      last_tool_call: self.registry.last_tool_call(agent_id),
      beads_issue_id,
    })
  }
  let supervisor = tui_supervisor_agent(self.registry)
  let wave : @types.TuiSnapshotWave = match supervisor {
    Some(agent) => {
      let supervisor_id = agent.agent_id.to_string()
      {
        run_id: self.run_id,
        wave: tui_supervisor_wave(read_lifecycle(supervisor_id)),
        integration_branch: agent.branch,
        started_at_unix: tui_run_started_at_unix(self.run_id),
        supervisor_id: Some(supervisor_id),
      }
    }
    None =>
      {
        run_id: self.run_id,
        wave: None,
        integration_branch: "",
        started_at_unix: tui_run_started_at_unix(self.run_id),
        supervisor_id: None,
      }
  }
  let prs : Array[@types.TuiSnapshotPr] = []
  for tracked in tui_sorted_tracked_prs(self.poller) {
    prs.push(self.tui_snapshot_pr(tracked, default_branch))
  }
  {
    schema_version: @types.tui_snapshot_schema_version,
    taken_at_ms: now_ms,
    wave,
    agents,
    prs,
    prs_as_of_ms: self.poller_vitals.last_tick_at_ms,
    beads: self.tui_beads_cache.summaries,
    beads_as_of_ms: self.tui_beads_cache.taken_at_ms,
    poller: {
      ..self.poller_vitals,
      tracked_prs: self.poller.tracked.length(),
      last_evt_age_sec: self.journal.last_event_age_sec(now_ms),
    },
    journal_seq: self.journal.latest_seq(),
    recent_events: self.journal.recent(),
  }
}

///|
fn tui_beads_list_commands(project_dir : String) -> Array[@workspace.Command] {
  [
    {
      program: "bd",
      args: ["ready", "--json", "--limit", "0"],
      workdir: Some(project_dir),
    },
    {
      program: "bd",
      args: ["list", "--json", "--status", "in_progress", "--limit", "0"],
      workdir: Some(project_dir),
    },
  ]
}

///|
/// Lazily refresh the daemon-side bead summary cache. No-op inside the TTL.
/// Emits BeadSummaryChanged for new or changed summaries.
pub async fn ServerState::refresh_tui_beads_cache_if_stale(
  self : ServerState,
  now_ms : Int64,
  bd_capture : async (@workspace.Command) -> (Int, String),
) -> Unit {
  match self.tui_beads_cache.taken_at_ms {
    Some(taken) if now_ms - taken < tui_beads_cache_ttl_ms => return
    _ => ()
  }
  if self.tui_beads_cache.refresh_in_flight {
    return
  }
  self.tui_beads_cache.refresh_in_flight = true
  let summaries : Array[@types.TuiBeadSummary] = []
  let seen : Map[String, Bool] = {}
  let mut captured_any = false
  for command in tui_beads_list_commands(self.config.project_dir) {
    let (code, output) = bd_capture(command)
    if code != 0 {
      continue
    }
    captured_any = true
    match @tools.parse_beads_issues_json(output) {
      Ok(issues) =>
        for issue in issues {
          if seen.contains(issue.id) {
            continue
          }
          seen.set(issue.id, true)
          summaries.push({
            issue_id: issue.id,
            status: issue.status,
            title: issue.title,
            assignee: issue.assignee,
          })
        }
      Err(_) => ()
    }
  }
  if !captured_any {
    self.tui_beads_cache.refresh_in_flight = false
    return
  }
  let previous : Map[String, @types.TuiBeadSummary] = {}
  for summary in self.tui_beads_cache.summaries {
    previous.set(summary.issue_id, summary)
  }
  for summary in summaries {
    let changed = match previous.get(summary.issue_id) {
      Some(old) => old != summary
      None => true
    }
    if changed {
      self.emit_tui_event(
        @types.TuiEvent::BeadSummaryChanged(
          issue_id=summary.issue_id,
          status=summary.status,
          title=summary.title,
        ),
      )
    }
  }
  for entry in previous {
    let (issue_id, _) = entry
    if !seen.contains(issue_id) {
      self.emit_tui_event(@types.TuiEvent::BeadRemoved(issue_id~))
    }
  }
  self.tui_beads_cache.summaries = summaries
  self.tui_beads_cache.taken_at_ms = Some(now_ms)
  self.tui_beads_cache.refresh_in_flight = false
}

///|
/// Default branch for copilot-skip rendering and the merge-gate policy,
/// resolved once per server process via local git metadata (no network).
pub async fn ServerState::tui_default_branch_cached(
  self : ServerState,
  capture : async (@workspace.Command) -> (Int, String),
) -> String {
  if !self.config.pr_policy.skip_copilot_on_feature_branch {
    return ""
  }
  match self.tui_default_branch {
    Some(value) if value != "" => value
    Some(_) | None => {
      let value = @tools.detect_default_branch_with_capture(
        self.config.project_dir,
        capture,
      )
      self.tui_default_branch = Some(value)
      value
    }
  }
}

///|
/// Poller-owned refresh for TUI caches that require process capture. Snapshot
/// requests read these fields without running commands.
pub async fn ServerState::refresh_tui_snapshot_caches_for_poller_tick(
  self : ServerState,
  now_sec : Int64,
  capture : async (@workspace.Command) -> (Int, String),
) -> Unit {
  ignore(self.tui_default_branch_cached(capture))
  self.refresh_tui_beads_cache_if_stale(now_sec * 1000L, capture)
}
