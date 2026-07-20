///|
pub(all) enum Reviewer {
  None
  Copilot
  Named(String)
} derive(Debug, Eq)

///|
pub fn Reviewer::to_wire_string(self : Reviewer) -> String {
  match self {
    None => "none"
    Copilot => "copilot"
    Named(handle) => handle
  }
}

///|
pub fn Reviewer::text_label(self : Reviewer) -> String {
  match self {
    None => "reviewer"
    Copilot => "Copilot"
    Named(handle) => handle
  }
}

///|
pub fn Reviewer::request_handle(self : Reviewer) -> String {
  match self {
    None => "reviewer"
    Copilot => "@copilot"
    Named(handle) => handle
  }
}

///|
pub impl Show for Reviewer with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub fn Reviewer::try_parse_wire(raw : String) -> Result[Reviewer, ChoirError] {
  let trimmed = raw.trim().to_owned()
  if trimmed == "" {
    return Err(ChoirError::config_error("reviewer must be non-empty"))
  }
  match trimmed.to_lower() {
    "none" => Ok(Reviewer::None)
    "copilot" => Ok(Reviewer::Copilot)
    _ => Ok(Reviewer::Named(trimmed))
  }
}

///|
pub(all) enum ProvisionStrategy {
  Symlink
  Copy
  Command
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for ProvisionStrategy with fn output(self, logger) -> Unit {
  match self {
    Symlink => logger.write_string("symlink")
    Copy => logger.write_string("copy")
    Command => logger.write_string("command")
  }
}

///|
pub(all) struct ProvisionEntry {
  path : String
  strategy : ProvisionStrategy
  command : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The complete local daemon launch configuration.
pub(all) struct Config {
  project_dir : String
  listen_uds : String
} derive(Debug, Eq)

///|
pub fn Config::default() -> Config {
  { project_dir: ".", listen_uds: ".choir/run/server.sock" }
}
