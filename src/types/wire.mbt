///|
pub(all) enum WireValue {
  String(String)
  Raw(String)
} derive(Show, Eq)

///|
pub fn WireValue::to_compat_string(self : WireValue) -> String {
  match self {
    String(value) => value
    Raw(value) => value
  }
}

///|
/// Internal wire format request (UDS/TCP, not MCP JSON-RPC).
pub(all) struct RequestArgs {
  values : Map[String, WireValue]
} derive(Show)

///|
pub fn RequestArgs::new(values : Map[String, String]) -> RequestArgs {
  let converted : Map[String, WireValue] = {}
  values.each(fn(k, v) { converted.set(k, WireValue::String(v)) })
  { values: converted }
}

///|
pub fn RequestArgs::from_values(values : Map[String, WireValue]) -> RequestArgs {
  { values, }
}

///|
pub fn RequestArgs::get(self : RequestArgs, key : String) -> String? {
  match self.values.get(key) {
    Some(value) => Some(value.to_compat_string())
    None => None
  }
}

///|
pub fn RequestArgs::get_value(self : RequestArgs, key : String) -> WireValue? {
  self.values.get(key)
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
  self.values.each(fn(k, v) { f(k, v.to_compat_string()) })
}

///|
pub fn RequestArgs::each_value(
  self : RequestArgs,
  f : (String, WireValue) -> Unit,
) -> Unit {
  self.values.each(f)
}

///|
pub fn RequestArgs::to_map(self : RequestArgs) -> Map[String, String] {
  let converted : Map[String, String] = {}
  self.values.each(fn(k, v) { converted.set(k, v.to_compat_string()) })
  converted
}

///|
pub fn RequestArgs::to_value_map(self : RequestArgs) -> Map[String, WireValue] {
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
  values : Map[String, WireValue]
} derive(Show)

///|
pub fn ResponseFields::new(values : Map[String, String]) -> ResponseFields {
  let converted : Map[String, WireValue] = {}
  values.each(fn(k, v) { converted.set(k, WireValue::String(v)) })
  { values: converted }
}

///|
pub fn ResponseFields::from_values(
  values : Map[String, WireValue],
) -> ResponseFields {
  { values, }
}

///|
pub fn ResponseFields::get(self : ResponseFields, key : String) -> String? {
  match self.values.get(key) {
    Some(value) => Some(value.to_compat_string())
    None => None
  }
}

///|
pub fn ResponseFields::get_value(
  self : ResponseFields,
  key : String,
) -> WireValue? {
  self.values.get(key)
}

///|
pub fn ResponseFields::each(
  self : ResponseFields,
  f : (String, String) -> Unit,
) -> Unit {
  self.values.each(fn(k, v) { f(k, v.to_compat_string()) })
}

///|
pub fn ResponseFields::each_value(
  self : ResponseFields,
  f : (String, WireValue) -> Unit,
) -> Unit {
  self.values.each(f)
}

///|
pub fn ResponseFields::to_map(self : ResponseFields) -> Map[String, String] {
  let converted : Map[String, String] = {}
  self.values.each(fn(k, v) { converted.set(k, v.to_compat_string()) })
  converted
}

///|
pub fn ResponseFields::to_value_map(
  self : ResponseFields,
) -> Map[String, WireValue] {
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
pub fn Response::ok_values(self : Map[String, WireValue]) -> Response {
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
