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
/// Best-effort: ensure `<project_dir>/.choir/agents/root` exists and write `.birth_branch` with the
/// exact `git branch --show-current` stdout (empty when detached or unavailable). Matches former
/// `mkdir -p ... && git ... > ... 2>/dev/null || true` semantics; errors are ignored.
fn init_bootstrap_write_root_birth_branch_best_effort(
  project_dir : String,
  git_branch_stdout : String,
) -> Unit {
  let agents_root = project_dir + "/.choir/agents/root"
  let path = agents_root + "/.birth_branch"
  if !@sys.create_dir_all(agents_root) {
    return
  }
  ignore(@sys.write_file_sync(path, git_branch_stdout))
}

///|
test "init default claude settings json matches seeded statusline hook" {
  assert_eq(
    init_bootstrap_claude_settings_json(),
    "{\"statusLine\":{\"type\":\"command\",\"command\":\"choir statusline\"}}",
  )
}

///|
test "init bootstrap writes root birth branch file under project dir" {
  let project_dir = "/tmp/choir-birth-branch-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let path = project_dir + "/.choir/agents/root/.birth_branch"
  init_bootstrap_write_root_birth_branch_best_effort(project_dir, "my-branch\n")
  assert_eq(@sys.read_file(path), "my-branch\n")
}
