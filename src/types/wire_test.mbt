///|
/// A non-string argument used to be stringified and accepted wherever a string
/// was expected — an object arrived as the text `{"x":1}` and a Goal id lookup
/// would use it. Malformed arguments must fail validation instead of flowing
/// onward as garbage identifiers.
test "a wire string field reads only genuine strings" {
  let args = @types.RequestArgs::from_values({
    "goal_id": "goal-a".to_json(),
    "object": ({ "x": (1 : Int).to_json() } : Map[String, Json]).to_json(),
    "array": ([(1 : Int)] : Array[Int]).to_json(),
    "number": (7 : Int).to_json(),
    "boolean": true.to_json(),
    "null": Json::null(),
  })
  assert_eq(args.get("goal_id"), Some("goal-a"))
  assert_eq(args.get("object"), None)
  assert_eq(args.get("array"), None)
  assert_eq(args.get("number"), None)
  assert_eq(args.get("boolean"), None)
  assert_eq(args.get("null"), None)
  assert_eq(args.get("absent"), None)
  // A caller that genuinely wants the raw value still has get_json, and the
  // typed readers still read their own types.
  assert_true(args.get_json("object") is Some(_))
  assert_eq(args.get_int("number"), Some(7))
  assert_eq(args.get_bool("boolean"), Some(true))
  // Presence is unchanged: a non-string field is still present, just not a
  // string, so callers can tell "absent" from "wrong type".
  assert_true(args.contains("object"))
}
