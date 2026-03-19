///|
pub(all) struct PluginDef {
  name : String
  command : String
  tools : String
} derive(Show, Eq)

///|
fn skip_ws(s : String, start : Int) -> Int {
  let mut i = start
  while i < s.length() &&
        (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') {
    i = i + 1
  }
  i
}

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
fn parse_str(s : String, start : Int) -> (String, Int)? {
  if start >= s.length() || s[start] != '"' {
    return None
  }
  let buf = StringBuilder::new()
  let mut i = start + 1
  while i < s.length() {
    let c = Int::unsafe_to_char(s[i].to_int())
    if c == '"' {
      return Some((buf.to_string(), i + 1))
    }
    if c == '\\' {
      i = i + 1
      if i >= s.length() {
        return None
      }
      match Int::unsafe_to_char(s[i].to_int()) {
        '"' => buf.write_char('"')
        '\\' => buf.write_char('\\')
        'n' => buf.write_char('\n')
        'r' => buf.write_char('\r')
        't' => buf.write_char('\t')
        other => buf.write_char(other)
      }
    } else {
      buf.write_char(c)
    }
    i = i + 1
  }
  None
}

///|
fn parse_obj(s : String, start : Int) -> (Map[String, String], Int)? {
  let mut i = skip_ws(s, start)
  if i >= s.length() || s[i] != '{' {
    return None
  }
  i = i + 1
  let map : Map[String, String] = {}
  for {
    i = skip_ws(s, i)
    if i >= s.length() {
      return None
    }
    if s[i] == '}' {
      return Some((map, i + 1))
    }
    let (key, ki) = match parse_str(s, i) {
      Some(pair) => pair
      None => return None
    }
    i = skip_ws(s, ki)
    if i >= s.length() || s[i] != ':' {
      return None
    }
    i = skip_ws(s, i + 1)
    let (value, vi) = match parse_str(s, i) {
      Some(pair) => pair
      None => return None
    }
    map.set(key, value)
    i = skip_ws(s, vi)
    if i >= s.length() {
      return None
    }
    if s[i] == '}' {
      return Some((map, i + 1))
    }
    if s[i] != ',' {
      return None
    }
    i = i + 1
  }
}

///|
pub fn parse_plugins_json(s : String) -> Array[PluginDef] {
  let result : Array[PluginDef] = []
  let mut i = skip_ws(s, 0)
  if i >= s.length() || s[i] != '[' {
    return result
  }
  i = i + 1
  for {
    i = skip_ws(s, i)
    if i >= s.length() || s[i] == ']' {
      break
    }
    match parse_obj(s, i) {
      Some((map, next_i)) => {
        let name = map.get("name").unwrap_or("")
        let command = map.get("command").unwrap_or("")
        let tools = map.get("tools").unwrap_or("")
        if name != "" && command != "" {
          result.push({ name, command, tools })
        }
        i = skip_ws(s, next_i)
        if i < s.length() && s[i] == ',' {
          i = i + 1
        }
      }
      None => break
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
  args : Map[String, String],
  agent_id : String,
  role : String,
) -> String {
  let id = tool + "-" + agent_id
  let args_buf = StringBuilder::new()
  args_buf.write_char('{')
  let mut first = true
  for k, v in args {
    if not(first) {
      args_buf.write_char(',')
    }
    args_buf.write_string(
      "\"" + escape_json_string(k) + "\":\"" + escape_json_string(v) + "\"",
    )
    first = false
  }
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
/// Returns Ok(result_map) or Err(error_message).
pub fn parse_response(s : String) -> Result[Map[String, String], String] {
  if s == "" {
    return Err("empty response from plugin")
  }
  match parse_obj(s, skip_ws(s, 0)) {
    None => Err("invalid JSON response from plugin")
    Some((map, _)) => {
      let ok = map.get("ok").unwrap_or("false")
      if ok == "true" {
        let result : Map[String, String] = {}
        for k, v in map {
          if k != "ok" {
            result.set(k, v)
          }
        }
        Ok(result)
      } else {
        let err = map.get("error").unwrap_or("plugin returned error")
        Err(err)
      }
    }
  }
}
