///|
fn otlp_test_is_lower_hex_id(value : String, expected_len : Int) -> Bool {
  if value.length() != expected_len {
    return false
  }
  for i = 0; i < value.length(); i = i + 1 {
    let c = value[i]
    let digit = c >= '0' && c <= '9'
    let lower_hex = c >= 'a' && c <= 'f'
    if !digit && !lower_hex {
      return false
    }
  }
  true
}

///|
test "normalize_trace_id hashes run ids to valid lowercase hex trace ids" {
  let id = normalize_trace_id("1774234675")
  assert_eq(id.length(), 32)
  assert_true(otlp_test_is_lower_hex_id(id, 32))
  assert_false(id.contains("-"))
}

///|
test "normalize_trace_id is deterministic and distinguishes run ids" {
  let first = normalize_trace_id("1774234675-12345")
  let second = normalize_trace_id("1774234675-12345")
  let other = normalize_trace_id("1774234676-12345")
  assert_eq(first, second)
  assert_true(otlp_test_is_lower_hex_id(first, 32))
  assert_true(otlp_test_is_lower_hex_id(other, 32))
  assert_true(first != other)
}

///|
test "otlp_unix_ms_to_ns converts milliseconds to nanoseconds" {
  assert_eq(otlp_unix_ms_to_ns((1234 : UInt64)), (1_234_000_000 : UInt64))
}

///|
fn otlp_test_success_outcome() -> @transport.ExportOutcome {
  {
    success: true,
    attempts: 1,
    status_code: Some(200),
    error: None,
    retry_class: @transport.Success,
  }
}

///|
fn otlp_test_failed_outcome(
  status_code? : Int? = Some(503),
  retry_class? : @transport.RetryClass = @transport.Retryable,
) -> @transport.ExportOutcome {
  { success: false, attempts: 2, status_code, error: None, retry_class }
}

///|
fn otlp_test_decode_payload_body(payload : @transport.OtlpPayload) -> String {
  @utf8.decode(payload.body) catch {
    _ => abort("invalid UTF-8 payload body")
  }
}

///|
fn otlp_test_parse_payload_json(payload : @transport.OtlpPayload) -> Json {
  let text = otlp_test_decode_payload_body(payload)
  @json.parse(text) catch {
    err => abort("invalid OTLP JSON payload: \{err}")
  }
}

///|
fn otlp_test_span(name : String) -> @otlp.OtlpSpan {
  let mt_span = @moontrace.span(name)
  mt_span.start_time = (1000 : UInt64)
  mt_span.end_time = (2000 : UInt64)
  @otlp.span_to_otlp(mt_span)
}

///|
test "ServerState::new constructs OTLP exporter only when endpoint configured" {
  let endpoints : Array[String] = []
  let factory = fn(endpoint : String) -> OtlpSpanExporter {
    endpoints.push(endpoint)
    make_otlp_span_exporter_with_batch(async fn(_spans, _resource, _scope) {
      @async.sleep(0)
      Ok(otlp_test_success_outcome())
    })
  }
  let none_dir = "/tmp/choir-otlp-exporter-none-" +
    @env.now().reinterpret_as_int64().to_string()
  let none_state = ServerState::new(
    { ..@types.Config::default(), project_dir: none_dir },
    make_hermetic_recovery_provider(),
    otlp_exporter_factory=factory,
  )
  assert_false(none_state.has_otlp_span_exporter())
  @debug.assert_eq(endpoints, [])
  ignore(@sys.rm_rf(none_dir))

  let some_dir = "/tmp/choir-otlp-exporter-some-" +
    @env.now().reinterpret_as_int64().to_string()
  let some_state = ServerState::new(
    {
      ..@types.Config::default(),
      project_dir: some_dir,
      otlp_endpoint: Some("http://collector:4318"),
    },
    make_hermetic_recovery_provider(),
    otlp_exporter_factory=factory,
  )
  assert_true(some_state.has_otlp_span_exporter())
  @debug.assert_eq(endpoints, ["http://collector:4318"])
  ignore(@sys.rm_rf(some_dir))
}

///|
async test "OTLP exporter flushes queued spans through injected batch as valid JSON" {
  let batches : Array[Array[@otlp.OtlpSpan]] = []
  let resources : Array[@otlp.Resource] = []
  let scopes : Array[@otlp.InstrumentationScope] = []
  let exporter = make_otlp_span_exporter_with_batch(async fn(
    spans,
    resource,
    scope,
  ) {
    @async.sleep(0)
    batches.push(spans)
    resources.push(resource)
    scopes.push(scope)
    Ok(otlp_test_success_outcome())
  })
  let mt_span = @moontrace.span_with_trace(
    "tools/call fork_wave",
    "0000000000000000000000000000000f",
    fields=[
      @moontrace.field("agent_id", "leaf-1"),
      @moontrace.field("role", "Dev"),
      @moontrace.field("status", "ok"),
    ],
  )
  mt_span.start_time = (1000 : UInt64)
  mt_span.end_time = (2000 : UInt64)
  mt_span.status = @moontrace.Ok
  exporter.enqueue(@otlp.span_to_otlp(mt_span))
  assert_eq(exporter.queued_count(), 1)

  match exporter.flush() {
    Ok(count) => assert_eq(count, 1)
    Err(err) => abort("expected successful OTLP flush: \{err}")
  }
  assert_eq(exporter.queued_count(), 0)
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].length(), 1)
  assert_eq(batches[0][0].name, "tools/call fork_wave")

  match
    @transport.json_encoder().encode_spans(
      batches[0],
      resource=resources[0],
      scope=scopes[0],
    ) {
    Ok(payload) => {
      assert_eq(payload.content_type, @transport.otlp_json_content_type())
      let root_json = otlp_test_parse_payload_json(payload)
      guard root_json is Object(root) else { fail("expected OTLP JSON object") }
      assert_true(root.contains("resourceSpans"))
      let body = otlp_test_decode_payload_body(payload)
      assert_true(body.contains("\"service.name\""))
      assert_true(body.contains("\"choir\""))
      assert_true(body.contains("\"choir/server\""))
      assert_true(body.contains("\"tools/call fork_wave\""))
    }
    Err(err) => abort("expected JSON span payload: \{err}")
  }
}

///|
async test "OTLP exporter requeues failed flush ahead of newly enqueued spans" {
  let calls : Ref[Int] = @ref.new(0)
  let exporter_ref : Ref[OtlpSpanExporter?] = @ref.new(None)
  let batches : Array[Array[@otlp.OtlpSpan]] = []
  let exporter = make_otlp_span_exporter_with_batch(async fn(
    spans,
    _resource,
    _scope,
  ) {
    @async.sleep(0)
    calls.val = calls.val + 1
    if calls.val == 1 {
      match exporter_ref.val {
        Some(exporter) =>
          exporter.enqueue(otlp_test_span("queued-during-error"))
        None => abort("missing exporter ref")
      }
      Err(@transport.Network("collector unavailable"))
    } else {
      batches.push(spans)
      Ok(otlp_test_success_outcome())
    }
  })
  exporter_ref.val = Some(exporter)
  exporter.enqueue(otlp_test_span("first-drained"))
  exporter.enqueue(otlp_test_span("second-drained"))

  match exporter.flush() {
    Ok(_) => abort("expected failed OTLP flush")
    Err(err) => assert_true(err.to_string().contains("collector unavailable"))
  }
  assert_eq(exporter.queued_count(), 3)

  match exporter.flush() {
    Ok(count) => assert_eq(count, 3)
    Err(err) => abort("expected retry flush to succeed: \{err}")
  }
  assert_eq(exporter.queued_count(), 0)
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].length(), 3)
  assert_eq(batches[0][0].name, "first-drained")
  assert_eq(batches[0][1].name, "second-drained")
  assert_eq(batches[0][2].name, "queued-during-error")
}

///|
async test "OTLP exporter requeues non-success export outcomes" {
  let calls : Ref[Int] = @ref.new(0)
  let batches : Array[Array[@otlp.OtlpSpan]] = []
  let exporter = make_otlp_span_exporter_with_batch(async fn(
    spans,
    _resource,
    _scope,
  ) {
    @async.sleep(0)
    calls.val = calls.val + 1
    if calls.val == 1 {
      Ok(otlp_test_failed_outcome())
    } else {
      batches.push(spans)
      Ok(otlp_test_success_outcome())
    }
  })
  exporter.enqueue(otlp_test_span("not-silently-lost"))

  match exporter.flush() {
    Ok(_) => abort("expected non-success OTLP outcome to fail flush")
    Err(err) => assert_true(err.to_string().contains("success=false"))
  }
  assert_eq(exporter.queued_count(), 1)

  match exporter.flush() {
    Ok(count) => assert_eq(count, 1)
    Err(err) => abort("expected retry flush to succeed: \{err}")
  }
  assert_eq(exporter.queued_count(), 0)
  assert_eq(batches.length(), 1)
  assert_eq(batches[0][0].name, "not-silently-lost")
}

///|
test "OTLP exporter caps queue by dropping oldest spans" {
  let exporter = make_otlp_span_exporter_with_batch(
    async fn(_spans, _resource, _scope) {
      @async.sleep(0)
      Ok(otlp_test_success_outcome())
    },
    queue_cap=2,
  )
  exporter.enqueue(otlp_test_span("oldest"))
  exporter.enqueue(otlp_test_span("kept-1"))
  exporter.enqueue(otlp_test_span("kept-2"))

  assert_eq(exporter.queued_count(), 2)
  assert_eq(exporter.spans[0].name, "kept-1")
  assert_eq(exporter.spans[1].name, "kept-2")
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
