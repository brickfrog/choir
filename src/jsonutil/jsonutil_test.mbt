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
