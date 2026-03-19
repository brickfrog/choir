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
      let key = str[0:idx].to_string().trim().to_string() catch {
          _ => continue
        }
      let mut val = str[idx + 1:].to_string().trim().to_string() catch {
          _ => continue
        }
      if val.has_prefix("\"") && val.has_suffix("\"") && val.length() >= 2 {
        val = val[1:val.length() - 1].to_string() catch { _ => val }
      } else if val.has_prefix("'") && val.has_suffix("'") && val.length() >= 2 {
        val = val[1:val.length() - 1].to_string() catch { _ => val }
      }
      map.set(key, val)
    }
  }
  map
}
