///|
pub struct StatusSnapshot {
  agents : Array[AgentStatus]
  timestamp : Int64
} derive(Show)

///|
pub struct AgentStatus {
  agent_id : String
  role : String
  agent_type : String
  state : String
  workflow_state : String
  parent : String?
  children : Array[String]
  branch : String
  workspace : String
  tracked_pr : TrackedPRInfo?
  blocked_summary : String?
} derive(Show)

///|
pub struct TrackedPRInfo {
  pr_number : Int
  url : String
  branch : String
  parent_branch : String
  review_state : String
  ci_failed : Bool
  first_seen : Int64
} derive(Show)

///|
pub fn build_status_snapshot(
  project_dir : String,
  registry : @registry.AgentRegistry,
  poller_state : @poller.PollerState,
) -> StatusSnapshot {
  let agents = registry.list()
  let agent_statuses = []
  for agent in agents {
    let lifecycle = @phase.read_or_default_lifecycle(
      project_dir,
      agent.agent_id.to_string(),
      agent.role,
    )
    let tracked_pr = find_tracked_pr_for_agent(
      poller_state,
      agent.agent_id.to_string(),
    )
    let children = registry.children(agent.agent_id.to_string())
    let children_ids = []
    for child in children {
      children_ids.push(child.agent_id.to_string())
    }
    let blocked_summary = compute_blocked_summary(lifecycle, tracked_pr)
    agent_statuses.push({
      agent_id: agent.agent_id.to_string(),
      role: agent.role.to_string(),
      agent_type: agent.agent_type.to_string(),
      state: agent.state.to_string(),
      workflow_state: workflow_state_to_string(lifecycle.workflow),
      parent: agent.parent,
      children: children_ids,
      branch: agent.branch,
      workspace: agent.workspace,
      tracked_pr,
      blocked_summary,
    })
  }
  { agents: agent_statuses, timestamp: 0L }
}

///|
fn find_tracked_pr_for_agent(
  poller_state : @poller.PollerState,
  agent_id : String,
) -> TrackedPRInfo? {
  for tracked in poller_state.tracked.values() {
    if tracked.agent_id == agent_id {
      return Some({
        pr_number: tracked.pr_number,
        url: tracked.pr_url,
        branch: tracked.branch,
        parent_branch: tracked.parent_branch,
        review_state: review_state_to_string(tracked.last_review_state),
        ci_failed: tracked.last_ci_failed,
        first_seen: tracked.first_seen,
      })
    }
  }
  None
}

///|
fn compute_blocked_summary(
  lifecycle : @phase.AgentLifecycle,
  _tracked_pr : TrackedPRInfo?,
) -> String? {
  let policy = @phase.lifecycle_exit_policy(lifecycle)
  match policy {
    @phase.LifecycleExitPolicy::Blocked(reason~) => {
      let msg = match reason {
        @phase.ExitBlockReason::ChangesRequested =>
          "Blocked: Changes requested on PR"
        @phase.ExitBlockReason::OwnPROpen(number~) =>
          "Blocked: Own PR #" + number.to_string()
      }
      Some(msg)
    }
    @phase.LifecycleExitPolicy::Deferred(message~) => Some(message)
    @phase.LifecycleExitPolicy::Allowed => None
  }
}

///|
fn workflow_state_to_string(workflow : @phase.WorkflowState) -> String {
  match workflow {
    @phase.WorkflowState::Supervisor(supervisor) =>
      supervisor_lifecycle_to_string(supervisor)
    @phase.WorkflowState::Dev(dev) => dev_lifecycle_to_string(dev)
    @phase.WorkflowState::Worker(worker) => worker_lifecycle_to_string(worker)
  }
}

///|
fn supervisor_lifecycle_to_string(
  lifecycle : @phase.SupervisorLifecycle,
) -> String {
  match lifecycle {
    @phase.SupervisorLifecycle::Planning => "Planning"
    @phase.SupervisorLifecycle::Dispatching => "Dispatching"
    @phase.SupervisorLifecycle::Supervising(children~) =>
      "Supervising " + children.length().to_string() + " children"
    @phase.SupervisorLifecycle::OwnPRFiled(number~) =>
      "Own PR filed (#" + number.to_string() + ")"
    @phase.SupervisorLifecycle::Done => "Done"
    @phase.SupervisorLifecycle::Failed(reason~) =>
      "Failed: " + @phase.failure_reason_message(reason)
  }
}

///|
fn dev_lifecycle_to_string(lifecycle : @phase.DevLifecycle) -> String {
  match lifecycle {
    @phase.DevLifecycle::Working => "Working"
    @phase.DevLifecycle::ReviewOwned(pr_number~, state~) =>
      "Review owned: PR #" +
      pr_number.to_string() +
      " (" +
      review_ownership_to_string(state) +
      ")"
    @phase.DevLifecycle::ChangesRequested(pr_number~, next_round~) =>
      "Changes requested: PR #" +
      pr_number.to_string() +
      " (round " +
      next_round.to_string() +
      ")"
    @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, state~) =>
      "Exit deferred: PR #" +
      pr_number.to_string() +
      " (" +
      review_ownership_to_string(state) +
      ")"
    @phase.DevLifecycle::Exitable => "Exitable"
    @phase.DevLifecycle::Done(reason~) =>
      "Done: " + finalize_reason_to_string(reason)
    @phase.DevLifecycle::Failed(reason~) =>
      "Failed: " + @phase.failure_reason_message(reason)
  }
}

///|
fn worker_lifecycle_to_string(lifecycle : @phase.WorkerLifecycle) -> String {
  match lifecycle {
    @phase.WorkerLifecycle::Working => "Working"
    @phase.WorkerLifecycle::Exitable => "Exitable"
    @phase.WorkerLifecycle::Done(reason~) =>
      "Done: " + finalize_reason_to_string(reason)
    @phase.WorkerLifecycle::Failed(reason~) =>
      "Failed: " + @phase.failure_reason_message(reason)
  }
}

///|
fn review_ownership_to_string(state : @phase.ReviewOwnership) -> String {
  match state {
    @phase.ReviewOwnership::OpenUnreviewed(url~) =>
      if url == "" {
        "Open"
      } else {
        "Open at " + url
      }
    @phase.ReviewOwnership::FixesAwaitingReview(round~) =>
      "Awaiting review (round " + round.to_string() + ")"
    @phase.ReviewOwnership::ApprovedAwaitingMerge => "Approved, awaiting merge"
  }
}

///|
fn review_state_to_string(state : @poller.ReviewState) -> String {
  match state {
    @poller.ReviewState::None_ => "none"
    @poller.ReviewState::Approved => "approved"
    @poller.ReviewState::ChangesRequested => "changes_requested"
    @poller.ReviewState::Commented => "commented"
  }
}

///|
fn finalize_reason_to_string(reason : @phase.FinalizeReason) -> String {
  match reason {
    @phase.FinalizeReason::Shutdown => "Shutdown"
    @phase.FinalizeReason::Merged => "Merged"
    @phase.FinalizeReason::DisconnectFinalized => "Disconnect"
    @phase.FinalizeReason::RecoveredDone => "Recovered"
  }
}
