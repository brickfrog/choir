///|
pub(all) struct TomlDoc {
  values : Map[String, String]
} derive(Debug)

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
        val = val[1:val.length() - 1].to_string()
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

///|
pub impl Show for TomlDoc with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
