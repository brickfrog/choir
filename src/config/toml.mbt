///|
pub fn parse_toml(content : String) -> Map[String, String] {
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
      let key = str.substring(start=0, end=idx).trim().to_string()
      let mut val = str.substring(start=idx + 1).trim().to_string()
      if val.has_prefix("\"") && val.has_suffix("\"") && val.length() >= 2 {
        val = val.substring(start=1, end=val.length() - 1)
      }
      map.set(key, val)
    }
  }
  map
}
