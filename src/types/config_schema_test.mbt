///|
fn schema_has_entry(
  entries : Array[ConfigSchemaEntry],
  file : ConfigFile,
  key : String,
) -> Bool {
  for entry in entries {
    if entry.file == file && entry.key == key {
      return true
    }
  }
  false
}

///|
fn expected_config_schema_keys() -> Array[String] {
  [
    "default_role", "project_dir", "shell_command", "listen_uds", "listen_tcp", "tcp_auth_token",
    "otlp_endpoint", "agent_id", "extra_mcp_servers_json", "companions_json", "plugins_json",
    "terminal_session", "pr_review", "automerge", "review_mode", "merge_strategy",
    "moon_verify_target", "agy_migration_incomplete", "hooks_enforcement", "worker_no_handoff_prod_sec",
    "worker_no_handoff_escalate_sec", "poller_heartbeat_tick_sec", "prenotify_checks",
    "auto_pull_after_integration", "project.verify_cmd", "pr_policy.require_integration_audit",
    "pr_policy.skip_copilot_on_feature_branch", "auto_rebuild_after_pull", "auto_reload_after_rebuild",
    "pricing.<agent_type>.rate_in", "pricing.<agent_type>.rate_out",
  ]
}

///|
fn expected_local_config_schema_keys() -> Array[String] {
  [
    "role", "default_role", "project_dir", "listen_uds", "terminal_session", "agent_id",
    "parent_id", "branch", "parent_branch", "workspace", "terminal_target", "agent_type",
    "spawn_depth", "task_contract_json", "automerge", "review_mode", "merge_strategy",
    "auto_pull_after_integration", "auto_rebuild_after_pull", "auto_reload_after_rebuild",
    "wave_id",
  ]
}

///|
test "config_schema_entries covers Config and LocalConfig fields" {
  let entries = config_schema_entries()
  for key in expected_config_schema_keys() {
    assert_true(schema_has_entry(entries, ConfigToml, key))
  }
  for key in expected_local_config_schema_keys() {
    assert_true(schema_has_entry(entries, ConfigLocalToml, key))
  }
}

///|
test "config_schema_entries are complete enough to render" {
  let entries = config_schema_entries()
  for entry in entries {
    assert_true(entry.key != "")
    assert_true(entry.type_label != "")
    assert_true(entry.default_label != "")
    assert_true(entry.doc != "")
  }
  assert_true(schema_has_entry(entries, ConfigToml, "merge_strategy"))
  assert_true(schema_has_entry(entries, ConfigLocalToml, "merge_strategy"))
  assert_true(schema_has_entry(entries, ConfigToml, "automerge"))
  assert_true(schema_has_entry(entries, ConfigLocalToml, "automerge"))
  assert_true(schema_has_entry(entries, ConfigToml, "review_mode"))
  assert_true(schema_has_entry(entries, ConfigLocalToml, "review_mode"))
  assert_true(schema_has_entry(entries, ConfigToml, "hooks_enforcement"))
}

///|
test "render_schema_markdown includes config tables and core keys" {
  let markdown = render_schema_markdown(config_schema_entries())
  assert_true(markdown.contains("## .choir/config.toml"))
  assert_true(markdown.contains("## .choir/config.local.toml"))
  assert_true(markdown.contains("| Key |"))
  assert_true(markdown.contains("merge_strategy"))
  assert_true(markdown.contains("automerge"))
  assert_true(markdown.contains("review_mode"))
}

///|
test "render_schema_json emits parseable entries with merge_strategy" {
  let body = render_schema_json(config_schema_entries())
  let parsed = @json.parse(body) catch {
    _ => {
      fail("config schema JSON did not parse")
      return
    }
  }
  guard parsed is Array(items) else {
    fail("config schema JSON should be an array")
    return
  }
  let mut has_merge_strategy = false
  for item in items {
    guard item is Object(obj) else {
      fail("config schema JSON entries should be objects")
      return
    }
    match obj.get("key") {
      Some(String(key)) =>
        if key == "merge_strategy" {
          has_merge_strategy = true
        }
      _ => ()
    }
  }
  assert_true(has_merge_strategy)
}
