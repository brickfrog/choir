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
  companions_json : String?
  plugins_json : String?
  terminal_session : String
  /// When true, `file_pr` requests `@copilot` as a reviewer via `gh pr edit --add-reviewer` (best-effort).
  pr_review : Bool
} derive(Show)

///|
pub(all) struct LocalConfig {
  role : Role?
  agent_id : String?
  parent_id : String?
  branch : String?
  parent_branch : String?
  workspace : String?
  terminal_target : LocalTarget?
  agent_type : AgentType?
  spawn_depth : Int?
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
    companions_json: None,
    plugins_json: None,
    terminal_session: "choir",
    pr_review: true,
  }
}

///|
pub fn LocalConfig::default() -> LocalConfig {
  {
    role: None,
    agent_id: None,
    parent_id: None,
    branch: None,
    parent_branch: None,
    workspace: None,
    terminal_target: None,
    agent_type: None,
    spawn_depth: None,
  }
}
