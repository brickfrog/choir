///|
pub(all) enum JsonRpcId {
  Number(Int)
  String(String)
} derive(Show, Eq)

///|
/// A JSON-RPC request from an MCP client.
pub(all) struct JsonRpcRequest {
  jsonrpc : String
  id : JsonRpcId?
  req_method : String
  params : Json?
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
  id : JsonRpcId
  result : Json?
  error : JsonRpcError?
} derive(Show)
