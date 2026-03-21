///|
pub(all) enum LogLevel {
  Debug
  Info
  Warn
  Error_
} derive(Show, Eq)

///|
pub(all) struct LogEntry {
  level : LogLevel
  component : String
  agent_id : String?
  message : String
} derive(Show)

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
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn normalize_hex_id(value : String, width : Int) -> String {
  if value.length() >= width {
    value[value.length() - width:].to_string() catch {
      _ => value
    }
  } else {
    "0".repeat(width - value.length()) + value
  }
}

///|
fn parse_port_int(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut res = 0
  for c in s {
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

///|
fn endpoint_host_port(endpoint : String) -> (String, Int)? {
  let stripped = if endpoint.has_prefix("http://") {
    endpoint[7:].to_string() catch {
      _ => ""
    }
  } else if endpoint.has_prefix("https://") {
    endpoint[8:].to_string() catch {
      _ => ""
    }
  } else {
    endpoint
  }
  let authority = match stripped.rev_find("/") {
    Some(idx) => stripped[:idx].to_string() catch { _ => "" }
    None => stripped
  }
  if authority == "" {
    return None
  }
  match authority.rev_find(":") {
    Some(idx) => {
      let host = authority[:idx].to_string() catch { _ => "" }
      let port_str = authority[idx + 1:].to_string() catch { _ => "" }
      if host == "" || port_str == "" {
        return None
      }
      match parse_port_int(port_str) {
        Some(port) => Some((host, port))
        None => None
      }
    }
    None => Some((authority, 4318))
  }
}

///|
pub fn LogEntry::format(self : LogEntry) -> String {
  let level_str = match self.level {
    Debug => "DEBUG"
    Info => "INFO"
    Warn => "WARN"
    Error_ => "ERROR"
  }
  match self.agent_id {
    None => "[\{level_str}] [\{self.component}] \{self.message}"
    Some(id) => "[\{level_str}] [\{self.component}] [\{id}] \{self.message}"
  }
}

///|
pub fn Span::format(self : Span) -> String {
  let agent = match self.agent_id {
    Some(a) => a
    None => ""
  }
  let role = match self.role {
    Some(r) => r
    None => ""
  }
  let err = match self.error_msg {
    Some(e) => e
    None => ""
  }
  "{\"type\":\"span\",\"name\":\"" +
  escape_json_string(self.name) +
  "\",\"trace_id\":\"" +
  escape_json_string(self.trace_id) +
  "\",\"span_id\":\"" +
  escape_json_string(self.span_id) +
  "\",\"agent_id\":\"" +
  escape_json_string(agent) +
  "\",\"role\":\"" +
  escape_json_string(role) +
  "\",\"start_sec\":" +
  self.start_sec.to_string() +
  ",\"end_sec\":" +
  self.end_sec.to_string() +
  ",\"status\":\"" +
  escape_json_string(self.status) +
  "\",\"error\":\"" +
  escape_json_string(err) +
  "\"}"
}

///|
pub fn Span::emit(self : Span) -> Unit {
  println(self.format())
}

///|
pub fn Span::to_otlp_json(self : Span) -> String {
  let trace_id = normalize_hex_id(self.trace_id, 32)
  let span_id = normalize_hex_id(self.span_id, 16)
  let start_unix_nano = (self.start_sec * 1000000000L).to_string()
  let end_unix_nano = (self.end_sec * 1000000000L).to_string()
  let status_code = if self.status == "ok" { "1" } else { "2" }
  let attrs = []
  match self.agent_id {
    Some(agent_id) =>
      attrs.push(
        "{\"key\":\"agent_id\",\"value\":{\"stringValue\":\"" +
        escape_json_string(agent_id) +
        "\"}}",
      )
    None => ()
  }
  match self.role {
    Some(role) =>
      attrs.push(
        "{\"key\":\"role\",\"value\":{\"stringValue\":\"" +
        escape_json_string(role) +
        "\"}}",
      )
    None => ()
  }
  let attrs_json = if attrs.is_empty() {
    "[]"
  } else {
    "[" + attrs.join(",") + "]"
  }
  "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"choir\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"choir/server\"},\"spans\":[{\"traceId\":\"" +
  escape_json_string(trace_id) +
  "\",\"spanId\":\"" +
  escape_json_string(span_id) +
  "\",\"name\":\"" +
  escape_json_string(self.name) +
  "\",\"startTimeUnixNano\":\"" +
  escape_json_string(start_unix_nano) +
  "\",\"endTimeUnixNano\":\"" +
  escape_json_string(end_unix_nano) +
  "\",\"status\":{\"code\":" +
  status_code +
  "},\"attributes\":" +
  attrs_json +
  "}]}]}]}"
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

///|
pub fn log_info(component : String, message : String) -> LogEntry {
  { level: Info, component, agent_id: None, message }
}

///|
pub fn log_error(component : String, message : String) -> LogEntry {
  { level: Error_, component, agent_id: None, message }
}

///|
pub fn log_warn(component : String, message : String) -> LogEntry {
  { level: Warn, component, agent_id: None, message }
}

///|
pub fn log_with_agent(
  level : LogLevel,
  component : String,
  agent_id : String,
  message : String,
) -> LogEntry {
  { level, component, agent_id: Some(agent_id), message }
}
