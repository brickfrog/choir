///|
/// Agent roles in the orchestration hierarchy.
pub(all) enum Role {
  Root
  TL
  Dev
  Worker
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for Role with output(self, logger) -> Unit {
  match self {
    Root => logger.write_string("Root")
    TL => logger.write_string("TL")
    Dev => logger.write_string("Dev")
    Worker => logger.write_string("Worker")
  }
}

///|
/// Types of agents the orchestrator can manage.
pub(all) enum AgentType {
  Claude
  Gemini
  MoonPilot
  Codex
  CursorAgent
  Unknown
} derive(Debug, Eq)

///|
pub impl Show for AgentType with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
/// Where an agent runs.
pub(all) enum Host {
  Local
  Remote(String)
} derive(Debug, Eq)

///|
/// Type-safe agent identifier. Prevents mixing with branch names, slugs, etc.
pub(all) struct AgentId(String) derive(Debug, Eq, Compare, Hash)

///|
pub impl Show for AgentId with output(self, logger) -> Unit {
  logger.write_string(self.0)
}

///|
pub fn AgentId::to_string(self : AgentId) -> String {
  self.0
}

///|
/// Agent lifecycle states.
pub(all) enum AgentState {
  Spawning
  Active
  Completing
  Done
  Failed
} derive(Debug, Eq)

///|
pub impl Show for AgentState with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub(all) enum LifecycleTrigger {
  ChildSpawned
  ChildCompleted
  ChildFailed
  PRMerged
  AllChildrenDone
  OwnPRFiled
  PRCreated
  NotifyParentSuccess
  NotifyParentFailure
  ExitRequested
  MergeObserved
  ReviewReceived
  ReviewApproved
  FixesPushed
  ChildUpdated
  ChildRemoved
  ExitMerged
  ExitDisconnected
  ExitShutdown
  FinalizeComplete
  Raw(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ReviewMode {
  SinglePass
  Iterative
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn ReviewMode::to_wire_string(self : ReviewMode) -> String {
  match self {
    SinglePass => "single_pass"
    Iterative => "iterative"
  }
}

///|
pub impl Show for ReviewMode with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub fn ReviewMode::try_parse_wire(
  raw : String,
) -> Result[ReviewMode, ChoirError] {
  let normalized = raw.trim().to_lower().to_string()
  match normalized {
    "single_pass" => Ok(SinglePass)
    "iterative" => Ok(Iterative)
    _ =>
      Err(
        ChoirError::config_error(
          "review_mode must be \"single_pass\" or \"iterative\"",
        ),
      )
  }
}

///|
pub fn LifecycleTrigger::to_wire_string(self : LifecycleTrigger) -> String {
  match self {
    ChildSpawned => "ChildSpawned"
    ChildCompleted => "ChildCompleted"
    ChildFailed => "ChildFailed"
    PRMerged => "PRMerged"
    AllChildrenDone => "AllChildrenDone"
    OwnPRFiled => "OwnPRFiled"
    PRCreated => "PRCreated"
    NotifyParentSuccess => "NotifyParentSuccess"
    NotifyParentFailure => "NotifyParentFailure"
    ExitRequested => "ExitRequested"
    MergeObserved => "MergeObserved"
    ReviewReceived => "ReviewReceived"
    ReviewApproved => "ReviewApproved"
    FixesPushed => "FixesPushed"
    ChildUpdated => "ChildUpdated"
    ChildRemoved => "ChildRemoved"
    ExitMerged => "merged"
    ExitDisconnected => "disconnect"
    ExitShutdown => "shutdown"
    FinalizeComplete => "FinalizeComplete"
    Raw(s) => s
  }
}

///|
pub(all) enum ExitReason {
  Merged
  Disconnected
  Shutdown
} derive(Debug, Eq)

///|
pub impl Show for ExitReason with output(self, logger) -> Unit {
  match self {
    Merged => logger.write_string("Merged")
    Disconnected => logger.write_string("Disconnected")
    Shutdown => logger.write_string("Shutdown")
  }
}

///|
pub fn ExitReason::lifecycle_trigger(self : ExitReason) -> LifecycleTrigger {
  match self {
    Merged => ExitMerged
    Disconnected => ExitDisconnected
    Shutdown => ExitShutdown
  }
}

///|
/// Zellij target type for agent panes.
pub(all) enum TargetKind {
  ZellijTab
  ZellijPane
} derive(Debug, Eq)

///|
pub impl Show for TargetKind with output(self, logger) -> Unit {
  match self {
    ZellijTab => logger.write_string("ZellijTab")
    ZellijPane => logger.write_string("ZellijPane")
  }
}

///|
/// A typed terminal target — session + pane/tab identifier.
pub(all) struct LocalTarget {
  kind : TargetKind
  session : String
  name : String
} derive(Debug, Eq)

///|
pub impl Show for LocalTarget with output(self, logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
pub fn LocalTarget::to_string(self : LocalTarget) -> String {
  let prefix = match self.kind {
    ZellijTab => "zellij-tab:"
    ZellijPane => "zellij-pane:"
  }
  prefix + self.session + ":" + self.name
}

///|
pub fn LocalTarget::parse(target : String) -> LocalTarget? {
  let try_parse = fn(prefix : String, kind : TargetKind) -> LocalTarget? {
    match target.strip_prefix(prefix) {
      None => None
      Some(rest) =>
        match rest.split_once(":") {
          Some((session, name)) if session != "" && name != "" =>
            Some({ kind, session: session.to_string(), name: name.to_string() })
          _ => None
        }
    }
  }
  match try_parse("zellij-tab:", ZellijTab) {
    Some(lt) => Some(lt)
    None => try_parse("zellij-pane:", ZellijPane)
  }
}

///|
/// A managed agent in the orchestration tree.
pub(all) struct Agent {
  agent_id : AgentId
  role : Role
  agent_type : AgentType
  parent : String?
  workspace : String
  branch : String
  terminal_target : LocalTarget?
  host : Host
  state : AgentState
  /// Sub-TL nesting depth: 0 for root supervisor, 1 for a sub-TL under one TL level.
  spawn_depth : Int
} derive(Debug)

///|
/// Message status tag.
pub(all) enum Status {
  Success
  Failure
  Info
} derive(Debug, Eq)

///|
/// A message between agents.
pub(all) struct Message {
  sender : String
  recipient : String
  content : String
  status : Status?
} derive(Debug)

///|
/// A git worktree workspace.
pub(all) struct Workspace {
  path : String
  branch : String
  parent_branch : String
  host : Host
} derive(Debug)

///|
/// Isolation mode for agent workspaces.
pub(all) enum IsolationMode {
  Worktree
  Inline
  Standalone
} derive(Debug, Eq)

///|
/// PR tracking state.
pub(all) enum PRStatus {
  Open
  Merged
  Closed
} derive(Debug, Eq)

///|
/// CI check status.
pub(all) enum CIStatus {
  Pending
  Passing
  Failing
} derive(Debug, Eq)

///|
/// A tracked pull request.
pub(all) struct PR {
  number : Int
  branch : String
  base : String
  status : PRStatus
  ci_status : CIStatus
} derive(Debug)

///|
/// A coordination lock.
pub(all) struct MutexLock {
  name : String
  holder : String
  acquired : Int64
  ttl : Int64
} derive(Debug)

///|
pub(all) enum TaskStatus {
  Todo
  InProgress
  Done
} derive(Debug, Eq)

///|
/// Canonical task intent passed through spawn/planning flows.
pub(all) struct TaskContract {
  goal : String
  scope : Array[String]
  acceptance_checks : Array[String]
  constraints : Array[String]
  non_goals : Array[String]
  review_context : String?
  verify : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Normalized review rollup used by evaluation helpers.
pub(all) enum EvaluationReviewState {
  Unknown
  None_
  Commented
  Approved
  ChangesRequested
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Normalized CI rollup used by evaluation helpers.
pub(all) enum EvaluationCiRollup {
  Unknown
  InProgress
  Success
  Failure
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerifyStatus {
  Passed
  Failed
  NotObserved
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerifyCheckResult {
  name : String
  status : VerifyStatus
  details : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Typed evidence items used by advisory evaluation.
pub(all) enum EvaluationSignal {
  Review(state~ : EvaluationReviewState, body~ : String)
  Ci(status~ : EvaluationCiRollup)
  ThreadsObserved(count~ : Int)
  ThreadsUnobserved
  CopilotIssueCommentObserved
  CopilotIssueCommentUnobserved
  Verify(result~ : VerifyCheckResult)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Grouped evidence for one advisory evaluation pass.
pub(all) struct EvaluationBundle {
  task_contract : TaskContract?
  signals : Array[EvaluationSignal]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum EvaluationVerdict {
  Ready
  Blocked(reason~ : String)
  NeedsHuman(reason~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct EvaluationResult {
  verdict : EvaluationVerdict
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn TaskContract::empty() -> TaskContract {
  {
    goal: "",
    scope: [],
    acceptance_checks: [],
    constraints: [],
    non_goals: [],
    review_context: None,
    verify: [],
  }
}

///|
pub fn TaskContract::is_empty(self : TaskContract) -> Bool {
  self.goal.trim().to_string() == "" &&
  self.scope.length() == 0 &&
  self.acceptance_checks.length() == 0 &&
  self.constraints.length() == 0 &&
  self.non_goals.length() == 0 &&
  self.review_context is None &&
  self.verify.length() == 0
}

///|
pub fn TaskContract::to_json_string(self : TaskContract) -> String {
  self.to_json().stringify()
}

///|
fn evaluation_latest_review_state(
  signals : Array[EvaluationSignal],
) -> EvaluationReviewState {
  let mut latest = EvaluationReviewState::Unknown
  for signal in signals {
    match signal {
      EvaluationSignal::Review(state~, ..) => latest = state
      _ => ()
    }
  }
  latest
}

///|
fn evaluation_latest_ci_rollup(
  signals : Array[EvaluationSignal],
) -> EvaluationCiRollup {
  let mut latest = EvaluationCiRollup::Unknown
  for signal in signals {
    match signal {
      EvaluationSignal::Ci(status~) => latest = status
      _ => ()
    }
  }
  latest
}

///|
fn evaluation_latest_threads(signals : Array[EvaluationSignal]) -> Int? {
  let mut latest : Int? = None
  for signal in signals {
    match signal {
      EvaluationSignal::ThreadsObserved(count~) => latest = Some(count)
      EvaluationSignal::ThreadsUnobserved => latest = None
      _ => ()
    }
  }
  latest
}

///|
fn evaluation_copilot_seen(signals : Array[EvaluationSignal]) -> Bool {
  let mut seen = false
  for signal in signals {
    match signal {
      EvaluationSignal::CopilotIssueCommentObserved => seen = true
      EvaluationSignal::CopilotIssueCommentUnobserved => seen = false
      _ => ()
    }
  }
  seen
}

///|
fn evaluation_verify_results_for_required(
  required : Array[String],
  signals : Array[EvaluationSignal],
) -> Array[VerifyCheckResult] {
  let observed : Map[String, VerifyCheckResult] = {}
  for signal in signals {
    match signal {
      EvaluationSignal::Verify(result~) => observed.set(result.name, result)
      _ => ()
    }
  }
  let out : Array[VerifyCheckResult] = []
  for name in required {
    match observed.get(name) {
      Some(found) => out.push(found)
      None => out.push({ name, status: VerifyStatus::NotObserved, details: "" })
    }
  }
  out
}

///|
fn evaluation_missing_verify_names(
  results : Array[VerifyCheckResult],
) -> Array[String] {
  let out : Array[String] = []
  for result in results {
    if result.status == VerifyStatus::NotObserved {
      out.push(result.name)
    }
  }
  out
}

///|
fn evaluation_failed_verify_names(
  results : Array[VerifyCheckResult],
) -> Array[String] {
  let out : Array[String] = []
  for result in results {
    if result.status == VerifyStatus::Failed {
      out.push(result.name)
    }
  }
  out
}

///|
pub fn advisory_evaluation_result(
  bundle : EvaluationBundle,
) -> EvaluationResult {
  let review = evaluation_latest_review_state(bundle.signals)
  let ci = evaluation_latest_ci_rollup(bundle.signals)
  let threads = evaluation_latest_threads(bundle.signals)
  let copilot_seen = evaluation_copilot_seen(bundle.signals)
  let verify_required = match bundle.task_contract {
    Some(contract) => contract.verify
    None => []
  }
  let verify_results = evaluation_verify_results_for_required(
    verify_required,
    bundle.signals,
  )
  let failed_verify = evaluation_failed_verify_names(verify_results)
  if failed_verify.length() > 0 {
    let reason = "local verify failed: " + failed_verify.join(", ")
    return { verdict: Blocked(reason~), summary: reason }
  }
  let missing_verify = evaluation_missing_verify_names(verify_results)
  if review == EvaluationReviewState::ChangesRequested {
    let reason = "review requested changes"
    return { verdict: Blocked(reason~), summary: reason }
  }
  match threads {
    Some(count) =>
      if count > 0 {
        let reason = count.to_string() + " unresolved inline review thread(s)"
        return { verdict: Blocked(reason~), summary: reason }
      }
    None => ()
  }
  if ci == EvaluationCiRollup::Failure {
    let reason = "CI failing"
    return { verdict: Blocked(reason~), summary: reason }
  }
  if missing_verify.length() > 0 {
    let reason = "local verify not observed: " + missing_verify.join(", ")
    return { verdict: NeedsHuman(reason~), summary: reason }
  }
  if review == EvaluationReviewState::Unknown ||
    review == EvaluationReviewState::None_ {
    let reason = "no review observed"
    return { verdict: NeedsHuman(reason~), summary: reason }
  }
  if review == EvaluationReviewState::Commented && !copilot_seen {
    let reason = "waiting for Copilot comments"
    return { verdict: NeedsHuman(reason~), summary: reason }
  }
  if ci == EvaluationCiRollup::Unknown || ci == EvaluationCiRollup::InProgress {
    let reason = "latest head CI rollup is not all-success"
    return { verdict: NeedsHuman(reason~), summary: reason }
  }
  match threads {
    None => {
      let reason = "unresolved inline review threads not fetched"
      return { verdict: NeedsHuman(reason~), summary: reason }
    }
    Some(_) => ()
  }
  let summary = if evaluation_copilot_seen(bundle.signals) {
    "ready: no tracked blockers; Copilot issue comment observed"
  } else {
    "ready: no tracked blockers; Copilot issue comment not observed"
  }
  { verdict: Ready, summary }
}

///|
pub fn EvaluationVerdict::label(self : EvaluationVerdict) -> String {
  match self {
    Ready => "ready"
    Blocked(_) => "blocked"
    NeedsHuman(_) => "needs_human"
  }
}

///|
pub impl Show for Host with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for LifecycleTrigger with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub impl Show for Status with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for Message with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for Workspace with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for IsolationMode with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for PRStatus with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for CIStatus with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MutexLock with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TaskStatus with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TaskContract with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for EvaluationReviewState with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for EvaluationCiRollup with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for VerifyStatus with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for VerifyCheckResult with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for EvaluationSignal with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for EvaluationBundle with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for EvaluationVerdict with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for EvaluationResult with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

// ── Chainlink domain types ────────────────────────────────────────────────────

///|
pub(all) struct ChainlinkComment {
  id : Int
  content : String
  kind : String
} derive(Debug, Eq)

///|
pub(all) struct ChainlinkIssue {
  id : Int
  title : String
  description : String?
  priority : String
  status : String
  parent_id : Int?
  labels : Array[String]
  blocked_by : Array[Int]
  subissues : Array[ChainlinkIssue]
  comments : Array[ChainlinkComment]
} derive(Debug)

///|
pub impl Show for ChainlinkIssue with output(self, logger) -> Unit {
  let desc = match self.description {
    Some(d) => d
    None => "(none)"
  }
  let parent = match self.parent_id {
    Some(p) => p.to_string()
    None => "(none)"
  }
  let labels = if self.labels.is_empty() {
    "(none)"
  } else {
    self.labels.join(", ")
  }
  let blocked = if self.blocked_by.is_empty() {
    "(none)"
  } else {
    self.blocked_by.map(fn(n) { n.to_string() }).join(", ")
  }
  logger.write_string(
    "#\{self.id} [\{self.status}] [\{self.priority}] \{self.title}\ndesc: \{desc}\nparent: \{parent}\nlabels: \{labels}\nblocked_by: \{blocked}\nsubissues: \{self.subissues.length()}\ncomments: \{self.comments.length()}",
  )
}
