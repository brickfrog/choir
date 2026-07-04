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
        Some(tracked) => tracked.review_mode
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
fn parent_poll_ci_escalation_prefix(
  tracked : @poller.TrackedPR,
  reviewer? : @types.Reviewer = @types.Reviewer::None,
  review_required? : Bool = true,
) -> String {
  if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(
      tracked,
      review_required~,
    ) {
    let reviewer_handle = reviewer.request_handle()
    "Review timeout already fired — no review in snapshot. Run request_review(pr_number: \"" +
    tracked.pr_number.to_string() +
    "\", reviewer: \"" +
    reviewer_handle +
    "\").\n\n"
  } else {
    ""
  }
}

///|
fn task_contract_for_agent(
  state : ServerState,
  agent_id : String,
) -> @types.TaskContract? {
  state.task_contract_for_agent(agent_id)
}

///|
fn repair_task_contract_for_agent(
  state : ServerState,
  agent_id : String,
) -> @types.TaskContract? {
  state.repair_task_contract_for_agent(agent_id)
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
    | @poller.PollEvent::FixesPushed(_)
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
  _review_mode : @types.ReviewMode,
) -> Bool {
  automerge_candidate_event(event)
}

///|
fn manual_thread_snapshot_event(event : @poller.PollEvent) -> Bool {
  match event {
    @poller.PollEvent::ReviewReceived(_, _)
    | @poller.PollEvent::ReviewTimeout(_)
    | @poller.PollEvent::PRReady(_)
    | @poller.PollEvent::CopilotIssueCommentSeen(_)
    | @poller.PollEvent::MergeReady(_) => true
    _ => false
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
    | @poller.PollEvent::ReviewThreadsResolved(_)
    | @poller.PollEvent::FixesPushed(_) => true
    _ =>
      manual_thread_snapshot_event(event) ||
      (
        automerge_enabled &&
        automerge_candidate_event_for_review_mode(event, review_mode)
      )
  }
}

///|
pub fn merge_execution_mode_for_request(
  req : @types.Request,
) -> @evidence.MergeExecutionMode {
  if request_bool_arg(req, "automerge").unwrap_or(false) {
    return @evidence.MergeExecutionMode::ServerAutomerge
  }
  @evidence.MergeExecutionMode::Manual
}

///|
pub fn pr_needs_automerge_sweep_attempt(
  pr : @poller.TrackedPR,
  gate_ready : Bool,
  automerge_enabled : Bool,
) -> Bool {
  pr.review_mode == @types.ReviewMode::Iterative &&
  pr.merged_at_unix == None &&
  gate_ready &&
  automerge_enabled &&
  pr.last_automerge_attempt_sha != pr.last_sha
}

///|
fn automerge_audit_policy_block_retryable_message(msg : String) -> Bool {
  let policy_msg = if msg.has_prefix("validation error: ") {
    msg["validation error: ".length():].to_owned()
  } else {
    msg
  }
  if !policy_msg.has_prefix("policy blocked: audit receipt gate blocked PR #") {
    return false
  }
  policy_msg.contains(": missing audit receipt for HEAD tree ") ||
  policy_msg.contains(": malformed audit receipt for HEAD tree ") ||
  policy_msg.contains(": stale audit receipt (")
}

///|
fn automerge_retryable_audit_policy_block(resp : @types.Response) -> String? {
  // Only classify gate failures that a re-run of /audit on the same HEAD can
  // resolve. `audit receipt for HEAD tree ... reports N finding(s)` requires new
  // commits; retrying automerge in a loop will just spin without progress.
  match resp.error_message() {
    Some(msg) if automerge_audit_policy_block_retryable_message(msg) =>
      Some(msg)
    _ => None
  }
}

///|
fn automerge_delivery_log_error_detail(resp : @types.Response) -> String {
  match resp.error_message() {
    Some(msg) =>
      " error=" + msg.replace(old="\n", new=" ").replace(old="\r", new=" ")
    None => ""
  }
}

///|
async fn ServerState::deliver_automerge_audit_policy_block(
  self : ServerState,
  tracked : @poller.TrackedPR,
  caller_id : String,
  message : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn : async (Int) -> Unit,
) -> Unit {
  try {
    let parent = self.registry.get(caller_id)
    ignore(
      self.durable_deliver_to_agent(
        parent,
        tracked.agent_id,
        "[AUTOMERGE BLOCKED] PR #" +
        tracked.pr_number.to_string() +
        " needs TL audit action: " +
        message,
        @types.Status::Failure,
        runner,
        sleep_fn~,
      ),
    )
  } catch {
    _ => ()
  }
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
  capture~ : async (@workspace.Command) -> (Int, String),
  git_capture~ : async (String, Array[String]) -> String,
  bd_capture~ : async (@workspace.Command) -> (Int, String),
  review_mode? : @types.ReviewMode? = None,
  hook_capture~ : async (String, String, String?) -> (Int, String),
  path_exists~ : (String) -> Bool,
  read_file~ : (String) -> String,
  hook_path_exists~ : (String) -> Bool,
  hook_xdg_config_home~ : String?,
  hook_home~ : String,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Bool {
  if tracked.merged_at_unix != None ||
    state.poller.merged_observed(tracked.pr_number) {
    return false
  }
  let review_mode = review_mode.unwrap_or(tracked.review_mode)
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
  match event {
    @poller.PollEvent::ReviewThreadsResolved(_) =>
      append_poller_delivery_line(
        state.append_file,
        state.config.project_dir,
        "automerge gate recheck pr=" +
        tracked.pr_number.to_string() +
        " event=review_threads_resolved",
      )
    _ => ()
  }
  let task_contract = match
    repair_task_contract_for_agent(state, tracked.agent_id) {
    Some(contract) => Some(contract)
    None => {
      // Missing task contract is a permanent block for this head — re-running
      // the sweep without a contract change cannot succeed, so stamp the
      // attempt sha to prevent every subsequent poll-delivery tick from
      // retrying and re-emitting the same log line.
      match state.poller.get(tracked.pr_number) {
        Some(current) =>
          state.poller.restore({
            ..current,
            last_automerge_attempt_sha: tracked.last_sha,
          })
        None => ()
      }
      append_poller_delivery_line(
        state.append_file,
        state.config.project_dir,
        "automerge blocked pr=" +
        tracked.pr_number.to_string() +
        " agent=" +
        tracked.agent_id +
        " reason=missing_server_task_contract",
      )
      return false
    }
  }
  let task_contract = @types.task_contract_with_normalized_verify(
    task_contract,
    state.config.moon_verify_target,
  )
  let verify_results = match task_contract {
    Some(contract) =>
      @evidence.verify_results_for_required_at_head_with_ci(
        state.config.project_dir,
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
  let default_branch = @tools.detect_default_branch_with_capture(
    state.config.project_dir,
    capture,
  )
  let audit_receipt_state = @tools.audit_receipt_advisory_state_for_tracked_pr(
    state.config.project_dir,
    tracked.parent_branch,
    default_branch,
    tracked.last_sha,
    tracked.first_seen,
    capture,
    read_file,
    path_exists,
  )
  let decision = @poller.merge_policy_decision_for_tracked_pr(
    tracked,
    unresolved_threads,
    task_contract~,
    review_mode~,
    verify_results~,
    reviewer=state.config.pr_policy.reviewer,
    skip_copilot_on_feature_branch=state.config.pr_policy.skip_copilot_on_feature_branch,
    default_branch~,
    audit_receipt_state~,
  )
  guard decision is @policy.MergeDecision::MergeNow(_) else { return false }
  let caller_id = match
    automerge_parent_caller_id_for_tracked_pr(state, tracked) {
    Some(value) => value
    None => return false
  }
  let previous_automerge_attempt_sha = match
    state.poller.get(tracked.pr_number) {
    Some(current) => current.last_automerge_attempt_sha
    None => ""
  }
  match state.poller.get(tracked.pr_number) {
    Some(current) =>
      state.poller.restore({
        ..current,
        last_automerge_attempt_sha: tracked.last_sha,
      })
    None => ()
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
    git_capture~,
    bd_capture~,
    hook_capture~,
    path_exists~,
    hook_path_exists~,
    hook_xdg_config_home~,
    hook_home~,
    sleep_fn~,
  )
  append_poller_delivery_line(
    state.append_file,
    state.config.project_dir,
    "automerge result pr=" +
    tracked.pr_number.to_string() +
    " status=" +
    resp.status_tag() +
    automerge_delivery_log_error_detail(resp),
  )
  match automerge_retryable_audit_policy_block(resp) {
    Some(msg) => {
      match state.poller.get(tracked.pr_number) {
        Some(current) =>
          state.poller.restore({
            ..current,
            last_automerge_attempt_sha: previous_automerge_attempt_sha,
          })
        None => ()
      }
      append_poller_delivery_line(
        state.append_file,
        state.config.project_dir,
        "automerge audit policy block pr=" +
        tracked.pr_number.to_string() +
        " retryable=true message=" +
        msg.replace(old="\n", new=" ").replace(old="\r", new=" "),
      )
      state.deliver_automerge_audit_policy_block(
        tracked, caller_id, msg, runner, sleep_fn,
      )
    }
    None => ()
  }
  resp.is_ok()
}

///|
