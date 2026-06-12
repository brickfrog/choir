///|
/// Tool registry: maps (role, tool_name) to tool definitions.
pub struct ToolRegistry {
  tools : Map[String, @types.ToolDef]
}

///|
fn tool_def(
  name : String,
  description : String,
  allowed_roles : Array[@types.Role],
  read_only? : Bool = false,
) -> @types.ToolDef {
  { name, description, allowed_roles, read_only }
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
    tool_def("register", "Register an agent in the registry", all_roles),
    tool_def(
      "server_reload",
      "Persist server runtime state and re-exec choir-serve in place using the freshly built binary",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "fork_wave",
      "Spawn one or more agents in worktrees. For nontrivial decomposition, create child Beads issues first and pass per-leaf task_contracts with beads_issue_id for each child; single-child waves may pass beads_issue_id directly. Optional agent_type (codex|claude|moon_pilot|gemini|cursor_agent, default codex); optional role (dev|tl, default dev) for sub-TL children; optional review_context appended to each leaf task for file_pr / Copilot review; optional automerge, review_mode, and merge_strategy override server defaults for that wave. Agents will automatically notify you of PR/completion via MCP events; do not poll or use side-channels.",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "fork_session",
      "Create a named session subdirectory for a nested team",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "spawn_gemini",
      "Spawn a single Gemini leaf agent in a worktree. The leaf will automatically notify you of PR/completion via MCP events.",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "spawn_remote",
      "Spawn an agent on a remote machine via SSH, connecting back over TCP. The agent will automatically notify you via MCP events.",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "spawn_worker",
      "Spawn a read-only research/review worker in the root checkout by default; create a worker Beads issue first for durable nontrivial work and pass beads_issue_id. Optional agent_type (codex|claude|moon_pilot|gemini|cursor_agent, default codex). For write-capable mutation-testing review only, pass type=review isolation=worktree parent_branch=<branch>; Choir creates an isolated review worktree. Workers do not own a branch or PR. The worker will automatically send you its final report via the `notify_parent` tool once it finishes; wait for this notification in your MCP event stream instead of polling or waiting on KV keys.",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "file_pr",
      "Create or update PR for current branch; optional review_context posts an @copilot review comment when PR review is requested",
      [@types.Role::TL, @types.Role::Dev],
    ),
    tool_def(
      "tdd_intent",
      "Declare the leaf's TDD intent before writing the failing test; red/green checks use the configured task-contract verify command.",
      [@types.Role::Dev],
    ),
    tool_def(
      "tdd_red_check",
      "Advance a leaf from Intent to Red only when the configured task-contract verify command fails.",
      [@types.Role::Dev],
    ),
    tool_def(
      "tdd_green_check",
      "Advance a leaf through Green, optional Refactor, and Done only when the configured task-contract verify command passes.",
      [@types.Role::Dev],
    ),
    tool_def(
      "merge_pr",
      "Merge a child's PR; optional args: parent_branch (defaults to main), caller_id",
      [@types.Role::Root, @types.Role::TL, @types.Role::Operator],
    ),
    tool_def(
      "track_pr",
      "Track a PR in the background poller with owning branch/base metadata",
      [@types.Role::TL, @types.Role::Dev],
    ),
    tool_def("notify_parent", "Send message to parent agent", [
      @types.Role::TL,
      @types.Role::Dev,
      @types.Role::Worker,
    ]),
    tool_def(
      "report_usage",
      "Self-report usage for wave telemetry; no-op when caller has no wave_id",
      [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
    ),
    tool_def(
      "wave_state",
      "Read typed per-child PR/review/CI snapshot for the caller (Root/TL only). Replaces prose-notification tracking for merge/review readiness.",
      [@types.Role::Root, @types.Role::TL],
      read_only=true,
    ),
    tool_def(
      "status_bar_state",
      "Read schema-versioned per-pane status-bar snapshot for zjbar polling",
      all_roles,
      read_only=true,
    ),
    tool_def(
      "tui_snapshot",
      "Read the canonical full-state TUI snapshot (agents, tracked PRs, poller vitals, journal seq, recent events). Zero network I/O.",
      [@types.Role::Root, @types.Role::TL, @types.Role::Operator],
      read_only=true,
    ),
    tool_def(
      "tui_events_since",
      "Read journal events with seq > cursor (bounded batch) plus the latest seq; reports a stale cursor when rotation discarded the gap.",
      [@types.Role::Root, @types.Role::TL, @types.Role::Operator],
      read_only=true,
    ),
    tool_def(
      "crystallize_spec",
      "Scaffold a canonical eight-section spec template at .choir/context/<feature_slug>-spec.md. Refuses if the spec file already exists.",
      [@types.Role::Root, @types.Role::TL],
    ),
    // Dev leaves AND Workers MUST NOT mint their own audit receipts.
    // Auto-audit-on-file-pr is gone (the Sarcasmotron worker was the
    // historical Worker caller); the /audit skill is now TL-driven and
    // writes the receipt itself after the worker returns. Restrict to
    // Root/TL. The forgery hole is narrowed but not closed — Root/TL
    // could in principle still write a stale receipt without actually
    // running an audit; proper attestation requires binding the write
    // to a spawn_worker completion token, filed as follow-up.
    tool_def(
      "write_audit_receipt",
      "Write the typed audit receipt for the current audited HEAD, including findings_count.",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def("send_message", "Send message to any agent by ID", all_roles),
    tool_def(
      "check_inbox",
      "Drain your pending inbox: returns all queued messages and marks them delivered. Call this whenever you see a 'choir: N messages pending' nudge in your terminal.",
      all_roles,
    ),
    tool_def(
      "reply", "Store a reply to a pending interaction request", all_roles,
    ),
    tool_def("shutdown", "Notify parent, close own pane", [
      @types.Role::TL,
      @types.Role::Dev,
      @types.Role::Worker,
    ]),
    tool_def(
      "kill_agent",
      "Kill a child agent by agent_id; closes its pane and cleans up registry",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "kv_get",
      "Read one value from shared KV storage (flat key: no '/' in key)",
      all_roles,
      read_only=true,
    ),
    tool_def(
      "kv_set", "Write one value to shared KV storage (flat key: no '/' in key)",
      all_roles,
    ),
    tool_def(
      "kv_delete", "Delete one value from shared KV storage (flat key: no '/' in key)",
      all_roles,
    ),
    tool_def(
      "kv_list",
      "List all keys in shared KV storage",
      all_roles,
      read_only=true,
    ),
    tool_def(
      "goal_set",
      "Set or supersede the active TL goal for this session",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def("goal_clear", "Clear the active TL goal for this session", [
      @types.Role::Root,
      @types.Role::TL,
    ]),
    tool_def(
      "goal_status",
      "Inspect the active TL goal for this session",
      [@types.Role::Root, @types.Role::TL],
      read_only=true,
    ),
    tool_def(
      "mutex_acquire", "Acquire an in-memory coordination mutex", all_roles,
    ),
    tool_def(
      "mutex_release", "Release an in-memory coordination mutex", all_roles,
    ),
    tool_def(
      "mutex_status",
      "Inspect an in-memory coordination mutex",
      all_roles,
      read_only=true,
    ),
    tool_def(
      "task_list",
      "List Beads-backed shared tasks",
      [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
      read_only=true,
    ),
    tool_def(
      "task_get",
      "Get a Beads-backed shared task by ID",
      [@types.Role::TL, @types.Role::Dev, @types.Role::Worker],
      read_only=true,
    ),
    tool_def("task_create", "Create a Beads-backed shared task", [
      @types.Role::TL,
      @types.Role::Dev,
      @types.Role::Worker,
    ]),
    tool_def("task_update", "Update a Beads-backed shared task status/owner", [
      @types.Role::TL,
      @types.Role::Dev,
      @types.Role::Worker,
    ]),
    tool_def(
      "agent_list",
      "List active agents in the registry by default; optional parent_id filters to direct children and include_inactive=true shows the full registry view",
      all_roles,
      read_only=true,
    ),
    tool_def(
      "cancel_wave",
      "Kill all active children of the calling agent and clean up their lifecycle/PR tracking; optional force=true to cancel even mid-review children",
      [@types.Role::Root, @types.Role::TL],
    ),
    tool_def(
      "resolve_review_thread",
      "Resolve a GitHub pull request review thread by its thread ID; thread IDs are included in merge_pr unresolved-thread error messages",
      [@types.Role::Root, @types.Role::TL, @types.Role::Dev],
    ),
    tool_def(
      "resolve_my_review_threads",
      "Resolve all currently tracked unresolved GitHub review threads for the caller's PR(s) using the server's GitHub credentials.",
      [@types.Role::Root, @types.Role::TL, @types.Role::Dev],
    ),
    tool_def(
      "request_review",
      "Request a reviewer on a tracked PR using the server's GitHub credentials.",
      [@types.Role::Root, @types.Role::TL, @types.Role::Dev],
    ),
    tool_def(
      "suspend",
      "Suspend a child agent: transitions Active → Suspended, pausing poll delivery and the idle watchdog for that agent until `resume` is called. Use when handing the worktree back to a human for manual intervention.",
      [@types.Role::Root, @types.Role::TL, @types.Role::Operator],
    ),
    tool_def(
      "resume",
      "Resume a suspended child agent: transitions Suspended → Active, unblocking poll delivery for that agent.",
      [@types.Role::Root, @types.Role::TL],
    ),
  ]
  for def in defs {
    tools.set(def.name, def)
  }
  { tools, }
}

///|
pub fn ToolRegistry::tool_names(self : ToolRegistry) -> Array[String] {
  self.tools.keys().collect()
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
