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
