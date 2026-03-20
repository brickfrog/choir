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
fn find_substring(s : String, sub : String, start : Int) -> Int {
  if sub.length() == 0 {
    return start
  }
  if start >= s.length() {
    return -1
  }
  for i = start; i <= s.length() - sub.length(); i = i + 1 {
    let mut is_match = true
    for j = 0; j < sub.length(); j = j + 1 {
      if s[i + j] != sub[j] {
        is_match = false
        break
      }
    }
    if is_match {
      return i
    }
  }
  -1
}

///|
fn unescape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < s.length() {
    if s[i] == '\\' && i + 1 < s.length() {
      match s[i + 1] {
        'n' => {
          buf.write_char('\n')
          i = i + 2
        }
        'r' => {
          buf.write_char('\r')
          i = i + 2
        }
        't' => {
          buf.write_char('\t')
          i = i + 2
        }
        '"' => {
          buf.write_char('"')
          i = i + 2
        }
        '\\' => {
          buf.write_char('\\')
          i = i + 2
        }
        '/' => {
          buf.write_char('/')
          i = i + 2
        }
        _ => {
          buf.write_char(Int::unsafe_to_char(s[i].to_int()))
          i = i + 1
        }
      }
    } else {
      buf.write_char(Int::unsafe_to_char(s[i].to_int()))
      i = i + 1
    }
  }
  buf.to_string()
}

///|
fn get_string_value(json : String, key : String) -> String? {
  let key_pattern = "\"" + key + "\":\""
  let i = find_substring(json, key_pattern, 0)
  if i == -1 {
    None
  } else {
    let start = i + key_pattern.length()
    let mut end = start
    while end < json.length() {
      if json[end] == '"' && (end == 0 || json[end - 1] != '\\') {
        break
      }
      end = end + 1
    }
    if end >= json.length() {
      None
    } else {
      Some(unescape_json_string(json[start:end].to_string() catch { _ => "" }))
    }
  }
}

///|
fn get_int_value(json : String, key : String) -> Int? {
  let key_pattern = "\"" + key + "\":"
  let i = find_substring(json, key_pattern, 0)
  if i == -1 {
    None
  } else {
    let start = i + key_pattern.length()
    let mut end = start
    while end < json.length() && json[end] >= '0' && json[end] <= '9' {
      end = end + 1
    }
    if end == start {
      None
    } else {
      parse_int(json[start:end].to_string()) catch {
        _ => None
      }
    }
  }
}

///|
fn get_id_value(json : String) -> JsonRpcId? {
  let key_pattern = "\"id\":"
  let i = find_substring(json, key_pattern, 0)
  if i == -1 {
    return None
  }
  let start = i + key_pattern.length()
  if start >= json.length() {
    return None
  }
  if json[start] == '"' {
    match get_string_value(json, "id") {
      Some(v) => Some(String(v))
      None => None
    }
  } else {
    match get_int_value(json, "id") {
      Some(v) => Some(Number(v))
      None => None
    }
  }
}

///|
fn get_params_map(json : String) -> Map[String, String]? {
  let key_pattern = "\"params\":{"
  let i = find_substring(json, key_pattern, 0)
  if i == -1 {
    None
  } else {
    let start = i + key_pattern.length()
    let mut depth = 1
    let mut end = start
    while end < json.length() && depth > 0 {
      if json[end] == '{' {
        depth = depth + 1
      } else if json[end] == '}' {
        depth = depth - 1
      }
      end = end + 1
    }
    if depth == 0 {
      let params_str = json[start:end - 1].to_string() catch {
        _ => return None
      }
      let map = {}
      match get_string_value(params_str, "name") {
        Some(n) => map.set("name", n)
        None => ()
      }
      let arg_pattern = "\"arguments\":"
      let j = find_substring(params_str, arg_pattern, 0)
      if j != -1 {
        let arg_start = j + arg_pattern.length()
        if arg_start < params_str.length() {
          if params_str[arg_start] == '"' {
            let mut arg_end = arg_start + 1
            while arg_end < params_str.length() {
              if params_str[arg_end] == '"' &&
                (arg_end == 0 || params_str[arg_end - 1] != '\\') {
                break
              }
              arg_end = arg_end + 1
            }
            if arg_end < params_str.length() {
              map.set(
                "arguments",
                params_str[arg_start + 1:arg_end].to_string() catch {
                  _ => ""
                },
              )
            }
          } else if params_str[arg_start] == '{' {
            let mut arg_depth = 1
            let mut arg_end = arg_start + 1
            while arg_end < params_str.length() && arg_depth > 0 {
              if params_str[arg_end] == '{' {
                arg_depth = arg_depth + 1
              } else if params_str[arg_end] == '}' {
                arg_depth = arg_depth - 1
              }
              arg_end = arg_end + 1
            }
            if arg_depth == 0 {
              map.set(
                "arguments",
                params_str[arg_start:arg_end].to_string() catch {
                  _ => ""
                },
              )
            }
          }
        }
      }
      Some(map)
    } else {
      None
    }
  }
}

///|
/// Parse a flat JSON object string into a Map[String, String].
/// Only extracts string-valued keys; non-string values (numbers, booleans, objects) are skipped.
pub fn parse_flat_json_object(s : String) -> Map[String, String] {
  let map : Map[String, String] = {}
  let mut i = 0
  while i < s.length() {
    if s[i] == '"' {
      let key_start = i + 1
      let mut key_end = key_start
      while key_end < s.length() && s[key_end] != '"' {
        key_end = key_end + 1
      }
      if key_end >= s.length() {
        break
      }
      let key = s[key_start:key_end].to_string() catch { _ => "" }
      let mut j = key_end + 1
      while j < s.length() && (s[j] == ':' || s[j] == ' ') {
        j = j + 1
      }
      if j < s.length() && s[j] == '"' {
        let val_start = j + 1
        let mut val_end = val_start
        while val_end < s.length() {
          if s[val_end] == '"' && (val_end == 0 || s[val_end - 1] != '\\') {
            break
          }
          val_end = val_end + 1
        }
        if val_end < s.length() {
          let val = unescape_json_string(
            s[val_start:val_end].to_string() catch {
              _ => ""
            },
          )
          if key != "" {
            map.set(key, val)
          }
          i = val_end + 1
        } else {
          i = j + 1
        }
      } else {
        i = j + 1
      }
    } else {
      i = i + 1
    }
  }
  map
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
  Ok({ jsonrpc, id, req_method: method_val, params })
}
