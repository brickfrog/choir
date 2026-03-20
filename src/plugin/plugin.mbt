///|
pub(all) struct PluginDef {
  name : String
  command : String
  tools : String
} derive(Show, Eq)

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
pub fn parse_plugins_json(s : String) -> Array[PluginDef] {
  let result : Array[PluginDef] = []
  for value_map in @jsonutil.parse_json_object_array_text(s) {
    let name = match value_map.get("name") {
      Some(@jsonutil.JsonValueText::String(value)) => value
      Some(@jsonutil.JsonValueText::Raw(value)) => value
      None => ""
    }
    let command = match value_map.get("command") {
      Some(@jsonutil.JsonValueText::String(value)) => value
      Some(@jsonutil.JsonValueText::Raw(value)) => value
      None => ""
    }
    let tools = match value_map.get("tools") {
      Some(@jsonutil.JsonValueText::String(value)) => value
      Some(@jsonutil.JsonValueText::Raw(value)) => value
      None => ""
    }
    if name != "" && command != "" {
      result.push({ name, command, tools })
    }
  }
  result
}

///|
/// Returns true if this plugin handles the given tool name.
/// A plugin with an empty tools string is a catch-all.
pub fn PluginDef::handles(self : PluginDef, tool_name : String) -> Bool {
  if self.tools.trim().to_string() == "" {
    return true
  }
  for part in self.tools.split(",") {
    if part.trim().to_string() == tool_name {
      return true
    }
  }
  false
}

///|
/// Build a JSON request line for the plugin protocol.
pub fn build_request(
  tool : String,
  args : @types.RequestArgs,
  agent_id : String,
  role : String,
) -> String {
  let id = tool + "-" + agent_id
  let args_buf = StringBuilder::new()
  args_buf.write_char('{')
  let mut first = true
  args.each_value(fn(k, v) {
    if not(first) {
      args_buf.write_char(',')
    }
    args_buf.write_char('"')
    args_buf.write_string(escape_json_string(k))
    args_buf.write_string("\":")
    match v {
      @types.WireValue::String(text) =>
        args_buf.write_string("\"" + escape_json_string(text) + "\"")
      @types.WireValue::Raw(text) => args_buf.write_string(text)
    }
    first = false
  })
  args_buf.write_char('}')
  let buf = StringBuilder::new()
  buf.write_string("{\"id\":\"")
  buf.write_string(escape_json_string(id))
  buf.write_string("\",\"tool\":\"")
  buf.write_string(escape_json_string(tool))
  buf.write_string("\",\"args\":")
  buf.write_string(args_buf.to_string())
  buf.write_string(",\"agent_id\":\"")
  buf.write_string(escape_json_string(agent_id))
  buf.write_string("\",\"role\":\"")
  buf.write_string(escape_json_string(role))
  buf.write_string("\"}")
  buf.to_string()
}

///|
/// Parse a flat JSON response line from a plugin.
/// Returns Ok(result_payload) or Err(error_message).
pub fn parse_response(s : String) -> Result[@types.Response, String] {
  if s == "" {
    return Err("empty response from plugin")
  }
  let values = @jsonutil.parse_flat_json_value_object(s)
  let ok = match values.get("ok") {
    Some(@jsonutil.JsonValueText::String(value)) => value == "true"
    Some(@jsonutil.JsonValueText::Raw(value)) => value == "true"
    None => false
  }
  if ok {
    let result : Map[String, @types.WireValue] = {}
    values.each(fn(k, v) {
      if k != "ok" {
        match v {
          @jsonutil.JsonValueText::String(text) =>
            result.set(k, @types.WireValue::String(text))
          @jsonutil.JsonValueText::Raw(text) =>
            result.set(k, @types.WireValue::Raw(text))
        }
      }
    })
    Ok(@types.Response::ok_values(result))
  } else {
    let err = match values.get("error") {
      Some(@jsonutil.JsonValueText::String(value)) => value
      Some(@jsonutil.JsonValueText::Raw(value)) => value
      None => "plugin returned error"
    }
    Err(err)
  }
}
