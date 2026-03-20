///|
/// Internal wire format request (UDS/TCP, not MCP JSON-RPC).
pub(all) struct Request {
  req_method : String
  role : Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
pub(all) struct ResponseFields {
  values : Map[String, String]
} derive(Show)

///|
pub fn ResponseFields::new(values : Map[String, String]) -> ResponseFields {
  { values, }
}

///|
pub fn ResponseFields::get(self : ResponseFields, key : String) -> String? {
  self.values.get(key)
}

///|
pub fn ResponseFields::each(
  self : ResponseFields,
  f : (String, String) -> Unit,
) -> Unit {
  self.values.each(f)
}

///|
pub fn ResponseFields::to_map(self : ResponseFields) -> Map[String, String] {
  self.values
}

///|
/// Internal wire format response.
pub(all) enum Response {
  Ok(ResponseFields)
  Err(String)
} derive(Show)

///|
pub fn Response::ok(self : Map[String, String]) -> Response {
  Ok(ResponseFields::new(self))
}

///|
pub fn Response::ok_payload(self : Response) -> ResponseFields? {
  match self {
    Ok(fields) => Some(fields)
    Err(_) => None
  }
}

///|
pub fn Response::ok_fields(self : Response) -> Map[String, String]? {
  match self.ok_payload() {
    Some(fields) => Some(fields.to_map())
    None => None
  }
}

///|
pub fn Response::ok_field(self : Response, key : String) -> String? {
  match self.ok_payload() {
    Some(fields) => fields.get(key)
    None => None
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
