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
fn hex_nibble(n : Int) -> Char {
  if n < 10 {
    Int::unsafe_to_char('0'.to_int() + n)
  } else {
    Int::unsafe_to_char('A'.to_int() + (n - 10))
  }
}

///|
fn write_json_control_unicode(buf : StringBuilder, code : Int) -> Unit {
  buf.write_string("\\u")
  buf.write_char(hex_nibble((code >> 12) & 0xf))
  buf.write_char(hex_nibble((code >> 8) & 0xf))
  buf.write_char(hex_nibble((code >> 4) & 0xf))
  buf.write_char(hex_nibble(code & 0xf))
}

///|
pub fn escape_for_json(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    let code = c.to_int()
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if code == 8 {
      buf.write_string("\\b")
    } else if code == 9 {
      buf.write_string("\\t")
    } else if code == 10 {
      buf.write_string("\\n")
    } else if code == 12 {
      buf.write_string("\\f")
    } else if code == 13 {
      buf.write_string("\\r")
    } else if code >= 0 && code <= 31 {
      write_json_control_unicode(buf, code)
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
  assert_eq(escape_for_json("\u0000\u0001\u0007"), "\\u0000\\u0001\\u0007")
  assert_eq(escape_for_json("\b\f"), "\\b\\f")
}
