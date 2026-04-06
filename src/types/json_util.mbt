///|
pub fn sanitize_agent_id(agent_id : String) -> String {
  let buf = StringBuilder::new()
  for c in agent_id {
    if c == '/' || c == '\\' || c == '\u0000' {
      buf.write_char('_')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
pub fn json_field_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
pub fn json_field_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
pub fn json_field_int64(fields : Map[String, Json], key : String) -> Int64? {
  match fields.get(key) {
    Some(Number(n, ..)) => Some(n.to_int64())
    Some(String(s)) => {
      let mut res = 0L
      let mut valid = s != ""
      for c in s {
        if c >= '0' && c <= '9' {
          res = res * 10L + (c.to_int() - '0'.to_int()).to_int64()
        } else {
          valid = false
        }
      }
      if valid {
        Some(res)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
pub fn json_field_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}
