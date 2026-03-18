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
      name: "fork_wave",
      description: "Spawn N parallel Claude agents in worktrees",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_gemini",
      description: "Spawn Gemini agent",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "file_pr",
      description: "Create or update PR for current branch",
      allowed_roles: [@types.Role::TL, @types.Role::Dev],
    },
    {
      name: "merge_pr",
      description: "Merge a child's PR",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
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
      name: "shutdown",
      description: "Notify parent, close own pane",
      allowed_roles: [@types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "task_list",
      description: "List tasks from shared task list",
      allowed_roles: [@types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "task_get",
      description: "Get task by ID",
      allowed_roles: [@types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "task_update",
      description: "Update task status/owner",
      allowed_roles: [@types.Role::Dev, @types.Role::Worker],
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
