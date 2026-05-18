///|
pub let server_log_rotate_cap_bytes : Int = 8000000

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
  rename : (String, String) -> Bool,
  cap_bytes? : Int = server_log_rotate_cap_bytes,
) -> Bool {
  let log_path = server_log_project_path(project_dir, rel_path)
  if server_log_should_rotate(file_size(log_path), cap_bytes~) {
    rename(log_path, log_path + ".1")
  } else {
    false
  }
}

///|
pub fn normalize_trace_id(run_id : String) -> String {
  if run_id.length() >= 32 {
    run_id[run_id.length() - 32:].to_owned()
  } else {
    "0".repeat(32 - run_id.length()) + run_id
  }
}

///|
pub fn build_otlp_envelope(span : @otlp.OtlpSpan) -> String {
  let svc_attr : Map[String, Json] = {}
  svc_attr.set("key", "service.name".to_json())
  svc_attr.set("value", { "stringValue": "choir".to_json() }.to_json())

  let scope : Map[String, Json] = {}
  scope.set("name", "choir/server".to_json())

  let scope_spans : Map[String, Json] = {}
  scope_spans.set("scope", scope.to_json())
  scope_spans.set("spans", [span.to_json()].to_json())

  let resource : Map[String, Json] = {}
  resource.set("attributes", [svc_attr.to_json()].to_json())

  let resource_spans : Map[String, Json] = {}
  resource_spans.set("resource", resource.to_json())
  resource_spans.set("scopeSpans", [scope_spans.to_json()].to_json())

  let root : Map[String, Json] = {}
  root.set("resourceSpans", [resource_spans.to_json()].to_json())
  root.to_json().stringify()
}

///|
pub fn export_otlp_span(span : @otlp.OtlpSpan, endpoint : String) -> Unit {
  ignore(span)
  ignore(endpoint)
}
