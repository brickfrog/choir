///|
struct SchemaProp {
  name : String
  desc : String
} derive(Show, Eq)

///|
struct CatalogTool {
  name : String
  description : String
  props : Array[SchemaProp]
  required : Array[String]
} derive(Show, Eq)

///|
fn json_string(s : String) -> String {
  "\"" + escape_json_string(s) + "\""
}

///|
fn schema_prop_json(prop : SchemaProp) -> JsonValue {
  JsonValue::Object({
    "type": JsonValue::String("string"),
    "description": JsonValue::String(prop.desc),
  })
}

///|
fn json_string_array(items : Array[String]) -> String {
  let buf = StringBuilder::new()
  buf.write_char('[')
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(json_string(items[i]))
  }
  buf.write_char(']')
  buf.to_string()
}

///|
fn schema_json(
  props : Array[SchemaProp],
  required : Array[String],
) -> JsonValue {
  let properties : Map[String, JsonValue] = {}
  for prop in props {
    properties.set(prop.name, schema_prop_json(prop))
  }
  JsonValue::Object({
    "type": JsonValue::String("object"),
    "properties": JsonValue::Object(properties),
    "required": JsonValue::Raw(json_string_array(required)),
  })
}

///|
fn tool_json(tool : CatalogTool) -> String {
  json_value_to_json(
    JsonValue::Object({
      "name": JsonValue::String(tool.name),
      "description": JsonValue::String(tool.description),
      "inputSchema": schema_json(tool.props, tool.required),
    }),
  )
}

///|
fn text_content_json(text : String) -> String {
  "[{\"type\":\"text\",\"text\":" + json_string(text) + "}]"
}

///|
/// Translate an MCP JSON-RPC tools/call request to an internal Request.
pub fn to_internal_request(
  rpc : JsonRpcRequest,
  role : @types.Role,
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
  let params = match rpc.params {
    Some(JsonValue::Object(p)) => p
    _ => ({} : Map[String, JsonValue])
  }
  let name = match params.get("name") {
    Some(JsonValue::String(n)) => n
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
  let args = match params.get("arguments") {
    Some(JsonValue::String(json_str)) => parse_flat_json_object(json_str)
    Some(JsonValue::Raw(json_str)) => parse_flat_json_object(json_str)
    None => {}
    Some(_) => {}
  }
  Ok({
    req_method: rpc.req_method,
    role,
    name,
    args: @types.RequestArgs::new(args),
  })
}

///|
/// Create a JSON-RPC response for the MCP initialize handshake.
pub fn initialize_response(id : JsonRpcId) -> JsonRpcResponse {
  {
    jsonrpc: "2.0",
    id,
    result: Some(
      JsonValue::Object({
        "protocolVersion": JsonValue::String("2024-11-05"),
        "capabilities": JsonValue::Raw("{\"tools\":{}}"),
        "serverInfo": JsonValue::Raw(
          "{\"name\":\"choir\",\"version\":\"1.0.0\"}",
        ),
      }),
    ),
    error: None,
  }
}

///|
fn spawn_leaf_props(
  default_slug : String,
  agent_label : String,
) -> Array[SchemaProp] {
  [
    { name: "task", desc: "Primary task for the " + agent_label },
    { name: "prompt", desc: "Optional full prompt override" },
    {
      name: "slug",
      desc: "Agent slug / branch suffix (default " + default_slug + ")",
    },
    { name: "branch", desc: "Compatibility alias for slug" },
    { name: "parent_branch", desc: "Parent branch (default main)" },
    {
      name: "fork_session",
      desc: "For Claude children, inherit parent session context when true",
    },
    {
      name: "parent_session_id",
      desc: "Explicit Claude parent session id override for --resume",
    },
    { name: "read_first", desc: "Newline-separated paths to read first" },
    { name: "steps", desc: "Newline-separated implementation steps" },
    { name: "verify", desc: "Newline-separated verification commands" },
    { name: "done_criteria", desc: "Newline-separated acceptance criteria" },
    { name: "boundary", desc: "Newline-separated things the agent must not do" },
    { name: "constraints", desc: "Newline-separated extra constraints" },
    {
      name: "context",
      desc: "Context or reasoning summary for the child agent",
    },
    {
      name: "key_decisions",
      desc: "Newline-separated decisions that are already fixed",
    },
    { name: "non_goals", desc: "Newline-separated non-goals" },
  ]
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
      desc: "Worker agent type: gemini, claude, or moon_pilot",
    },
    { name: "type", desc: "Worker profile: implementation or research" },
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
      description: "Fork a new wave of worker agents in a new git worktree",
      props: [
        { name: "task", desc: "Task description for the wave" },
        {
          name: "parent_branch",
          desc: "Parent branch for spawned children (default main)",
        },
        { name: "branch", desc: "Compatibility alias for parent_branch" },
        { name: "count", desc: "Number of workers to spawn (default 1)" },
        { name: "slug_prefix", desc: "Slug prefix for spawned children" },
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
      ],
      required: [],
    },
    {
      name: "merge_pr",
      description: "Merge a pull request by number",
      props: [
        { name: "pr_number", desc: "Pull request number to merge" },
        { name: "parent_branch", desc: "Branch to merge into" },
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
      name: "spawn_gemini",
      description: "Spawn a Gemini leaf agent in a new worktree",
      props: spawn_leaf_props("gemini-leaf", "Gemini leaf agent"),
      required: ["task"],
    },
    {
      name: "spawn_moon_pilot",
      description: "Spawn a Moon Pilot leaf agent in a new worktree",
      props: spawn_leaf_props("moon-pilot-leaf", "Moon Pilot leaf agent"),
      required: ["task"],
    },
    {
      name: "spawn_worker",
      description: "Spawn an inline worker in the current repo/session for research or small in-place tasks; no branch or PR",
      props: spawn_worker_props(),
      required: ["task"],
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
      name: "task_create",
      description: "Create a new task in shared task storage",
      props: [
        { name: "id", desc: "Task slug/ID" },
        { name: "title", desc: "Task title" },
        { name: "status", desc: "Initial status (default todo)" },
        { name: "assignee", desc: "Assignee agent ID" },
        { name: "notes", desc: "Task notes" },
      ],
      required: ["id", "title"],
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
  ]
}

///|
/// Create a JSON-RPC response with the list of available tools.
pub fn tools_list_response(id : JsonRpcId) -> JsonRpcResponse {
  let defs = tool_defs()
  let buf = StringBuilder::new()
  buf.write_char('[')
  for i = 0; i < defs.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(tool_json(defs[i]))
  }
  buf.write_char(']')
  let tools_json = buf.to_string()
  {
    jsonrpc: "2.0",
    id,
    result: Some(JsonValue::Object({ "tools": JsonValue::Raw(tools_json) })),
    error: None,
  }
}

///|
/// Translate an internal Response to a JSON-RPC response.
pub fn from_internal_response(
  id : JsonRpcId,
  resp : @types.Response,
) -> JsonRpcResponse {
  match resp.ok_payload() {
    Some(data) => {
      let payload : Map[String, JsonValue] = {}
      data.each_value(fn(k, v) {
        match v {
          @types.WireValue::String(text) =>
            payload.set(k, JsonValue::String(text))
          @types.WireValue::Raw(text) => payload.set(k, JsonValue::Raw(text))
        }
      })
      let text = json_value_to_json(JsonValue::Object(payload))
      let content = text_content_json(text)
      {
        jsonrpc: "2.0",
        id,
        result: Some(
          JsonValue::Object({
            "content": JsonValue::Raw(content),
            "structuredContent": JsonValue::Object(payload),
            "isError": JsonValue::Raw("false"),
          }),
        ),
        error: None,
      }
    }
    None => {
      let msg = match resp.error_message() {
        Some(v) => v
        None => ""
      }
      let content = text_content_json(msg)
      {
        jsonrpc: "2.0",
        id,
        result: Some(
          JsonValue::Object({
            "content": JsonValue::Raw(content),
            "structuredContent": JsonValue::Object({
              "error": JsonValue::String(msg),
            }),
            "isError": JsonValue::Raw("true"),
          }),
        ),
        error: None,
      }
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
