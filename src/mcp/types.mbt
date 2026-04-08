///|
pub(all) enum JsonRpcId {
  Number(Int)
  String(String)
} derive(Debug, Eq)

///|
pub impl Show for JsonRpcId with output(self, logger) {
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
}

///|
pub impl Show for JsonRpcRequest with output(self, logger) {
  logger.write_string("JsonRpcRequest { req_method: ")
  logger.write_string(self.req_method)
  logger.write_string(" }")
}

///|
/// A JSON-RPC error object.
pub(all) struct JsonRpcError {
  code : Int
  message : String
} derive(Debug, Eq)

///|
/// A JSON-RPC response to an MCP client.
pub(all) struct JsonRpcResponse {
  jsonrpc : String
  id : JsonRpcId
  result : Json?
  error : JsonRpcError?
}

///|
pub impl Show for JsonRpcResponse with output(self, logger) {
  logger.write_string("JsonRpcResponse { id: ")
  self.id.output(logger)
  logger.write_string(" }")
}
