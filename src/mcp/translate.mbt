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
      args: {},
    })
  }
  if rpc.req_method != method_tools_call {
    return Err({
      code: err_method_not_found,
      message: "unsupported method: " + rpc.req_method,
    })
  }
  let params = match rpc.params {
    Some(p) => p
    None => {}
  }
  let name = match params.get("name") {
    Some(n) => n
    None =>
      return Err({
        code: err_invalid_params,
        message: "missing 'name' in params",
      })
  }
  let args = match params.get("arguments") {
    Some(json_str) => parse_flat_json_object(json_str)
    None => {}
  }
  Ok({ req_method: rpc.req_method, role, name, args })
}

///|
/// Create a JSON-RPC response for the MCP initialize handshake.
pub fn initialize_response(id : Int) -> JsonRpcResponse {
  {
    jsonrpc: "2.0",
    id,
    result: Some({
      "protocolVersion": "2024-11-05",
      "capabilities": "{\"tools\":{}}",
      "serverInfo": "{\"name\":\"choir\",\"version\":\"1.0.0\"}",
    }),
    error: None,
  }
}

///|
fn schema(props : String, required : String) -> String {
  "{\"type\":\"object\",\"properties\":{" +
  props +
  "},\"required\":[" +
  required +
  "]}"
}

///|
fn prop(name : String, desc : String) -> String {
  "\"" + name + "\":{\"type\":\"string\",\"description\":\"" + desc + "\"}"
}

///|
/// Create a JSON-RPC response with the list of available tools.
pub fn tools_list_response(id : Int) -> JsonRpcResponse {
  let s = schema
  let p = prop
  let tools_json = "[" +
    "{\"name\":\"fork_wave\",\"description\":\"Fork a new wave of worker agents in a new git worktree\",\"inputSchema\":" +
    s(
      p("task", "Task description for the wave") +
      "," +
      p("branch", "Branch name for the worktree") +
      "," +
      p("count", "Number of workers to spawn (default 1)"),
      "\"task\",\"branch\"",
    ) +
    "}," +
    "{\"name\":\"file_pr\",\"description\":\"File a pull request for the current branch\",\"inputSchema\":" +
    s(p("agent_id", "ID of the agent filing the PR"), "\"agent_id\"") +
    "}," +
    "{\"name\":\"merge_pr\",\"description\":\"Merge a pull request by number\",\"inputSchema\":" +
    s(
      p("pr_number", "Pull request number to merge") +
      "," +
      p("parent_branch", "Branch to merge into"),
      "\"pr_number\",\"parent_branch\"",
    ) +
    "}," +
    "{\"name\":\"track_pr\",\"description\":\"Track a pull request in the background poller\",\"inputSchema\":" +
    s(
      p("pr_number", "Pull request number to track") +
      "," +
      p("agent_id", "Agent ID to notify on events"),
      "\"pr_number\",\"agent_id\"",
    ) +
    "}," +
    "{\"name\":\"notify_parent\",\"description\":\"Notify the parent agent with a status update\",\"inputSchema\":" +
    s(
      p("caller_id", "ID of the calling agent") +
      "," +
      p("message", "Message to send to parent"),
      "\"caller_id\",\"message\"",
    ) +
    "}," +
    "{\"name\":\"send_message\",\"description\":\"Send a message to another agent\",\"inputSchema\":" +
    s(
      p("target_id", "ID of the target agent") +
      "," +
      p("message", "Message content to send"),
      "\"target_id\",\"message\"",
    ) +
    "}," +
    "{\"name\":\"spawn_gemini\",\"description\":\"Spawn a Gemini leaf agent in a new worktree\",\"inputSchema\":" +
    s(
      p("task", "Task for the Gemini agent") +
      "," +
      p("branch", "Branch name for the worktree"),
      "\"task\",\"branch\"",
    ) +
    "}," +
    "{\"name\":\"spawn_moon_pilot\",\"description\":\"Spawn a Moon Pilot leaf agent in a new worktree\",\"inputSchema\":" +
    s(
      p("task", "Task for the Moon Pilot agent") +
      "," +
      p("branch", "Branch name for the worktree"),
      "\"task\",\"branch\"",
    ) +
    "}," +
    "{\"name\":\"spawn_worker\",\"description\":\"Spawn an inline worker agent in a tmux window\",\"inputSchema\":" +
    s(
      p("task", "Task for the worker agent") +
      "," +
      p("agent_id", "ID to assign the worker"),
      "\"task\",\"agent_id\"",
    ) +
    "}," +
    "{\"name\":\"kv_get\",\"description\":\"Read one value from shared KV storage\",\"inputSchema\":" +
    s(p("key", "Storage key to read"), "\"key\"") +
    "}," +
    "{\"name\":\"kv_set\",\"description\":\"Write one value to shared KV storage\",\"inputSchema\":" +
    s(
      p("key", "Storage key to write") + "," + p("value", "Value to store"),
      "\"key\",\"value\"",
    ) +
    "}," +
    "{\"name\":\"kv_delete\",\"description\":\"Delete one value from shared KV storage\",\"inputSchema\":" +
    s(p("key", "Storage key to delete"), "\"key\"") +
    "}," +
    "{\"name\":\"mutex_acquire\",\"description\":\"Acquire an in-memory coordination mutex\",\"inputSchema\":" +
    s(
      p("name", "Mutex name") +
      "," +
      p("agent_id", "ID of the acquiring agent") +
      "," +
      p("ttl_sec", "Optional TTL in seconds"),
      "\"name\",\"agent_id\"",
    ) +
    "}," +
    "{\"name\":\"mutex_release\",\"description\":\"Release an in-memory coordination mutex\",\"inputSchema\":" +
    s(
      p("name", "Mutex name") + "," + p("agent_id", "ID of the releasing agent"),
      "\"name\",\"agent_id\"",
    ) +
    "}," +
    "{\"name\":\"mutex_status\",\"description\":\"Inspect an in-memory coordination mutex\",\"inputSchema\":" +
    s(p("name", "Mutex name to inspect"), "\"name\"") +
    "}," +
    "{\"name\":\"task_list\",\"description\":\"List tasks from shared task storage\",\"inputSchema\":" +
    s(p("slug", "Optional slug filter"), "") +
    "}," +
    "{\"name\":\"task_get\",\"description\":\"Get one task from shared task storage\",\"inputSchema\":" +
    s(p("slug", "Task slug"), "\"slug\"") +
    "}," +
    "{\"name\":\"task_update\",\"description\":\"Update one task in shared task storage\",\"inputSchema\":" +
    s(
      p("slug", "Task slug") + "," + p("task", "Updated task JSON"),
      "\"slug\",\"task\"",
    ) +
    "}," +
    "{\"name\":\"kv_list\",\"description\":\"List keys in shared KV storage\",\"inputSchema\":" +
    s(p("prefix", "Optional key prefix filter"), "") +
    "}," +
    "{\"name\":\"task_create\",\"description\":\"Create a new task in shared task storage\",\"inputSchema\":" +
    s(
      p("id", "Task slug/ID") +
      "," +
      p("title", "Task title") +
      "," +
      p("status", "Initial status (default todo)") +
      "," +
      p("assignee", "Assignee agent ID") +
      "," +
      p("notes", "Task notes"),
      "\"id\",\"title\"",
    ) +
    "}," +
    "{\"name\":\"fork_session\",\"description\":\"Create a new named session directory\",\"inputSchema\":" +
    s(p("name", "Session name (slug)"), "\"name\"") +
    "}," +
    "{\"name\":\"spawn_remote\",\"description\":\"Spawn a remote agent via SSH\",\"inputSchema\":" +
    s(
      p("ssh_target", "SSH host to connect to") +
      "," +
      p("repo_url", "Git repo URL to clone") +
      "," +
      p("tcp_addr", "TCP address for reverse connection") +
      "," +
      p("task", "Task for the remote agent") +
      "," +
      p("slug", "Agent slug (default remote-leaf)") +
      "," +
      p("parent_branch", "Parent branch (default main)"),
      "\"ssh_target\",\"repo_url\",\"tcp_addr\"",
    ) +
    "}," +
    "{\"name\":\"shutdown\",\"description\":\"Shutdown the server\",\"inputSchema\":" +
    s("", "") +
    "}" +
    "]"
  { jsonrpc: "2.0", id, result: Some({ "tools": tools_json }), error: None }
}

///|
/// Translate an internal Response to a JSON-RPC response.
pub fn from_internal_response(
  id : Int,
  resp : @types.Response,
) -> JsonRpcResponse {
  match resp {
    @types.Response::Ok(data) => {
      let text = map_to_json(data)
      let content = "[{\"type\":\"text\",\"text\":\"" +
        escape_json_string(text) +
        "\"}]"
      {
        jsonrpc: "2.0",
        id,
        result: Some({ "content": content, "isError": "false" }),
        error: None,
      }
    }
    @types.Response::Err(msg) =>
      {
        jsonrpc: "2.0",
        id,
        result: None,
        error: Some({ code: err_internal, message: msg }),
      }
  }
}

///|
/// Create a JSON-RPC error response.
pub fn error_response(
  id : Int,
  code : Int,
  message : String,
) -> JsonRpcResponse {
  { jsonrpc: "2.0", id, result: None, error: Some({ code, message }) }
}
