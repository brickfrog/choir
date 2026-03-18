///|
/// Parse the internal wire format JSON request.
/// Format: { "method": "...", "role": "...", "name": "...", "args": { "k": "v", ... } }
pub fn parse_request(data : String) -> Result[@types.Request, String] {
  let method_val = match get_field(data, "method") {
    Some(m) => m
    None => return Err("missing field: method")
  }
  let role_str = match get_field(data, "role") {
    Some(r) => r
    None => return Err("missing field: role")
  }
  let role = match role_str {
    "root" => @types.Role::Root
    "tl" => @types.Role::TL
    "dev" => @types.Role::Dev
    "worker" => @types.Role::Worker
    _ => return Err("invalid role: \{role_str}")
  }
  let name = match get_field(data, "name") {
    Some(n) => n
    None => return Err("missing field: name")
  }
  let args = parse_args(data)
  Ok({ req_method: method_val, role, name, args })
}

///|
fn index_of(str : String, sub : String, start? : Int = 0) -> Int {
  let str_len = str.length()
  let sub_len = sub.length()
  if sub_len == 0 {
    return start
  }
  for i = start; i <= str_len - sub_len; i = i + 1 {
    let mut match_found = true
    for j = 0; j < sub_len; j = j + 1 {
      if str[i + j] != sub[j] {
        match_found = false
        break
      }
    }
    if match_found {
      return i
    }
  }
  -1
}

///|
fn index_of_quote_end(str : String, start : Int) -> Int {
  for i = start; i < str.length(); i = i + 1 {
    if str[i] == '"' && (i == 0 || str[i - 1] != '\\') {
      return i
    }
  }
  -1
}

///|
fn get_field(data : String, field : String) -> String? {
  let field_name = "\"" + field + "\""
  let start_idx = index_of(data, field_name)
  if start_idx == -1 {
    return None
  }
  let colon_idx = index_of(data, ":", start=start_idx + field_name.length())
  if colon_idx == -1 {
    return None
  }
  let value_quote_start = index_of(data, "\"", start=colon_idx + 1)
  if value_quote_start == -1 {
    return None
  }
  let value_quote_end = index_of_quote_end(data, value_quote_start + 1)
  if value_quote_end == -1 {
    return None
  }
  Some(data[value_quote_start + 1:value_quote_end].to_string()) catch {
    _ => None
  }
}

///|
fn parse_args(data : String) -> Map[String, String] {
  let args_map = Map::new()
  let args_key = "\"args\""
  let start_idx = index_of(data, args_key)
  if start_idx == -1 {
    return args_map
  }
  let colon_idx = index_of(data, ":", start=start_idx + args_key.length())
  if colon_idx == -1 {
    return args_map
  }
  let brace_start = index_of(data, "{", start=colon_idx + 1)
  if brace_start == -1 {
    return args_map
  }

  // Find the closing brace of the args object
  let mut brace_end = -1
  let mut in_quote = false
  for i = brace_start + 1; i < data.length(); i = i + 1 {
    let c = data[i]
    if c == '"' && (i == 0 || data[i - 1] != '\\') {
      in_quote = not(in_quote)
    }
    if c == '}' && not(in_quote) {
      brace_end = i
      break
    }
  }

  if brace_end == -1 {
    return args_map
  }

  let content = data[brace_start + 1:brace_end].to_string() catch { _ => "" }
  if content == "" {
    return args_map
  }

  // Parse key-value pairs in content
  let mut i = 0
  while i < content.length() {
    // skip whitespace and delimiters
    while i < content.length() {
      let c = content[i]
      if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' {
        i = i + 1
      } else {
        break
      }
    }
    if i >= content.length() {
      break
    }

    // find key start
    if content[i] != '"' {
      break
    }
    let key_start = i + 1
    let key_end_idx = index_of_quote_end(content, key_start)
    if key_end_idx == -1 {
      break
    }
    let key = content[key_start:key_end_idx].to_string() catch { _ => "" }
    i = key_end_idx + 1

    // skip to colon
    let colon_idx = index_of(content, ":", start=i)
    if colon_idx == -1 {
      break
    }
    i = colon_idx + 1

    // skip whitespace
    while i < content.length() {
      let c = content[i]
      if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
        i = i + 1
      } else {
        break
      }
    }
    if i >= content.length() {
      break
    }

    // find value
    if content[i] != '"' {
      break
    }
    let val_start = i + 1
    let val_end_idx = index_of_quote_end(content, val_start)
    if val_end_idx == -1 {
      break
    }
    let val = content[val_start:val_end_idx].to_string() catch { _ => "" }
    i = val_end_idx + 1

    if key != "" {
      args_map.set(key, val)
    }
  }

  args_map
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
/// Serialize the internal wire format response.
/// Format: { "ok": true, "result": { "k": "v", ... } }
/// or: { "ok": false, "error": "..." }
pub fn format_response(resp : @types.Response) -> String {
  let buf = StringBuilder::new()
  match resp {
    @types.Response::Ok(result) => {
      buf.write_string("{\"ok\": true, \"result\": {")
      let mut first = true
      result.each(fn(k, v) {
        if not(first) {
          buf.write_string(", ")
        }
        buf.write_char('"')
        buf.write_string(escape_json_string(k))
        buf.write_string("\": \"")
        buf.write_string(escape_json_string(v))
        buf.write_char('"')
        first = false
      })
      buf.write_string("}}")
    }
    @types.Response::Err(err) => {
      buf.write_string("{\"ok\": false, \"error\": \"")
      buf.write_string(escape_json_string(err))
      buf.write_string("\"}")
    }
  }
  buf.to_string()
}
