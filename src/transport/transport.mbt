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
fn get_field(data : String, field : String) -> String? {
  let field_key = "\"" + field + "\": \""
  let start_idx = index_of(data, field_key)
  if start_idx == -1 {
    return None
  }
  let value_start = start_idx + field_key.length()
  let end_idx = index_of(data, "\"", start=value_start)
  if end_idx == -1 {
    return None
  }
  Some(data[value_start:end_idx].to_string()) catch {
    _ => None
  }
}

///|
fn parse_args(data : String) -> Map[String, String] {
  let args_map = Map::new()
  let args_key = "\"args\": {"
  let start_idx = index_of(data, args_key)
  if start_idx == -1 {
    return args_map
  }
  let args_content_start = start_idx + args_key.length()
  let end_idx = index_of(data, "}", start=args_content_start)
  if end_idx == -1 {
    return args_map
  }
  let args_content = data[args_content_start:end_idx].to_string() catch {
    _ => ""
  }
  if args_content == "" {
    return args_map
  }

  // Simple split by comma
  let parts = args_content.split(",")
  for part in parts {
    let kv = part.split(":")
    let k_v_array = kv.to_array()
    if k_v_array.length() == 2 {
      let key = k_v_array[0].trim().to_string()
      let val = k_v_array[1].trim().to_string()

      let key = if key.has_prefix("\"") &&
        key.has_suffix("\"") &&
        key.length() >= 2 {
        key[1:key.length() - 1].to_string() catch {
          _ => key
        }
      } else {
        key
      }

      let val = if val.has_prefix("\"") &&
        val.has_suffix("\"") &&
        val.length() >= 2 {
        val[1:val.length() - 1].to_string() catch {
          _ => val
        }
      } else {
        val
      }

      if key != "" {
        args_map.set(key, val)
      }
    }
  }
  args_map
}

///|
/// Serialize the internal wire format response.
/// Format: { "ok": true, \"result\": { "k": "v", ... } }
/// or: { "ok": false, \"error\": "..." }
pub fn format_response(resp : @types.Response) -> String {
  match resp {
    Ok(result) => {
      let mut s = "{\"ok\": true, \"result\": {"
      let mut first = true
      result.each(fn(k, v) {
        if not(first) {
          s = s + ", "
        }
        s = s + "\"\{k}\": \"\{v}\""
        first = false
      })
      s = s + "}}"
      s
    }
    Err(err) => "{\"ok\": false, \"error\": \"\{err}\"}"
  }
}
