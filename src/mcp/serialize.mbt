///|
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
pub fn json_value_to_json(value : JsonValue) -> String {
  match value {
    Object(m) => map_to_json(m)
    String(s) => "\"" + escape_json_string(s) + "\""
    Raw(s) => s
  }
}

///|
fn map_to_json(m : Map[String, JsonValue]) -> String {
  let buf = StringBuilder::new()
  buf.write_char('{')
  let mut first = true
  m.each(fn(k, v) {
    if first {
      first = false
    } else {
      buf.write_char(',')
    }
    buf.write_char('"')
    buf.write_string(escape_json_string(k))
    buf.write_string("\":")
    buf.write_string(json_value_to_json(v))
  })
  buf.write_char('}')
  buf.to_string()
}

///|
fn id_to_json(id : JsonRpcId) -> String {
  match id {
    Number(n) => n.to_string()
    String(s) => "\"" + escape_json_string(s) + "\""
  }
}

///|
/// Serialize a JsonRpcResponse to a JSON string.
pub fn JsonRpcResponse::to_json_string(self : JsonRpcResponse) -> String {
  let buf = StringBuilder::new()
  buf.write_string("{\"jsonrpc\":\"2.0\",\"id\":")
  buf.write_string(id_to_json(self.id))
  match self.result {
    Some(data) => {
      buf.write_string(",\"result\":")
      buf.write_string(json_value_to_json(data))
    }
    None => ()
  }
  match self.error {
    Some(err) => {
      buf.write_string(",\"error\":{\"code\":")
      buf.write_string(err.code.to_string())
      buf.write_string(",\"message\":\"")
      buf.write_string(escape_json_string(err.message))
      buf.write_string("\"}")
    }
    None => ()
  }
  buf.write_char('}')
  buf.to_string()
}
