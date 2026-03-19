///|
/// Parsed server configuration.
pub(all) struct Config {
  default_role : Role
  project_dir : String
  shell_command : String?
  listen_uds : String
  listen_tcp : String?
  tcp_auth_token : String?
  otlp_endpoint : String?
  agent_id : String?
  extra_mcp_servers_json : String?
} derive(Show)

///|
/// Default configuration values.
pub fn Config::default() -> Config {
  {
    default_role: TL,
    project_dir: ".",
    shell_command: None,
    listen_uds: ".choir/server.sock",
    listen_tcp: None,
    tcp_auth_token: None,
    otlp_endpoint: None,
    agent_id: None,
    extra_mcp_servers_json: None,
  }
}
