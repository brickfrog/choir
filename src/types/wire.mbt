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

///|
pub fn Response::ok_fields(self : Response) -> Map[String, String]? {
  match self {
    Ok(fields) => Some(fields)
    Err(_) => None
  }
}

///|
pub fn Response::ok_field(self : Response, key : String) -> String? {
  match self {
    Ok(fields) => fields.get(key)
    Err(_) => None
  }
}

///|
pub fn Response::is_ok(self : Response) -> Bool {
  match self {
    Ok(_) => true
    Err(_) => false
  }
}

///|
pub fn Response::error_message(self : Response) -> String? {
  match self {
    Ok(_) => None
    Err(msg) => Some(msg)
  }
}

///|
pub fn Response::status_tag(self : Response) -> String {
  if self.is_ok() {
    "ok"
  } else {
    "error"
  }
}
