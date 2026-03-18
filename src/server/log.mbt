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
