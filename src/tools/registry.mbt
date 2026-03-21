///|
/// Tool registry: maps (role, tool_name) to tool definitions.
pub struct ToolRegistry {
  tools : Map[String, @types.ToolDef]
}

///|
/// Create a new tool registry with the default tool set from SPEC section 6.
pub fn ToolRegistry::new() -> ToolRegistry {
  let tools : Map[String, @types.ToolDef] = {}
  let all_roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  let defs : Array[@types.ToolDef] = [
    {
      name: "register",
      description: "Register an agent in the registry",
      allowed_roles: all_roles,
    },
    {
      name: "spawn_gemini",
      description: "Spawn a Gemini leaf agent in its own worktree and branch. This is the default implementation-leaf path. Use it for tasks that should end in commit, PR, review follow-up, and eventual parent merge; PR creation alone is not terminal completion",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_moon_pilot",
      description: "Spawn a Moon Pilot leaf agent in its own worktree and branch. Use this for implementation tasks that should end in commit, PR, review follow-up, and eventual parent merge; PR creation alone is not terminal completion",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "fork_wave",
      description: "Spawn N parallel Claude sub-TL agents in worktrees. Use this only when you specifically want Claude fan-out, not the default Gemini leaf path",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "fork_session",
      description: "Create a named session subdirectory for a nested team",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_remote",
      description: "Spawn an agent on a remote machine via SSH, connecting back over TCP",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_worker",
      description: "Spawn an inline worker in the current repo/session for research, review, or very small in-place tasks. Workers do not own a branch or PR and must not be used for tasks that should end in file_pr, track_pr, or parent-merge flow",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "file_pr",
      description: "Create or update PR for current branch",
      allowed_roles: [@types.Role::TL, @types.Role::Dev],
    },
    {
      name: "merge_pr",
      description: "Merge a child's PR; optional args: parent_branch (defaults to main), caller_id (defaults to server)",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "track_pr",
      description: "Track a PR in the background poller with owning branch/base metadata",
      allowed_roles: [@types.Role::TL, @types.Role::Dev],
    },
    {
      name: "notify_parent",
      description: "Send message to parent agent",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "send_message",
      description: "Send message to any agent by ID",
      allowed_roles: all_roles,
    },
    {
      name: "reply",
      description: "Store a reply to a pending interaction request",
      allowed_roles: all_roles,
    },
    {
      name: "shutdown",
      description: "Notify parent, close own pane",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "kv_get",
      description: "Read one value from shared KV storage",
      allowed_roles: all_roles,
    },
    {
      name: "kv_set",
      description: "Write one value to shared KV storage",
      allowed_roles: all_roles,
    },
    {
      name: "kv_delete",
      description: "Delete one value from shared KV storage",
      allowed_roles: all_roles,
    },
    {
      name: "kv_list",
      description: "List all keys in shared KV storage",
      allowed_roles: all_roles,
    },
    {
      name: "mutex_acquire",
      description: "Acquire an in-memory coordination mutex",
      allowed_roles: all_roles,
    },
    {
      name: "mutex_release",
      description: "Release an in-memory coordination mutex",
      allowed_roles: all_roles,
    },
    {
      name: "mutex_status",
      description: "Inspect an in-memory coordination mutex",
      allowed_roles: all_roles,
    },
    {
      name: "task_list",
      description: "List tasks from shared task list",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "task_get",
      description: "Get task by ID",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "task_update",
      description: "Update task status/owner",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "task_create",
      description: "Create a new task",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
  ]
  for def in defs {
    tools.set(def.name, def)
  }
  { tools, }
}

///|
/// Look up a tool, checking role permissions.
pub fn ToolRegistry::lookup(
  self : ToolRegistry,
  role : @types.Role,
  name : String,
) -> Result[@types.ToolDef, @types.ExoError] {
  match self.tools.get(name) {
    None => Err(@types.ExoError::ToolNotFound(name))
    Some(def) =>
      if def.is_role_allowed(role) {
        Ok(def)
      } else {
        Err(@types.ExoError::PermissionDenied(role.to_string(), name))
      }
  }
}
