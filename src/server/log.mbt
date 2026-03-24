///|
pub(all) struct Span {
  trace_id : String
  span_id : String
  name : String
  agent_id : String?
  role : String?
  start_sec : Int64
  end_sec : Int64
  status : String
  error_msg : String?
} derive(Show)

///|
fn normalize_hex_id(value : String, width : Int) -> String {
  if value.length() >= width {
    value[value.length() - width:].to_string()
  } else {
    "0".repeat(width - value.length()) + value
  }
}

///|
pub fn Span::format(self : Span) -> String {
  {
    "type": "span".to_json(),
    "name": self.name.to_json(),
    "trace_id": self.trace_id.to_json(),
    "span_id": self.span_id.to_json(),
    "agent_id": self.agent_id.unwrap_or("").to_json(),
    "role": self.role.unwrap_or("").to_json(),
    "start_sec": self.start_sec.to_json(),
    "end_sec": self.end_sec.to_json(),
    "status": self.status.to_json(),
    "error": self.error_msg.unwrap_or("").to_json(),
  }
  .to_json()
  .stringify()
}

///|
pub fn Span::emit(self : Span) -> Unit {
  println(self.format())
}

///|
fn otlp_string_attr(key : String, value : String) -> Json {
  {
    "key": key.to_json(),
    "value": { "stringValue": value.to_json() }.to_json(),
  }.to_json()
}

///|
pub fn Span::to_otlp_json(self : Span) -> String {
  let trace_id = normalize_hex_id(self.trace_id, 32)
  let span_id = normalize_hex_id(self.span_id, 16)
  let start_unix_nano = (self.start_sec * 1000000000L).to_string()
  let end_unix_nano = (self.end_sec * 1000000000L).to_string()
  let status_code : Int = if self.status == "ok" { 1 } else { 2 }
  let attrs : Array[Json] = []
  match self.agent_id {
    Some(agent_id) => attrs.push(otlp_string_attr("agent_id", agent_id))
    None => ()
  }
  match self.role {
    Some(role) => attrs.push(otlp_string_attr("role", role))
    None => ()
  }
  let span_obj : Map[String, Json] = {
    "traceId": trace_id.to_json(),
    "spanId": span_id.to_json(),
    "name": self.name.to_json(),
    "startTimeUnixNano": start_unix_nano.to_json(),
    "endTimeUnixNano": end_unix_nano.to_json(),
    "status": { "code": status_code.to_json() }.to_json(),
    "attributes": attrs.to_json(),
  }
  let scope_span : Map[String, Json] = {
    "scope": { "name": "choir/server".to_json() }.to_json(),
    "spans": [span_obj.to_json()].to_json(),
  }
  let resource_span : Map[String, Json] = {
    "resource": {
      "attributes": [otlp_string_attr("service.name", "choir")].to_json(),
    }.to_json(),
    "scopeSpans": [scope_span.to_json()].to_json(),
  }
  { "resourceSpans": [resource_span.to_json()].to_json() }.to_json().stringify()
}

///|
pub async fn Span::export_otlp(self : Span, endpoint : String) -> Unit {
  let base_url = if endpoint.has_prefix("http://") ||
    endpoint.has_prefix("https://") {
    endpoint
  } else {
    "http://" + endpoint
  }
  let url = if base_url.has_suffix("/") {
    base_url + "v1/traces"
  } else {
    base_url + "/v1/traces"
  }
  let body = self.to_otlp_json()
  let headers = { "Content-Type": "application/json" }
  try {
    let _ = @http.post(url, body, headers~)
  } catch {
    _ => ()
  }
}
