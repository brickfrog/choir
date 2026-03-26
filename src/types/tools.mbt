///|
/// Specification for spawning an agent.
pub(all) struct SpawnSpec {
  slug : String
  role : Role
  agent_type : AgentType
  task : String
  isolation : IsolationMode
  parent_id : String
  parent_branch : String
  /// Skip destructive worktree recreation and use an existing `.choir/worktrees/<workspace_slug>` tree.
  reuse_workspace : Bool
  /// Directory name under `.choir/worktrees/` when `reuse_workspace` is true (often the salvaged slug).
  workspace_slug : String?
  /// Git branch checked out in that tree (usually the salvaged agent id / branch name).
  reuse_git_branch : String?
} derive(Show)

///|
/// Tool definition in the registry.
pub(all) struct ToolDef {
  name : String
  description : String
  allowed_roles : Array[Role]
} derive(Show)

///|
/// Check if a role is allowed to call a tool.
pub fn ToolDef::is_role_allowed(self : ToolDef, role : Role) -> Bool {
  self.allowed_roles.contains(role)
}
