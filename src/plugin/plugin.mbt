///|
pub(all) struct PluginDef {
  name : String
  command : String
  tools : String
} derive(Eq)

///|
pub(all) struct PluginCall {
  tool : String
  args : @types.RequestArgs
  agent_id : String
  role : String
} derive(Eq)

///|
pub fn parse_plugins_json(s : String) -> Array[PluginDef] {
  let result : Array[PluginDef] = []
  let json = @json.parse(s) catch { _ => return result }
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Object(obj) else { continue }
    let name = match @types.json_field_string(obj, "name") {
      Some(s) => s
      None => ""
    }
    let command = match @types.json_field_string(obj, "command") {
      Some(s) => s
      None => ""
    }
    let tools = match @types.json_field_string(obj, "tools") {
      Some(s) => s
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
  if self.tools.trim().to_owned() == "" {
    return true
  }
  for part in self.tools.split(",") {
    if part.trim().to_owned() == tool_name {
      return true
    }
  }
  false
}

///|
pub fn find_handler(
  plugins : Array[PluginDef],
  tool_name : String,
) -> PluginDef? {
  let mut found : PluginDef? = None
  for plugin in plugins {
    if plugin.handles(tool_name) {
      found = Some(plugin)
      break
    }
  }
  found
}

///|
/// Build a JSON request line for the plugin protocol.
pub fn build_request(call : PluginCall) -> String {
  let id = call.tool + "-" + call.agent_id
  let args_map : Map[String, Json] = {}
  call.args.each_json(fn(k, v) { args_map.set(k, v) })
  let obj : Map[String, Json] = {}
  obj.set("id", id.to_json())
  obj.set("tool", call.tool.to_json())
  obj.set("args", args_map.to_json())
  obj.set("agent_id", call.agent_id.to_json())
  obj.set("role", call.role.to_json())
  obj.to_json().stringify()
}

///|
/// Parse a flat JSON response line from a plugin.
/// Returns Ok(result_payload) or Err(error_message).
pub fn parse_response(s : String) -> Result[@types.Response, String] {
  if s == "" {
    return Err("empty response from plugin")
  }
  let json = @json.parse(s) catch {
    _ => return Err("invalid JSON from plugin")
  }
  guard json is Object(obj) else {
    return Err("plugin response is not a JSON object")
  }
  let ok = match obj.get("ok") {
    Some(True) => true
    Some(String(v)) => v == "true"
    _ => false
  }
  if ok {
    let result : Map[String, Json] = {}
    obj.each(fn(k, v) { if k != "ok" { result.set(k, v) } })
    Ok(@types.Response::ok_values(result))
  } else {
    let err = match obj.get("error") {
      Some(String(v)) => v
      _ => "plugin returned error"
    }
    Err(err)
  }
}
