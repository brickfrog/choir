///|
/// Translate an MCP JSON-RPC tools/call request to an internal Request.
pub fn to_internal_request(
  rpc : JsonRpcRequest,
  role : @types.Role,
) -> Result[@types.Request, JsonRpcError] {
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
