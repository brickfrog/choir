///|
/// Default Claude Code `settings.json` body when none exists (statusline hook).
fn init_bootstrap_claude_settings_json() -> String {
  "{\"statusLine\":{\"type\":\"command\",\"command\":\"choir statusline\"}}"
}

///|
/// Create `.claude` and seed `settings.json` only when absent; errors ignored (matches former `sh -c`).
fn init_bootstrap_seed_claude_settings_best_effort() -> Unit {
  if !@sys.create_dir_all(".claude") {
    return
  }
  if @sys.path_exists(".claude/settings.json") {
    return
  }
  ignore(
    @sys.write_file_sync(
      ".claude/settings.json",
      init_bootstrap_claude_settings_json(),
    ),
  )
}

///|
/// Create `.choir` and write `config.toml` when absent; exits on failure (matches former `sh` bootstrap).
fn init_bootstrap_ensure_choir_dir_and_config_if_absent(
  config_body : String,
) -> Unit {
  if !@sys.create_dir_all(".choir") {
    @sys.write_stderr("error: failed to create .choir directory\n")
    @sys.exit(1)
  }
  if !@sys.path_exists(".choir/config.toml") {
    if !@sys.write_file_sync(".choir/config.toml", config_body) {
      @sys.write_stderr("error: failed to write .choir/config.toml\n")
      @sys.exit(1)
    }
  }
}

///|
test "init default claude settings json matches seeded statusline hook" {
  assert_eq(
    init_bootstrap_claude_settings_json(),
    "{\"statusLine\":{\"type\":\"command\",\"command\":\"choir statusline\"}}",
  )
}
