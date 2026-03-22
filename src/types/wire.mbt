///|
/// Extract a compat string from a Json value.
/// String → inner text (unquoted), everything else → .stringify().
fn json_to_compat_string(json : Json) -> String {
  match json {
    String(s) => s
    _ => json.stringify()
  }
}

///|
/// Internal wire format request (UDS/TCP, not MCP JSON-RPC).
pub(all) struct RequestArgs {
  values : Map[String, Json]
} derive(Show)

///|
pub fn RequestArgs::new(values : Map[String, String]) -> RequestArgs {
  let converted : Map[String, Json] = {}
  values.each(fn(k, v) { converted.set(k, v.to_json()) })
  { values: converted }
}

///|
pub fn RequestArgs::from_values(values : Map[String, Json]) -> RequestArgs {
  { values, }
}

///|
pub fn RequestArgs::get(self : RequestArgs, key : String) -> String? {
  match self.values.get(key) {
    Some(value) => Some(json_to_compat_string(value))
    None => None
  }
}

///|
pub fn RequestArgs::get_json(self : RequestArgs, key : String) -> Json? {
  self.values.get(key)
}

///|
pub fn RequestArgs::get_int(self : RequestArgs, key : String) -> Int? {
  match self.values.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
pub fn RequestArgs::get_bool(self : RequestArgs, key : String) -> Bool? {
  match self.values.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
pub fn RequestArgs::contains(self : RequestArgs, key : String) -> Bool {
  self.values.contains(key)
}

///|
pub fn RequestArgs::each(
  self : RequestArgs,
  f : (String, String) -> Unit,
) -> Unit {
  self.values.each(fn(k, v) { f(k, json_to_compat_string(v)) })
}

///|
pub fn RequestArgs::each_json(
  self : RequestArgs,
  f : (String, Json) -> Unit,
) -> Unit {
  self.values.each(f)
}

///|
pub fn RequestArgs::to_map(self : RequestArgs) -> Map[String, String] {
  let converted : Map[String, String] = {}
  self.values.each(fn(k, v) { converted.set(k, json_to_compat_string(v)) })
  converted
}

///|
pub fn RequestArgs::to_json_map(self : RequestArgs) -> Map[String, Json] {
  self.values
}

///|
pub(all) struct Request {
  req_method : String
  role : Role
  name : String
  args : RequestArgs
} derive(Show)

///|
pub(all) struct ResponseFields {
  values : Map[String, Json]
} derive(Show)

///|
pub fn ResponseFields::new(values : Map[String, String]) -> ResponseFields {
  let converted : Map[String, Json] = {}
  values.each(fn(k, v) { converted.set(k, v.to_json()) })
  { values: converted }
}

///|
pub fn ResponseFields::from_values(
  values : Map[String, Json],
) -> ResponseFields {
  { values, }
}

///|
pub fn ResponseFields::get(self : ResponseFields, key : String) -> String? {
  match self.values.get(key) {
    Some(value) => Some(json_to_compat_string(value))
    None => None
  }
}

///|
pub fn ResponseFields::get_json(self : ResponseFields, key : String) -> Json? {
  self.values.get(key)
}

///|
pub fn ResponseFields::each(
  self : ResponseFields,
  f : (String, String) -> Unit,
) -> Unit {
  self.values.each(fn(k, v) { f(k, json_to_compat_string(v)) })
}

///|
pub fn ResponseFields::each_json(
  self : ResponseFields,
  f : (String, Json) -> Unit,
) -> Unit {
  self.values.each(f)
}

///|
pub fn ResponseFields::to_map(self : ResponseFields) -> Map[String, String] {
  let converted : Map[String, String] = {}
  self.values.each(fn(k, v) { converted.set(k, json_to_compat_string(v)) })
  converted
}

///|
pub fn ResponseFields::to_json_map(self : ResponseFields) -> Map[String, Json] {
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
pub fn Response::ok_values(self : Map[String, Json]) -> Response {
  Ok(ResponseFields::from_values(self))
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
