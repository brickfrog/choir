///|
pub(all) enum JsonRpcId {
  Number(Int)
  String(String)
} derive(Eq)

///|
pub impl Show for JsonRpcId with output(self, logger) -> Unit {
  match self {
    Number(n) => logger.write_string(n.to_string())
    String(s) => logger.write_string(s)
  }
}

///|
/// A JSON-RPC request from an MCP client.
pub(all) struct JsonRpcRequest {
  jsonrpc : String
  id : JsonRpcId?
  req_method : String
  params : Json?
} derive(Eq)

///|
/// A JSON-RPC error object.
pub(all) struct JsonRpcError {
  code : Int
  message : String
} derive(Eq)

///|
/// A JSON-RPC response to an MCP client.
pub(all) struct JsonRpcResponse {
  jsonrpc : String
  id : JsonRpcId
  result : Json?
  error : JsonRpcError?
} derive(Eq)
