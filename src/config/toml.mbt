///|
pub(all) struct TomlDoc {
  values : Map[String, String]
} derive(Debug)

///|
fn unescape_basic_toml_string(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < s.length() {
    let c = Int::unsafe_to_char(s[i].to_int())
    if c != '\\' || i + 1 >= s.length() {
      buf.write_char(c)
      i = i + 1
      continue
    }
    let next = Int::unsafe_to_char(s[i + 1].to_int())
    match next {
      '"' => buf.write_char('"')
      '\\' => buf.write_char('\\')
      'n' => buf.write_char('\n')
      'r' => buf.write_char('\r')
      't' => buf.write_char('\t')
      _ => {
        buf.write_char(c)
        buf.write_char(next)
      }
    }
    i = i + 2
  }
  buf.to_string()
}

///|
pub fn TomlDoc::get(self : TomlDoc, key : String) -> String? {
  self.values.get(key)
}

///|
pub fn TomlDoc::get_or(
  self : TomlDoc,
  key : String,
  fallback : String,
) -> String {
  self.get(key).unwrap_or(fallback)
}

///|
pub fn TomlDoc::get_optional_nonempty(self : TomlDoc, key : String) -> String? {
  match self.get(key) {
    Some(value) => if value == "" { None } else { Some(value) }
    None => None
  }
}

///|
pub fn TomlDoc::to_map(self : TomlDoc) -> Map[String, String] {
  self.values
}

///|
fn toml_value_without_comment(raw : String) -> String {
  let mut in_basic = false
  let mut in_literal = false
  let mut escaped = false
  let mut end = raw.length()
  for index = 0; index < raw.length(); index = index + 1 {
    let char = raw[index]
    if in_basic && escaped {
      escaped = false
      continue
    }
    if in_basic && char == '\\' {
      escaped = true
      continue
    }
    if char == '"' && !in_literal {
      in_basic = !in_basic
    } else if char == '\'' && !in_basic {
      in_literal = !in_literal
    } else if char == '#' && !in_basic && !in_literal {
      end = index
      break
    }
  }
  raw[0:end].to_owned().trim().to_owned()
}

///|
pub fn parse_toml_doc(content : String) -> TomlDoc {
  let map : Map[String, String] = Map([], capacity=0)
  let lines = content.split("\n")
  let mut section = ""
  for line in lines {
    let str = line.to_owned().trim().to_owned()
    if str.has_prefix("#") || str == "" {
      continue
    }
    if str.has_prefix("[") && str.has_suffix("]") && str.length() >= 2 {
      section = str[1:str.length() - 1].to_owned().trim().to_owned()
      continue
    }
    let mut idx = -1
    for i, c in str {
      if c == '=' {
        idx = i
        break
      }
    }
    if idx != -1 {
      let raw_key = str[0:idx].to_owned().trim().to_owned()
      let key = if section == "" { raw_key } else { section + "." + raw_key }
      let mut val = toml_value_without_comment(str[idx + 1:].to_owned())
      if val.has_prefix("\"") && val.has_suffix("\"") && val.length() >= 2 {
        val = unescape_basic_toml_string(val[1:val.length() - 1].to_owned())
      } else if val.has_prefix("'") && val.has_suffix("'") && val.length() >= 2 {
        val = val[1:val.length() - 1].to_owned()
      }
      map.set(key, val)
    }
  }
  { values: map }
}

///|
pub fn parse_toml(content : String) -> Map[String, String] {
  parse_toml_doc(content).to_map()
}
