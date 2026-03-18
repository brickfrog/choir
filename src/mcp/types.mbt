///|
/// A JSON-RPC request from an MCP client.
pub(all) struct JsonRpcRequest {
  jsonrpc : String
  id : Int
  req_method : String
  params : Map[String, String]?
} derive(Show)

///|
/// A JSON-RPC error object.
pub(all) struct JsonRpcError {
  code : Int
  message : String
} derive(Show, Eq)

///|
/// A JSON-RPC response to an MCP client.
pub(all) struct JsonRpcResponse {
  jsonrpc : String
  id : Int
  result : Map[String, String]?
  error : JsonRpcError?
} derive(Show)
