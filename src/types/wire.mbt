///|
/// Internal wire format request (UDS/TCP, not MCP JSON-RPC).
pub(all) struct Request {
  req_method : String
  role : Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
/// Internal wire format response.
pub(all) enum Response {
  Ok(Map[String, String])
  Err(String)
} derive(Show)
