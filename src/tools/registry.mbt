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
      name: "fork_wave",
      description: "Spawn one or more agents in worktrees; optional agent_type (gemini|claude|moon_pilot|codex|cursor_agent, default gemini); optional role (dev|tl, default dev) for sub-TL children; optional review_context appended to each leaf task for file_pr / Copilot review; optional automerge and review_mode override server defaults for that wave. Agents will automatically notify you of PR/completion via MCP events; do not poll or use side-channels.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "fork_session",
      description: "Create a named session subdirectory for a nested team",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_gemini",
      description: "Spawn a single Gemini leaf agent in a worktree. The leaf will automatically notify you of PR/completion via MCP events.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "rescue_leaf",
      description: "Manual rescue: spawn a replacement dev leaf (default cursor_agent) into an existing salvaged worktree/branch; hand off lifecycle and re-point tracked PRs",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_remote",
      description: "Spawn an agent on a remote machine via SSH, connecting back over TCP. The agent will automatically notify you via MCP events.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "spawn_worker",
      description: "Spawn an inline worker for research/review; optional agent_type (gemini|claude|moon_pilot, default gemini). Workers do not own a branch or PR. The worker will automatically send you its final report via the `notify_parent` tool once it finishes; wait for this notification in your MCP event stream instead of polling or waiting on KV keys.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "file_pr",
      description: "Create or update PR for current branch; optional review_context posts an @copilot review comment when PR review is requested",
      allowed_roles: [@types.Role::TL, @types.Role::Dev],
    },
    {
      name: "merge_pr",
      description: "Merge a child's PR; optional args: parent_branch (defaults to main), caller_id, force (bypass poller/threads/policy guard — force=true requires `choir tl-parent-override on` for the calling agent)",
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
      name: "report_usage",
      description: "Self-report usage for wave telemetry; no-op when caller has no wave_id",
      allowed_roles: [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    },
    {
      name: "wave_state",
      description: "Read typed per-child PR/review/CI snapshot for the caller (Root/TL only). Replaces prose-notification tracking for merge/review readiness.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
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
      name: "kill_agent",
      description: "Kill a child agent by agent_id; closes its pane and cleans up registry",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "kv_get",
      description: "Read one value from shared KV storage (flat key: no '/' in key)",
      allowed_roles: all_roles,
    },
    {
      name: "kv_set",
      description: "Write one value to shared KV storage (flat key: no '/' in key)",
      allowed_roles: all_roles,
    },
    {
      name: "kv_delete",
      description: "Delete one value from shared KV storage (flat key: no '/' in key)",
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
      name: "agent_list",
      description: "List active agents in the registry by default; optional parent_id filters to direct children and include_inactive=true shows the full registry view",
      allowed_roles: all_roles,
    },
    {
      name: "cancel_wave",
      description: "Kill all active children of the calling agent and clean up their lifecycle/PR tracking; optional force=true to cancel even mid-review children",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "resolve_review_thread",
      description: "Resolve a GitHub pull request review thread by its thread ID; thread IDs are included in merge_pr unresolved-thread error messages",
      allowed_roles: [@types.Role::Root, @types.Role::TL, @types.Role::Dev],
    },
    {
      name: "suspend",
      description: "Suspend a child agent: transitions Active → Suspended, pausing poll delivery and the idle watchdog for that agent until `resume` is called. Use when handing the worktree back to a human for manual intervention.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
    },
    {
      name: "resume",
      description: "Resume a suspended child agent: transitions Suspended → Active, unblocking poll delivery for that agent.",
      allowed_roles: [@types.Role::Root, @types.Role::TL],
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
) -> @types.ToolDef raise @types.ChoirError {
  match self.tools.get(name) {
    None => raise @types.ChoirError::tool_not_found(name)
    Some(def) =>
      if def.is_role_allowed(role) {
        def
      } else {
        raise @types.ChoirError::permission_denied(role.to_wire_string(), name)
      }
  }
}
