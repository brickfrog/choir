///|
test "parse_mcp_config_json valid" {
  let s = "{\"servers\":{\"linear\":{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@linear/mcp-server\"]}}}"
  let m = parse_mcp_config_json(s).unwrap()
  assert_eq(m.length(), 1)
  let srv = m.get("linear").unwrap()
  match srv.transport {
    McpTransport::Stdio => ()
  }
  assert_eq(srv.command, "npx")
  assert_eq(srv.args, ["-y", "@linear/mcp-server"])
}

///|
test "parse_mcp_config_json missing command" {
  let s = "{\"servers\":{\"linear\":{\"type\":\"stdio\"}}}"
  let res = parse_mcp_config_json(s)
  match res {
    Err(e) => assert_true(e.message().contains("missing or invalid command"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json missing type" {
  let s = "{\"servers\":{\"linear\":{\"command\":\"npx\"}}}"
  let res = parse_mcp_config_json(s)
  match res {
    Err(e) => assert_true(e.message().contains("missing or invalid type"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json unsupported type" {
  let s = "{\"servers\":{\"linear\":{\"type\":\"http\",\"command\":\"npx\"}}}"
  let res = parse_mcp_config_json(s)
  match res {
    Err(e) => assert_true(e.message().contains("unsupported type http"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json malformed JSON includes parser message" {
  let res = parse_mcp_config_json("{ malformed }")
  match res {
    Err(e) => {
      assert_true(e.message().contains("malformed JSON"))
      assert_true(e.message().contains(":"))
    }
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json missing servers" {
  let res = parse_mcp_config_json("{}")
  match res {
    Err(e) => assert_true(e.message().contains("missing or invalid .servers"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json non-object entry" {
  let res = parse_mcp_config_json("{\"servers\":{\"a\":1}}")
  match res {
    Err(e) => assert_true(e.message().contains("must be an object"))
    Ok(_) => fail("expected error")
  }
}

///|
test "merge_mcp_maps clean merge" {
  let b : Map[String, Json] = { "a": "1".to_json() }
  let u : Map[String, Json] = { "b": "2".to_json() }
  let m = merge_mcp_maps(b, u).unwrap()
  assert_eq(m.get("a"), Some("1".to_json()))
  assert_eq(m.get("b"), Some("2".to_json()))
}

///|
test "merge_mcp_maps choir collision" {
  let b : Map[String, Json] = { "choir": "1".to_json() }
  let u : Map[String, Json] = { "choir": "2".to_json() }
  let res = merge_mcp_maps(b, u)
  match res {
    Err(e) => assert_true(e.message().contains("clashes with builtin"))
    Ok(_) => fail("expected error")
  }
}
