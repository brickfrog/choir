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
/// JSON object field bag used on the internal wire (request args and ok-payload fields).
pub(all) struct FieldMap {
  values : Map[String, Json]
} derive(Show)

///|
pub type RequestArgs = FieldMap

///|
pub type ResponseFields = FieldMap

///|
pub fn FieldMap::new(values : Map[String, String]) -> FieldMap {
  let converted : Map[String, Json] = {}
  values.each(fn(k, v) { converted.set(k, v.to_json()) })
  { values: converted }
}

///|
pub fn FieldMap::from_values(values : Map[String, Json]) -> FieldMap {
  { values, }
}

///|
pub fn FieldMap::get(self : FieldMap, key : String) -> String? {
  match self.values.get(key) {
    Some(value) => Some(json_to_compat_string(value))
    None => None
  }
}

///|
pub fn FieldMap::get_json(self : FieldMap, key : String) -> Json? {
  self.values.get(key)
}

///|
pub fn FieldMap::get_int(self : FieldMap, key : String) -> Int? {
  match self.values.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
pub fn FieldMap::get_bool(self : FieldMap, key : String) -> Bool? {
  match self.values.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
pub fn FieldMap::contains(self : FieldMap, key : String) -> Bool {
  self.values.contains(key)
}

///|
pub fn FieldMap::each(self : FieldMap, f : (String, String) -> Unit) -> Unit {
  self.values.each(fn(k, v) { f(k, json_to_compat_string(v)) })
}

///|
pub fn FieldMap::each_json(self : FieldMap, f : (String, Json) -> Unit) -> Unit {
  self.values.each(f)
}

///|
pub fn FieldMap::to_map(self : FieldMap) -> Map[String, String] {
  let converted : Map[String, String] = {}
  self.values.each(fn(k, v) { converted.set(k, json_to_compat_string(v)) })
  converted
}

///|
pub fn FieldMap::to_json_map(self : FieldMap) -> Map[String, Json] {
  self.values
}

///|
/// Internal wire format request (UDS/TCP, not MCP JSON-RPC).
pub(all) struct Request {
  req_method : String
  role : Role
  name : String
  args : RequestArgs
} derive(Show)

///|
/// Internal wire format response.
pub(all) enum Response {
  Ok(ResponseFields)
  Err(String)
} derive(Show)

///|
pub fn Response::ok(self : Map[String, String]) -> Response {
  Ok(FieldMap::new(self))
}

///|
pub fn Response::ok_values(self : Map[String, Json]) -> Response {
  Ok(FieldMap::from_values(self))
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
pub fn Response::with_warning(self : Response, warning : String) -> Response {
  match self {
    Ok(fields) => {
      let values = fields.to_json_map()
      values.set("warning", warning.to_json())
      Ok(FieldMap::from_values(values))
    }
    Err(_) => self
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
