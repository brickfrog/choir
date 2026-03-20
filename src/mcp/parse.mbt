///|
fn parse_int(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut res = 0
  for c in s {
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

///|
fn get_string_value(json : String, key : String) -> String? {
  match @jsonutil.get_json_field_value(json, key) {
    Some(@jsonutil.JsonValueText::String(value)) => Some(value)
    _ => None
  }
}

///|
fn get_id_value(json : String) -> JsonRpcId? {
  match @jsonutil.get_json_field_value(json, "id") {
    Some(@jsonutil.JsonValueText::String(value)) => Some(String(value))
    Some(@jsonutil.JsonValueText::Raw(value)) =>
      match parse_int(value) {
        Some(id) => Some(Number(id))
        None => None
      }
    None => None
  }
}

///|
fn get_params_map(json : String) -> Map[String, JsonValue]? {
  match @jsonutil.get_json_field_value(json, "params") {
    Some(@jsonutil.JsonValueText::Raw(params_json)) => {
      let map : Map[String, JsonValue] = {}
      match @jsonutil.get_json_field_value(params_json, "name") {
        Some(@jsonutil.JsonValueText::String(name)) =>
          map.set("name", JsonValue::String(name))
        _ => ()
      }
      match @jsonutil.get_json_field_value(params_json, "arguments") {
        Some(@jsonutil.JsonValueText::String(arguments)) =>
          map.set("arguments", JsonValue::String(arguments))
        Some(@jsonutil.JsonValueText::Raw(arguments)) =>
          map.set("arguments", JsonValue::Raw(arguments))
        None => ()
      }
      Some(map)
    }
    _ => None
  }
}

///|
pub fn parse_flat_json_object(s : String) -> Map[String, String] {
  @jsonutil.parse_flat_json_object(s)
}

///|
pub fn parse_jsonrpc_request(
  line : String,
) -> Result[JsonRpcRequest, JsonRpcError] {
  let jsonrpc = match get_string_value(line, "jsonrpc") {
    Some(v) => v
    None => return Err({ code: err_invalid_params, message: "missing jsonrpc" })
  }
  let id = get_id_value(line)
  let method_val = match get_string_value(line, "method") {
    Some(v) => v
    None => return Err({ code: err_invalid_params, message: "missing method" })
  }
  let params = get_params_map(line)
  Ok({
    jsonrpc,
    id,
    req_method: method_val,
    params: match params {
      Some(map) => Some(Object(map))
      None => None
    },
  })
}
