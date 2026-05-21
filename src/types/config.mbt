///|
pub let audit_heartbeat_sec_max : Int = 2_147_483

///|
pub let audit_max_rounds_max : Int = 2_147_483

///|
pub(all) struct PrPolicy {
  require_integration_audit : Bool
} derive(Debug, Eq)

///|
pub fn PrPolicy::default() -> PrPolicy {
  { require_integration_audit: true }
}

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
  /// Global default for server-triggered automerge after policy reaches `MergeNow`.
  automerge : Bool
  /// Review loop behavior after fixes are pushed for review comments.
  review_mode : ReviewMode
  /// Target appended to bare `moon check` / `moon test` verify commands.
  moon_verify_target : MoonVerifyTarget
  /// Safety kill-switch while the agy migration is incomplete: rejects Gemini provider spawns.
  agy_migration_incomplete : Bool
  /// Worker-only no-handoff prod threshold in seconds; 0 disables prod/stall.
  worker_no_handoff_prod_sec : Int64
  /// Worker-only no-handoff stalled-event grace after prod in seconds; 0 disables stalled event.
  worker_no_handoff_escalate_sec : Int64
  /// file_pr->main audit heartbeat cadence in seconds; 0 disables running heartbeats.
  audit_heartbeat_sec : Int
  /// file_pr->main audit hard limit; exhausted findings return AuditLoopExhausted.
  audit_max_rounds : Int
  /// Minimum mutation kill rate required after a leaf's own tests pass.
  mutation_kill_rate_min : Double
  /// Poller heartbeat cadence in seconds; 0 disables heartbeat ticks.
  poller_heartbeat_tick_sec : Int
  /// Local checks that must pass before a Dev success `notify_parent` handoff.
  prenotify_checks : Array[String]
  /// Best-effort `git pull --ff-only` on the parent worktree after an integration PR merges.
  auto_pull_after_integration : Bool
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
  role : Role?
  agent_id : String?
  parent_id : String?
  branch : String?
  parent_branch : String?
  workspace : String?
  terminal_target : LocalTarget?
  agent_type : AgentType?
  spawn_depth : Int?
  task_contract : TaskContract?
  /// Per-wave automerge override persisted into spawned leaf config. `None` inherits global config.
  automerge : Bool?
  /// Per-wave review-mode override. `None` inherits global config.
  review_mode : ReviewMode?
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
    moon_verify_target: Native,
    agy_migration_incomplete: false,
    worker_no_handoff_prod_sec: 120L,
    worker_no_handoff_escalate_sec: 120L,
    audit_heartbeat_sec: 60,
    audit_max_rounds: 3,
    mutation_kill_rate_min: 0.8,
    poller_heartbeat_tick_sec: 60,
    prenotify_checks: [
      "moon check --target native", "moon test --target native", "moon run src/bin/choir_lint --target native",
    ],
    auto_pull_after_integration: true,
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
    auto_pull_after_integration: None,
    auto_rebuild_after_pull: None,
    auto_reload_after_rebuild: None,
    wave_id: None,
  }
}
