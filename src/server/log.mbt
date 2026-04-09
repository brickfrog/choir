///|
pub fn normalize_trace_id(run_id : String) -> String {
  if run_id.length() >= 32 {
    run_id[run_id.length() - 32:].to_string()
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
pub async fn export_otlp_span(span : @otlp.OtlpSpan, endpoint : String) -> Unit {
  ignore(span)
  ignore(endpoint)
}
