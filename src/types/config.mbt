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
