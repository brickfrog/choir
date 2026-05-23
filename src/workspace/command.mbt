///|
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Debug, Eq)

///|
pub impl Show for Command with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
/// Marker `Command.program` for `run_native_choir_file_command` / `exec.run`.
/// Args: `[worktree_path, basename_under_.choir, file_body]`.
pub let native_write_choir_file_program : String = "__choir_native_write_choir_file__"

///|
/// Marker for `run_native_workspace_rel_file_command`: args `[workspace_root, relative_path, file_body]`.
pub let native_write_workspace_rel_file_program : String = "__choir_native_write_workspace_rel_file__"

///|
/// Args: `[worktree_path]` — install `.choir/bin/choir-leaf-tool` and tool symlinks.
pub let native_leaf_helpers_program : String = "__choir_native_leaf_helpers__"

///|
/// Args: `[project_dir, workspace, branch]` — best-effort prune/remove worktree path, `rm -rf`,
/// and delete branch; always returns `0` from the runner.
pub let native_worktree_bootstrap_cleanup_program : String = "__choir_native_worktree_bootstrap_cleanup__"

///|
/// Args: `[project_dir, branch]` — best-effort `git fetch origin <branch>` with stderr warnings;
/// always returns `0` from the runner.
pub let native_git_fetch_origin_branch_best_effort_program : String = "__choir_native_git_fetch_origin_branch_best_effort__"

///|
/// Args: `[worktree_path, exclude_snippet]` — best-effort: resolve `info/exclude` via
/// `git rev-parse --git-path`, append `exclude_snippet` when its first line is not already present.
/// Native implementation always returns `0` (warnings on stderr when skipped), like other
/// `*_best_effort` helpers, so `run_strict` spawn sequences are not aborted by QoL failures.
pub let native_worktree_seed_agent_runtime_gitexclude_program : String = "__choir_native_worktree_seed_agent_runtime_gitexclude__"

///|
/// Args: `[project_dir]` — prepare a seed HOME whose agy runtime cache paths
/// point into `.choir/agy-shared-cache/` before the server runs agy once.
pub let native_agy_shared_cache_prepare_program : String = "__choir_native_agy_shared_cache_prepare__"

///|
/// Args: `[project_dir]` — validate that the server-side agy bootstrap populated
/// the expected shared runtime cache files.
pub let native_agy_shared_cache_validate_program : String = "__choir_native_agy_shared_cache_validate__"

///|
/// Args: `[project_dir]` — shared agy cache warmup. If the cache is cold,
/// prepare the seed HOME, run the agy cold-bootstrap command, and validate the
/// resulting shared runtime cache. Step failures warn and return their failing
/// status so callers can surface a precise cache prerequisite error.
pub let native_agy_shared_cache_seed_if_needed_program : String = "__choir_native_agy_shared_cache_seed_if_needed__"

///|
/// Args: `[project_dir, worktree_path]` — symlink the populated shared agy
/// runtime cache into the leaf HOME. Missing or incomplete shared cache warns
/// and continues because cache sharing is a startup optimization.
pub let native_agy_cache_links_program : String = "__choir_native_agy_cache_links__"

///|
pub fn Command::to_string(self : Command) -> String {
  let mut args_str = ""
  for arg in self.args {
    let quoted = @sys.shell_quote(arg)
    if args_str == "" {
      args_str = quoted
    } else {
      args_str = args_str + " " + quoted
    }
  }
  let base = if args_str == "" {
    self.program
  } else {
    self.program + " " + args_str
  }
  match self.workdir {
    None => base
    Some(dir) => "cd " + @sys.shell_quote(dir) + " && " + base
  }
}

///|
/// Ensure `.choir/` exists and write `basename` (e.g. `config.toml`) under it.
/// Returns `0` on success, `1` on failure, `-1` if `cmd` is not a native choir-file write.
pub fn run_native_choir_file_command(cmd : Command) -> Int {
  if cmd.program != native_write_choir_file_program {
    return -1
  }
  if cmd.args.length() != 3 {
    return 1
  }
  let worktree_path = cmd.args[0]
  let basename = cmd.args[1]
  let content = cmd.args[2]
  let choir_dir = worktree_path + "/.choir"
  if !@sys.create_dir_all(choir_dir) {
    return 1
  }
  let path = choir_dir + "/" + basename
  if !@sys.write_file_sync(path, content) {
    return 1
  }
  0
}

///|
fn validate_workspace_rel_path(rel : String) -> Bool {
  if rel == "" || rel.has_prefix("/") {
    return false
  }
  if rel.contains("..") {
    return false
  }
  true
}

///|
fn parent_dir_for_file(full_path : String) -> String {
  let last_slash = match full_path.rev_find("/") {
    Some(i) => i
    None => -1
  }
  if last_slash <= 0 {
    return "."
  }
  full_path[0:last_slash].to_owned()
}

///|
/// Ensure `workspace_root/relative_path` exists (parent dirs) and write `content`.
/// Returns `0` on success, `1` on failure, `-1` if `cmd` is not this native write.
pub fn run_native_workspace_rel_file_command(cmd : Command) -> Int {
  if cmd.program != native_write_workspace_rel_file_program {
    return -1
  }
  if cmd.args.length() != 3 {
    return 1
  }
  let root_raw = cmd.args[0]
  let rel = cmd.args[1]
  let content = cmd.args[2]
  if !validate_workspace_rel_path(rel) {
    return 1
  }
  let root = match @sys.realpath_native(root_raw) {
    Some(p) => p
    None => root_raw
  }
  let full = root + "/" + rel
  if !full.has_prefix(root + "/") && full != root {
    return 1
  }
  let parent = parent_dir_for_file(full)
  if !@sys.create_dir_all(parent) {
    return 1
  }
  let parent_real = match @sys.realpath_native(parent) {
    Some(p) => p
    None => return 1
  }
  if !parent_real.has_prefix(root + "/") && parent_real != root {
    return 1
  }
  if !@sys.write_file_sync(full, content) {
    return 1
  }
  0
}

///|
fn leaf_helper_script_body() -> String {
  (
    #|#!/bin/sh
    #|tool="${0##*/}"
    #|exec choir leaf-tool "$tool" "$@"
  )
}

///|
/// Body of the `gh` shim installed under `worktree_path/.choir/bin/gh`. Hard-
/// blocks `gh pr create` so leaves must go through the `file_pr` MCP tool —
/// raw `gh pr create` bypasses choir's auto-Copilot-reviewer wiring and PR
/// tracking, which has burned us before (cursor_agent in particular slips
/// past the prompt-level guidance and fires `gh pr create` directly). Every
/// other `gh` subcommand passes through to the next `gh` on `PATH` after the
/// shim's own directory.
pub fn gh_shim_script_body() -> String {
  (
    #|#!/bin/sh
    #|# choir gh shim: route PR write ops through choir MCP tools; pass everything else through.
    #|if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    #|  echo "choir: 'gh pr create' is blocked." >&2
    #|  echo "choir: use the 'file_pr' MCP tool instead -- it auto-requests @copilot review and tracks the PR." >&2
    #|  echo "choir: raw 'gh pr create' here would skip both, leaving the PR uncovered." >&2
    #|  exit 1
    #|fi
    #|if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
    #|  echo "choir: 'gh pr merge' is blocked (including --admin)." >&2
    #|  echo "choir: use the 'merge_pr' MCP tool instead -- it honors the audit gate and verify policy." >&2
    #|  echo "choir: if merge_pr blocks on something you believe is wrong, fix the gate (choir-file-pr-preflight, choir-t92), don't bypass it." >&2
    #|  exit 1
    #|fi
    #|if [ "$1" = "pr" ] && { [ "$2" = "close" ] || [ "$2" = "reopen" ] || [ "$2" = "ready" ] || [ "$2" = "edit" ]; }; then
    #|  echo "choir: 'gh pr $2' is blocked. PR lifecycle writes must go through choir MCP tools or the human." >&2
    #|  exit 1
    #|fi
    #|this_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || this_dir=
    #|IFS=:
    #|for d in $PATH; do
    #|  [ -z "$d" ] && continue
    #|  [ "$d" = "$this_dir" ] && continue
    #|  if [ -x "$d/gh" ]; then
    #|    unset IFS
    #|    exec "$d/gh" "$@"
    #|  fi
    #|done
    #|unset IFS
    #|echo "choir gh shim: real 'gh' not found on PATH (excluding $this_dir)" >&2
    #|exit 127
  )
}

///|
/// Body of the `gh-bounded` wrapper installed under
/// `worktree_path/.choir/bin/gh-bounded`. Wraps any `gh` invocation in a 30s
/// `timeout` so leaves can't hang indefinitely on stalled GitHub network
/// calls (the `gh` CLI has no built-in network timeout, see choir-vj3).
pub fn gh_bounded_script_body() -> String {
  (
    #|#!/bin/sh
    #|exec timeout 30s gh "$@"
  )
}

///|
pub fn bounded_gh_command(
  project_dir : String,
  gh_args : Array[String],
) -> Command {
  let args : Array[String] = ["30s", "gh"]
  for arg in gh_args {
    args.push(arg)
  }
  { program: "timeout", args, workdir: Some(project_dir) }
}

///|
/// Body of the `bash-bounded` wrapper installed under
/// `worktree_path/.choir/bin/bash-bounded`. Wraps shell pipelines in a 60s
/// timeout so leaf-local helpers can bound broad shell commands consistently.
pub fn bash_bounded_script_body() -> String {
  (
    #|#!/bin/sh
    #|exec timeout 60s bash "$@"
  )
}

///|
/// Body of the `choir_lint` wrapper installed under
/// `worktree_path/.choir/bin/choir_lint`. Delegates to Moon so the wrapper
/// follows Moon's current build/run layout while forwarding the leaf's
/// arguments to the linter.
pub fn choir_lint_wrapper_script_body() -> String {
  (
    #|#!/bin/sh
    #|script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 1
    #|project_dir=$(CDPATH= cd -- "$script_dir/../.." 2>/dev/null && pwd) || exit 1
    #|cd "$project_dir" || exit 1
    #|exec moon run src/bin/choir_lint --target native -- "$@"
  )
}

///|
/// Install leaf helper scripts under `worktree_path/.choir/bin` without shell heredocs.
/// Returns `0` on success, `1` on failure, `-1` if `cmd` is not this native command.
pub fn run_native_leaf_helpers_command(cmd : Command) -> Int {
  if cmd.program != native_leaf_helpers_program {
    return -1
  }
  if cmd.args.length() != 1 {
    return 1
  }
  let worktree_path = cmd.args[0]
  if worktree_path == "" {
    return 1
  }
  let bin_dir = worktree_path + "/.choir/bin"
  if !@sys.create_dir_all(bin_dir) {
    return 1
  }
  let script_path = bin_dir + "/choir-leaf-tool"
  if !@sys.write_file_sync(script_path, leaf_helper_script_body()) {
    return 1
  }
  if !@sys.chmod_mode(script_path, 0o755) {
    return 1
  }
  let names = [
    "file_pr", "notify_parent", "shutdown", "task_list", "task_get", "task_create",
    "task_update", "report_usage", "tdd_intent", "tdd_red_check", "tdd_green_check",
    "resolve_my_review_threads", "request_review",
  ]
  for name in names {
    let link_path = bin_dir + "/" + name
    if !@sys.symlink_force("choir-leaf-tool", link_path) {
      return 1
    }
  }
  let gh_shim_path = bin_dir + "/gh"
  if !@sys.write_file_sync(gh_shim_path, gh_shim_script_body()) {
    return 1
  }
  if !@sys.chmod_mode(gh_shim_path, 0o755) {
    return 1
  }
  let gh_bounded_path = bin_dir + "/gh-bounded"
  if !@sys.write_file_sync(gh_bounded_path, gh_bounded_script_body()) {
    return 1
  }
  if !@sys.chmod_mode(gh_bounded_path, 0o755) {
    return 1
  }
  let bash_bounded_path = bin_dir + "/bash-bounded"
  if !@sys.write_file_sync(bash_bounded_path, bash_bounded_script_body()) {
    return 1
  }
  if !@sys.chmod_mode(bash_bounded_path, 0o755) {
    return 1
  }
  let choir_lint_path = bin_dir + "/choir_lint"
  if !@sys.write_file_sync(choir_lint_path, choir_lint_wrapper_script_body()) {
    return 1
  }
  if !@sys.chmod_mode(choir_lint_path, 0o755) {
    return 1
  }
  0
}

///|
/// Best-effort worktree cleanup before a fresh `git worktree add`. Implemented in `stub.c` (direct
/// `git`/`rm` argv, no shell).
/// Returns `0` on success, `1` on bad args, `-1` if `cmd` is not this native command.
pub fn run_native_worktree_bootstrap_cleanup_command(cmd : Command) -> Int {
  if cmd.program != native_worktree_bootstrap_cleanup_program {
    return -1
  }
  if cmd.args.length() != 3 {
    return 1
  }
  @sys.worktree_bootstrap_cleanup_native(cmd.args[0], cmd.args[1], cmd.args[2])
  0
}

///|
/// Best-effort `git fetch origin <branch>` in `project_dir`. Returns `0` on success, `1` on bad args,
/// `-1` if `cmd` is not this native command.
pub fn run_native_git_fetch_origin_branch_best_effort_command(
  cmd : Command,
) -> Int {
  if cmd.program != native_git_fetch_origin_branch_best_effort_program {
    return -1
  }
  if cmd.args.length() != 2 {
    return 1
  }
  @sys.git_fetch_origin_branch_best_effort_native(cmd.args[0], cmd.args[1])
  0
}

///|
/// Best-effort append of agent-runtime ignore rules. Returns `1` only on bad args, `0` after
/// attempting (native layer always reports success to the runner), `-1` if not this command.
pub fn run_native_worktree_seed_agent_runtime_gitexclude_command(
  cmd : Command,
) -> Int {
  if cmd.program != native_worktree_seed_agent_runtime_gitexclude_program {
    return -1
  }
  if cmd.args.length() != 2 {
    return 1
  }
  ignore(
    @sys.worktree_seed_agent_runtime_gitexclude_native(cmd.args[0], cmd.args[1]),
  )
  0
}

///|
pub fn agy_home_relative_path() -> String {
  ".choir/agy-home"
}

///|
pub fn agy_home_path(worktree_path : String) -> String {
  worktree_path + "/" + agy_home_relative_path()
}

///|
fn absolute_agy_shared_cache_project_dir(project_dir : String) -> String {
  if project_dir == "" {
    return project_dir
  }
  match @sys.realpath_native(project_dir) {
    Some(path) => return path
    None => ()
  }
  if project_dir.has_prefix("/") {
    project_dir
  } else {
    let cwd = @env.current_dir().unwrap_or(".")
    cwd + "/" + project_dir
  }
}

///|
fn agy_shared_cache_root(project_dir : String) -> String {
  absolute_agy_shared_cache_project_dir(project_dir) +
  "/.choir/agy-shared-cache"
}

///|
fn agy_shared_cache_seed_home(project_dir : String) -> String {
  agy_shared_cache_root(project_dir) + "/home"
}

///|
pub(all) struct AgySharedCacheColdBootstrapExec {
  home : String
} derive(Debug, Eq)

///|
pub fn agy_shared_cache_cold_bootstrap_exec(
  cmd : Command,
) -> AgySharedCacheColdBootstrapExec? {
  if cmd.program != "env" || cmd.args.length() != 5 {
    return None
  }
  let home_prefix = "HOME="
  let home_arg = cmd.args[0]
  if !home_arg.has_prefix(home_prefix) {
    return None
  }
  if cmd.args[1] != "agy" ||
    cmd.args[2] != "--dangerously-skip-permissions" ||
    cmd.args[3] != "--print" ||
    cmd.args[4] != "Reply READY." {
    return None
  }
  match cmd.workdir {
    Some(_) => ()
    None => return None
  }
  Some({ home: home_arg[home_prefix.length():].to_owned() })
}

///|
fn agy_shared_cache_file_nonempty(
  path : String,
  path_entry_exists : (String) -> Bool,
  file_size : (String) -> Int,
) -> Bool {
  path_entry_exists(path) && file_size(path) > 0
}

///|
fn agy_shared_cache_playwright_populated(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  file_size : (String) -> Int,
) -> Bool {
  let playwright_root = shared_root + "/ms-playwright-go"
  if !path_entry_exists(playwright_root) {
    return false
  }
  for version in list_dir(playwright_root) {
    let version_root = playwright_root + "/" + version
    if path_entry_exists(version_root) &&
      agy_shared_cache_file_nonempty(
        version_root + "/node",
        path_entry_exists,
        file_size,
      ) &&
      agy_shared_cache_file_nonempty(
        version_root + "/package/package.json",
        path_entry_exists,
        file_size,
      ) {
      return true
    }
  }
  false
}

///|
fn agy_shared_cache_bin_populated(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  file_size : (String) -> Int,
) -> Bool {
  let bin_root = shared_root + "/antigravity-cli-bin"
  path_entry_exists(bin_root) &&
  agy_shared_cache_file_nonempty(
    bin_root + "/webm_encoder",
    path_entry_exists,
    file_size,
  )
}

///|
fn agy_shared_cache_is_populated(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  file_size : (String) -> Int,
) -> Bool {
  agy_shared_cache_playwright_populated(
    shared_root, path_entry_exists, list_dir, file_size,
  ) &&
  agy_shared_cache_bin_populated(shared_root, path_entry_exists, file_size)
}

///|
priv enum AgySharedCacheSeedStep {
  Prepare
  ColdBootstrap
  ReValidate
}

///|
fn AgySharedCacheSeedStep::label(self : AgySharedCacheSeedStep) -> String {
  match self {
    Prepare => "prepare"
    ColdBootstrap => "cold-bootstrap"
    ReValidate => "re-validate"
  }
}

///|
fn agy_shared_cache_seed_failure_warning(
  step : AgySharedCacheSeedStep,
  status : Int,
  detail : String,
) -> String {
  let trimmed = detail.trim().to_owned()
  let suffix = if trimmed == "" { "" } else { ": " + trimmed }
  "choir: warning: agy shared cache seed " +
  step.label() +
  " failed (exit " +
  status.to_string() +
  ")" +
  suffix +
  "\n"
}

///|
fn warn_agy_shared_cache_seed_failure(
  step : AgySharedCacheSeedStep,
  status : Int,
  detail : String,
  write_stderr : (String) -> Unit,
) -> Unit {
  write_stderr(agy_shared_cache_seed_failure_warning(step, status, detail))
}

///|
fn handled_native_failure_status(status : Int) -> Int {
  if status < 0 {
    1
  } else {
    status
  }
}

///|
fn run_native_agy_shared_cache_prepare_paths_with_io(
  project_dir : String,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  rm_rf? : (String) -> Bool = @sys.rm_rf,
  symlink_force? : (String, String) -> Bool = @sys.symlink_force,
) -> Int {
  if project_dir == "" {
    return 1
  }
  let shared_root = agy_shared_cache_root(project_dir)
  let seed_home = agy_shared_cache_seed_home(project_dir)
  let shared_playwright = shared_root + "/ms-playwright-go"
  let shared_bin = shared_root + "/antigravity-cli-bin"
  let seed_playwright = seed_home + "/.cache/ms-playwright-go"
  let seed_bin = seed_home + "/.gemini/antigravity-cli/bin"
  if !create_dir_all(shared_playwright) ||
    !create_dir_all(shared_bin) ||
    !create_dir_all(seed_home + "/.cache") ||
    !create_dir_all(seed_home + "/.gemini/antigravity-cli") {
    return 1
  }
  ignore(rm_rf(seed_playwright))
  ignore(rm_rf(seed_bin))
  if !symlink_force(shared_playwright, seed_playwright) {
    return 1
  }
  if !symlink_force(shared_bin, seed_bin) {
    return 1
  }
  0
}

///|
pub fn run_native_agy_shared_cache_prepare_command(cmd : Command) -> Int {
  if cmd.program != native_agy_shared_cache_prepare_program {
    return -1
  }
  if cmd.args.length() != 1 {
    return 1
  }
  run_native_agy_shared_cache_prepare_paths_with_io(cmd.args[0])
}

///|
fn run_native_agy_shared_cache_validate_paths_with_io(
  project_dir : String,
  path_entry_exists? : (String) -> Bool = @sys.path_entry_exists,
  list_dir? : (String) -> Array[String] = @sys.list_dir,
  file_size? : (String) -> Int = @sys.file_size,
) -> Int {
  if project_dir == "" {
    return 1
  }
  if agy_shared_cache_is_populated(
      agy_shared_cache_root(project_dir),
      path_entry_exists,
      list_dir,
      file_size,
    ) {
    0
  } else {
    1
  }
}

///|
pub fn run_native_agy_shared_cache_validate_command(cmd : Command) -> Int {
  if cmd.program != native_agy_shared_cache_validate_program {
    return -1
  }
  if cmd.args.length() != 1 {
    return 1
  }
  run_native_agy_shared_cache_validate_paths_with_io(cmd.args[0])
}

///|
pub fn run_native_agy_shared_cache_seed_if_needed_command_with_runner(
  cmd : Command,
  run_bootstrap : (Command) -> (Int, String),
  path_entry_exists? : (String) -> Bool = @sys.path_entry_exists,
  list_dir? : (String) -> Array[String] = @sys.list_dir,
  file_size? : (String) -> Int = @sys.file_size,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  rm_rf? : (String) -> Bool = @sys.rm_rf,
  symlink_force? : (String, String) -> Bool = @sys.symlink_force,
  write_stderr? : (String) -> Unit = @sys.write_stderr,
) -> Int {
  if cmd.program != native_agy_shared_cache_seed_if_needed_program {
    return -1
  }
  if cmd.args.length() != 1 {
    return 1
  }
  let project_dir = cmd.args[0]
  if project_dir == "" {
    return 1
  }
  if agy_shared_cache_is_populated(
      agy_shared_cache_root(project_dir),
      path_entry_exists,
      list_dir,
      file_size,
    ) {
    return 0
  }
  let prepare_status = run_native_agy_shared_cache_prepare_paths_with_io(
    project_dir,
    create_dir_all~,
    rm_rf~,
    symlink_force~,
  )
  if prepare_status != 0 {
    warn_agy_shared_cache_seed_failure(
      Prepare,
      prepare_status,
      "could not prepare seed HOME and shared cache links",
      write_stderr,
    )
    return prepare_status
  }
  let (bootstrap_status, bootstrap_stderr) = run_bootstrap(
    agy_shared_cache_cold_bootstrap(project_dir),
  )
  if bootstrap_status != 0 {
    let handled_status = handled_native_failure_status(bootstrap_status)
    warn_agy_shared_cache_seed_failure(
      ColdBootstrap,
      handled_status,
      bootstrap_stderr,
      write_stderr,
    )
    return handled_status
  }
  let validate_status = run_native_agy_shared_cache_validate_paths_with_io(
    project_dir,
    path_entry_exists~,
    list_dir~,
    file_size~,
  )
  if validate_status != 0 {
    warn_agy_shared_cache_seed_failure(
      ReValidate,
      validate_status,
      "shared cache did not validate after cold-bootstrap",
      write_stderr,
    )
    return validate_status
  }
  0
}

///|
fn agy_gemini_settings_json() -> String {
  let settings : Map[String, Json] = {
    "security": {
      "auth": { "selectedType": "oauth-personal".to_json() }.to_json(),
    }.to_json(),
    "ui": { "theme": "ANSI".to_json() }.to_json(),
    "approvalMode": "yolo".to_json(),
    "general": {
      "defaultApprovalMode": "yolo".to_json(),
      "previewFeatures": true.to_json(),
    }.to_json(),
  }
  settings.to_json().stringify(indent=2)
}

///|
fn symlink_shared_cache_dir_with_io(
  shared_dir : String,
  link_path : String,
  path_entry_exists : (String) -> Bool,
  create_dir_all : (String) -> Bool,
  rm_rf : (String) -> Bool,
  symlink_force : (String, String) -> Bool,
) -> Bool {
  if !path_entry_exists(shared_dir) {
    return false
  }
  let parent = parent_dir_for_file(link_path)
  if !create_dir_all(parent) {
    return false
  }
  if path_entry_exists(link_path) {
    if !rm_rf(link_path) {
      return false
    }
  }
  symlink_force(shared_dir, link_path)
}

///|
fn run_native_agy_cache_links_paths_with_io(
  project_dir : String,
  worktree_path : String,
  path_entry_exists? : (String) -> Bool = @sys.path_entry_exists,
  list_dir? : (String) -> Array[String] = @sys.list_dir,
  file_size? : (String) -> Int = @sys.file_size,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  rm_rf? : (String) -> Bool = @sys.rm_rf,
  symlink_force? : (String, String) -> Bool = @sys.symlink_force,
  write_file? : (String, String) -> Bool = @sys.write_file_sync,
  write_stderr? : (String) -> Unit = @sys.write_stderr,
) -> Int {
  if project_dir == "" || worktree_path == "" {
    return 1
  }
  let shared_root = agy_shared_cache_root(project_dir)
  if !agy_shared_cache_is_populated(
      shared_root, path_entry_exists, list_dir, file_size,
    ) {
    write_stderr(
      "choir: warning: agy shared cache links skipped because shared cache is not populated\n",
    )
    return 0
  }
  let home = agy_home_path(worktree_path)
  if !symlink_shared_cache_dir_with_io(
      shared_root + "/ms-playwright-go",
      home + "/.cache/ms-playwright-go",
      path_entry_exists,
      create_dir_all,
      rm_rf,
      symlink_force,
    ) {
    write_stderr("choir: warning: agy shared cache playwright link failed\n")
    return 0
  }
  if !symlink_shared_cache_dir_with_io(
      shared_root + "/antigravity-cli-bin",
      home + "/.gemini/antigravity-cli/bin",
      path_entry_exists,
      create_dir_all,
      rm_rf,
      symlink_force,
    ) {
    write_stderr("choir: warning: agy shared cache binary link failed\n")
    return 0
  }
  if !create_dir_all(home + "/.gemini") {
    write_stderr("choir: warning: agy settings seed failed\n")
    return 0
  }
  let settings_path = home + "/.gemini/settings.json"
  if file_size(settings_path) <= 0 {
    if !write_file(settings_path, agy_gemini_settings_json()) {
      write_stderr("choir: warning: agy settings seed failed\n")
      return 0
    }
  }
  0
}

///|
pub fn run_native_agy_cache_links_command(
  cmd : Command,
  write_stderr? : (String) -> Unit = @sys.write_stderr,
) -> Int {
  if cmd.program != native_agy_cache_links_program {
    return -1
  }
  if cmd.args.length() != 2 {
    return 1
  }
  run_native_agy_cache_links_paths_with_io(
    cmd.args[0],
    cmd.args[1],
    write_stderr~,
  )
}

///|
pub fn agy_cache_links(project_dir : String, worktree_path : String) -> Command {
  {
    program: native_agy_cache_links_program,
    args: [project_dir, worktree_path],
    workdir: None,
  }
}

///|
pub fn agy_shared_cache_prepare(project_dir : String) -> Command {
  {
    program: native_agy_shared_cache_prepare_program,
    args: [project_dir],
    workdir: None,
  }
}

///|
pub fn agy_shared_cache_cold_bootstrap(project_dir : String) -> Command {
  let resolved_project_dir = absolute_agy_shared_cache_project_dir(project_dir)
  {
    program: "env",
    args: [
      "HOME=" + agy_shared_cache_seed_home(resolved_project_dir),
      "agy",
      "--dangerously-skip-permissions",
      "--print",
      "Reply READY.",
    ],
    workdir: Some(resolved_project_dir),
  }
}

///|
pub fn agy_shared_cache_validate(project_dir : String) -> Command {
  {
    program: native_agy_shared_cache_validate_program,
    args: [project_dir],
    workdir: None,
  }
}

///|
pub fn agy_shared_cache_seed_if_needed(project_dir : String) -> Command {
  {
    program: native_agy_shared_cache_seed_if_needed_program,
    args: [project_dir],
    workdir: None,
  }
}

///|
/// After `git worktree add`, keep `git status` clean when agent CLIs write under `.cursor/`, etc.
pub fn command_seed_worktree_agent_runtime_gitexclude(
  worktree_path : String,
) -> Command {
  {
    program: native_worktree_seed_agent_runtime_gitexclude_program,
    args: [worktree_path, agent_runtime_gitexclude_snippet()],
    workdir: None,
  }
}

///|
/// Write `workspace_root/relative_path` with native file I/O (via `exec.run` sentinel).
pub fn workspace_relative_file_command(
  workspace_root : String,
  relative_path : String,
  content : String,
) -> Command {
  {
    program: native_write_workspace_rel_file_program,
    args: [workspace_root, relative_path, content],
    workdir: None,
  }
}

///|
/// Write .choir/config.local.toml into worktree with role override.
/// Executed as a native file write by `exec.run`, not an inline shell snippet.
pub fn write_local_config(worktree_path : String, content : String) -> Command {
  {
    program: native_write_choir_file_program,
    args: [worktree_path, "config.local.toml", content],
    workdir: None,
  }
}

///|
/// Write .choir/config.toml into worktree with client connection settings.
pub fn write_spawn_config(worktree_path : String, content : String) -> Command {
  {
    program: native_write_choir_file_program,
    args: [worktree_path, "config.toml", content],
    workdir: None,
  }
}

///|
fn resolve_named_context_path(project_dir : String, name : String) -> String? {
  let local_path = project_dir + "/.choir/context/" + name + ".md"
  if @sys.read_file(local_path) != "" {
    return Some(
      if local_path.has_prefix("/") {
        local_path
      } else {
        @env.current_dir().unwrap_or(".") + "/" + local_path
      },
    )
  }
  let global_base = @sys.getenv("HOME").unwrap_or("") + "/.choir/context"
  let global_path = global_base + "/" + name + ".md"
  if global_base != "/.choir/context" && @sys.read_file(global_path) != "" {
    return Some(global_path)
  }
  None
}

///|
/// Resolve hidden Choir-owned context files with two-tier fallback.
/// For each name, checks project-local `.choir/context/{name}.md` first,
/// then global `~/.choir/context/{name}.md`.
pub fn resolve_context_paths(
  project_dir : String,
  role : String,
) -> Array[String] {
  let paths : Array[String] = []
  for name in ["problems", "common", role] {
    match resolve_named_context_path(project_dir, name) {
      Some(path) => if !paths.contains(path) { paths.push(path) }
      None => ()
    }
  }
  paths
}

///|
/// Install shell helpers for CLIs that do not load MCP tools directly.
pub fn write_leaf_helper_scripts(worktree_path : String) -> Command {
  { program: native_leaf_helpers_program, args: [worktree_path], workdir: None }
}

///|
pub fn trust_gemini_folder(worktree_path : String) -> Command {
  {
    program: "env",
    args: [
      "HOME=" + agy_home_path(worktree_path),
      "choir",
      "trust-gemini-folder",
      worktree_path,
    ],
    workdir: None,
  }
}

///|
fn agy_mcp_config_relative_path() -> String {
  agy_home_relative_path() + "/.gemini/config/mcp_config.json"
}

///|
fn agy_hooks_relative_path() -> String {
  agy_home_relative_path() + "/.gemini/config/hooks.json"
}

///|
/// Generate agy's MCP config with the leaf-local Choir stdio server.
pub fn agy_mcp_config_json(
  worktree_path : String,
  agent_name : String,
  role : String,
) -> String {
  let mcp = {
    "choir": {
      "type": "stdio".to_json(),
      "command": "choir".to_json(),
      "args": [
        "mcp-stdio", "--role", role, "--name", agent_name, "--wait-socket-tries",
        "300", "--stderr-append-log", ".choir/mcp-stdio.stderr.log",
      ].to_json(),
      "cwd": worktree_path.to_json(),
      "alwaysLoad": true.to_json(),
    }.to_json(),
  }
  let settings : Map[String, Json] = { "mcpServers": mcp.to_json() }
  settings.to_json().stringify(indent=2)
}

///|
fn agy_command_hook(command : String) -> Json {
  {
    "type": "command".to_json(),
    "command": command.to_json(),
    "timeout": Int::to_json(60),
  }.to_json()
}

///|
/// Generate agy's hooks.json. For model-cycle hooks, agy's direct command
/// handlers are top-level `PreInvocation`/`PostInvocation` event keys; wrapping
/// them in the older Gemini `{ matcher, hooks: [...] }` shape loads but does not
/// execute.
pub fn agy_hooks_json(wasm_hooks_path? : String? = None) -> String {
  let hook_spec : Map[String, Json] = {
    "Stop": [agy_command_hook("choir hook worker-exit --runtime gemini")].to_json(),
  }
  match wasm_hooks_path {
    Some(path) => {
      let model_hook = fn(func_name : String) -> Json {
        agy_command_hook(
          "extism call " + @sys.shell_quote(path) + " " + func_name + " --wasi",
        )
      }
      hook_spec.set("PreInvocation", [model_hook("before_model")].to_json())
      hook_spec.set("PostInvocation", [model_hook("after_model")].to_json())
      hook_spec.set("PreToolUse", [model_hook("pre_tool_use")].to_json())
    }
    None => ()
  }
  hook_spec.to_json().stringify(indent=2)
}

///|
pub fn write_agy_mcp_config(
  worktree_path : String,
  agent_name : String,
  role : String,
) -> Command {
  let content = agy_mcp_config_json(worktree_path, agent_name, role)
  workspace_relative_file_command(
    worktree_path,
    agy_mcp_config_relative_path(),
    content,
  )
}

///|
pub fn write_agy_hooks(
  worktree_path : String,
  wasm_hooks_path? : String? = None,
) -> Command {
  let content = agy_hooks_json(wasm_hooks_path~)
  workspace_relative_file_command(
    worktree_path,
    agy_hooks_relative_path(),
    content,
  )
}

///|
/// Generate .cursor/mcp.json content for Cursor Agent worktrees.
pub fn cursor_mcp_json(agent_name : String, role : String) -> String {
  let mcp = {
    "choir": {
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role, "--name", agent_name].to_json(),
      "type": "stdio".to_json(),
    }.to_json(),
  }
  let settings : Map[String, Json] = { "mcpServers": mcp.to_json() }
  settings.to_json().stringify(indent=2)
}

///|
/// Write .cursor/mcp.json in the workspace for Cursor Agent.
pub fn write_cursor_mcp_json(
  worktree_path : String,
  agent_name : String,
  role : String,
) -> Command {
  let content = cursor_mcp_json(agent_name, role)
  workspace_relative_file_command(worktree_path, ".cursor/mcp.json", content)
}

///|
/// Post a comment on a GitHub PR via `gh pr comment`.
pub fn gh_pr_comment(
  pr_number : Int,
  body : String,
  project_dir : String,
) -> Command {
  {
    program: "gh",
    args: ["pr", "comment", pr_number.to_string(), "--body", body],
    workdir: Some(project_dir),
  }
}

///|
/// Request a PR reviewer via `gh pr edit --add-reviewer` (GitHub Reviewers API).
pub fn gh_pr_add_reviewer(
  pr_number : Int,
  reviewer : String,
  project_dir : String,
) -> Command {
  bounded_gh_command(project_dir, [
    "pr",
    "edit",
    pr_number.to_string(),
    "--add-reviewer",
    reviewer,
  ])
}
