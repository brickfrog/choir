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
pub fn escape_for_json(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\t' {
      buf.write_string("\\t")
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
test "sanitize_agent_id" {
  assert_eq(sanitize_agent_id("agent/1\\2\u00003"), "agent_1_2_3")
  assert_eq(sanitize_agent_id("normal_agent-id"), "normal_agent-id")
}

///|
test "escape_for_json" {
  assert_eq(escape_for_json("a\"b\\c\n"), "a\\\"b\\\\c\\n")
}
