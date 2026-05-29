///|
pub let heartbeat_sec_max : Int = 2_147_483

///|
pub(all) struct PrPolicy {
  require_integration_audit : Bool
  skip_copilot_on_feature_branch : Bool
} derive(Debug, Eq)

///|
pub fn PrPolicy::default() -> PrPolicy {
  { require_integration_audit: true, skip_copilot_on_feature_branch: true }
}

///|
pub(all) struct Project {
  verify_cmd : String?
} derive(Debug, Eq)

///|
pub fn Project::default() -> Project {
  { verify_cmd: None }
}

///|
/// Parsed server configuration.
pub(all) struct Config {
  /// Default role used when local config does not override it.
  default_role : Role
  /// Project root used for Choir-managed paths.
  project_dir : String
  /// Optional shell command used when launching interactive agent panes.
  shell_command : String?
  /// Unix-domain socket path for the Choir server.
  listen_uds : String
  /// Optional TCP listen address for the Choir server.
  listen_tcp : String?
  /// Optional bearer token required for TCP RPC clients.
  tcp_auth_token : String?
  /// Optional OpenTelemetry OTLP endpoint for tracing.
  otlp_endpoint : String?
  /// Optional canonical id for the current agent.
  agent_id : String?
  /// Optional JSON object merged into generated MCP server settings.
  extra_mcp_servers_json : String?
  /// Optional JSON array describing companion agents to launch.
  companions_json : String?
  /// Optional JSON object for user plugin configuration.
  plugins_json : String?
  /// Zellij session name used for local terminal targets.
  terminal_session : String
  /// When true, `file_pr` requests `@copilot` as a reviewer via `gh pr edit --add-reviewer` (best-effort).
  pr_review : Bool
  /// Global default for server-triggered automerge after policy reaches `MergeNow`.
  automerge : Bool
  /// Review loop behavior after fixes are pushed for review comments.
  review_mode : ReviewMode
  /// Strategy flag used when Choir runs `gh pr merge`.
  merge_strategy : MergeStrategy
  /// Target appended to bare `moon check` / `moon test` verify commands.
  moon_verify_target : MoonVerifyTarget
  /// Safety kill-switch while the agy migration is incomplete: rejects Gemini provider spawns.
  agy_migration_incomplete : Bool
  /// Worker-only no-handoff prod threshold in seconds; 0 disables prod/stall.
  worker_no_handoff_prod_sec : Int64
  /// Worker-only no-handoff stalled-event grace after prod in seconds; 0 disables stalled event.
  worker_no_handoff_escalate_sec : Int64
  /// Poller heartbeat cadence in seconds; 0 disables heartbeat ticks.
  poller_heartbeat_tick_sec : Int
  /// Local checks that must pass before a Dev success `notify_parent` handoff.
  prenotify_checks : Array[String]
  /// Best-effort `git pull --ff-only` on the parent worktree after an integration PR merges.
  auto_pull_after_integration : Bool
  /// Per-project defaults for repo-agnostic orchestration.
  project : Project
  /// PR policy toggles for integration/default-branch merge enforcement.
  pr_policy : PrPolicy
  /// Placeholder only in v1; parsed and persisted but not acted on.
  auto_rebuild_after_pull : Bool
  /// Placeholder only in v1; parsed and persisted but not acted on.
  auto_reload_after_rebuild : Bool
  /// Per-agent-type token pricing, keyed by canonical AgentType wire string.
  pricing : Map[String, PricingRate]
} derive(Debug)

///|
pub(all) struct PricingRate {
  rate_in : Double
  rate_out : Double
} derive(Debug, Eq)

///|
pub(all) struct LocalConfig {
  /// Local role override for this worktree or agent.
  role : Role?
  /// Local canonical id for this agent.
  agent_id : String?
  /// Parent agent id for handoff routing.
  parent_id : String?
  /// Git branch assigned to this worktree.
  branch : String?
  /// Branch this worktree files PRs into.
  parent_branch : String?
  /// Filesystem path to this agent worktree.
  workspace : String?
  /// Local terminal target for routing messages to this agent.
  terminal_target : LocalTarget?
  /// Agent CLI/provider assigned to this worktree.
  agent_type : AgentType?
  /// Depth marker used to prevent unbounded recursive spawning.
  spawn_depth : Int?
  /// Task contract assigned by the server for gate enforcement.
  task_contract : TaskContract?
  /// Per-wave automerge override persisted into spawned leaf config. `None` inherits global config.
  automerge : Bool?
  /// Per-wave review-mode override. `None` inherits global config.
  review_mode : ReviewMode?
  /// Per-wave merge-strategy override. `None` inherits global config.
  merge_strategy : MergeStrategy?
  /// Optional root-local override for post-integration-merge parent pull.
  auto_pull_after_integration : Bool?
  /// Placeholder only in v1; parsed but not acted on.
  auto_rebuild_after_pull : Bool?
  /// Placeholder only in v1; parsed but not acted on.
  auto_reload_after_rebuild : Bool?
  /// Wave telemetry id assigned by `fork_wave`. `None` for root/pre-scaffold agents.
  wave_id : String?
} derive(Debug)

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
    automerge: false,
    review_mode: SinglePass,
    merge_strategy: Merge,
    moon_verify_target: Native,
    agy_migration_incomplete: false,
    worker_no_handoff_prod_sec: 120L,
    worker_no_handoff_escalate_sec: 120L,
    poller_heartbeat_tick_sec: 60,
    prenotify_checks: [],
    auto_pull_after_integration: true,
    project: Project::default(),
    pr_policy: PrPolicy::default(),
    auto_rebuild_after_pull: false,
    auto_reload_after_rebuild: false,
    pricing: {},
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
    task_contract: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    auto_pull_after_integration: None,
    auto_rebuild_after_pull: None,
    auto_reload_after_rebuild: None,
    wave_id: None,
  }
}
