///|
fn sanitize_agent_id(agent_id : String) -> String {
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
fn escape_for_json(s : String) -> String {
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
fn append_event(
  project_dir : String,
  agent_id : String,
  event_type : String,
  data_json : String,
) -> Bool {
  let sanitized_id = sanitize_agent_id(agent_id)
  let events_dir = project_dir + "/.choir/events/"
  let path = events_dir + sanitized_id + ".jsonl"
  let now = @poller.now_sec()
  let line = "{\"ts\":" +
    now.to_string() +
    ",\"type\":\"" +
    event_type +
    "\",\"agent_id\":\"" +
    agent_id +
    "\",\"data\":" +
    data_json +
    "}\n"
  @sys.append_file_sync(path, line)
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

///|
test "append_event writes jsonl" {
  let project_dir = "/tmp/choir_event_log_test"
  ignore(
    @sys.system(
      "rm -rf " + project_dir + " && mkdir -p " + project_dir + "/.choir/events",
    ),
  )
  let ok = append_event(
    project_dir, "test/agent", "tools.call", "{\"tool\":\"test\"}",
  )
  assert_true(ok)
  let content = @sys.read_file(project_dir + "/.choir/events/test_agent.jsonl")
  assert_true(content.contains("\"type\":\"tools.call\""))
  assert_true(content.contains("\"agent_id\":\"test/agent\""))
  assert_true(content.contains("\"data\":{\"tool\":\"test\"}"))
  assert_true(content.has_suffix("\n"))

  let ok2 = append_event(
    project_dir, "test/agent", "tools.call", "{\"tool\":\"test2\"}",
  )
  assert_true(ok2)
  let content2 = @sys.read_file(project_dir + "/.choir/events/test_agent.jsonl")
  assert_true(content2.contains("test2"))

  ignore(@sys.system("rm -rf " + project_dir))
}
