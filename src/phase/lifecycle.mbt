///|
pub(all) enum FinalizeReason {
  Shutdown
  Merged
  DisconnectFinalized
  RecoveredDone
  /// Prior leaf finished after a rescue handoff; not a hard failure.
  RescuedByReplacement
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum FailureReason {
  UnexpectedDisconnect
  WatchdogTimeout
  ParentFailureNotification
  ChildFailure(message~ : String)
  RecoveredFailed
  ModelAtCapacity
  McpInitializeFailure
  ParentKilled
  BlockedByReview
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn FailureReason::to_wire_string(self : FailureReason) -> String {
  match self {
    UnexpectedDisconnect => "unexpected_disconnect"
    WatchdogTimeout => "watchdog_timeout"
    ParentFailureNotification => "parent_failure_notification"
    ChildFailure(message~) => "child_failure: " + message
    RecoveredFailed => "recovered_failed"
    ModelAtCapacity => "model_at_capacity"
    McpInitializeFailure => "mcp_initialize_failure"
    ParentKilled => "parent_killed"
    BlockedByReview => "blocked_by_review"
  }
}

///|
pub(all) enum ExitBlockReason {
  ChangesRequested
  OwnPROpen(number~ : Int, url~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ReviewOwnership {
  OpenUnreviewed(url~ : String)
  FixesAwaitingReview(round~ : Int)
  ApprovedAwaitingMerge
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ChildLifecycleSummary {
  Working
  ReviewOwned(pr_number~ : Int, state~ : ReviewOwnership)
  ChangesRequested(pr_number~ : Int, next_round~ : Int)
  ExitRequestedDeferred(pr_number~ : Int, state~ : ReviewOwnership)
  Exitable
  Done
  Failed(reason~ : FailureReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ChildLifecycle {
  child_id : String
  slug : String
  branch : String
  agent_type : @types.AgentType
  summary : ChildLifecycleSummary
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SupervisorLifecycle {
  Planning
  Dispatching
  Supervising(children~ : Array[ChildLifecycle], wave~ : Int)
  WaveComplete(wave~ : Int, children~ : Array[ChildLifecycle])
  OwnPRFiled(number~ : Int, url~ : String)
  Done
  Failed(reason~ : FailureReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum DevLifecycle {
  Working
  ReviewOwned(pr_number~ : Int, state~ : ReviewOwnership)
  ChangesRequested(pr_number~ : Int, next_round~ : Int)
  ExitRequestedDeferred(pr_number~ : Int, state~ : ReviewOwnership)
  Exitable
  Done(reason~ : FinalizeReason)
  Failed(reason~ : FailureReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum WorkerLifecycle {
  Working
  Exitable
  Done(reason~ : FinalizeReason)
  Failed(reason~ : FailureReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum WorkflowState {
  Supervisor(SupervisorLifecycle)
  Dev(DevLifecycle)
  Worker(WorkerLifecycle)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ProcessState {
  Connected
  Finalizing(reason~ : FinalizeReason)
  Finalized(reason~ : FinalizeReason)
  Failed(reason~ : FailureReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentLifecycle {
  agent_id : String
  role : @types.Role
  process : ProcessState
  workflow : WorkflowState
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Side effects produced by lifecycle orchestration; interpreted by the host
/// (`interpret_lifecycle_effects`) to perform persistence. When `registry` is
/// provided to the interpreter, a successful `PersistLifecycle` also updates
/// that agent's row if it is already registered (same idea as `persist_lifecycle`).
pub(all) enum LifecycleEffect {
  PersistLifecycle(lifecycle~ : AgentLifecycle)
  AppendLifecycleEvent(
    agent_id~ : String,
    from_lc~ : AgentLifecycle,
    to_lc~ : AgentLifecycle,
    trigger~ : @types.LifecycleTrigger
  )
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum LifecycleExitPolicy {
  Blocked(reason~ : ExitBlockReason)
  Deferred(message~ : String)
  Allowed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum LifecycleDisconnectPolicy {
  Preserve
  Fail(reason~ : FailureReason)
  FinalizeDone(reason~ : FinalizeReason)
  Ignore
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum DevLifecycleEvent {
  PRCreated(pr_number~ : Int, url~ : String)
  ReviewReceived(pr_number~ : Int, body~ : String)
  ReviewApproved(pr_number~ : Int)
  FixesPushed(pr_number~ : Int, sha~ : String)
  ExitRequested
  MergeObserved(pr_number~ : Int)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SupervisorEvent {
  ChildSpawned(child~ : ChildLifecycle)
  ChildUpdated(
    child_id~ : String,
    summary~ : ChildLifecycleSummary,
    agent_type~ : @types.AgentType?
  )
  ChildRemoved(child_id~ : String)
  ChildFailed(child_id~ : String, reason~ : FailureReason)
  AllChildrenComplete
  OwnPRFiled(number~ : Int, url~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
fn review_summary_message(pr_number : Int, state : ReviewOwnership) -> String {
  match state {
    OpenUnreviewed(url~) => {
      let suffix = if url == "" { "" } else { " at " + url }
      "PR filed (" + pr_number.to_string() + ")" + suffix
    }
    FixesAwaitingReview(round~) =>
      "PR " +
      pr_number.to_string() +
      " awaiting re-review (round " +
      round.to_string() +
      ")"
    ApprovedAwaitingMerge =>
      "PR " + pr_number.to_string() + " approved and awaiting merge"
  }
}

///|
fn next_round_for_review(state : ReviewOwnership) -> Int {
  match state {
    OpenUnreviewed(_) => 1
    FixesAwaitingReview(round~) => round + 1
    ApprovedAwaitingMerge => 1
  }
}

///|
pub fn lifecycle_key(agent_id : String) -> String {
  "lifecycle--" + sanitize_branch(agent_id)
}

///|
pub fn default_workflow_state(role : @types.Role) -> WorkflowState {
  match role {
    @types.Role::Root => Supervisor(Planning)
    @types.Role::TL => Supervisor(Planning)
    @types.Role::Dev => Dev(Working)
    @types.Role::Worker => Worker(Working)
  }
}

///|
pub fn lifecycle_for_agent(agent : @types.Agent) -> AgentLifecycle {
  let process = match agent.state {
    @types.AgentState::Spawning => Connected
    @types.AgentState::Active => Connected
    @types.AgentState::Completing => Finalizing(reason=FinalizeReason::Shutdown)
    @types.AgentState::Done => Finalized(reason=FinalizeReason::RecoveredDone)
    @types.AgentState::Failed => Failed(reason=FailureReason::RecoveredFailed)
  }
  {
    agent_id: agent.agent_id.to_string(),
    role: agent.role,
    process,
    workflow: default_workflow_state(agent.role),
  }
}

///|
pub fn lifecycle_for_role(
  agent_id : String,
  role : @types.Role,
) -> AgentLifecycle {
  { agent_id, role, process: Connected, workflow: default_workflow_state(role) }
}

///|
pub fn AgentLifecycle::to_agent_state(
  self : AgentLifecycle,
) -> @types.AgentState {
  match self.process {
    Connected => @types.AgentState::Active
    Finalizing(_) => @types.AgentState::Completing
    Finalized(_) => @types.AgentState::Done
    Failed(_) => @types.AgentState::Failed
  }
}

///|
pub fn child_summary_from_lifecycle(
  lifecycle : AgentLifecycle,
) -> ChildLifecycleSummary {
  match lifecycle.workflow {
    Supervisor(_) => ChildLifecycleSummary::Working
    Dev(Working) => ChildLifecycleSummary::Working
    Dev(ReviewOwned(pr_number~, state~)) =>
      ChildLifecycleSummary::ReviewOwned(pr_number~, state~)
    Dev(ChangesRequested(pr_number~, next_round~)) =>
      ChildLifecycleSummary::ChangesRequested(pr_number~, next_round~)
    Dev(ExitRequestedDeferred(pr_number~, state~)) =>
      ChildLifecycleSummary::ExitRequestedDeferred(pr_number~, state~)
    Dev(Exitable) => ChildLifecycleSummary::Exitable
    Dev(Done(..)) => ChildLifecycleSummary::Done
    Dev(Failed(reason~)) => ChildLifecycleSummary::Failed(reason~)
    Worker(Working) => ChildLifecycleSummary::Working
    Worker(Exitable) => ChildLifecycleSummary::Exitable
    Worker(Done(..)) => ChildLifecycleSummary::Done
    Worker(Failed(reason~)) => ChildLifecycleSummary::Failed(reason~)
  }
}

///|
pub fn supervisor_exit_policy(
  lifecycle : SupervisorLifecycle,
) -> LifecycleExitPolicy {
  match lifecycle {
    Planning => Allowed
    Dispatching => Deferred(message="Still dispatching children")
    Supervising(children~, ..) => {
      let mut active = 0
      for child in children {
        match child.summary {
          Done | Failed(_) => ()
          _ => active = active + 1
        }
      }
      if active == 0 {
        Allowed
      } else {
        Deferred(message="Waiting for " + active.to_string() + " children")
      }
    }
    WaveComplete(..) => Allowed
    OwnPRFiled(number~, url~) => Blocked(reason=OwnPROpen(number~, url~))
    Done => Allowed
    Failed(_) => Allowed
  }
}

///|
pub fn dev_exit_policy(lifecycle : DevLifecycle) -> LifecycleExitPolicy {
  match lifecycle {
    Working => Allowed
    ReviewOwned(pr_number~, state~) =>
      Deferred(message=review_summary_message(pr_number, state))
    ChangesRequested(_, ..) => Blocked(reason=ExitBlockReason::ChangesRequested)
    ExitRequestedDeferred(pr_number~, state~) =>
      Deferred(message=review_summary_message(pr_number, state))
    Exitable => Allowed
    Done(..) => Allowed
    Failed(..) => Allowed
  }
}

///|
pub fn worker_exit_policy(lifecycle : WorkerLifecycle) -> LifecycleExitPolicy {
  match lifecycle {
    Working => Allowed
    Exitable => Allowed
    Done(..) => Allowed
    Failed(..) => Allowed
  }
}

///|
pub fn lifecycle_exit_policy(lifecycle : AgentLifecycle) -> LifecycleExitPolicy {
  match lifecycle.workflow {
    Supervisor(supervisor) => supervisor_exit_policy(supervisor)
    Dev(dev) => dev_exit_policy(dev)
    Worker(worker) => worker_exit_policy(worker)
  }
}

///|
pub fn lifecycle_dev_disconnect_policy(
  lifecycle : DevLifecycle,
) -> LifecycleDisconnectPolicy {
  match lifecycle {
    Working => Fail(reason=UnexpectedDisconnect)
    ReviewOwned(..) => Preserve
    // Waiting on reviewer-requested changes; work is in-flight and needs human
    // follow-up — preserve across disconnect so the fix/review cycle is not lost.
    ChangesRequested(..) => Preserve
    ExitRequestedDeferred(..) => Preserve
    Exitable => FinalizeDone(reason=DisconnectFinalized)
    Done(..) => Ignore
    Failed(..) => Ignore
  }
}

///|
pub fn worker_disconnect_policy(
  lifecycle : WorkerLifecycle,
) -> LifecycleDisconnectPolicy {
  match lifecycle {
    Working => Fail(reason=UnexpectedDisconnect)
    Exitable => FinalizeDone(reason=DisconnectFinalized)
    Done(..) => Ignore
    Failed(..) => Ignore
  }
}

///|
pub fn lifecycle_disconnect_policy(
  lifecycle : AgentLifecycle,
) -> LifecycleDisconnectPolicy {
  match lifecycle.workflow {
    Supervisor(_) => Fail(reason=UnexpectedDisconnect)
    Dev(dev) => lifecycle_dev_disconnect_policy(dev)
    Worker(worker) => worker_disconnect_policy(worker)
  }
}

///|
/// Whether an agent is exempt from the idle watchdog.
///
/// Exempt:
/// - **Dev `Done` / `Failed`**: terminal.
/// - **Dev `ExitRequestedDeferred`**: deferred exit while PR/review coordination
///   is still resolving; killing mid-wait would lose that handshake.
/// - **Worker `Done` / `Failed`**: terminal.
/// - **`Supervisor`**: TL agents are out of scope for leaf idle cleanup.
///
/// **Not** exempt (examples): **`Working`**, **`ReviewOwned`**, **`ChangesRequested`**,
/// **`Dev(Exitable)`** — e.g. a leaf that opened a PR then went silent must still
/// be reclaimed; a leaf in **`Exitable`** waiting on parent shutdown is still
/// killable if it sits idle for the watchdog timeout.
pub fn lifecycle_idle_watchdog_exempt(lifecycle : AgentLifecycle) -> Bool {
  match lifecycle.workflow {
    Dev(Done(..)) | Dev(Failed(..)) => true
    Dev(ExitRequestedDeferred(..)) => true
    Worker(Done(..)) | Worker(Failed(..)) => true
    Supervisor(_) => true
    _ => false
  }
}

///|
pub fn dev_lifecycle_transition(
  lifecycle : DevLifecycle,
  event : DevLifecycleEvent,
) -> TransitionResult[DevLifecycle] {
  match (lifecycle, event) {
    (Working, PRCreated(pr_number~, url~)) =>
      Transitioned(ReviewOwned(pr_number~, state=OpenUnreviewed(url~)))
    (Exitable, PRCreated(pr_number~, url~)) =>
      Transitioned(ReviewOwned(pr_number~, state=OpenUnreviewed(url~)))
    (
      ReviewOwned(pr_number=n, state=FixesAwaitingReview(round~)),
      ReviewReceived(pr_number=c, ..),
    ) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c, next_round=round + 1))
      } else {
        InvalidTransition("review count mismatch")
      }
    (ReviewOwned(pr_number=n, ..), ReviewReceived(pr_number=c, ..)) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c, next_round=1))
      } else {
        InvalidTransition("review count mismatch")
      }
    (ReviewOwned(pr_number=n, ..), ReviewApproved(pr_number=c)) =>
      if c == n {
        Transitioned(ReviewOwned(pr_number=c, state=ApprovedAwaitingMerge))
      } else {
        InvalidTransition("review count mismatch")
      }
    (ChangesRequested(pr_number=n, next_round~), FixesPushed(pr_number=c, ..)) =>
      if c == n {
        Transitioned(
          ReviewOwned(pr_number=c, state=FixesAwaitingReview(round=next_round)),
        )
      } else {
        InvalidTransition("fix count mismatch")
      }
    (Working, ExitRequested) => Transitioned(Exitable)
    (Exitable, ExitRequested) => Transitioned(Exitable)
    (ReviewOwned(pr_number~, state~), ExitRequested) =>
      Transitioned(ExitRequestedDeferred(pr_number~, state~))
    (ExitRequestedDeferred(pr_number=n, ..), ReviewApproved(pr_number=c)) =>
      if c == n {
        Transitioned(
          ExitRequestedDeferred(pr_number=c, state=ApprovedAwaitingMerge),
        )
      } else {
        InvalidTransition("review count mismatch")
      }
    (
      ExitRequestedDeferred(pr_number=n, state=review_state),
      ReviewReceived(pr_number=c, ..),
    ) =>
      if c == n {
        Transitioned(
          ChangesRequested(
            pr_number=c,
            next_round=next_round_for_review(review_state),
          ),
        )
      } else {
        InvalidTransition("review count mismatch")
      }
    (ReviewOwned(pr_number=n, ..), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done(reason=Merged))
      } else {
        InvalidTransition("merge count mismatch")
      }
    (ExitRequestedDeferred(pr_number=n, ..), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done(reason=Merged))
      } else {
        InvalidTransition("merge count mismatch")
      }
    (Exitable, MergeObserved(_)) => Transitioned(Done(reason=Merged))
    (_, _) => InvalidTransition("invalid transition for DevLifecycle")
  }
}

///|
fn update_child_row(
  children : Array[ChildLifecycle],
  child_id : String,
  summary : ChildLifecycleSummary,
  agent_type : @types.AgentType?,
) -> Array[ChildLifecycle] {
  let updated = []
  let mut found = false
  for child in children {
    if child.child_id == child_id {
      let next_type = match agent_type {
        Some(t) => t
        None => child.agent_type
      }
      updated.push({ ..child, summary, agent_type: next_type })
      found = true
    } else {
      updated.push(child)
    }
  }
  if found {
    updated
  } else {
    children
  }
}

///|
fn update_child_summary(
  children : Array[ChildLifecycle],
  child_id : String,
  summary : ChildLifecycleSummary,
) -> Array[ChildLifecycle] {
  update_child_row(children, child_id, summary, None)
}

///|
fn remove_child(
  children : Array[ChildLifecycle],
  child_id : String,
) -> Array[ChildLifecycle] {
  let updated = []
  for child in children {
    if child.child_id != child_id {
      updated.push(child)
    }
  }
  updated
}

///|
fn children_all_terminal(children : Array[ChildLifecycle]) -> Bool {
  let mut all_terminal = true
  for child in children {
    match child.summary {
      Done | Failed(_) => ()
      _ => all_terminal = false
    }
  }
  all_terminal
}

///|
pub fn supervisor_transition(
  lifecycle : SupervisorLifecycle,
  event : SupervisorEvent,
) -> TransitionResult[SupervisorLifecycle] {
  match (lifecycle, event) {
    (Planning, ChildSpawned(child~)) =>
      Transitioned(Supervising(children=[child], wave=1))
    (Dispatching, ChildSpawned(child~)) =>
      Transitioned(Supervising(children=[child], wave=1))
    (Supervising(children~, wave~), ChildSpawned(child~)) => {
      let next = children.copy()
      next.push(child)
      Transitioned(Supervising(children=next, wave~))
    }
    (WaveComplete(wave~, ..), ChildSpawned(child~)) =>
      Transitioned(Supervising(children=[child], wave=wave + 1))
    (Planning, OwnPRFiled(number~, url~)) =>
      Transitioned(OwnPRFiled(number~, url~))
    (Dispatching, OwnPRFiled(number~, url~)) =>
      Transitioned(OwnPRFiled(number~, url~))
    (Supervising(..), OwnPRFiled(number~, url~)) =>
      Transitioned(OwnPRFiled(number~, url~))
    (WaveComplete(_, ..), OwnPRFiled(number~, url~)) =>
      Transitioned(OwnPRFiled(number~, url~))
    (
      Supervising(children~, wave~),
      ChildUpdated(child_id~, summary~, agent_type~),
    ) => {
      let updated = update_child_row(children, child_id, summary, agent_type)
      if children_all_terminal(updated) {
        Transitioned(WaveComplete(wave~, children=updated))
      } else {
        Transitioned(Supervising(children=updated, wave~))
      }
    }
    (Supervising(children~, wave~), ChildFailed(child_id~, reason~)) => {
      let updated = update_child_summary(
        children,
        child_id,
        ChildLifecycleSummary::Failed(reason~),
      )
      if children_all_terminal(updated) {
        Transitioned(WaveComplete(wave~, children=updated))
      } else {
        Transitioned(Supervising(children=updated, wave~))
      }
    }
    (Supervising(children~, wave~), ChildRemoved(child_id~)) =>
      Transitioned(
        Supervising(children=remove_child(children, child_id), wave~),
      )
    (
      WaveComplete(wave~, children~),
      ChildUpdated(child_id~, summary~, agent_type~),
    ) => {
      let updated = update_child_row(children, child_id, summary, agent_type)
      if children_all_terminal(updated) {
        Transitioned(WaveComplete(wave~, children=updated))
      } else {
        Transitioned(Supervising(children=updated, wave~))
      }
    }
    (WaveComplete(wave~, children~), ChildFailed(child_id~, reason~)) => {
      let updated = update_child_summary(
        children,
        child_id,
        ChildLifecycleSummary::Failed(reason~),
      )
      if children_all_terminal(updated) {
        Transitioned(WaveComplete(wave~, children=updated))
      } else {
        Transitioned(Supervising(children=updated, wave~))
      }
    }
    (WaveComplete(wave~, children~), ChildRemoved(child_id~)) => {
      let updated = remove_child(children, child_id)
      if children_all_terminal(updated) {
        Transitioned(WaveComplete(wave~, children=updated))
      } else {
        Transitioned(Supervising(children=updated, wave~))
      }
    }
    (Supervising(children~, wave~), AllChildrenComplete) =>
      if children_all_terminal(children) {
        Transitioned(WaveComplete(wave~, children~))
      } else {
        InvalidTransition("children still active")
      }
    (_, _) => InvalidTransition("invalid transition for SupervisorLifecycle")
  }
}

///|
pub fn failure_reason_message(reason : FailureReason) -> String {
  match reason {
    UnexpectedDisconnect => "unexpected disconnect"
    WatchdogTimeout => "watchdog timeout"
    ParentFailureNotification => "parent failure notification"
    ChildFailure(message~) => message
    RecoveredFailed => "recovered failed"
    ModelAtCapacity => "model at capacity"
    McpInitializeFailure => "MCP initialize failure"
    ParentKilled => "parent killed"
    BlockedByReview => "blocked by review"
  }
}

///|
pub fn classify_failure(message : String) -> FailureReason {
  let lower = message.to_lower()
  if lower.contains("model at capacity") ||
    lower.contains("at capacity") ||
    lower.contains("rate limit") {
    ModelAtCapacity
  } else if lower.contains("mcp initialize failure") ||
    lower.contains("mcp connection failed") ||
    lower.contains("mcp initialize") ||
    lower.contains("mcp handshake") ||
    lower.contains("failed to initialize") {
    McpInitializeFailure
  } else if lower.contains("watchdog") ||
    (lower.contains("timeout") && lower.contains("idle")) {
    WatchdogTimeout
  } else if lower.contains("disconnect") || lower.contains("crashed") {
    UnexpectedDisconnect
  } else if lower.contains("parent killed") ||
    lower.contains("killed by parent") ||
    lower.contains("agent killed") {
    ParentKilled
  } else if lower.contains("blocked by review") ||
    lower.contains("changes requested") {
    BlockedByReview
  } else {
    ChildFailure(message~)
  }
}

///|
pub fn exit_block_reason_message(reason : ExitBlockReason) -> String {
  match reason {
    ChangesRequested => "Changes requested"
    OwnPROpen(number~, url~) =>
      "PR filed (" + number.to_string() + ") at " + url
  }
}

///|
pub fn lifecycle_to_json(lifecycle : AgentLifecycle) -> String {
  lifecycle.to_json().stringify()
}

///|
pub fn lifecycle_from_json(json_str : String) -> AgentLifecycle? {
  let json = @json.parse(json_str) catch { _ => return None }
  try {
    let lc : AgentLifecycle = @json.from_json(json)
    Some(lc)
  } catch {
    _ => None
  }
}

///|
pub fn last_segment_after_dot(value : String) -> String {
  let last_dot = match value.rev_find(".") {
    Some(i) => i
    None => -1
  }
  if last_dot == -1 {
    value
  } else {
    value[last_dot + 1:].to_string()
  }
}

///|
pub fn extract_slug(agent_id : String) -> String {
  last_segment_after_dot(agent_id)
}

///|
/// Copy dev workflow state from a failing leaf to a pending replacement agent id (KV lifecycle file).
pub fn handoff_dev_workflow_to_new_agent(
  project_dir : String,
  from_agent_id : String,
  to_agent_id : String,
  to_role : @types.Role,
) -> Result[Unit, @types.ChoirError] {
  match read_lifecycle(project_dir, from_agent_id) {
    Some(lc) =>
      match lc.workflow {
        Dev(dev) => {
          let next = {
            agent_id: to_agent_id,
            role: to_role,
            process: Connected,
            workflow: Dev(dev),
          }
          if write_lifecycle(project_dir, next) {
            Ok(())
          } else {
            Err(
              @types.ChoirError::workspace_error(
                "failed to write lifecycle for " + to_agent_id,
              ),
            )
          }
        }
        _ =>
          Err(
            @types.ChoirError::validation_error(
              "rescue source must be a dev leaf lifecycle",
            ),
          )
      }
    None =>
      Err(
        @types.ChoirError::validation_error(
          "missing lifecycle for " + from_agent_id,
        ),
      )
  }
}

///|
pub fn mark_agent_rescued_superseded(
  project_dir : String,
  from_agent_id : String,
  role : @types.Role,
) -> Bool {
  let lc = read_or_default_lifecycle(project_dir, from_agent_id, role)
  let next_workflow = match lc.workflow {
    Dev(_) => Dev(Done(reason=RescuedByReplacement))
    Worker(_) => Worker(Done(reason=RescuedByReplacement))
    Supervisor(sup) => Supervisor(sup)
  }
  let next = {
    ..lc,
    process: Finalized(reason=RescuedByReplacement),
    workflow: next_workflow,
  }
  write_lifecycle(project_dir, next)
}

///|
/// Drop a child entry from a supervisor's persisted lifecycle (TL/Root).
pub fn remove_child_from_supervisor_lifecycle(
  project_dir : String,
  parent_id : String,
  child_id : String,
) -> Unit {
  let parent_lifecycle = match read_lifecycle(project_dir, parent_id) {
    Some(lc) => lc
    None => return
  }
  let supervisor = match parent_lifecycle.workflow {
    Supervisor(supervisor) => supervisor
    _ => return
  }
  match supervisor_transition(supervisor, ChildRemoved(child_id~)) {
    Transitioned(new_supervisor) =>
      ignore(
        write_lifecycle(project_dir, {
          ..parent_lifecycle,
          workflow: Supervisor(new_supervisor),
        }),
      )
    InvalidTransition(_) => ()
  }
}

///|
pub impl StateMachine for SupervisorLifecycle with machine_name(_) -> String {
  "supervisor"
}

///|
pub impl StateMachine for SupervisorLifecycle with can_exit(self) -> StopCheckResult {
  match supervisor_exit_policy(self) {
    Blocked(reason~) => MustBlock(exit_block_reason_message(reason))
    Deferred(message~) => ShouldNudge(message)
    Allowed => Clean
  }
}

///|
pub fn SupervisorLifecycle::transition(
  self : SupervisorLifecycle,
  event : SupervisorEvent,
) -> TransitionResult[SupervisorLifecycle] {
  supervisor_transition(self, event)
}

///|
pub impl Show for FinalizeReason with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for FailureReason with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ExitBlockReason with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ReviewOwnership with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ChildLifecycleSummary with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SupervisorLifecycle with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for DevLifecycle with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for WorkerLifecycle with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for WorkflowState with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ProcessState with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for AgentLifecycle with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for LifecycleEffect with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for LifecycleExitPolicy with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for LifecycleDisconnectPolicy with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for DevLifecycleEvent with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SupervisorEvent with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
