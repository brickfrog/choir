///|
test "Claude Conductor keeps default tools and uses strict MCP config" {
  let command = conductor_launch_command("/repo", "/opt/choir/bin/choir")
  let joined = command.args.join(" ")
  assert_eq(command.program, "claude")
  assert_true(joined.contains("--strict-mcp-config"))
  assert_false(command.args.contains("--tools"))
  assert_true(
    joined.contains(
      "--allowedTools mcp__choir__goal_submit,mcp__choir__goal_status,mcp__choir__goal_cancel,mcp__choir__goal_steer,mcp__choir__goal_attach,mcp__choir__goal_answer,mcp__choir__task_list,mcp__choir__task_get,mcp__choir__task_create,mcp__choir__task_update",
    ),
  )
  assert_true(
    joined.contains("--dangerously-load-development-channels server:choir"),
  )
  assert_true(joined.contains("--setting-sources project"))
  assert_true(
    joined.contains(
      "--append-system-prompt-file /repo/.choir/state/conductor-prompt.md",
    ),
  )
  assert_false(joined.contains("--plugin-dir"))
  assert_true(joined.contains("\"command\":\"/opt/choir/bin/choir\""))
  assert_true(joined.contains("\"--channel\""))
  assert_false(joined.contains("\"command\":\"choir\""))
  assert_false(joined.contains("zellij"))
  let settings = conductor_claude_settings_json("/opt/choir/bin/choir")
  assert_true(settings.contains("\"Stop\""))
  assert_true(settings.contains("\"enabledMcpjsonServers\":[\"choir\"]"))
  assert_true(settings.contains("/opt/choir/bin/choir"))
  assert_true(settings.contains("conductor-stop"))
  assert_true(settings.contains("conductor-statusline"))
  assert_true(settings.contains("\"statusLine\""))
  assert_true(settings.contains("\"padding\":0"))
  assert_false(settings.contains("refreshInterval"))
  assert_false(settings.contains("automatic_polling_allowed"))
  let parsed = @json.parse(settings) catch {
    _ => fail("Conductor settings are not valid JSON")
  }
  guard parsed is Object(root) else {
    fail("Conductor settings are not an object")
  }
  guard root.get("statusLine") is Some(Object(statusline)) else {
    fail("Conductor statusLine is absent")
  }
  assert_eq(
    statusline.get("command"),
    Some("'/opt/choir/bin/choir' conductor-statusline".to_json()),
  )
  assert_eq(statusline.get("padding"), Some((0 : Int).to_json()))
}

///|
test "Claude Conductor project MCP merge preserves unrelated servers" {
  let existing =
    #|{"custom":{"preserved":true},"mcpServers":{"other":{"type":"stdio","command":"/opt/other","args":[]}}}
  let merged = conductor_claude_project_mcp_config_json(
    existing, "/opt/choir/bin/choir",
  ).unwrap()
  let parsed = @json.parse(merged) catch {
    _ => fail("merged MCP config is invalid")
  }
  guard parsed is Object(root) else {
    fail("merged MCP config is not an object")
  }
  assert_true(root.get("custom") is Some(_))
  guard root.get("mcpServers") is Some(Object(servers)) else {
    fail("merged MCP servers are absent")
  }
  assert_true(servers.get("other") is Some(_))
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("Choir MCP server is absent")
  }
  assert_eq(choir.get("command"), Some("/opt/choir/bin/choir".to_json()))
  assert_true(choir.to_json().stringify().contains("\"--channel\""))
  assert_true(
    conductor_claude_project_mcp_config_json(
      "{\"mcpServers\":[]}", "/opt/choir/bin/choir",
    )
    is Err(_),
  )
}

///|
/// The launch argv and the declared surface are two lists that used to drift —
/// the flags changed five times in one day. This is the coupling: every flag
/// the launch passes must be declared, or qualification would never check it
/// against the installed CLI.
test "every Conductor launch flag is declared in the qualified surface" {
  let declared = @harness.conductor_surface_flags().map(fn(flag) { flag.name })
  let passed : Array[String] = []
  for lean in [false, true] {
    let command = conductor_launch_command("/repo", "/usr/bin/choir", lean~)
    for argument in command.args {
      if argument.has_prefix("--") && !passed.contains(argument) {
        passed.push(argument)
      }
    }
  }
  for argument in passed {
    assert_true(declared.contains(argument))
  }
  // And nothing is declared that the launch never passes, so the surface is
  // exactly what Choir depends on rather than a wish list.
  for flag in declared {
    assert_true(passed.contains(flag))
  }
}

///|
/// The live probe and the runtime Take path each built this argv independently,
/// so a protocol change had to be made twice and the probe could silently stop
/// exercising what the runtime actually does. One builder now, and this pins
/// the wire contract it produces.
test "a BoxLite request carries its auth and body exactly once" {
  let with_body = boxlite_http_arguments(
    "secret-key",
    "http://127.0.0.1:22000",
    "POST",
    "/v1/boxes",
    Some("{\"name\":\"box-1\"}"),
    30,
  )
  @debug.assert_eq(with_body, [
    "-fsS", "--max-time", "30", "-X", "POST", "-H", "Authorization: Bearer secret-key",
    "-H", "Content-Type: application/json", "--data-binary", "{\"name\":\"box-1\"}",
    "http://127.0.0.1:22000/v1/boxes",
  ])
  // A bodyless call sends no content type and no body flag, so a GET cannot
  // accidentally carry an empty payload.
  let without_body = boxlite_http_arguments(
    "secret-key",
    "http://127.0.0.1:22000",
    "GET",
    "/v1/boxes/box-1",
    None,
    20,
  )
  @debug.assert_eq(without_body, [
    "-fsS", "--max-time", "20", "-X", "GET", "-H", "Authorization: Bearer secret-key",
    "http://127.0.0.1:22000/v1/boxes/box-1",
  ])
  // The timeout is the only thing the two stacks disagree about, and it is a
  // parameter rather than a second copy of the protocol.
  assert_true(with_body.contains("30"))
  assert_true(without_body.contains("20"))
  // The clone body is one definition both stacks use.
  assert_eq(boxlite_clone_request_body("box-2"), "{\"name\":\"box-2\"}")
}
