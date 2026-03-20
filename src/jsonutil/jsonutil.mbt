///|
pub enum JsonValueText {
  String(String)
  Raw(String)
} derive(Show, Eq)

///|
pub fn find_substring(s : String, sub : String, start? : Int = 0) -> Int {
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
pub fn index_of_quote_end(str : String, start : Int) -> Int {
  for i = start; i < str.length(); i = i + 1 {
    if str[i] == '"' && (i == 0 || str[i - 1] != '\\') {
      return i
    }
  }
  -1
}

///|
pub fn skip_json_whitespace(s : String, start : Int) -> Int {
  let mut i = start
  while i < s.length() {
    let c = s[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i = i + 1
    } else {
      break
    }
  }
  i
}

///|
pub fn unescape_json_string(s : String) -> String {
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
pub fn read_json_string_literal(s : String, start : Int) -> (String, Int)? {
  if start >= s.length() || s[start] != '"' {
    return None
  }
  let end = index_of_quote_end(s, start + 1)
  if end == -1 {
    return None
  }
  let raw = s[start + 1:end].to_string() catch { _ => return None }
  Some((unescape_json_string(raw), end + 1))
}

///|
fn read_balanced_json(
  s : String,
  start : Int,
  open : Int,
  close : Int,
) -> (String, Int)? {
  if start >= s.length() || s[start].to_int() != open {
    return None
  }
  let mut depth = 1
  let mut i = start + 1
  let mut in_string = false
  while i < s.length() && depth > 0 {
    if s[i] == '"' && (i == 0 || s[i - 1] != '\\') {
      in_string = not(in_string)
    } else if not(in_string) {
      if s[i].to_int() == open {
        depth = depth + 1
      } else if s[i].to_int() == close {
        depth = depth - 1
      }
    }
    i = i + 1
  }
  if depth != 0 {
    None
  } else {
    let raw = s[start:i].to_string() catch { _ => return None }
    Some((raw, i))
  }
}

///|
pub fn read_json_value_text(s : String, start : Int) -> (JsonValueText, Int)? {
  let i = skip_json_whitespace(s, start)
  if i >= s.length() {
    return None
  }
  match s[i] {
    '"' =>
      match read_json_string_literal(s, i) {
        Some((value, next)) => Some((JsonValueText::String(value), next))
        None => None
      }
    '{' =>
      match read_balanced_json(s, i, '{'.to_int(), '}'.to_int()) {
        Some((value, next)) => Some((JsonValueText::Raw(value), next))
        None => None
      }
    '[' =>
      match read_balanced_json(s, i, '['.to_int(), ']'.to_int()) {
        Some((value, next)) => Some((JsonValueText::Raw(value), next))
        None => None
      }
    _ => {
      let mut end = i
      while end < s.length() {
        let c = s[end]
        if c == ',' ||
          c == '}' ||
          c == ']' ||
          c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == '\r' {
          break
        }
        end = end + 1
      }
      if end == i {
        None
      } else {
        let raw = s[i:end].to_string() catch { _ => return None }
        Some((JsonValueText::Raw(raw), end))
      }
    }
  }
}

///|
pub fn parse_flat_json_object(s : String) -> Map[String, String] {
  let map : Map[String, String] = {}
  let mut i = skip_json_whitespace(s, 0)
  if i < s.length() && s[i] == '{' {
    i = i + 1
  }
  while i < s.length() {
    i = skip_json_whitespace(s, i)
    if i >= s.length() || s[i] == '}' {
      break
    }
    if s[i] == ',' {
      i = i + 1
      continue
    }
    let (key, after_key) = match read_json_string_literal(s, i) {
      Some(value) => value
      None => break
    }
    let colon_idx = skip_json_whitespace(s, after_key)
    if colon_idx >= s.length() || s[colon_idx] != ':' {
      break
    }
    let (value, after_value) = match read_json_value_text(s, colon_idx + 1) {
      Some(parsed) => parsed
      None => break
    }
    if key != "" {
      match value {
        JsonValueText::String(v) => map.set(key, v)
        JsonValueText::Raw(v) => map.set(key, v)
      }
    }
    i = after_value
  }
  map
}

///|
pub fn parse_flat_json_value_object(s : String) -> Map[String, JsonValueText] {
  let map : Map[String, JsonValueText] = {}
  let mut i = skip_json_whitespace(s, 0)
  if i < s.length() && s[i] == '{' {
    i = i + 1
  }
  while i < s.length() {
    i = skip_json_whitespace(s, i)
    if i >= s.length() || s[i] == '}' {
      break
    }
    if s[i] == ',' {
      i = i + 1
      continue
    }
    let (key, after_key) = match read_json_string_literal(s, i) {
      Some(value) => value
      None => break
    }
    let colon_idx = skip_json_whitespace(s, after_key)
    if colon_idx >= s.length() || s[colon_idx] != ':' {
      break
    }
    let (value, after_value) = match read_json_value_text(s, colon_idx + 1) {
      Some(parsed) => parsed
      None => break
    }
    if key != "" {
      map.set(key, value)
    }
    i = after_value
  }
  map
}

///|
pub fn get_json_field_value(s : String, key : String) -> JsonValueText? {
  let map_key = "\"" + key + "\""
  let mut search_from = 0
  while search_from < s.length() {
    let key_idx = find_substring(s, map_key, start=search_from)
    if key_idx == -1 {
      return None
    }
    let colon_idx = skip_json_whitespace(s, key_idx + map_key.length())
    if colon_idx < s.length() && s[colon_idx] == ':' {
      match read_json_value_text(s, colon_idx + 1) {
        Some((value, _)) => return Some(value)
        None => return None
      }
    }
    search_from = key_idx + map_key.length()
  }
  None
}
