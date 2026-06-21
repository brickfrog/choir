///|
pub let server_log_rotate_cap_bytes : Int = 8000000

///|
pub let otlp_span_queue_cap : Int = 10000

///|
fn server_log_project_path(project_dir : String, rel : String) -> String {
  if project_dir == "" || project_dir == "." {
    rel
  } else {
    project_dir + "/" + rel
  }
}

///|
pub fn server_log_should_rotate(
  size : Int,
  cap_bytes? : Int = server_log_rotate_cap_bytes,
) -> Bool {
  size > cap_bytes
}

///|
/// On fresh server start, rotate an unbounded append log to `<path>.1` when it exceeds the cap.
pub fn serve_rotate_log_if_large(
  project_dir : String,
  rel_path : String,
  file_size : (String) -> Int,
  rename_file : (String, String) -> Bool,
  cap_bytes? : Int = server_log_rotate_cap_bytes,
) -> Bool {
  let log_path = server_log_project_path(project_dir, rel_path)
  serve_rotate_resolved_log_if_large(
    log_path,
    file_size,
    rename_file,
    cap_bytes~,
  )
}

///|
fn serve_rotate_resolved_log_if_large(
  log_path : String,
  file_size : (String) -> Int,
  rename_file : (String, String) -> Bool,
  cap_bytes? : Int = server_log_rotate_cap_bytes,
) -> Bool {
  if server_log_should_rotate(file_size(log_path), cap_bytes~) {
    rename_file(log_path, log_path + ".1")
  } else {
    false
  }
}

///|
test "serve_rotate_resolved_log_if_large rotates oversized logs through injected adapters" {
  let log_path = "/tmp/choir-project/.choir/logs/serve.log"
  let sized_paths : Array[String] = []
  let renamed_paths : Array[(String, String)] = []
  let rotated = serve_rotate_resolved_log_if_large(
    log_path,
    fn(path) {
      sized_paths.push(path)
      8000001
    },
    fn(from_path, to_path) {
      renamed_paths.push((from_path, to_path))
      true
    },
  )
  assert_true(rotated)
  @debug.assert_eq(sized_paths, [log_path])
  @debug.assert_eq(renamed_paths, [(log_path, log_path + ".1")])
}

///|
pub fn normalize_trace_id(run_id : String) -> String {
  let hi = otlp_fnv1a64(run_id, 0x9e3779b97f4a7c15UL)
  let lo = otlp_fnv1a64(run_id, 0x6c62272e07bb0142UL)
  let trace_id = otlp_hex_u64(hi) + otlp_hex_u64(lo)
  if trace_id == "00000000000000000000000000000000" {
    "00000000000000000000000000000001"
  } else {
    trace_id
  }
}

///|
fn otlp_fnv1a64(value : String, salt : UInt64) -> UInt64 {
  let mut hash = 14695981039346656037UL ^ salt
  for i = 0; i < value.length(); i = i + 1 {
    hash = hash ^ value.code_unit_at(i).to_int().to_uint64()
    hash = hash * 1099511628211UL
  }
  hash
}

///|
fn otlp_hex_u64(value : UInt64) -> String {
  value.to_string(radix=16).pad_start(16, '0')
}

///|
pub fn otlp_unix_ms_to_ns(ms : UInt64) -> UInt64 {
  ms * (1_000_000 : UInt64)
}

///|
pub(all) struct OtlpSpanExporter {
  mut spans : Array[@otlp.OtlpSpan]
  queue_cap : Int
  mut queue_drop_warned : Bool
  resource : @otlp.Resource
  scope : @otlp.InstrumentationScope
  export_batch : async (
    Array[@otlp.OtlpSpan],
    @otlp.Resource,
    @otlp.InstrumentationScope,
  ) -> Result[@transport.ExportOutcome, @transport.TransportError]
}

///|
fn choir_otlp_resource() -> @otlp.Resource {
  @otlp.resource(service_name="choir")
}

///|
fn choir_otlp_scope() -> @otlp.InstrumentationScope {
  @otlp.instrumentation_scope(name="choir/server")
}

///|
fn choir_otlp_json_headers() -> Map[String, String] {
  { "Content-Type": @transport.json_encoder().content_type() }
}

///|
pub fn make_otlp_span_exporter_with_batch(
  export_batch : async (
    Array[@otlp.OtlpSpan],
    @otlp.Resource,
    @otlp.InstrumentationScope,
  ) -> Result[@transport.ExportOutcome, @transport.TransportError],
  queue_cap? : Int = otlp_span_queue_cap,
) -> OtlpSpanExporter {
  {
    spans: [],
    queue_cap: if queue_cap <= 0 {
      1
    } else {
      queue_cap
    },
    queue_drop_warned: false,
    resource: choir_otlp_resource(),
    scope: choir_otlp_scope(),
    export_batch,
  }
}

///|
pub fn make_otlp_span_exporter(endpoint : String) -> OtlpSpanExporter {
  let client = @transport.async_http_client(timeout_ms=5000)
  let tx = @transport.transport(
    client,
    endpoint,
    headers=choir_otlp_json_headers(),
  )
  make_otlp_span_exporter_with_batch(async fn(spans, resource, scope) {
    tx.export_spans(spans, resource~, scope~)
  })
}

///|
pub fn otlp_span_exporter_for_config(
  config : @types.Config,
  factory? : (String) -> OtlpSpanExporter = make_otlp_span_exporter,
) -> OtlpSpanExporter? {
  match config.otlp_endpoint {
    Some(endpoint) => Some(factory(endpoint))
    None => None
  }
}

///|
pub fn OtlpSpanExporter::enqueue(
  self : OtlpSpanExporter,
  span : @otlp.OtlpSpan,
) -> Unit {
  self.spans.push(span)
  self.enforce_queue_cap()
}

///|
fn OtlpSpanExporter::enforce_queue_cap(self : OtlpSpanExporter) -> Unit {
  if self.spans.length() <= self.queue_cap {
    return
  }
  let dropped = self.spans.length() - self.queue_cap
  let capped : Array[@otlp.OtlpSpan] = []
  for i = dropped; i < self.spans.length(); i = i + 1 {
    capped.push(self.spans[i])
  }
  self.spans = capped
  if !self.queue_drop_warned {
    self.queue_drop_warned = true
    @moontrace.warn("OTLP span queue cap reached", fields=[
      @moontrace.field("queue_cap", self.queue_cap),
      @moontrace.field("dropped_spans", dropped),
    ])
  }
}

///|
pub fn OtlpSpanExporter::queued_count(self : OtlpSpanExporter) -> Int {
  self.spans.length()
}

///|
fn OtlpSpanExporter::requeue_drained_front(
  self : OtlpSpanExporter,
  drained : Array[@otlp.OtlpSpan],
) -> Unit {
  let queued_after_failure = self.spans
  self.spans = drained
  for span in queued_after_failure {
    self.spans.push(span)
  }
  self.enforce_queue_cap()
}

///|
fn otlp_retry_class_to_string(retry_class : @transport.RetryClass) -> String {
  match retry_class {
    @transport.Success => "success"
    @transport.Retryable => "retryable"
    @transport.NonRetryable => "non_retryable"
  }
}

///|
fn otlp_export_outcome_error(
  outcome : @transport.ExportOutcome,
) -> @transport.TransportError {
  match outcome.error {
    Some(err) => err
    None => {
      let status = match outcome.status_code {
        Some(code) => code.to_string()
        None => "none"
      }
      @transport.Request(
        "OTLP span export failed: success=false status_code=" +
        status +
        " retry_class=" +
        otlp_retry_class_to_string(outcome.retry_class) +
        " attempts=" +
        outcome.attempts.to_string(),
      )
    }
  }
}

///|
pub async fn OtlpSpanExporter::flush(
  self : OtlpSpanExporter,
) -> Result[Int, @transport.TransportError] {
  if self.spans.length() == 0 {
    return Ok(0)
  }
  let spans = self.spans
  self.spans = []
  match (self.export_batch)(spans, self.resource, self.scope) {
    Ok(outcome) =>
      if outcome.success {
        Ok(spans.length())
      } else {
        self.requeue_drained_front(spans)
        Err(otlp_export_outcome_error(outcome))
      }
    Err(err) => {
      self.requeue_drained_front(spans)
      Err(err)
    }
  }
}

///|
pub fn ServerState::has_otlp_span_exporter(self : ServerState) -> Bool {
  self.otlp_exporter is Some(_)
}

///|
pub fn ServerState::otlp_queued_span_count(self : ServerState) -> Int {
  match self.otlp_exporter {
    Some(exporter) => exporter.queued_count()
    None => 0
  }
}

///|
pub async fn ServerState::flush_otlp_spans(
  self : ServerState,
) -> Result[Int, @transport.TransportError] {
  match self.otlp_exporter {
    Some(exporter) => exporter.flush()
    None => Ok(0)
  }
}

///|
pub async fn ServerState::run_otlp_span_export_loop(
  self : ServerState,
  interval_ms? : Int = 1000,
) -> Unit {
  if !self.has_otlp_span_exporter() {
    return
  }
  for ;; {
    @async.sleep(interval_ms)
    match self.flush_otlp_spans() {
      Ok(_) => ()
      Err(err) =>
        @moontrace.warn("OTLP span export failed", fields=[
          @moontrace.field("error", err.to_string()),
        ])
    }
  }
}
