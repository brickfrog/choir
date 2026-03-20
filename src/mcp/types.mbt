///|
pub(all) enum JsonRpcId {
  Number(Int)
  String(String)
} derive(Show, Eq)

///|
pub(all) enum JsonValue {
  Object(Map[String, JsonValue])
  String(String)
  Raw(String)
} derive(Show)

///|
/// A JSON-RPC request from an MCP client.
pub(all) struct JsonRpcRequest {
  jsonrpc : String
  id : JsonRpcId?
  req_method : String
  params : JsonValue?
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
  result : JsonValue?
  error : JsonRpcError?
} derive(Show)
