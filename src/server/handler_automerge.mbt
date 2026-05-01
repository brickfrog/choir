///|
fn ServerState::request_with_review_mode_default(
  self : ServerState,
  req : @types.Request,
) -> @types.Request {
  if req.name != "merge_pr" || req.args.contains("review_mode") {
    return req
  }
  let review_mode = match request_int_arg(req, "pr_number") {
    Some(pr_number) =>
      match self.poller.get(pr_number) {
        Some(tracked) =>
          review_mode_for_agent(
            self.config,
            local_config_for_agent(
              self.config.project_dir,
              self.registry,
              tracked.agent_id,
            ),
          )
        None => self.config.review_mode
      }
    None => self.config.review_mode
  }
  let values : Map[String, Json] = {}
  req.args.each_json(fn(k, v) { values.set(k, v) })
  values.set("review_mode", review_mode.to_wire_string().to_json())
  { ..req, args: @types.RequestArgs::from_values(values) }
}

///|
/// When review-wait already timed out with no review in snapshot, CI-only parent lines must not read like ordinary progress.
fn parent_poll_ci_escalation_prefix(tracked : @poller.TrackedPR) -> String {
  if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
    "Review timeout already fired — no review in snapshot. Run: gh pr edit --add-reviewer @copilot\n\n"
  } else {
    ""
  }
}

///|
fn task_contract_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
) -> @types.TaskContract? {
  let agent_workspace = Some(registry.get(agent_id).workspace) catch {
    _ => None
  }
  @workspace.task_contract_for_agent_workspace(
    project_dir,
    agent_workspace,
    @phase.extract_slug(agent_id),
  )
}

///|
fn local_config_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
) -> @types.LocalConfig? {
  let agent_workspace = Some(registry.get(agent_id).workspace) catch {
    _ => None
  }
  let candidate_paths : Array[String] = []
  match agent_workspace {
    Some(w) =>
      if w != "" {
        candidate_paths.push(w + "/.choir/config.local.toml")
      }
    None => ()
  }
  let fallback_path = @workspace.worktree_path(
      project_dir,
      @phase.extract_slug(agent_id),
    ) +
    "/.choir/config.local.toml"
  if !candidate_paths.contains(fallback_path) {
    candidate_paths.push(fallback_path)
  }
  for path in candidate_paths {
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    match @config.parse_local_config(content) {
      Ok(local_cfg) => return Some(local_cfg)
      Err(_) => ()
    }
  }
  None
}

///|
pub fn automerge_enabled_for_agent(
  config : @types.Config,
  local_cfg : @types.LocalConfig?,
) -> Bool {
  match local_cfg {
    Some(cfg) =>
      match cfg.automerge {
        Some(value) => value
        None => config.automerge
      }
    None => config.automerge
  }
}

///|
pub fn review_mode_for_agent(
  config : @types.Config,
  local_cfg : @types.LocalConfig?,
) -> @types.ReviewMode {
  match local_cfg {
    Some(cfg) =>
      match cfg.review_mode {
        Some(value) => value
        None => config.review_mode
      }
    None => config.review_mode
  }
}

///|
fn automerge_candidate_event(event : @poller.PollEvent) -> Bool {
  match event {
    @poller.PollEvent::PRReady(_)
    | @poller.PollEvent::CIFailureCleared(_)
    | @poller.PollEvent::CILatestHeadRollupSucceeded(_)
    | @poller.PollEvent::CopilotIssueCommentSeen(_)
    | @poller.PollEvent::MergeReady(_)
    | @poller.PollEvent::ReviewThreadsResolved(_) => true
    _ => false
  }
}

///|
fn automerge_candidate_event_for_review_mode(
  event : @poller.PollEvent,
  review_mode : @types.ReviewMode,
) -> Bool {
  match event {
    @poller.PollEvent::FixesPushed(_) =>
      review_mode == @types.ReviewMode::SinglePass
    _ => automerge_candidate_event(event)
  }
}

///|
pub fn should_fetch_unresolved_threads_for_pending_event(
  event : @poller.PollEvent,
  automerge_enabled : Bool,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> Bool {
  match event {
    @poller.PollEvent::CIFailureCleared(_)
    | @poller.PollEvent::CILatestHeadRollupSucceeded(_)
    | @poller.PollEvent::ReviewThreadsResolved(_) => true
    @poller.PollEvent::FixesPushed(_) =>
      review_mode == @types.ReviewMode::SinglePass ||
      (
        automerge_enabled &&
        automerge_candidate_event_for_review_mode(event, review_mode)
      )
    _ =>
      automerge_enabled &&
      automerge_candidate_event_for_review_mode(event, review_mode)
  }
}

///|
pub fn merge_execution_mode_for_request(
  req : @types.Request,
) -> @evidence.MergeExecutionMode {
  if request_bool_arg(req, "force").unwrap_or(false) {
    return @evidence.MergeExecutionMode::ForceOverride
  }
  if request_bool_arg(req, "automerge").unwrap_or(false) {
    return @evidence.MergeExecutionMode::ServerAutomerge
  }
  @evidence.MergeExecutionMode::Manual
}

///|
fn automerge_parent_caller_id_for_tracked_pr(
  state : ServerState,
  tracked : @poller.TrackedPR,
) -> String? {
  Some(state.resolve_parent_for_delivery(tracked.agent_id).agent_id.to_string()) catch {
    _ => None
  }
}

///|
fn automerge_merge_pr_request(
  tracked : @poller.TrackedPR,
  caller_id : String,
  review_mode : @types.ReviewMode,
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
pub async fn maybe_trigger_automerge_for_pending_event(
  state : ServerState,
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR,
  unresolved_threads : Int?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> Bool {
  if !automerge_candidate_event_for_review_mode(event, review_mode) {
    return false
  }
  let local_cfg = local_config_for_agent(
    state.config.project_dir,
    state.registry,
    tracked.agent_id,
  )
  if !automerge_enabled_for_agent(state.config, local_cfg) {
    return false
  }
  let task_contract = task_contract_for_agent(
    state.config.project_dir,
    state.registry,
    tracked.agent_id,
  )
  let verify_results = match task_contract {
    Some(contract) =>
      @evidence.verify_results_for_required_at_head(
        state.config.project_dir,
        tracked.agent_id,
        contract.verify,
        tracked.last_sha,
      )
    None => []
  }
  let decision = @poller.merge_policy_decision_for_tracked_pr(
    tracked,
    unresolved_threads,
    task_contract~,
    review_mode~,
    verify_results~,
  )
  guard decision is @policy.MergeDecision::MergeNow(_) else { return false }
  let caller_id = match
    automerge_parent_caller_id_for_tracked_pr(state, tracked) {
    Some(value) => value
    None => return false
  }
  append_poller_delivery_line(
    state.append_file,
    state.config.project_dir,
    "automerge attempt pr=" +
    tracked.pr_number.to_string() +
    " agent=" +
    tracked.agent_id,
  )
  let resp = state.handle_with_runner_and_capture(
    automerge_merge_pr_request(tracked, caller_id, review_mode),
    runner~,
    capture~,
  )
  append_poller_delivery_line(
    state.append_file,
    state.config.project_dir,
    "automerge result pr=" +
    tracked.pr_number.to_string() +
    " status=" +
    resp.status_tag(),
  )
  resp.is_ok()
}

///|
