///|
pub(all) enum ConfigFile {
  ConfigToml
  ConfigLocalToml
} derive(Debug, Eq)

///|
pub impl Show for ConfigFile with fn output(self, logger) -> Unit {
  logger.write_string(self.schema_file_name())
}

///|
pub(all) struct ConfigSchemaEntry {
  file : ConfigFile
  key : String
  type_label : String
  default_label : String
  doc : String
} derive(Debug, Eq)

///|
fn ConfigFile::schema_file_name(self : ConfigFile) -> String {
  match self {
    ConfigToml => "config.toml"
    ConfigLocalToml => "config.local.toml"
  }
}

///|
fn ConfigFile::schema_heading(self : ConfigFile) -> String {
  ".choir/" + self.schema_file_name()
}

///|
fn schema_entry(
  file : ConfigFile,
  key : String,
  type_label : String,
  default_label : String,
  doc : String,
) -> ConfigSchemaEntry {
  { file, key, type_label, default_label, doc }
}

///|
pub fn config_schema_entries() -> Array[ConfigSchemaEntry] {
  [
    schema_entry(
      ConfigToml,
      "default_role",
      "Role { root | tl | dev | worker }",
      "\"tl\"",
      "Default role used when local config does not override it.",
    ),
    schema_entry(
      ConfigToml,
      "project_dir",
      "String",
      "\".\"",
      "Project root used for Choir-managed paths.",
    ),
    schema_entry(
      ConfigToml,
      "project.verify_cmd",
      "String?",
      "unset",
      "Optional default verify command used for fork_wave task contracts when no per-leaf verify command is supplied.",
    ),
    schema_entry(
      ConfigToml,
      "shell_command",
      "String?",
      "unset",
      "Optional shell command used when launching interactive agent panes.",
    ),
    schema_entry(
      ConfigToml,
      "listen_uds",
      "String",
      "\".choir/server.sock\"",
      "Unix-domain socket path for the Choir server.",
    ),
    schema_entry(
      ConfigToml,
      "listen_tcp",
      "String?",
      "unset",
      "Optional TCP listen address for the Choir server.",
    ),
    schema_entry(
      ConfigToml,
      "tcp_auth_token",
      "String?",
      "unset",
      "Optional bearer token required for TCP RPC clients.",
    ),
    schema_entry(
      ConfigToml,
      "otlp_endpoint",
      "String?",
      "unset",
      "Optional OpenTelemetry OTLP endpoint for tracing.",
    ),
    schema_entry(
      ConfigToml,
      "agent_id",
      "String?",
      "unset",
      "Optional canonical id for the current agent.",
    ),
    schema_entry(
      ConfigToml,
      "extra_mcp_servers_json",
      "String?",
      "unset",
      "Optional JSON object merged into generated MCP server settings.",
    ),
    schema_entry(
      ConfigToml,
      "companions_json",
      "String?",
      "unset",
      "Optional JSON array describing companion agents to launch.",
    ),
    schema_entry(
      ConfigToml,
      "plugins_json",
      "String?",
      "unset",
      "Optional JSON object for user plugin configuration.",
    ),
    schema_entry(
      ConfigToml,
      "terminal_session",
      "String",
      "\"choir\"",
      "Zellij session name used for local terminal targets.",
    ),
    schema_entry(
      ConfigToml,
      "automerge",
      "Bool",
      "false",
      "Global default for server-triggered automerge after policy reaches `MergeNow`.",
    ),
    schema_entry(
      ConfigToml,
      "review_mode",
      "ReviewMode { single_pass | iterative }",
      "\"single_pass\"",
      "Review loop behavior after fixes are pushed for review comments.",
    ),
    schema_entry(
      ConfigToml,
      "merge_strategy",
      "MergeStrategy { merge | squash | rebase }",
      "\"merge\"",
      "Strategy flag used when Choir runs `gh pr merge`.",
    ),
    schema_entry(
      ConfigToml,
      "moon_verify_target",
      "MoonVerifyTarget { native | wasm | wasm-gc | js }",
      "\"native\"",
      "Target appended to bare `moon check` / `moon test` verify commands.",
    ),
    schema_entry(
      ConfigToml,
      "agy_migration_incomplete",
      "Bool",
      "false",
      "Safety kill-switch while the agy migration is incomplete: rejects Gemini provider spawns.",
    ),
    schema_entry(
      ConfigToml,
      "hooks_enforcement",
      "Bool",
      "false",
      "When true, spawned hook-capable agents get task-contract boundary guard hooks.",
    ),
    schema_entry(
      ConfigToml,
      "worker_no_handoff_idle_sec",
      "Int64",
      "120",
      "Worker/leaf no-handoff idle threshold in seconds; 0 disables stalled event.",
    ),
    schema_entry(
      ConfigToml,
      "poller_heartbeat_tick_sec",
      "Int",
      "60",
      "Poller heartbeat cadence in seconds; 0 disables heartbeat ticks.",
    ),
    schema_entry(
      ConfigToml,
      "prenotify_checks",
      "Array[String]",
      "[\"moon check --target native\", \"CHOIR_TEST_NO_EXEC=1 moon test --target native\", \"CHOIR_TEST_REAL_EXEC=1 moon test --target native src/exec\", \"moon run src/bin/choir_lint --target native\"]",
      "Local checks that must pass before a Dev success `notify_parent` handoff.",
    ),
    schema_entry(
      ConfigToml,
      "auto_pull_after_integration",
      "Bool",
      "true",
      "Best-effort `git pull --ff-only` on the parent worktree after an integration PR merges.",
    ),
    schema_entry(
      ConfigToml,
      "pr_policy.require_integration_audit",
      "Bool",
      "true",
      "PR policy toggles for integration/default-branch merge enforcement.",
    ),
    schema_entry(
      ConfigToml,
      "pr_policy.skip_copilot_on_feature_branch",
      "Bool",
      "true",
      "When true, `file_pr` skips Copilot reviewer requests for PRs targeting non-default parent branches.",
    ),
    schema_entry(
      ConfigToml,
      "pr_policy.reviewer",
      "Reviewer { none | copilot | <handle> }",
      "\"none\"",
      "Reviewer requested by `file_pr`; `none` disables external reviewer requests. A configured Named reviewer is waited on like Copilot: a non-responsive reviewer stalls merge until the TL intervenes or config changes. Chosen reviewer = chosen wait.",
    ),
    schema_entry(
      ConfigToml,
      "auto_rebuild_after_pull",
      "Bool",
      "false",
      "Placeholder only in v1; parsed and persisted but not acted on.",
    ),
    schema_entry(
      ConfigToml,
      "auto_reload_after_rebuild",
      "Bool",
      "false",
      "Placeholder only in v1; parsed and persisted but not acted on.",
    ),
    schema_entry(
      ConfigToml,
      "pricing.<agent_type>.rate_in",
      "Double",
      "unset",
      "Per-agent-type token pricing, keyed by canonical AgentType wire string.",
    ),
    schema_entry(
      ConfigToml,
      "pricing.<agent_type>.rate_out",
      "Double",
      "unset",
      "Per-agent-type token pricing, keyed by canonical AgentType wire string.",
    ),
    schema_entry(
      ConfigLocalToml,
      "role",
      "Role?",
      "inherits global default_role",
      "Local role override for this worktree or agent.",
    ),
    schema_entry(
      ConfigLocalToml,
      "default_role",
      "Role?",
      "unset",
      "Machine-local default role fallback when config.toml omits it.",
    ),
    schema_entry(
      ConfigLocalToml,
      "project_dir",
      "String?",
      "unset",
      "Machine-local project root fallback when config.toml omits it.",
    ),
    schema_entry(
      ConfigLocalToml,
      "listen_uds",
      "String?",
      "unset",
      "Machine-local Unix-domain socket fallback when config.toml omits it.",
    ),
    schema_entry(
      ConfigLocalToml,
      "terminal_session",
      "String?",
      "unset",
      "Machine-local Zellij session fallback when config.toml omits it.",
    ),
    schema_entry(
      ConfigLocalToml,
      "agent_id",
      "String?",
      "unset",
      "Local canonical id for this agent.",
    ),
    schema_entry(
      ConfigLocalToml,
      "parent_id",
      "String?",
      "unset",
      "Parent agent id for handoff routing.",
    ),
    schema_entry(
      ConfigLocalToml,
      "branch",
      "String?",
      "unset",
      "Git branch assigned to this worktree.",
    ),
    schema_entry(
      ConfigLocalToml,
      "parent_branch",
      "String?",
      "unset",
      "Branch this worktree files PRs into.",
    ),
    schema_entry(
      ConfigLocalToml,
      "workspace",
      "String?",
      "unset",
      "Filesystem path to this agent worktree.",
    ),
    schema_entry(
      ConfigLocalToml,
      "terminal_target",
      "LocalTarget?",
      "unset",
      "Local terminal target for routing messages to this agent.",
    ),
    schema_entry(
      ConfigLocalToml,
      "agent_type",
      "AgentType?",
      "unset",
      "Agent CLI/provider assigned to this worktree.",
    ),
    schema_entry(
      ConfigLocalToml,
      "spawn_depth",
      "Int?",
      "unset",
      "Depth marker used to prevent unbounded recursive spawning.",
    ),
    schema_entry(
      ConfigLocalToml,
      "task_contract_json",
      "TaskContract JSON?",
      "unset",
      "Task contract assigned by the server for gate enforcement.",
    ),
    schema_entry(
      ConfigLocalToml,
      "automerge",
      "Bool?",
      "inherits global",
      "Per-wave automerge override persisted into spawned leaf config. `None` inherits global config.",
    ),
    schema_entry(
      ConfigLocalToml,
      "review_mode",
      "ReviewMode?",
      "inherits global",
      "Per-wave review-mode override. `None` inherits global config.",
    ),
    schema_entry(
      ConfigLocalToml,
      "merge_strategy",
      "MergeStrategy?",
      "inherits global",
      "Per-wave merge-strategy override. `None` inherits global config.",
    ),
    schema_entry(
      ConfigLocalToml,
      "auto_pull_after_integration",
      "Bool?",
      "inherits global",
      "Optional root-local override for post-integration-merge parent pull.",
    ),
    schema_entry(
      ConfigLocalToml,
      "auto_rebuild_after_pull",
      "Bool?",
      "unset",
      "Placeholder only in v1; parsed but not acted on.",
    ),
    schema_entry(
      ConfigLocalToml,
      "auto_reload_after_rebuild",
      "Bool?",
      "unset",
      "Placeholder only in v1; parsed but not acted on.",
    ),
    schema_entry(
      ConfigLocalToml,
      "wave_id",
      "String?",
      "unset",
      "Wave telemetry id assigned by `fork_wave`. `None` for root/pre-scaffold agents.",
    ),
  ]
}

///|
fn markdown_table_escape(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    match c {
      '|' => out.write_string("\\|")
      '\n' => out.write_char(' ')
      '\r' => out.write_char(' ')
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn render_schema_markdown_file(
  out : StringBuilder,
  entries : Array[ConfigSchemaEntry],
  file : ConfigFile,
) -> Unit {
  out.write_string("## ")
  out.write_string(file.schema_heading())
  out.write_string("\n\n")
  out.write_string("| Key | Type | Default | Doc |\n")
  out.write_string("| --- | --- | --- | --- |\n")
  for entry in entries {
    if entry.file != file {
      continue
    }
    out.write_string("| ")
    out.write_string(markdown_table_escape(entry.key))
    out.write_string(" | ")
    out.write_string(markdown_table_escape(entry.type_label))
    out.write_string(" | ")
    out.write_string(markdown_table_escape(entry.default_label))
    out.write_string(" | ")
    out.write_string(markdown_table_escape(entry.doc))
    out.write_string(" |\n")
  }
}

///|
pub fn render_schema_markdown(entries : Array[ConfigSchemaEntry]) -> String {
  let out = StringBuilder::new()
  render_schema_markdown_file(out, entries, ConfigToml)
  out.write_string("\n")
  render_schema_markdown_file(out, entries, ConfigLocalToml)
  out.to_string()
}

///|
fn config_schema_entry_json(entry : ConfigSchemaEntry) -> Json {
  let obj : Map[String, Json] = {
    "file": entry.file.schema_file_name().to_json(),
    "key": entry.key.to_json(),
    "type": entry.type_label.to_json(),
    "default": entry.default_label.to_json(),
    "doc": entry.doc.to_json(),
  }
  obj.to_json()
}

///|
pub fn render_schema_json(entries : Array[ConfigSchemaEntry]) -> String {
  let arr : Array[Json] = []
  for entry in entries {
    arr.push(config_schema_entry_json(entry))
  }
  arr.to_json().stringify()
}
