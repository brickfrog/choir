///|
test "parse_flat_json_object preserves strings and primitives" {
  let parsed = parse_flat_json_object(
    "{\"task\":\"build\",\"count\":3,\"fork_session\":true,\"empty\":null}",
  )
  assert_eq(parsed.get("task"), Some("build"))
  assert_eq(parsed.get("count"), Some("3"))
  assert_eq(parsed.get("fork_session"), Some("true"))
  assert_eq(parsed.get("empty"), Some("null"))
}

///|
test "parse_flat_json_value_object preserves value kinds" {
  let parsed = parse_flat_json_value_object(
    "{\"task\":\"build\",\"count\":3,\"fork_session\":true,\"meta\":{\"a\":1}}",
  )
  match parsed.get("task") {
    Some(@jsonutil.JsonValueText::String(value)) => assert_eq(value, "build")
    _ => fail("expected string task")
  }
  match parsed.get("count") {
    Some(@jsonutil.JsonValueText::Raw(value)) => assert_eq(value, "3")
    _ => fail("expected raw count")
  }
  match parsed.get("fork_session") {
    Some(@jsonutil.JsonValueText::Raw(value)) => assert_eq(value, "true")
    _ => fail("expected raw fork_session")
  }
  match parsed.get("meta") {
    Some(@jsonutil.JsonValueText::Raw(value)) => assert_eq(value, "{\"a\":1}")
    _ => fail("expected raw meta")
  }
}

///|
test "read_json_value_text handles object and array raw text" {
  match read_json_value_text("{\"a\":1}", 0) {
    Some((JsonValueText::Raw(value), _)) => assert_eq(value, "{\"a\":1}")
    _ => fail("expected raw object")
  }
  match read_json_value_text("[1,true]", 0) {
    Some((JsonValueText::Raw(value), _)) => assert_eq(value, "[1,true]")
    _ => fail("expected raw array")
  }
}

///|
test "get_json_field_value distinguishes strings and raw values" {
  let json = "{\"name\":\"fork_wave\",\"count\":3}"
  match get_json_field_value(json, "name") {
    Some(@jsonutil.JsonValueText::String(value)) =>
      assert_eq(value, "fork_wave")
    _ => fail("expected string field")
  }
  match get_json_field_value(json, "count") {
    Some(@jsonutil.JsonValueText::Raw(value)) => assert_eq(value, "3")
    _ => fail("expected raw field")
  }
}

///|
test "parse_json_object_array_text keeps only object entries" {
  let parsed = parse_json_object_array_text(
    "[{\"name\":\"p1\",\"command\":\"./one\"},true,{\"name\":\"p2\",\"command\":\"./two\",\"tools\":\"search\"}]",
  )
  assert_eq(parsed.length(), 2)
  match parsed[0].get("name") {
    Some(@jsonutil.JsonValueText::String(value)) => assert_eq(value, "p1")
    _ => fail("expected first object name")
  }
  match parsed[1].get("tools") {
    Some(@jsonutil.JsonValueText::String(value)) => assert_eq(value, "search")
    _ => fail("expected tools field")
  }
}
