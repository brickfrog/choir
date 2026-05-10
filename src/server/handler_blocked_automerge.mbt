///|
/// Conservative matcher for the leaf-side gh timeout discipline.
///
/// Keep this intentionally substring-based and narrow: it requires the
/// explicit `[BLOCKED]` marker, a gh/review-thread term, and one of the stable
/// bounded-timeout signatures. Real work blockers such as compile failures
/// must not auto-merge just because the latest poller snapshot is clean.
fn blocked_gh_automerge_reason_matches(message : String) -> Bool {
  let lower = message.to_lower()
  let blocked_marker = lower.contains("[blocked]") ||
    lower.contains("blocked-on-gh")
  if !blocked_marker {
    return false
  }
  let bounded_timeout = lower.contains("bounded") ||
    lower.contains("timeout 30s") ||
    lower.contains("exit 124")
  if !bounded_timeout {
    return false
  }
  lower.contains("bounded-gh") ||
  lower.contains("gh api") ||
  lower.contains("`gh") ||
  lower.contains(" github") ||
  lower.contains("graphql") ||
  lower.contains("review-thread") ||
  lower.contains("review thread")
}

///|
fn blocked_gh_notify_request_parts(req : @types.Request) -> (String, String)? {
  if req.name != "notify_parent" {
    return None
  }
  let caller_id = match req.args.get("caller_id") {
    Some(value) if value != "" => value
    _ => return None
  }
  let message = match req.args.get("message") {
    Some(value) => value
    None => ""
  }
  if blocked_gh_automerge_reason_matches(message) {
    Some((caller_id, message))
  } else {
    None
  }
}

///|
fn blocked_gh_lifecycle_pr_number(lifecycle : @phase.AgentLifecycle) -> Int? {
  match lifecycle.workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(pr_number~, ..))
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number~, ..)
    )
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, ..)
    ) => Some(pr_number)
    _ => None
  }
}

///|
fn blocked_gh_latest_evidence_bundle(
  project_dir : String,
  agent_id : String,
) -> @types.EvaluationBundle {
  @evidence.evaluation_bundle_from_evidence(
    @evidence.replay_agent_evidence_records(project_dir, agent_id),
  )
}

///|
fn blocked_gh_poll_snapshot_ready(
  project_dir : String,
  tracked : @poller.TrackedPR,
) -> Bool {
  let bundle = blocked_gh_latest_evidence_bundle(project_dir, tracked.agent_id)
  let threads = @types.evaluation_latest_threads(bundle.signals)
  let latest_ci = @types.evaluation_latest_ci_rollup(bundle.signals)
  latest_ci == @types.EvaluationCiRollup::Success &&
  tracked.last_ci_rollup == @poller.CiRollupStatus::Success &&
  @poller.tl_tracked_pr_merge_gate_snapshot_ready(tracked, threads)
}

///|
fn blocked_gh_automerge_tracked_pr(
  state : ServerState,
  caller_id : String,
) -> @poller.TrackedPR? {
  let lifecycle = state.current_lifecycle(caller_id)
  let pr_number = match blocked_gh_lifecycle_pr_number(lifecycle) {
    Some(value) => value
    None => return None
  }
  match state.poller.get(pr_number) {
    Some(tracked) if tracked.agent_id == caller_id => Some(tracked)
    _ => None
  }
}

///|
fn blocked_gh_automerge_parent_caller_id(
  state : ServerState,
  tracked : @poller.TrackedPR,
) -> String? {
  Some(state.resolve_parent_for_delivery(tracked.agent_id).agent_id.to_string()) catch {
    _ => None
  }
}

///|
fn blocked_gh_automerge_merge_pr_request(
  tracked : @poller.TrackedPR,
  caller_id : String,
) -> @types.Request {
  let parent_branch = if tracked.parent_branch == "" {
    "main"
  } else {
    tracked.parent_branch
  }
  let args : Map[String, Json] = {
    "pr_number": tracked.pr_number.to_json(),
    "caller_id": caller_id.to_json(),
    "parent_branch": parent_branch.to_json(),
    "automerge": true.to_json(),
  }
  {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(args),
  }
}

///|
async fn ServerState::maybe_trigger_automerge_for_blocked_gh_notify(
  self : ServerState,
  req : @types.Request,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let (caller_id, _) = match blocked_gh_notify_request_parts(req) {
    Some(parts) => parts
    None => return false
  }
  let tracked = match blocked_gh_automerge_tracked_pr(self, caller_id) {
    Some(value) => value
    None => return false
  }
  if !automerge_enabled_for_agent(
      self.config,
      local_config_for_agent(self.config.project_dir, self.registry, caller_id),
    ) {
    return false
  }
  if !blocked_gh_poll_snapshot_ready(self.config.project_dir, tracked) {
    return false
  }
  let parent_caller_id = match
    blocked_gh_automerge_parent_caller_id(self, tracked) {
    Some(value) => value
    None => return false
  }
  append_poller_delivery_line(
    self.append_file,
    self.config.project_dir,
    "blocked-gh automerge attempt pr=" +
    tracked.pr_number.to_string() +
    " agent=" +
    tracked.agent_id,
  )
  let resp = self.handle_with_runner_and_capture(
    blocked_gh_automerge_merge_pr_request(tracked, parent_caller_id),
    runner~,
    capture~,
  )
  append_poller_delivery_line(
    self.append_file,
    self.config.project_dir,
    "blocked-gh automerge result pr=" +
    tracked.pr_number.to_string() +
    " status=" +
    resp.status_tag(),
  )
  resp.is_ok()
}
