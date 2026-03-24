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
  let mt_span = @moontrace.span(
    "tools/call fork_wave",
    fields=@moontrace.fields([
      ("agent_id", "leaf-1".to_json()),
      ("role", "TL".to_json()),
      ("status", "ok".to_json()),
    ]),
  )
  mt_span.start_time = (1000 : UInt64)
  mt_span.end_time = (2000 : UInt64)
  let otlp_span = @otlp.span_to_otlp(
    mt_span,
    trace_id="0".repeat(32),
    status_code=1,
  )
  assert_eq(otlp_span.name, "tools/call fork_wave")
  assert_eq(otlp_span.trace_id, "0".repeat(32))
  assert_eq(otlp_span.status_code, 1)
  assert_eq(otlp_span.attributes.length(), 3)
  assert_eq(otlp_span.attributes[0].key, "agent_id")
}
