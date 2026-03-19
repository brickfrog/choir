///|
test "format with agent_id" {
  let entry = log_with_agent(Info, "server", "agent-123", "starting")
  assert_eq(entry.format(), "[INFO] [server] [agent-123] starting")
}

///|
test "format without agent_id" {
  let entry = log_info("poller", "polling")
  assert_eq(entry.format(), "[INFO] [poller] polling")
}

///|
test "info convenience constructor" {
  let entry = log_info("c1", "m1")
  assert_eq(entry.level, Info)
  assert_eq(entry.component, "c1")
  assert_eq(entry.message, "m1")
  let none : String? = None
  assert_eq(entry.agent_id, none)
}

///|
test "warn convenience constructor" {
  let entry = log_warn("c2", "m2")
  assert_eq(entry.level, Warn)
  assert_eq(entry.component, "c2")
  assert_eq(entry.message, "m2")
  let none : String? = None
  assert_eq(entry.agent_id, none)
}

///|
test "error convenience constructor" {
  let entry = log_error("c3", "m3")
  assert_eq(entry.level, Error_)
  assert_eq(entry.component, "c3")
  assert_eq(entry.message, "m3")
  let none : String? = None
  assert_eq(entry.agent_id, none)
}

///|
test "log_with_agent" {
  let entry = log_with_agent(Debug, "c4", "a4", "m4")
  assert_eq(entry.level, Debug)
  assert_eq(entry.component, "c4")
  assert_eq(entry.agent_id, Some("a4"))
  assert_eq(entry.message, "m4")
}

///|
test "span format emits structured json" {
  let span = Span::{
    trace_id: "trace-1",
    span_id: "span-1",
    name: "tools/call mutex_acquire",
    agent_id: Some("agent-1"),
    role: Some("Dev"),
    start_sec: 10L,
    end_sec: 11L,
    status: "ok",
    error_msg: None,
  }
  let line = span.format()
  assert_true(line.contains("\"type\":\"span\""))
  assert_true(line.contains("\"name\":\"tools/call mutex_acquire\""))
  assert_true(line.contains("\"trace_id\":\"trace-1\""))
  assert_true(line.contains("\"span_id\":\"span-1\""))
  assert_true(line.contains("\"agent_id\":\"agent-1\""))
  assert_true(line.contains("\"role\":\"Dev\""))
  assert_true(line.contains("\"start_sec\":10"))
  assert_true(line.contains("\"end_sec\":11"))
  assert_true(line.contains("\"status\":\"ok\""))
  assert_true(line.contains("\"error\":\"\""))
}

///|
test "span to_otlp_json" {
  let span = Span::{
    trace_id: "abc",
    span_id: "7",
    name: "tools/call kv_get",
    agent_id: Some("dev-1"),
    role: Some("dev"),
    start_sec: 1000L,
    end_sec: 1001L,
    status: "ok",
    error_msg: None,
  }
  let json = span.to_otlp_json()
  assert_true(json.contains("\"traceId\":\"00000000000000000000000000000abc\""))
  assert_true(json.contains("\"spanId\":\"0000000000000007\""))
  assert_true(json.contains("\"startTimeUnixNano\":\"1000000000000\""))
  assert_true(json.contains("\"name\":\"tools/call kv_get\""))
  assert_true(json.contains("\"code\":1"))
}
