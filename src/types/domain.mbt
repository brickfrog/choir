///|
/// Agent roles in the orchestration hierarchy.
pub(all) enum Role {
  Root
  TL
  Dev
  Worker
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for Role with output(self, logger) {
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
pub impl Show for AgentType with output(self, logger) {
  match self {
    Claude => logger.write_string("Claude")
    Gemini => logger.write_string("Gemini")
    MoonPilot => logger.write_string("MoonPilot")
    Codex => logger.write_string("Codex")
    CursorAgent => logger.write_string("CursorAgent")
    Unknown => logger.write_string("Unknown")
  }
}

///|
/// Where an agent runs.
pub(all) enum Host {
  Local
  Remote(String)
} derive(Debug, Eq)

///|
pub impl Show for Host with output(self, logger) {
  match self {
    Local => logger.write_string("Local")
    Remote(s) => {
      logger.write_string("Remote(")
      logger.write_string(s)
      logger.write_string(")")
    }
  }
}

///|
/// Type-safe agent identifier. Prevents mixing with branch names, slugs, etc.
pub(all) struct AgentId(String) derive(Debug, Eq, Compare, Hash)

///|
pub impl Show for AgentId with output(self, logger) {
  logger.write_string(self.0)
}

///|
pub fn AgentId::to_wire_string(self : AgentId) -> String {
  self.0
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
pub impl Show for AgentState with output(self, logger) {
  logger.write_string(self.to_wire_string())
}

///|
pub fn AgentState::to_wire_string(self : AgentState) -> String {
  match self {
    Spawning => "spawning"
    Active => "active"
    Completing => "completing"
    Done => "done"
    Failed => "failed"
  }
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
pub impl Show for LifecycleTrigger with output(self, logger) {
  logger.write_string(self.to_wire_string())
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
pub impl Show for ExitReason with output(self, logger) {
  logger.write_string(self.to_wire_string())
}

///|
pub fn ExitReason::to_wire_string(self : ExitReason) -> String {
  match self {
    Merged => "merged"
    Disconnected => "disconnected"
    Shutdown => "shutdown"
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
pub impl Show for TargetKind with output(self, logger) {
  logger.write_string(self.to_wire_string())
}

///|
pub fn TargetKind::to_wire_string(self : TargetKind) -> String {
  match self {
    ZellijTab => "zellij-tab"
    ZellijPane => "zellij-pane"
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
pub impl Show for LocalTarget with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
pub fn LocalTarget::to_wire_string(self : LocalTarget) -> String {
  self.to_string()
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
} derive(Debug, Eq)

///|
/// Message status tag.
pub(all) enum Status {
  Success
  Failure
  Info
} derive(Debug, Eq)

///|
pub impl Show for Status with output(self, logger) {
  match self {
    Success => logger.write_string("Success")
    Failure => logger.write_string("Failure")
    Info => logger.write_string("Info")
  }
}

///|
/// A message between agents.
pub(all) struct Message {
  sender : String
  recipient : String
  content : String
  status : Status?
} derive(Debug, Eq)

///|
/// A git worktree workspace.
pub(all) struct Workspace {
  path : String
  branch : String
  parent_branch : String
  host : Host
} derive(Debug, Eq)

///|
/// Isolation mode for agent workspaces.
pub(all) enum IsolationMode {
  Worktree
  Inline
  Standalone
} derive(Debug, Eq)

///|
pub impl Show for IsolationMode with output(self, logger) {
  match self {
    Worktree => logger.write_string("Worktree")
    Inline => logger.write_string("Inline")
    Standalone => logger.write_string("Standalone")
  }
}

///|
/// PR tracking state.
pub(all) enum PRStatus {
  Open
  Merged
  Closed
} derive(Debug, Eq)

///|
pub impl Show for PRStatus with output(self, logger) {
  match self {
    Open => logger.write_string("Open")
    Merged => logger.write_string("Merged")
    Closed => logger.write_string("Closed")
  }
}

///|
/// CI check status.
pub(all) enum CIStatus {
  Pending
  Passing
  Failing
} derive(Debug, Eq)

///|
pub impl Show for CIStatus with output(self, logger) {
  match self {
    Pending => logger.write_string("Pending")
    Passing => logger.write_string("Passing")
    Failing => logger.write_string("Failing")
  }
}

///|
/// A tracked pull request.
pub(all) struct PR {
  number : Int
  branch : String
  base : String
  status : PRStatus
  ci_status : CIStatus
} derive(Debug, Eq)

///|
/// A coordination lock.
pub(all) struct MutexLock {
  name : String
  holder : String
  acquired : Int64
  ttl : Int64
} derive(Debug, Eq)

///|
pub(all) enum TaskStatus {
  Todo
  InProgress
  Done
} derive(Debug, Eq)
