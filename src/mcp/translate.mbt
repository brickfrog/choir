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
  let args = match rpc.params {
    Some(p) => p
    None => {}
  }
  let name = match args.get("name") {
    Some(n) => n
    None =>
      return Err({
        code: err_invalid_params,
        message: "missing 'name' in params",
      })
  }
  Ok({ req_method: rpc.req_method, role, name, args })
}

///|
/// Create a JSON-RPC response with the list of available tools.
pub fn tools_list_response(id : Int) -> JsonRpcResponse {
  let tools_json = "[" +
    "{\"name\":\"fork_wave\",\"description\":\"Fork a new wave of worker agents\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"file_pr\",\"description\":\"File a pull request for the current branch\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"merge_pr\",\"description\":\"Merge a pull request by number\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"notify_parent\",\"description\":\"Notify the parent agent with a status update\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"send_message\",\"description\":\"Send a message to another agent\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"spawn_gemini\",\"description\":\"Spawn a Gemini leaf agent in a new worktree\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"spawn_worker\",\"description\":\"Spawn an inline worker agent\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"task_list\",\"description\":\"List tasks from shared task storage\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"task_get\",\"description\":\"Get one task from shared task storage\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"task_update\",\"description\":\"Update one task in shared task storage\",\"inputSchema\":{\"type\":\"object\"}}," +
    "{\"name\":\"shutdown\",\"description\":\"Shutdown the server\",\"inputSchema\":{\"type\":\"object\"}}" +
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
    @types.Response::Ok(data) =>
      { jsonrpc: "2.0", id, result: Some(data), error: None }
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
