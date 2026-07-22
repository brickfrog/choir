///|
test "Conductor request wire preserves structured arguments" {
  let values : Map[String, Json] = {
    "count": (3 : Int).to_json(),
    "enabled": true.to_json(),
    "selection": ["choir-a", "choir-b"].to_json(),
  }
  let request : @types.Request = {
    req_method: "tools/call",
    name: "goal_submit",
    args: @types.RequestArgs::from_values(values),
  }
  let wire = format_request(request)
  match parse_request(wire) {
    Ok(parsed) => {
      assert_eq(parsed.req_method, "tools/call")
      assert_eq(parsed.name, "goal_submit")
      @debug.assert_eq(parsed.args.get_json("count"), Some((3 : Int).to_json()))
      @debug.assert_eq(parsed.args.get_json("enabled"), Some(true.to_json()))
      @debug.assert_eq(
        parsed.args.get_json("selection"),
        Some(["choir-a", "choir-b"].to_json()),
      )
    }
    Err(error) => fail(error)
  }
}

///|
test "Conductor registration contains only its capability" {
  let wire = format_conductor_registration_request("capability-token")
  match parse_request(wire) {
    Ok(parsed) => {
      assert_eq(parsed.req_method, "register")
      assert_eq(parsed.name, "register")
      @debug.assert_eq(
        parsed.args.get(@types.registration_token_arg),
        Some("capability-token"),
      )
      assert_eq(parsed.args.to_json_map().length(), 1)
    }
    Err(error) => fail(error)
  }
}

///|
test "wire parser rejects malformed requests" {
  assert_true(parse_request("not json") is Err(_))
  assert_true(parse_request("{}") is Err(_))
  assert_true(
    parse_request(
      "{\"method\":\"tools/call\",\"role\":\"worker\",\"name\":\"x\"}",
    )
    is Err(_),
  )
}

///|
test "response wire round trips success and failure" {
  let values : Map[String, Json] = {
    "goal_id": "goal-a".to_json(),
    "count": (2 : Int).to_json(),
  }
  let success = @types.Response::ok_values(values)
  match parse_response(format_response(success)) {
    Ok(parsed) => {
      assert_true(parsed.is_ok())
      match parsed.ok_payload() {
        Some(fields) => {
          @debug.assert_eq(fields.get("goal_id"), Some("goal-a"))
          @debug.assert_eq(fields.get_json("count"), Some((2 : Int).to_json()))
        }
        None => fail("expected success fields")
      }
    }
    Err(error) => fail(error)
  }
  match parse_response(format_response(@types.Response::Err("denied"))) {
    Ok(parsed) => {
      assert_false(parsed.is_ok())
      @debug.assert_eq(parsed.error_message(), Some("denied"))
    }
    Err(error) => fail(error)
  }
}

///|
test "JSON-RPC detection is structural" {
  assert_true(
    is_jsonrpc_request("{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}"),
  )
  assert_false(is_jsonrpc_request("{\"method\":\"initialize\"}"))
  assert_false(is_jsonrpc_request("not json"))
}
