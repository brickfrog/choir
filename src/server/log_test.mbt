///|
test "normalize_trace_id pads short ids to 32 chars" {
  let id = normalize_trace_id("1774234675")
  assert_eq(id.length(), 32)
  assert_true(id.has_suffix("1774234675"))
  assert_true(id.has_prefix("0000000000000000000000"))
}

///|
test "normalize_trace_id truncates long ids to 32 chars" {
  let long_id = "0".repeat(40) + "abc"
  let id = normalize_trace_id(long_id)
  assert_eq(id.length(), 32)
}

///|
test "build_otlp_envelope includes choir resource and scope" {
  let span : @otlp.OtlpSpan = {
    trace_id: "0".repeat(32),
    span_id: "0".repeat(16),
    parent_span_id: "",
    name: "tools/call kv_get",
    kind: 1,
    start_time_unix_nano: (1000 : UInt64),
    end_time_unix_nano: (2000 : UInt64),
    attributes: [],
    status_code: 1,
    status_message: "",
  }
  let json = build_otlp_envelope(span)
  assert_true(json.contains("\"service.name\""))
  assert_true(json.contains("\"choir\""))
  assert_true(json.contains("\"choir/server\""))
  assert_true(json.contains("\"tools/call kv_get\""))
  assert_true(json.contains("resourceSpans"))
}

///|
test "span_to_otlp preserves choir fields as attributes" {
  let mt_span = @moontrace.span("tools/call fork_wave", fields=[
    @moontrace.field("agent_id", "leaf-1"),
    @moontrace.field("role", "TL"),
    @moontrace.field("status", "ok"),
  ])
  mt_span.start_time = (1000 : UInt64)
  mt_span.end_time = (2000 : UInt64)
  mt_span.status = @moontrace.Ok
  let otlp_span = @otlp.span_to_otlp(mt_span)
  assert_eq(otlp_span.name, "tools/call fork_wave")
  assert_eq(otlp_span.status_code, 1)
  assert_eq(otlp_span.attributes.length(), 3)
  assert_eq(otlp_span.attributes[0].key, "agent_id")
}

///|
test "request_log_level maps read-only tools to trace" {
  let read_only : @types.ToolDef = {
    name: "status_bar_state",
    description: "read",
    allowed_roles: [@types.Role::Root],
    read_only: true,
  }
  let mutating : @types.ToolDef = {
    name: "file_pr",
    description: "write",
    allowed_roles: [@types.Role::TL],
    read_only: false,
  }
  assert_true(request_log_level(read_only) == RequestLogLevel::Trace)
  assert_true(request_log_level(mutating) == RequestLogLevel::Info)
}

///|
test "request_log_level_for_request uses registry read-only annotation" {
  let project_dir = "/tmp/choir-request-log-readonly-" +
    @env.now().reinterpret_as_int64().to_string()
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Root,
    name: "status_bar_state",
    args: @types.RequestArgs::from_values({}),
  }
  assert_true(
    request_log_level_for_request(state, req) == RequestLogLevel::Trace,
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
test "request_log_level_for_request keeps mutating tools at info" {
  let project_dir = "/tmp/choir-request-log-mutating-" +
    @env.now().reinterpret_as_int64().to_string()
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
  )
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Root,
    name: "kv_set",
    args: @types.RequestArgs::from_values({
      "key": "request-log".to_json(),
      "value": "info".to_json(),
    }),
  }
  assert_true(
    request_log_level_for_request(state, req) == RequestLogLevel::Info,
  )
  ignore(@sys.rm_rf(project_dir))
}
