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
test "build_request format" {
  let args : Map[String, String] = {}
  args.set("param", "val")
  let req = @plugin.build_request("my_tool", args, "agent1", "tl")
  assert_eq(req.contains("\"tool\":\"my_tool\""), true)
  assert_eq(req.contains("\"agent_id\":\"agent1\""), true)
  assert_eq(req.contains("\"role\":\"tl\""), true)
  assert_eq(req.contains("\"param\":\"val\""), true)
}

///|
test "parse_response ok" {
  let resp = "{\"ok\":\"true\",\"status\":\"done\",\"branch\":\"feat-x\"}"
  match @plugin.parse_response(resp) {
    Ok(m) => {
      assert_eq(m.get("status"), Some("done"))
      assert_eq(m.get("branch"), Some("feat-x"))
      assert_eq(m.get("ok"), None)
    }
    Err(_) => fail("expected Ok")
  }
}

///|
test "parse_response error" {
  let resp = "{\"ok\":\"false\",\"error\":\"plugin crashed\"}"
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
