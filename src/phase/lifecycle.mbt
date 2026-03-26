///|
pub(all) enum FinalizeReason {
  Shutdown
  Merged
  DisconnectFinalized
  RecoveredDone
} derive(Show, Eq)

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
} derive(Show, Eq)

///|
pub(all) enum ExitBlockReason {
  ChangesRequested
  OwnPROpen(number~ : Int, url~ : String)
} derive(Show, Eq)

///|
pub(all) enum ReviewOwnership {
  OpenUnreviewed(url~ : String)
  FixesAwaitingReview(round~ : Int)
  ApprovedAwaitingMerge
} derive(Show, Eq)

///|
pub(all) enum ChildLifecycleSummary {
  Working
  ReviewOwned(pr_number~ : Int, state~ : ReviewOwnership)
  ChangesRequested(pr_number~ : Int, next_round~ : Int)
  ExitRequestedDeferred(pr_number~ : Int, state~ : ReviewOwnership)
  Exitable
  Done
  Failed(reason~ : FailureReason)
} derive(Show, Eq)

///|
pub(all) struct ChildLifecycle {
  child_id : String
  slug : String
  branch : String
  agent_type : String
  summary : ChildLifecycleSummary
} derive(Show, Eq)

///|
pub(all) enum SupervisorLifecycle {
  Planning
  Dispatching
  Supervising(children~ : Array[ChildLifecycle])
  OwnPRFiled(number~ : Int, url~ : String)
  Done
  Failed(reason~ : FailureReason)
} derive(Show, Eq)

///|
pub(all) enum DevLifecycle {
  Working
  ReviewOwned(pr_number~ : Int, state~ : ReviewOwnership)
  ChangesRequested(pr_number~ : Int, next_round~ : Int)
  ExitRequestedDeferred(pr_number~ : Int, state~ : ReviewOwnership)
  Exitable
  Done(reason~ : FinalizeReason)
  Failed(reason~ : FailureReason)
} derive(Show, Eq)

///|
pub(all) enum WorkerLifecycle {
  Working
  Exitable
  Done(reason~ : FinalizeReason)
  Failed(reason~ : FailureReason)
} derive(Show, Eq)

///|
pub(all) enum WorkflowState {
  Supervisor(SupervisorLifecycle)
  Dev(DevLifecycle)
  Worker(WorkerLifecycle)
} derive(Show, Eq)

///|
pub(all) enum ProcessState {
  Connected
  Finalizing(reason~ : FinalizeReason)
  Finalized(reason~ : FinalizeReason)
  Failed(reason~ : FailureReason)
} derive(Show, Eq)

///|
pub(all) struct AgentLifecycle {
  agent_id : String
  role : @types.Role
  process : ProcessState
  workflow : WorkflowState
} derive(Show, Eq)

///|
pub(all) enum LifecycleExitPolicy {
  Blocked(reason~ : ExitBlockReason)
  Deferred(message~ : String)
  Allowed
} derive(Show, Eq)

///|
pub(all) enum LifecycleDisconnectPolicy {
  Preserve
  Fail(reason~ : FailureReason)
  FinalizeDone(reason~ : FinalizeReason)
  Ignore
} derive(Show, Eq)

///|
pub(all) enum DevLifecycleEvent {
  PRCreated(pr_number~ : Int, url~ : String)
  ReviewReceived(pr_number~ : Int, body~ : String)
  ReviewApproved(pr_number~ : Int)
  FixesPushed(pr_number~ : Int, sha~ : String)
  ExitRequested
  MergeObserved(pr_number~ : Int)
} derive(Show, Eq)

///|
pub(all) enum SupervisorEvent {
  ChildSpawned(child~ : ChildLifecycle)
  ChildUpdated(child_id~ : String, summary~ : ChildLifecycleSummary)
  ChildRemoved(child_id~ : String)
  ChildFailed(child_id~ : String, reason~ : FailureReason)
  OwnPRFiled(number~ : Int, url~ : String)
} derive(Show, Eq)

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
fn lifecycle_path(project_dir : String, agent_id : String) -> String {
  project_dir + "/.choir/kv/" + lifecycle_key(agent_id)
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
    Supervising(children~) => {
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
    ChangesRequested(..) => Fail(reason=UnexpectedDisconnect)
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
fn update_child_summary(
  children : Array[ChildLifecycle],
  child_id : String,
  summary : ChildLifecycleSummary,
) -> Array[ChildLifecycle] {
  let updated = []
  let mut found = false
  for child in children {
    if child.child_id == child_id {
      updated.push({ ..child, summary, })
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
pub fn supervisor_transition(
  lifecycle : SupervisorLifecycle,
  event : SupervisorEvent,
) -> TransitionResult[SupervisorLifecycle] {
  match (lifecycle, event) {
    (Planning, ChildSpawned(child~)) =>
      Transitioned(Supervising(children=[child]))
    (Dispatching, ChildSpawned(child~)) =>
      Transitioned(Supervising(children=[child]))
    (Supervising(children~), ChildSpawned(child~)) => {
      let next = children.copy()
      next.push(child)
      Transitioned(Supervising(children=next))
    }
    (Planning, OwnPRFiled(number~, url~)) =>
      Transitioned(OwnPRFiled(number~, url~))
    (Supervising(children~), ChildUpdated(child_id~, summary~)) =>
      Transitioned(
        Supervising(children=update_child_summary(children, child_id, summary)),
      )
    (Supervising(children~), ChildFailed(child_id~, reason~)) =>
      Transitioned(
        Supervising(
          children=update_child_summary(
            children,
            child_id,
            ChildLifecycleSummary::Failed(reason~),
          ),
        ),
      )
    (Supervising(children~), ChildRemoved(child_id~)) =>
      Transitioned(Supervising(children=remove_child(children, child_id)))
    (_, _) => InvalidTransition("invalid transition for SupervisorLifecycle")
  }
}

///|
fn finalize_reason_to_json(reason : FinalizeReason) -> Json {
  match reason {
    Shutdown => { "tag": "Shutdown".to_json() }.to_json()
    Merged => { "tag": "Merged".to_json() }.to_json()
    DisconnectFinalized => { "tag": "DisconnectFinalized".to_json() }.to_json()
    RecoveredDone => { "tag": "RecoveredDone".to_json() }.to_json()
  }
}

///|
fn finalize_reason_from_json(json : Json) -> FinalizeReason? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("Shutdown")) => Some(Shutdown)
    Some(String("Merged")) => Some(Merged)
    Some(String("DisconnectFinalized")) => Some(DisconnectFinalized)
    Some(String("RecoveredDone")) => Some(RecoveredDone)
    _ => None
  }
}

///|
fn failure_reason_to_json(reason : FailureReason) -> Json {
  match reason {
    UnexpectedDisconnect =>
      { "tag": "UnexpectedDisconnect".to_json() }.to_json()
    WatchdogTimeout => { "tag": "WatchdogTimeout".to_json() }.to_json()
    ParentFailureNotification =>
      { "tag": "ParentFailureNotification".to_json() }.to_json()
    ChildFailure(message~) =>
      { "tag": "ChildFailure".to_json(), "message": message.to_json() }.to_json()
    RecoveredFailed => { "tag": "RecoveredFailed".to_json() }.to_json()
    ModelAtCapacity => { "tag": "ModelAtCapacity".to_json() }.to_json()
    McpInitializeFailure =>
      { "tag": "McpInitializeFailure".to_json() }.to_json()
    ParentKilled => { "tag": "ParentKilled".to_json() }.to_json()
    BlockedByReview => { "tag": "BlockedByReview".to_json() }.to_json()
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
fn failure_reason_from_json(json : Json) -> FailureReason? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("UnexpectedDisconnect")) => Some(UnexpectedDisconnect)
    Some(String("WatchdogTimeout")) => Some(WatchdogTimeout)
    Some(String("ParentFailureNotification")) => Some(ParentFailureNotification)
    Some(String("ChildFailure")) =>
      match obj.get("message") {
        Some(String(message)) => Some(ChildFailure(message~))
        _ => None
      }
    Some(String("RecoveredFailed")) => Some(RecoveredFailed)
    Some(String("ModelAtCapacity")) => Some(ModelAtCapacity)
    Some(String("McpInitializeFailure")) => Some(McpInitializeFailure)
    Some(String("ParentKilled")) => Some(ParentKilled)
    Some(String("BlockedByReview")) => Some(BlockedByReview)
    _ => None
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
fn review_ownership_to_json(state : ReviewOwnership) -> Json {
  match state {
    OpenUnreviewed(url~) =>
      { "tag": "OpenUnreviewed".to_json(), "url": url.to_json() }.to_json()
    FixesAwaitingReview(round~) =>
      { "tag": "FixesAwaitingReview".to_json(), "round": round.to_json() }.to_json()
    ApprovedAwaitingMerge =>
      { "tag": "ApprovedAwaitingMerge".to_json() }.to_json()
  }
}

///|
fn review_ownership_from_json(json : Json) -> ReviewOwnership? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("OpenUnreviewed")) =>
      match obj.get("url") {
        Some(String(url)) => Some(OpenUnreviewed(url~))
        _ => None
      }
    Some(String("FixesAwaitingReview")) =>
      match obj.get("round") {
        Some(Number(round, ..)) =>
          Some(FixesAwaitingReview(round=round.to_int()))
        _ => None
      }
    Some(String("ApprovedAwaitingMerge")) => Some(ApprovedAwaitingMerge)
    _ => None
  }
}

///|
fn child_summary_to_json(summary : ChildLifecycleSummary) -> Json {
  match summary {
    Working => { "tag": "Working".to_json() }.to_json()
    ReviewOwned(pr_number~, state~) =>
      {
        "tag": "ReviewOwned".to_json(),
        "pr_number": pr_number.to_json(),
        "state": review_ownership_to_json(state),
      }.to_json()
    ChangesRequested(pr_number~, next_round~) =>
      {
        "tag": "ChangesRequested".to_json(),
        "pr_number": pr_number.to_json(),
        "next_round": next_round.to_json(),
      }.to_json()
    ExitRequestedDeferred(pr_number~, state~) =>
      {
        "tag": "ExitRequestedDeferred".to_json(),
        "pr_number": pr_number.to_json(),
        "state": review_ownership_to_json(state),
      }.to_json()
    Exitable => { "tag": "Exitable".to_json() }.to_json()
    Done => { "tag": "Done".to_json() }.to_json()
    Failed(reason~) =>
      { "tag": "Failed".to_json(), "reason": failure_reason_to_json(reason) }.to_json()
  }
}

///|
fn child_summary_from_json(json : Json) -> ChildLifecycleSummary? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("Working")) => Some(Working)
    Some(String("ReviewOwned")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("state") is Some(state) else { return None }
      match review_ownership_from_json(state) {
        Some(review_state) =>
          Some(ReviewOwned(pr_number=n.to_int(), state=review_state))
        None => None
      }
    }
    Some(String("ChangesRequested")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("next_round") is Some(Number(r, ..)) else { return None }
      Some(ChangesRequested(pr_number=n.to_int(), next_round=r.to_int()))
    }
    Some(String("ExitRequestedDeferred")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("state") is Some(state) else { return None }
      match review_ownership_from_json(state) {
        Some(review_state) =>
          Some(ExitRequestedDeferred(pr_number=n.to_int(), state=review_state))
        None => None
      }
    }
    Some(String("Exitable")) => Some(Exitable)
    Some(String("Done")) => Some(Done)
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(reason) =>
          match failure_reason_from_json(reason) {
            Some(parsed) => Some(Failed(reason=parsed))
            None => None
          }
        None => None
      }
    _ => None
  }
}

///|
fn child_lifecycle_to_json(child : ChildLifecycle) -> Json {
  {
    "child_id": child.child_id.to_json(),
    "slug": child.slug.to_json(),
    "branch": child.branch.to_json(),
    "agent_type": child.agent_type.to_json(),
    "summary": child_summary_to_json(child.summary),
  }.to_json()
}

///|
fn child_lifecycle_from_json(json : Json) -> ChildLifecycle? {
  guard json is Object(obj) else { return None }
  guard obj.get("child_id") is Some(String(child_id)) else { return None }
  guard obj.get("slug") is Some(String(slug)) else { return None }
  guard obj.get("branch") is Some(String(branch)) else { return None }
  guard obj.get("agent_type") is Some(String(agent_type)) else { return None }
  guard obj.get("summary") is Some(summary) else { return None }
  match child_summary_from_json(summary) {
    Some(parsed_summary) =>
      Some({ child_id, slug, branch, agent_type, summary: parsed_summary })
    None => None
  }
}

///|
fn supervisor_lifecycle_to_json(state : SupervisorLifecycle) -> Json {
  match state {
    Planning => { "tag": "Planning".to_json() }.to_json()
    Dispatching => { "tag": "Dispatching".to_json() }.to_json()
    Supervising(children~) =>
      {
        "tag": "Supervising".to_json(),
        "children": children.map(child_lifecycle_to_json).to_json(),
      }.to_json()
    OwnPRFiled(number~, url~) =>
      {
        "tag": "OwnPRFiled".to_json(),
        "number": number.to_json(),
        "url": url.to_json(),
      }.to_json()
    Done => { "tag": "Done".to_json() }.to_json()
    Failed(reason~) =>
      { "tag": "Failed".to_json(), "reason": failure_reason_to_json(reason) }.to_json()
  }
}

///|
fn supervisor_lifecycle_from_json(json : Json) -> SupervisorLifecycle? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("Planning")) => Some(Planning)
    Some(String("Dispatching")) => Some(Dispatching)
    Some(String("Supervising")) =>
      match obj.get("children") {
        Some(Array(children_json)) => {
          let children = []
          for child_json in children_json {
            match child_lifecycle_from_json(child_json) {
              Some(child) => children.push(child)
              None => return None
            }
          }
          Some(Supervising(children~))
        }
        _ => None
      }
    Some(String("OwnPRFiled")) => {
      guard obj.get("number") is Some(Number(number, ..)) else { return None }
      guard obj.get("url") is Some(String(url)) else { return None }
      Some(OwnPRFiled(number=number.to_int(), url~))
    }
    Some(String("Done")) => Some(Done)
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(reason) =>
          match failure_reason_from_json(reason) {
            Some(parsed) => Some(Failed(reason=parsed))
            None => None
          }
        None => None
      }
    _ => None
  }
}

///|
fn dev_lifecycle_to_json(state : DevLifecycle) -> Json {
  match state {
    Working => { "tag": "Working".to_json() }.to_json()
    ReviewOwned(pr_number~, state~) =>
      {
        "tag": "ReviewOwned".to_json(),
        "pr_number": pr_number.to_json(),
        "state": review_ownership_to_json(state),
      }.to_json()
    ChangesRequested(pr_number~, next_round~) =>
      {
        "tag": "ChangesRequested".to_json(),
        "pr_number": pr_number.to_json(),
        "next_round": next_round.to_json(),
      }.to_json()
    ExitRequestedDeferred(pr_number~, state~) =>
      {
        "tag": "ExitRequestedDeferred".to_json(),
        "pr_number": pr_number.to_json(),
        "state": review_ownership_to_json(state),
      }.to_json()
    Exitable => { "tag": "Exitable".to_json() }.to_json()
    Done(reason~) =>
      { "tag": "Done".to_json(), "reason": finalize_reason_to_json(reason) }.to_json()
    Failed(reason~) =>
      { "tag": "Failed".to_json(), "reason": failure_reason_to_json(reason) }.to_json()
  }
}

///|
fn dev_lifecycle_from_json(json : Json) -> DevLifecycle? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("Working")) => Some(Working)
    Some(String("ReviewOwned")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("state") is Some(state) else { return None }
      match review_ownership_from_json(state) {
        Some(parsed_state) =>
          Some(ReviewOwned(pr_number=n.to_int(), state=parsed_state))
        None => None
      }
    }
    Some(String("ChangesRequested")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("next_round") is Some(Number(r, ..)) else { return None }
      Some(ChangesRequested(pr_number=n.to_int(), next_round=r.to_int()))
    }
    Some(String("ExitRequestedDeferred")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("state") is Some(state) else { return None }
      match review_ownership_from_json(state) {
        Some(parsed_state) =>
          Some(ExitRequestedDeferred(pr_number=n.to_int(), state=parsed_state))
        None => None
      }
    }
    Some(String("Exitable")) => Some(Exitable)
    Some(String("Done")) =>
      match obj.get("reason") {
        Some(reason) =>
          match finalize_reason_from_json(reason) {
            Some(parsed) => Some(Done(reason=parsed))
            None => None
          }
        None => None
      }
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(reason) =>
          match failure_reason_from_json(reason) {
            Some(parsed) => Some(Failed(reason=parsed))
            None => None
          }
        None => None
      }
    _ => None
  }
}

///|
fn worker_lifecycle_to_json(state : WorkerLifecycle) -> Json {
  match state {
    Working => { "tag": "Working".to_json() }.to_json()
    Exitable => { "tag": "Exitable".to_json() }.to_json()
    Done(reason~) =>
      { "tag": "Done".to_json(), "reason": finalize_reason_to_json(reason) }.to_json()
    Failed(reason~) =>
      { "tag": "Failed".to_json(), "reason": failure_reason_to_json(reason) }.to_json()
  }
}

///|
fn worker_lifecycle_from_json(json : Json) -> WorkerLifecycle? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("Working")) => Some(Working)
    Some(String("Exitable")) => Some(Exitable)
    Some(String("Done")) =>
      match obj.get("reason") {
        Some(reason) =>
          match finalize_reason_from_json(reason) {
            Some(parsed) => Some(Done(reason=parsed))
            None => None
          }
        None => None
      }
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(reason) =>
          match failure_reason_from_json(reason) {
            Some(parsed) => Some(Failed(reason=parsed))
            None => None
          }
        None => None
      }
    _ => None
  }
}

///|
fn workflow_state_to_json(state : WorkflowState) -> Json {
  match state {
    Supervisor(supervisor) =>
      {
        "tag": "Supervisor".to_json(),
        "state": supervisor_lifecycle_to_json(supervisor),
      }.to_json()
    Dev(dev) =>
      { "tag": "Dev".to_json(), "state": dev_lifecycle_to_json(dev) }.to_json()
    Worker(worker) =>
      { "tag": "Worker".to_json(), "state": worker_lifecycle_to_json(worker) }.to_json()
  }
}

///|
fn workflow_state_from_json(json : Json) -> WorkflowState? {
  guard json is Object(obj) else { return None }
  guard obj.get("state") is Some(state_json) else { return None }
  match obj.get("tag") {
    Some(String("Supervisor")) =>
      match supervisor_lifecycle_from_json(state_json) {
        Some(parsed) => Some(Supervisor(parsed))
        None => None
      }
    Some(String("Dev")) =>
      match dev_lifecycle_from_json(state_json) {
        Some(parsed) => Some(Dev(parsed))
        None => None
      }
    Some(String("Worker")) =>
      match worker_lifecycle_from_json(state_json) {
        Some(parsed) => Some(Worker(parsed))
        None => None
      }
    _ => None
  }
}

///|
fn process_state_to_json(state : ProcessState) -> Json {
  match state {
    Connected => { "tag": "Connected".to_json() }.to_json()
    Finalizing(reason~) =>
      {
        "tag": "Finalizing".to_json(),
        "reason": finalize_reason_to_json(reason),
      }.to_json()
    Finalized(reason~) =>
      {
        "tag": "Finalized".to_json(),
        "reason": finalize_reason_to_json(reason),
      }.to_json()
    Failed(reason~) =>
      { "tag": "Failed".to_json(), "reason": failure_reason_to_json(reason) }.to_json()
  }
}

///|
fn process_state_from_json(json : Json) -> ProcessState? {
  guard json is Object(obj) else { return None }
  match obj.get("tag") {
    Some(String("Connected")) => Some(Connected)
    Some(String("Finalizing")) =>
      match obj.get("reason") {
        Some(reason) =>
          match finalize_reason_from_json(reason) {
            Some(parsed) => Some(Finalizing(reason=parsed))
            None => None
          }
        None => None
      }
    Some(String("Finalized")) =>
      match obj.get("reason") {
        Some(reason) =>
          match finalize_reason_from_json(reason) {
            Some(parsed) => Some(Finalized(reason=parsed))
            None => None
          }
        None => None
      }
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(reason) =>
          match failure_reason_from_json(reason) {
            Some(parsed) => Some(Failed(reason=parsed))
            None => None
          }
        None => None
      }
    _ => None
  }
}

///|
pub fn lifecycle_to_json(lifecycle : AgentLifecycle) -> String {
  {
    "agent_id": lifecycle.agent_id.to_json(),
    "role": lifecycle.role.to_string().to_json(),
    "process": process_state_to_json(lifecycle.process),
    "workflow": workflow_state_to_json(lifecycle.workflow),
  }
  .to_json()
  .stringify()
}

///|
pub fn lifecycle_from_json(json_str : String) -> AgentLifecycle? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(obj) else { return None }
  guard obj.get("agent_id") is Some(String(agent_id)) else { return None }
  let role = match obj.get("role") {
    Some(String("Root")) => @types.Role::Root
    Some(String("TL")) => @types.Role::TL
    Some(String("Dev")) => @types.Role::Dev
    Some(String("Worker")) => @types.Role::Worker
    _ => return None
  }
  guard obj.get("process") is Some(process_json) else { return None }
  guard obj.get("workflow") is Some(workflow_json) else { return None }
  match
    (
      process_state_from_json(process_json),
      workflow_state_from_json(workflow_json),
    ) {
    (Some(process), Some(workflow)) =>
      Some({ agent_id, role, process, workflow })
    _ => None
  }
}

///|
pub fn read_lifecycle(
  project_dir : String,
  agent_id : String,
) -> AgentLifecycle? {
  let content = @sys.read_file(lifecycle_path(project_dir, agent_id))
  if content == "" {
    None
  } else {
    lifecycle_from_json(content)
  }
}

///|
pub fn write_lifecycle(
  project_dir : String,
  lifecycle : AgentLifecycle,
) -> Bool {
  @sys.write_file_sync(
    lifecycle_path(project_dir, lifecycle.agent_id),
    lifecycle_to_json(lifecycle),
  )
}

///|
pub fn read_or_default_lifecycle(
  project_dir : String,
  agent_id : String,
  role : @types.Role,
) -> AgentLifecycle {
  match read_lifecycle(project_dir, agent_id) {
    Some(lifecycle) => lifecycle
    None => lifecycle_for_role(agent_id, role)
  }
}

///|
pub fn last_segment_after_dot(value : String) -> String {
  let mut last_dot = -1
  for i = value.length() - 1; i >= 0; i = i - 1 {
    if value[i] == '.' {
      last_dot = i
      break
    }
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
