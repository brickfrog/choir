///|
/// Conservative matcher for the leaf-side gh timeout discipline.
///
/// Keep this intentionally narrow. Auto-merge on a [BLOCKED] notify only when
/// the leaf's own message simultaneously names: (a) the [BLOCKED]/blocked-on-gh
/// marker, (b) the `bounded` discipline keyword from the gh-discipline prompt,
/// (c) a timeout signature (`timed out` / `timeout 30s` / `exit 124`), AND
/// (d) a review/gh context term. Real work blockers — compile failures,
/// unresolved merge conflicts, work-correctness issues — must not match just
/// because the latest poller snapshot looks clean. Loosening any of these
/// gates is how we false-positive auto-merge a broken PR.
fn blocked_gh_automerge_reason_matches(message : String) -> Bool {
  let lower = message.to_lower()
  if !(lower.contains("[blocked]") || lower.contains("blocked-on-gh")) {
    return false
  }
  if !lower.contains("bounded") {
    return false
  }
  if !(lower.contains("timed out") ||
    lower.contains("timeout 30s") ||
    lower.contains("exit 124")) {
    return false
  }
  lower.contains("review-state") ||
  lower.contains("review-thread") ||
  lower.contains("review thread") ||
  lower.contains("gh api") ||
  lower.contains("gh pr") ||
  lower.contains("github") ||
  lower.contains("graphql")
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
  review_mode : @types.ReviewMode,
  reviewer : @types.Reviewer,
  skip_copilot_on_feature_branch : Bool,
  default_branch : String,
) -> Bool {
  let bundle = blocked_gh_latest_evidence_bundle(project_dir, tracked.agent_id)
  let threads = @types.evaluation_latest_threads(bundle.signals)
  let latest_ci = @types.evaluation_latest_ci_rollup(bundle.signals)
  // Match the normal merge gate: clear if rollup is Success or NoChecks.
  let evidence_ci_clear = latest_ci == @types.EvaluationCiRollup::Success ||
    latest_ci == @types.EvaluationCiRollup::NoChecks
  let tracked_ci_clear = tracked.last_ci_rollup ==
    @poller.CiRollupStatus::Success ||
    tracked.last_ci_rollup == @poller.CiRollupStatus::NoChecks
  let review_required = @policy.review_required_for_branch(
    reviewer,
    skip_copilot_on_feature_branch,
    tracked.parent_branch,
    default_branch,
  )
  evidence_ci_clear &&
  tracked_ci_clear &&
  @poller.tl_tracked_pr_merge_gate_snapshot_ready(
    tracked,
    threads,
    review_mode~,
    review_required~,
  )
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
  review_mode : @types.ReviewMode,
) -> @types.Request {
  let parent_branch = if tracked.parent_branch == "" {
    "main"
  } else {
    tracked.parent_branch
  }
  // Pass the leaf's effective review_mode through to merge_pr; without it
  // the tool defaults to SinglePass, which can diverge from the snapshot
  // gating that just decided this PR is ready to merge.
  let args : Map[String, Json] = {
    "pr_number": tracked.pr_number.to_json(),
    "caller_id": caller_id.to_json(),
    "parent_branch": parent_branch.to_json(),
    "automerge": true.to_json(),
    "review_mode": review_mode.to_wire_string().to_json(),
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
  let local_cfg = local_config_for_agent(
    self.config.project_dir,
    self.registry,
    caller_id,
  )
  if !automerge_enabled_for_agent(self.config, local_cfg) {
    return false
  }
  let review_mode = tracked.review_mode
  if !blocked_gh_poll_snapshot_ready(
      self.config.project_dir,
      tracked,
      review_mode,
      self.config.pr_policy.reviewer,
      self.config.pr_policy.skip_copilot_on_feature_branch,
      "",
    ) {
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
    blocked_gh_automerge_merge_pr_request(
      tracked, parent_caller_id, review_mode,
    ),
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
