///|
/// Decision payload returned by [`should_auto_rescue`] when a leaf in
/// `Dev(ReviewOwned)` exits cleanly while its PR still has unresolved review
/// threads. Carries the exact PR number and unresolved-thread count so the
/// dispatcher can build a concrete rescue task body.
pub(all) struct AutoRescueDecision {
  pr_number : Int
  unresolved_count : Int
} derive(Debug, Eq)

///|
pub impl Show for AutoRescueDecision with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
/// Pure policy: should the disconnect handler auto-spawn `rescue_leaf` instead
/// of failing the agent?
///
/// Returns `Some(decision)` only when ALL of:
/// - `workflow` is `Dev(ReviewOwned(pr_number, _))`
/// - `exit_code == 0` (clean exit, not a crash)
/// - `unresolved_thread_count > 0`
/// - `!pr_merged`
/// - `!parent_shutdown_issued`
///
/// Otherwise returns `None` and the disconnect handler proceeds with its
/// normal Fail-branch behavior.
pub fn should_auto_rescue(
  workflow : @phase.WorkflowState,
  exit_code : Int,
  unresolved_thread_count : Int,
  pr_merged : Bool,
  parent_shutdown_issued : Bool,
) -> AutoRescueDecision? {
  guard workflow
    is @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(pr_number~, ..)
    ) else {
    return None
  }
  if exit_code != 0 {
    return None
  }
  if unresolved_thread_count <= 0 {
    return None
  }
  if pr_merged {
    return None
  }
  if parent_shutdown_issued {
    return None
  }
  Some({ pr_number, unresolved_count: unresolved_thread_count })
}

///|
/// Build the rescue-leaf task body referencing concrete PR number, branch, and
/// unresolved-thread count. Centralized so both the wiring code and tests can
/// assert on the exact text.
pub fn auto_rescue_task_body(
  decision : AutoRescueDecision,
  branch : String,
) -> String {
  "Address the " +
  decision.unresolved_count.to_string() +
  " remaining unresolved review threads on PR #" +
  decision.pr_number.to_string() +
  " for branch " +
  branch +
  ". Resolve each thread via the GraphQL resolveReviewThread mutation after pushing fixes. Do not exit until zero unresolved threads remain."
}

///|
/// Parent-facing message emitted when auto-rescue fires. Distinguishable from
/// the usual `[FAILED]` banner so a parent supervisor can see the durable
/// safety net engaged.
pub fn auto_rescue_parent_message(
  agent_id : String,
  decision : AutoRescueDecision,
) -> String {
  "[AUTO-RESCUE TRIGGERED] " +
  agent_id +
  " exited cleanly while PR #" +
  decision.pr_number.to_string() +
  " still had " +
  decision.unresolved_count.to_string() +
  " unresolved review thread(s); spawning rescue leaf to address them."
}

///|
/// Slug for the rescue leaf spawned by auto-rescue. Includes a timestamp
/// suffix so multiple auto-rescues for the same parent do not collide on
/// branch name (`<parent>.<slug>`).
pub fn auto_rescue_slug(now_unix_sec : Int64) -> String {
  "auto-rescue-" + now_unix_sec.to_string()
}

///|
/// Evaluate the auto-rescue policy and dispatch `rescue_leaf` if all gates
/// pass. Returns `true` when the rescue path took ownership of teardown
/// (caller must skip its normal Fail finalization); `false` when the policy
/// rejected or the dispatch failed.
///
/// Effect-architecture notes:
/// - All host I/O (GraphQL fetch, rescue spawn) goes through the injected
///   `runner` and `capture` adapters; no direct `@sys`/`@process` calls.
/// - On dispatch failure the caller falls through to the existing Fail path
///   so an agent never silently disappears.
pub async fn ServerState::try_auto_rescue_review_owned(
  self : ServerState,
  agent_id : String,
  agent : @types.Agent,
  exit_code : Int,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  // Scope is strictly Dev leaves with a parent. Top-level/orphan agents are
  // never auto-rescued — the existing Fail path handles them.
  if agent.role != @types.Role::Dev {
    return false
  }
  let parent_id = match agent.parent {
    Some(p) => p
    None => return false
  }
  let lifecycle = self.current_lifecycle(agent_id)
  // Both signals are derivable from the workflow itself when we are in the
  // disconnect Fail branch:
  //   - `Dev(ReviewOwned(_))`  ⇒ merge has not been observed (else the
  //     workflow would already be `Dev(Done(reason=Merged))`).
  //   - `Dev(ReviewOwned(_))`  ⇒ parent has not issued a shutdown directive
  //     (else the workflow would be `Dev(ExitRequestedDeferred(..))`).
  // Threading them as explicit policy inputs keeps the gate testable in
  // isolation without inventing a parallel state model.
  let pr_merged = false
  let parent_shutdown_issued = false
  // Probe the policy with a placeholder thread count so we can short-circuit
  // before paying for the GraphQL round-trip when the workflow is not
  // `Dev(ReviewOwned)` or any non-thread gate already rejects.
  let pre_decision = should_auto_rescue(
    lifecycle.workflow,
    exit_code,
    1,
    pr_merged,
    parent_shutdown_issued,
  )
  let pr_number = match pre_decision {
    Some(d) => d.pr_number
    None => return false
  }
  let (owner, repo) = match
    @tools.fetch_gh_repo_owner_name(self.config.project_dir, capture) {
    Some(pair) => pair
    None => return false
  }
  let (unresolved_count, _formatted) = @tools.fetch_unresolved_review_threads_with_repo(
    pr_number,
    owner,
    repo,
    self.config.project_dir,
    capture,
  )
  let decision = match
    should_auto_rescue(
      lifecycle.workflow,
      exit_code,
      unresolved_count,
      pr_merged,
      parent_shutdown_issued,
    ) {
    Some(d) => d
    None => return false
  }
  let rescue_args : @tools.RescueLeafArgs = {
    task: auto_rescue_task_body(decision, agent.branch),
    task_contract: @types.TaskContract::empty(),
    caller_id: parent_id,
    from_agent_id: agent_id,
    new_slug: auto_rescue_slug(@poller.now_sec()),
    // Auto-rescue uses Claude regardless of the failing leaf's agent type:
    // codex is the cohort that triggers this path, and rescuing it with
    // codex would re-enter the same premature-exit bug.
    agent_type: @types.AgentType::Claude,
    parent_session_id: None,
  }
  let response = @tools.interpret_rescue_leaf(
    rescue_args,
    self.config.project_dir,
    self.config.terminal_session,
    runner,
    capture,
    Some(self.registry),
    Some(self.poller),
    extra_mcp_servers_json=self.config.extra_mcp_servers_json,
    shell_command=self.config.shell_command,
    listen_uds=self.config.listen_uds,
    listen_tcp=self.config.listen_tcp,
    tcp_auth_token=self.config.tcp_auth_token,
  )
  match response {
    @types.Response::Err(detail) => {
      @moontrace.warn("auto-rescue dispatch failed", fields=[
        @moontrace.field("agent", agent_id),
        @moontrace.field("pr", decision.pr_number),
        @moontrace.field("error", detail),
      ])
      false
    }
    _ => {
      // Append a typed lifecycle event so the event log distinguishes
      // auto-rescue from a manual Fail at this transition. The lifecycle
      // itself was already mutated by `interpret_rescue_leaf` (handoff +
      // mark superseded); we record the trigger only.
      let post = self.current_lifecycle(agent_id)
      ignore(
        append_lifecycle_event(
          self.config.project_dir,
          agent_id,
          lifecycle,
          post,
          @types.LifecycleTrigger::AutoRescueTriggered,
        ),
      )
      try {
        let parent = self.resolve_parent_by_id(parent_id)
        ignore(
          self.durable_deliver_to_agent(
            parent,
            agent_id,
            auto_rescue_parent_message(agent_id, decision),
            @types.Status::Info,
            runner,
          ),
        )
      } catch {
        _ => ()
      }
      true
    }
  }
}
