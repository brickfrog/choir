///|
/// Specification for spawning an agent.
pub(all) struct SpawnSpec {
  slug : String
  role : Role
  agent_type : AgentType
  task : String
  task_contract : TaskContract?
  isolation : IsolationMode
  parent_id : String
  parent_branch : String
  /// Skip destructive worktree recreation and use an existing `.choir/worktrees/<workspace_slug>` tree.
  reuse_workspace : Bool
  /// Directory name under `.choir/worktrees/` when `reuse_workspace` is true (often the salvaged slug).
  workspace_slug : String?
  /// Git branch checked out in that tree (usually the salvaged agent id / branch name).
  reuse_git_branch : String?
  /// Same semantics as `Agent.spawn_depth`; 0 at root TL, 1 for a sub-TL spawned under depth 0.
  spawn_depth : Int
  /// Per-wave automerge override persisted into the spawned leaf config. `None` inherits global config.
  automerge : Bool?
  /// Per-wave review-mode override persisted into the spawned leaf config. `None` inherits global config.
  review_mode : ReviewMode?
  /// Chainlink issue identifier sourced from MCP `fork_wave` arg `issue_id`, persisted into `config.local.toml`.
  chainlink_issue_id : String?
} derive(Debug)

///|
/// Tool definition in the registry.
pub(all) struct ToolDef {
  name : String
  description : String
  allowed_roles : Array[Role]
} derive(Debug)

///|
/// Check if a role is allowed to call a tool.
pub fn ToolDef::is_role_allowed(self : ToolDef, role : Role) -> Bool {
  self.allowed_roles.contains(role)
}

///|
pub impl Show for SpawnSpec with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ToolDef with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
