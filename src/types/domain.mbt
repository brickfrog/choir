///|
/// Agent roles in the orchestration hierarchy.
pub(all) enum Role {
  Root
  TL
  Dev
  Worker
} derive(Show, Eq)

///|
/// Types of agents the orchestrator can manage.
pub(all) enum AgentType {
  Claude
  Gemini
  MoonPilot
  Codex
  CursorAgent
} derive(Show, Eq)

///|
/// Where an agent runs.
pub(all) enum Host {
  Local
  Remote(String)
} derive(Show, Eq)

///|
/// Type-safe agent identifier. Prevents mixing with branch names, slugs, etc.
pub(all) struct AgentId(String) derive(Show, Eq, Compare, Hash)

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
} derive(Show, Eq)

///|
/// Zellij target type for agent panes.
pub(all) enum TargetKind {
  ZellijTab
  ZellijPane
} derive(Show, Eq)

///|
/// A typed terminal target — session + pane/tab identifier.
pub(all) struct LocalTarget {
  kind : TargetKind
  session : String
  name : String
} derive(Show, Eq)

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
} derive(Show)

///|
/// Message status tag.
pub(all) enum Status {
  Success
  Failure
  Info
} derive(Show, Eq)

///|
/// A message between agents.
pub(all) struct Message {
  sender : String
  recipient : String
  content : String
  status : Status?
} derive(Show)

///|
/// A git worktree workspace.
pub(all) struct Workspace {
  path : String
  branch : String
  parent_branch : String
  host : Host
} derive(Show)

///|
/// Isolation mode for agent workspaces.
pub(all) enum IsolationMode {
  Worktree
  Inline
  Standalone
} derive(Show, Eq)

///|
/// PR tracking state.
pub(all) enum PRStatus {
  Open
  Merged
  Closed
} derive(Show, Eq)

///|
/// CI check status.
pub(all) enum CIStatus {
  Pending
  Passing
  Failing
} derive(Show, Eq)

///|
/// A tracked pull request.
pub(all) struct PR {
  number : Int
  branch : String
  base : String
  status : PRStatus
  ci_status : CIStatus
} derive(Show)

///|
/// A coordination lock.
pub(all) struct MutexLock {
  name : String
  holder : String
  acquired : Int64
  ttl : Int64
} derive(Show)
