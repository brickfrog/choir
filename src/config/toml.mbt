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
pub fn parse_toml_doc(content : String) -> TomlDoc {
  let map : Map[String, String] = Map::new()
  let lines = content.split("\n")
  for line in lines {
    let str = line.to_string().trim().to_string()
    if str.has_prefix("#") || str == "" {
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
      let key = str[0:idx].to_string().trim().to_string()
      let mut val = str[idx + 1:].to_string().trim().to_string()
      if val.has_prefix("\"") && val.has_suffix("\"") && val.length() >= 2 {
        val = unescape_basic_toml_string(val[1:val.length() - 1].to_string())
      } else if val.has_prefix("'") && val.has_suffix("'") && val.length() >= 2 {
        val = val[1:val.length() - 1].to_string()
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
