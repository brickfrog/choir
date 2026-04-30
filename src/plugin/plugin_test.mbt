///|
test "parse_plugins_json empty array" {
  let plugins = @plugin.parse_plugins_json("[]")
  assert_eq(plugins.length(), 0)
}

///|
test "parse_plugins_json single plugin with tools" {
  let json = "[{\"name\":\"myplugin\",\"command\":\"./my-plugin\",\"tools\":\"search,deploy\"}]"
  let plugins = @plugin.parse_plugins_json(json)
  assert_eq(plugins.length(), 1)
  assert_eq(plugins[0].name, "myplugin")
  assert_eq(plugins[0].command, "./my-plugin")
  assert_eq(plugins[0].tools, "search,deploy")
}

///|
test "parse_plugins_json catch-all plugin (no tools)" {
  let json = "[{\"name\":\"p\",\"command\":\"./p\",\"tools\":\"\"}]"
  let plugins = @plugin.parse_plugins_json(json)
  assert_eq(plugins.length(), 1)
  assert_eq(plugins[0].tools, "")
}

///|
test "parse_plugins_json ignores non-object entries" {
  let json = "[{\"name\":\"p\",\"command\":\"./p\"},true,3,{\"name\":\"q\",\"command\":\"./q\",\"tools\":\"deploy\"}]"
  let plugins = @plugin.parse_plugins_json(json)
  assert_eq(plugins.length(), 2)
  assert_eq(plugins[0].name, "p")
  assert_eq(plugins[1].tools, "deploy")
}

///|
test "PluginDef::handles catch-all matches any tool" {
  let p : @plugin.PluginDef = { name: "p", command: "./p", tools: "" }
  assert_eq(p.handles("anything"), true)
  assert_eq(p.handles("fork_wave"), true)
}

///|
test "PluginDef::handles specific tools" {
  let p : @plugin.PluginDef = {
    name: "p",
    command: "./p",
    tools: "search,deploy",
  }
  assert_eq(p.handles("search"), true)
  assert_eq(p.handles("deploy"), true)
  assert_eq(p.handles("other"), false)
}

///|
test "find_handler returns first matching plugin" {
  let plugins : Array[@plugin.PluginDef] = [
    { name: "catchall", command: "./catch", tools: "" },
    { name: "searcher", command: "./search", tools: "search,deploy" },
  ]
  match @plugin.find_handler(plugins, "search") {
    Some(found) => assert_eq(found.name, "catchall")
    None => fail("expected plugin")
  }
}

///|
test "build_request format" {
  let req = @plugin.build_request({
    tool: "my_tool",
    args: @types.RequestArgs::from_values({
      "param": "val".to_json(),
      "count": (3).to_json(),
    }),
    agent_id: "agent1",
    role: "tl",
  })
  assert_eq(req.contains("\"tool\":\"my_tool\""), true)
  assert_eq(req.contains("\"agent_id\":\"agent1\""), true)
  assert_eq(req.contains("\"role\":\"tl\""), true)
  assert_eq(req.contains("\"param\":\"val\""), true)
  assert_eq(req.contains("\"count\":3"), true)
}

///|
test "parse_response ok" {
  let resp = "{\"ok\":true,\"status\":\"done\",\"branch\":\"feat-x\",\"count\":3}"
  match @plugin.parse_response(resp) {
    Ok(parsed) => {
      @debug.assert_eq(parsed.ok_field("status"), Some("done"))
      @debug.assert_eq(parsed.ok_field("branch"), Some("feat-x"))
      match parsed.ok_payload() {
        Some(fields) =>
          @debug.assert_eq(fields.get_json("count"), Some((3).to_json()))
        None => fail("expected payload")
      }
    }
    Err(_) => fail("expected Ok")
  }
}

///|
test "parse_response error" {
  let resp = "{\"ok\":false,\"error\":\"plugin crashed\"}"
  match @plugin.parse_response(resp) {
    Ok(_) => fail("expected Err")
    Err(e) => assert_eq(e, "plugin crashed")
  }
}

///|
test "parse_response empty string" {
  match @plugin.parse_response("") {
    Ok(_) => fail("expected Err")
    Err(e) => assert_eq(e, "empty response from plugin")
  }
}
