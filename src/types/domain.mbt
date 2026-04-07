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
