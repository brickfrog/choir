///|
struct SchemaProp {
  name : String
  desc : String
} derive(Debug, Eq)

///|
struct CatalogTool {
  name : String
  description : String
  props : Array[SchemaProp]
  required : Array[String]
} derive(Debug, Eq)

///|
fn schema_prop_json(prop : SchemaProp) -> Json {
  let m : Map[String, Json] = {
    "type": "string".to_json(),
    "description": prop.desc.to_json(),
  }
  m.to_json()
}

///|
fn schema_json(props : Array[SchemaProp], required : Array[String]) -> Json {
  let properties : Map[String, Json] = {}
  for prop in props {
    properties.set(prop.name, schema_prop_json(prop))
  }
  let req_arr : Array[Json] = required.map(fn(s) { s.to_json() })
  let m : Map[String, Json] = {
    "type": "object".to_json(),
    "properties": properties.to_json(),
    "required": req_arr.to_json(),
  }
  m.to_json()
}

///|
fn tool_json(tool : CatalogTool) -> Json {
  let m : Map[String, Json] = {
    "name": tool.name.to_json(),
    "description": tool.description.to_json(),
    "inputSchema": schema_json(tool.props, tool.required),
  }
  m.to_json()
}

///|
fn text_content_json(text : String) -> Json {
  let entry : Map[String, Json] = {
    "type": "text".to_json(),
    "text": text.to_json(),
  }
  [entry.to_json()].to_json()
}

///|
/// Translate an MCP JSON-RPC tools/call request to an internal Request.
pub fn to_internal_request(
  rpc : JsonRpcRequest,
  role : @types.Role,
  default_caller_id? : String? = None,
) -> Result[@types.Request, JsonRpcError] {
  if rpc.req_method == method_tools_list {
    // Return a sentinel request that the server will recognize
    return Ok({
      req_method: method_tools_list,
      role,
      name: "tools_list",
      args: @types.RequestArgs::new({}),
    })
  }
  if rpc.req_method != method_tools_call {
    return Err({
      code: err_method_not_found,
      message: "unsupported method: " + rpc.req_method,
    })
  }
  let params : Map[String, Json] = match rpc.params {
    Some(Object(p)) => p
    _ => {}
  }
  let name = match params.get("name") {
    Some(String(n)) => n
    None =>
      return Err({
        code: err_invalid_params,
        message: "missing 'name' in params",
      })
    Some(_) =>
      return Err({
        code: err_invalid_params,
        message: "invalid 'name' in params",
      })
  }
  let args_json : Map[String, Json] = match params.get("arguments") {
    Some(Object(obj)) => obj
    Some(String(json_str)) => {
      // Legacy: arguments passed as a JSON string
      let flat = parse_flat_json_object(json_str)
      let converted : Map[String, Json] = {}
      flat.each(fn(k, v) { converted.set(k, v.to_json()) })
      converted
    }
    _ => {}
  }
  // Always set caller_id from connection identity -- agents cannot self-identify
  match default_caller_id {
    Some(id) => args_json.set("caller_id", id.to_json())
    None => ()
  }
  Ok({
    req_method: rpc.req_method,
    role,
    name,
    args: @types.RequestArgs::from_values(args_json),
  })
}

///|
/// Create a JSON-RPC response for the MCP initialize handshake.
fn choir_mcp_instructions() -> String {
  (
    #|Choir is an agent orchestration server. You are the Team Lead (TL). Delegate all implementation to leaf agents via fork_wave (default gemini; set agent_type for claude, moon_pilot, codex, or cursor_agent). Never edit files directly -- read code to understand it, then delegate. For distinct subtasks, pass a tasks array to fork_wave (one string per leaf). For identical parallel work, pass task + count. spawn_worker is research-only -- workers cannot edit files or file PRs. After spawning leaves, stop and wait for notify_parent messages. Do not poll with sleep or git log. Use merge_pr to merge PRs, not git merge. Merge one at a time. Do not merge PRs until Copilot has reviewed them -- review notifications arrive automatically via the poller. When a leaf reports a PR, wait for the [REVIEW] notification before merging. Do not tell the user a PR is merged based on [PR READY], [FIXES PUSHED], or leaf notify_parent/shutdown text alone. Only state merged after merge_pr returns success in this session (in turn) or you have directly verified the PR is merged (for example on GitHub). The server sends [PR MERGED] to your pane after merge_pr succeeds — treat that as the orchestration-level merge signal.
    #|
    #|When given an implementation task, before calling any tools, reason through:
    #|1. Boundaries — what are the independent units of work? Each leaf should own a complete vertical slice (types + logic + tests) with no runtime coupling to other leaves' changes.
    #|2. Interfaces — if leaves touch shared code, what are the contracts? Define shared types, function signatures, or module boundaries as scaffold before forking. Two leaves should never need to coordinate on a type definition.
    #|3. Entanglement check — will merging leaf A's PR create conflicts with leaf B's? If yes, they're not independent — either sequence them (wave 1 then wave 2) or merge them into one leaf.
    #|4. Size — single leaf (self-contained, one area) or wave (2+ independent subtasks)?
    #|5. Agent types — gemini (default, bulk implementation), cursor_agent (refactor/file navigation), codex (isolated logic), claude (complex reasoning/architecture), spawn_worker (no branch, runs in parent workspace).
    #|6. Scaffold — commit shared types, interfaces, or test infra to the parent branch before forking. Every leaf should inherit a compilable, complete interface contract.
    #|After merging all PRs in a wave, spawn a worker to run the full test suite on your branch before starting the next wave or filing your own PR.
    #|Then state your plan in 2-4 lines and execute immediately. Do not ask for approval unless the task is genuinely ambiguous.
  )
}

///|
pub fn initialize_response(id : JsonRpcId) -> JsonRpcResponse {
  let empty_obj : Map[String, Json] = {}
  let capabilities : Map[String, Json] = { "tools": empty_obj.to_json() }
  let server_info : Map[String, Json] = {
    "name": "choir".to_json(),
    "version": "1.0.0".to_json(),
  }
  let result : Map[String, Json] = {
    "protocolVersion": "2024-11-05".to_json(),
    "capabilities": capabilities.to_json(),
    "serverInfo": server_info.to_json(),
    "instructions": choir_mcp_instructions().to_json(),
  }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
fn spawn_worker_props() -> Array[SchemaProp] {
  [
    { name: "task", desc: "Primary task for the worker agent" },
    { name: "prompt", desc: "Optional full prompt override" },
    { name: "slug", desc: "Worker slug (default inline-worker)" },
    { name: "agent_id", desc: "Compatibility alias for slug" },
    {
      name: "agent_type",
      desc: "Worker agent type: gemini, claude, moon_pilot, codex, or cursor_agent",
    },
    { name: "type", desc: "Worker profile: research or review" },
    { name: "read_first", desc: "Newline-separated paths to read first" },
    { name: "steps", desc: "Newline-separated implementation steps" },
    { name: "verify", desc: "Newline-separated verification commands" },
    { name: "done_criteria", desc: "Newline-separated acceptance criteria" },
    {
      name: "boundary",
      desc: "Newline-separated things the worker must not do",
    },
    { name: "constraints", desc: "Newline-separated extra constraints" },
    { name: "context", desc: "Context or reasoning summary for the worker" },
    {
      name: "key_decisions",
      desc: "Newline-separated decisions that are already fixed",
    },
    { name: "non_goals", desc: "Newline-separated non-goals" },
  ]
}

///|
fn tool_defs() -> Array[CatalogTool] {
  [
    {
      name: "fork_wave",
      description: "Spawn agents in new worktrees (default dev leaves; optional role=tl for a sub-team-lead). For distinct tasks, pass a tasks array (one entry per leaf, count is inferred). For identical tasks (best-of-N), pass task + count. Set automerge=true to request automatic merge_pr once review policy is satisfied (default false — TL merges manually)",
      props: [
        { name: "task", desc: "Shared task for all leaves (use with count)" },
        {
          name: "tasks",
          desc: "JSON array of per-leaf task strings -- each leaf gets exactly one. Count is inferred from array length. Mutually exclusive with task+count",
        },
        {
          name: "agent_type",
          desc: "Agent type: gemini (default), claude, moon_pilot, codex, or cursor_agent",
        },
        {
          name: "role",
          desc: "Spawned child role: dev (default) or tl (sub-TL; nesting limited to one level below root TL)",
        },
        {
          name: "parent_branch",
          desc: "Parent branch for spawned children (default main)",
        },
        { name: "branch", desc: "Compatibility alias for parent_branch" },
        { name: "count", desc: "Number of leaves when using shared task" },
        { name: "slug_prefix", desc: "Slug prefix for spawned children" },
        {
          name: "automerge",
          desc: "Request automatic merge_pr after review policy is satisfied (default false — TL merges manually via merge_pr)",
        },
        { name: "read_first", desc: "Newline-separated paths to read first" },
        { name: "steps", desc: "Newline-separated implementation steps" },
        { name: "verify", desc: "Newline-separated verification commands" },
        { name: "done_criteria", desc: "Newline-separated acceptance criteria" },
        {
          name: "boundary",
          desc: "Newline-separated things children must not do",
        },
        { name: "constraints", desc: "Newline-separated extra constraints" },
        { name: "context", desc: "Context or reasoning summary for the wave" },
        {
          name: "key_decisions",
          desc: "Newline-separated decisions that are already fixed",
        },
        { name: "non_goals", desc: "Newline-separated non-goals" },
      ],
      required: ["task", "count"],
    },
    {
      name: "spawn_gemini",
      description: "Spawn a single Gemini leaf agent in a worktree",
      props: [
        { name: "task", desc: "Task for the agent" },
        { name: "slug", desc: "Agent slug (auto-derived if omitted)" },
        { name: "parent_branch", desc: "Parent branch (default main)" },
        { name: "caller_id", desc: "ID of the caller" },
      ],
      required: ["task"],
    },
    {
      name: "rescue_leaf",
      description: "Reuse a salvageable dev worktree/branch: spawn replacement agent (default cursor_agent), hand off dev lifecycle, transfer tracked PR ownership, supersede old leaf",
      props: [
        { name: "task", desc: "Task prompt for the replacement leaf" },
        {
          name: "from_agent_id",
          desc: "Salvaged leaf agent id (git branch / prior CHOIR_AGENT_ID)",
        },
        {
          name: "new_slug",
          desc: "Slug for the replacement agent (new id = parent_prefix.new_slug)",
        },
        {
          name: "caller_id",
          desc: "Owning parent id (must match salvaged leaf parent)",
        },
        {
          name: "agent_type",
          desc: "gemini|claude|moon_pilot|codex|cursor_agent (default cursor_agent)",
        },
      ],
      required: ["task", "from_agent_id", "new_slug", "caller_id"],
    },
    {
      name: "spawn_worker",
      description: "Spawn an inline worker for research/review. Workers do not own a branch or PR",
      props: spawn_worker_props(),
      required: ["task"],
    },
    {
      name: "file_pr",
      description: "Push the branch, create or resolve its PR, and auto-track it for review events",
      props: [
        { name: "branch", desc: "Branch to file a PR for" },
        {
          name: "agent_id",
          desc: "Compatibility alias for branch and tracked agent id",
        },
        {
          name: "parent_branch",
          desc: "Parent branch to target (default main)",
        },
        { name: "caller_id", desc: "Optional tracked agent id override" },
        { name: "title", desc: "PR title (default: branch slug)" },
        { name: "body", desc: "PR description body" },
      ],
      required: [],
    },
    {
      name: "merge_pr",
      description: "Merge a pull request by number",
      props: [
        { name: "pr_number", desc: "Pull request number to merge" },
        { name: "parent_branch", desc: "Branch to merge into" },
        { name: "force", desc: "Skip review comment checks (default false)" },
      ],
      required: ["pr_number", "parent_branch"],
    },
    {
      name: "track_pr",
      description: "Track a pull request in the background poller",
      props: [
        { name: "pr_number", desc: "Pull request number to track" },
        { name: "agent_id", desc: "Agent ID that owns the PR" },
        {
          name: "branch",
          desc: "Owning branch for the PR (defaults to agent_id)",
        },
        {
          name: "parent_branch",
          desc: "Parent branch / PR base (derived when omitted)",
        },
        { name: "pr_url", desc: "Pull request URL when known" },
      ],
      required: ["pr_number", "agent_id"],
    },
    {
      name: "notify_parent",
      description: "Notify the parent agent with a status update",
      props: [
        { name: "caller_id", desc: "ID of the calling agent" },
        { name: "message", desc: "Message to send to parent" },
      ],
      required: ["caller_id", "message"],
    },
    {
      name: "send_message",
      description: "Send a message to another agent",
      props: [
        { name: "target_id", desc: "ID of the target agent" },
        { name: "message", desc: "Message content to send" },
      ],
      required: ["target_id", "message"],
    },
    {
      name: "kv_get",
      description: "Read one value from shared KV storage",
      props: [{ name: "key", desc: "Storage key to read" }],
      required: ["key"],
    },
    {
      name: "kv_set",
      description: "Write one value to shared KV storage",
      props: [
        { name: "key", desc: "Storage key to write" },
        { name: "value", desc: "Value to store" },
      ],
      required: ["key", "value"],
    },
    {
      name: "kv_delete",
      description: "Delete one value from shared KV storage",
      props: [{ name: "key", desc: "Storage key to delete" }],
      required: ["key"],
    },
    {
      name: "mutex_acquire",
      description: "Acquire an in-memory coordination mutex",
      props: [
        { name: "name", desc: "Mutex name" },
        { name: "agent_id", desc: "ID of the acquiring agent" },
        { name: "ttl_sec", desc: "Optional TTL in seconds" },
      ],
      required: ["name", "agent_id"],
    },
    {
      name: "mutex_release",
      description: "Release an in-memory coordination mutex",
      props: [
        { name: "name", desc: "Mutex name" },
        { name: "agent_id", desc: "ID of the releasing agent" },
      ],
      required: ["name", "agent_id"],
    },
    {
      name: "mutex_status",
      description: "Inspect an in-memory coordination mutex",
      props: [{ name: "name", desc: "Mutex name to inspect" }],
      required: ["name"],
    },
    {
      name: "task_list",
      description: "List tasks from shared task storage",
      props: [{ name: "slug", desc: "Optional slug filter" }],
      required: [],
    },
    {
      name: "task_get",
      description: "Get one task from shared task storage",
      props: [{ name: "id", desc: "Task slug / ID" }],
      required: ["id"],
    },
    {
      name: "task_update",
      description: "Update one task in shared task storage",
      props: [
        { name: "id", desc: "Task slug / ID" },
        { name: "status", desc: "Updated status" },
        { name: "assignee", desc: "Updated assignee" },
        { name: "notes", desc: "Updated task notes" },
      ],
      required: ["id"],
    },
    {
      name: "kv_list",
      description: "List keys in shared KV storage",
      props: [{ name: "prefix", desc: "Optional key prefix filter" }],
      required: [],
    },
    {
      name: "fork_session",
      description: "Create a new named session directory",
      props: [{ name: "name", desc: "Session name (slug)" }],
      required: ["name"],
    },
    {
      name: "spawn_remote",
      description: "Spawn a remote agent via SSH",
      props: [
        { name: "ssh_target", desc: "SSH host to connect to" },
        { name: "repo_url", desc: "Git repo URL to clone" },
        { name: "tcp_addr", desc: "TCP address for reverse connection" },
        { name: "task", desc: "Task for the remote agent" },
        { name: "slug", desc: "Agent slug (default remote-leaf)" },
        { name: "parent_branch", desc: "Parent branch (default main)" },
      ],
      required: ["ssh_target", "repo_url", "tcp_addr"],
    },
    {
      name: "shutdown",
      description: "Shutdown the server",
      props: [
        {
          name: "caller_id",
          desc: "Optional calling agent id for best-effort shutdown",
        },
      ],
      required: [],
    },
    {
      name: "kill_agent",
      description: "Kill a child agent — closes its pane and cleans up. Use when an agent is stuck or its work is done",
      props: [
        { name: "agent_id", desc: "Agent ID to kill" },
        {
          name: "reason",
          desc: "Reason for killing (default: killed by parent)",
        },
      ],
      required: ["agent_id"],
    },
  ]
}

///|
/// Create a JSON-RPC response with the list of available tools.
pub fn tools_list_response(id : JsonRpcId) -> JsonRpcResponse {
  let defs = tool_defs()
  let tools_arr : Array[Json] = defs.map(fn(d) { tool_json(d) })
  let result : Map[String, Json] = { "tools": tools_arr.to_json() }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
/// Translate an internal Response to a JSON-RPC response.
pub fn from_internal_response(
  id : JsonRpcId,
  resp : @types.Response,
) -> JsonRpcResponse {
  match resp.ok_payload() {
    Some(data) => {
      let payload : Map[String, Json] = {}
      data.each_json(fn(k, v) { payload.set(k, v) })
      let text = payload.to_json().stringify()
      let content = text_content_json(text)
      let result : Map[String, Json] = {
        "content": content,
        "structuredContent": payload.to_json(),
        "isError": false.to_json(),
      }
      { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
    }
    None => {
      let msg = match resp.error_message() {
        Some(v) => v
        None => ""
      }
      let content = text_content_json(msg)
      let structured : Map[String, Json] = { "error": msg.to_json() }
      let result : Map[String, Json] = {
        "content": content,
        "structuredContent": structured.to_json(),
        "isError": true.to_json(),
      }
      { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
    }
  }
}

///|
/// Create a JSON-RPC error response.
pub fn error_response(
  id : JsonRpcId,
  code : Int,
  message : String,
) -> JsonRpcResponse {
  { jsonrpc: "2.0", id, result: None, error: Some({ code, message }) }
}

///|
pub impl Show for SchemaProp with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for CatalogTool with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
