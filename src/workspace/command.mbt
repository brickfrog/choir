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
/// Args: `[project_dir, worktree_path]` — ensure agy's heavy runtime cache dirs
/// are shared under `.choir/agy-shared-cache/` and symlinked into the leaf HOME.
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
    "task_update", "report_usage",
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
fn agy_shared_cache_root(project_dir : String) -> String {
  project_dir + "/.choir/agy-shared-cache"
}

///|
fn agy_shared_cache_complete_path(shared_root : String) -> String {
  shared_root + "/.complete"
}

///|
fn agy_shared_cache_lock_dir(shared_root : String) -> String {
  shared_root + ".lock"
}

///|
let agy_shared_cache_lock_stale_ms : Int64 = 300000L

///|
fn agy_cache_temp_suffix(worktree_path : String) -> String {
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string() +
  "-" +
  @types.sanitize_agent_id(worktree_path)
}

///|
fn seed_agy_shared_cache_temp(
  temp_root : String,
  _create_dir_all : (String) -> Bool,
  _write_file_sync : (String, String) -> Bool,
) -> Bool {
  // The native helper cannot prove agy's runtime was downloaded; callers that
  // populate the temp root must inject a real populator through `seed_temp`.
  ignore(temp_root)
  false
}

///|
fn agy_shared_cache_file_nonempty(
  path : String,
  path_entry_exists : (String) -> Bool,
  read_file : (String) -> String,
) -> Bool {
  path_entry_exists(path) && read_file(path) != ""
}

///|
fn agy_shared_cache_playwright_populated(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  read_file : (String) -> String,
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
        read_file,
      ) &&
      agy_shared_cache_file_nonempty(
        version_root + "/package/package.json",
        path_entry_exists,
        read_file,
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
  read_file : (String) -> String,
) -> Bool {
  let bin_root = shared_root + "/antigravity-cli-bin"
  path_entry_exists(bin_root) &&
  agy_shared_cache_file_nonempty(
    bin_root + "/agentapi",
    path_entry_exists,
    read_file,
  ) &&
  agy_shared_cache_file_nonempty(
    bin_root + "/webm_encoder",
    path_entry_exists,
    read_file,
  )
}

///|
fn agy_shared_cache_is_populated(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  read_file : (String) -> String,
) -> Bool {
  agy_shared_cache_playwright_populated(
    shared_root, path_entry_exists, list_dir, read_file,
  ) &&
  agy_shared_cache_bin_populated(shared_root, path_entry_exists, read_file)
}

///|
fn agy_shared_cache_is_complete(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  read_file : (String) -> String,
) -> Bool {
  path_entry_exists(agy_shared_cache_complete_path(shared_root)) &&
  agy_shared_cache_is_populated(
    shared_root, path_entry_exists, list_dir, read_file,
  )
}

///|
fn mark_existing_agy_shared_cache_seeded(
  shared_root : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  read_file : (String) -> String,
  write_file_sync : (String, String) -> Bool,
) -> Bool {
  if !agy_shared_cache_is_populated(
      shared_root, path_entry_exists, list_dir, read_file,
    ) {
    return false
  }
  let complete = agy_shared_cache_complete_path(shared_root)
  write_file_sync(complete, "complete\n") && path_entry_exists(complete)
}

///|
priv enum AgySharedCacheWaitResult {
  AgySharedCacheComplete
  AgySharedCacheStale(String)
}

///|
fn agy_shared_cache_lock_content_is_stale(
  content : String,
  pid_is_alive : (Int) -> Bool,
  now_ms : Int64,
) -> Bool {
  if content == "" {
    return true
  }
  let pid_dead = match agy_lock_holder_pid(content) {
    Some(pid) => !pid_is_alive(pid)
    None => false
  }
  let too_old = match agy_lock_holder_started_ms(content) {
    Some(started_ms) => now_ms - started_ms >= agy_shared_cache_lock_stale_ms
    None => false
  }
  pid_dead || too_old
}

///|
fn wait_for_agy_shared_cache_complete_or_stale(
  shared_root : String,
  lock_dir : String,
  path_entry_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
  read_file : (String) -> String,
  pid_is_alive : (Int) -> Bool,
  now_ms_fn : () -> Int64,
  sleep_milliseconds : (Int) -> Unit,
) -> AgySharedCacheWaitResult {
  for ;; {
    if agy_shared_cache_is_complete(
        shared_root, path_entry_exists, list_dir, read_file,
      ) {
      return AgySharedCacheComplete
    }
    let holder = read_file(lock_dir + "/holder")
    if agy_shared_cache_lock_content_is_stale(holder, pid_is_alive, now_ms_fn()) {
      return AgySharedCacheStale(holder)
    }
    sleep_milliseconds(25)
  }
}

///|
fn agy_shared_cache_lock_holder_content(
  worktree_path : String,
  pid : Int,
  now_ms : Int64,
) -> String {
  "pid=" +
  pid.to_string() +
  "\nstarted_ms=" +
  now_ms.to_string() +
  "\nholder=" +
  worktree_path +
  "\n"
}

///|
fn agy_parse_unsigned_i64(raw : String) -> Int64? {
  let s = raw.trim().to_owned()
  if s == "" {
    return None
  }
  let mut value = 0L
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
  }
  Some(value)
}

///|
fn agy_lock_holder_field(content : String, key : String) -> String? {
  let prefix = key + "="
  for raw in content.split("\n") {
    let line = raw.trim().to_owned()
    if line.has_prefix(prefix) {
      return Some(line[prefix.length():].trim().to_owned())
    }
  }
  None
}

///|
fn agy_lock_holder_started_ms(content : String) -> Int64? {
  match agy_lock_holder_field(content, "started_ms") {
    Some(raw) => agy_parse_unsigned_i64(raw)
    None => None
  }
}

///|
fn agy_lock_holder_pid(content : String) -> Int? {
  match agy_lock_holder_field(content, "pid") {
    Some(raw) =>
      match agy_parse_unsigned_i64(raw) {
        Some(pid) => Some(pid.to_int())
        None => None
      }
    None => None
  }
}

///|
fn ensure_agy_shared_cache_seeded(
  shared_root : String,
  worktree_path : String,
  path_entry_exists? : (String) -> Bool = @sys.path_entry_exists,
  list_dir? : (String) -> Array[String] = @sys.list_dir,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  write_file_sync? : (String, String) -> Bool = @sys.write_file_sync,
  rename_file_sync? : (String, String) -> Bool = @sys.rename_file_sync,
  rm_rf? : (String) -> Bool = @sys.rm_rf,
  sleep_milliseconds? : (Int) -> Unit = @sys.sleep_milliseconds,
  read_file? : (String) -> String = @sys.read_file,
  pid_is_alive? : (Int) -> Bool = @sys.pid_is_alive,
  now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
  seed_temp? : (String, (String) -> Bool, (String, String) -> Bool) -> Bool = seed_agy_shared_cache_temp,
  retry_stale_lock? : Bool = true,
) -> Bool {
  if agy_shared_cache_is_complete(
      shared_root, path_entry_exists, list_dir, read_file,
    ) {
    return true
  }
  if path_entry_exists(shared_root) &&
    mark_existing_agy_shared_cache_seeded(
      shared_root, path_entry_exists, list_dir, read_file, write_file_sync,
    ) {
    return true
  }
  let suffix = agy_cache_temp_suffix(worktree_path)
  let lock_dir = agy_shared_cache_lock_dir(shared_root)
  let tmp_lock = lock_dir + ".tmp." + suffix
  ignore(rm_rf(tmp_lock))
  if !create_dir_all(tmp_lock) {
    return false
  }
  if !write_file_sync(
      tmp_lock + "/holder",
      agy_shared_cache_lock_holder_content(
        worktree_path,
        @sys.get_pid(),
        now_ms_fn(),
      ),
    ) {
    ignore(rm_rf(tmp_lock))
    return false
  }
  if !rename_file_sync(tmp_lock, lock_dir) {
    ignore(rm_rf(tmp_lock))
    match
      wait_for_agy_shared_cache_complete_or_stale(
        shared_root, lock_dir, path_entry_exists, list_dir, read_file, pid_is_alive,
        now_ms_fn, sleep_milliseconds,
      ) {
      AgySharedCacheComplete => return true
      AgySharedCacheStale(holder_content) => {
        if retry_stale_lock && read_file(lock_dir + "/holder") == holder_content {
          ignore(rm_rf(lock_dir))
          return ensure_agy_shared_cache_seeded(
            shared_root,
            worktree_path,
            path_entry_exists~,
            list_dir~,
            create_dir_all~,
            write_file_sync~,
            rename_file_sync~,
            rm_rf~,
            sleep_milliseconds~,
            read_file~,
            pid_is_alive~,
            now_ms_fn~,
            seed_temp~,
            retry_stale_lock=false,
          )
        } else if retry_stale_lock {
          match
            wait_for_agy_shared_cache_complete_or_stale(
              shared_root, lock_dir, path_entry_exists, list_dir, read_file, pid_is_alive,
              now_ms_fn, sleep_milliseconds,
            ) {
            AgySharedCacheComplete => return true
            AgySharedCacheStale(_) => return false
          }
        }
        return false
      }
    }
  }

  if agy_shared_cache_is_complete(
      shared_root, path_entry_exists, list_dir, read_file,
    ) {
    ignore(rm_rf(lock_dir))
    return true
  }
  if path_entry_exists(shared_root) {
    let ok = mark_existing_agy_shared_cache_seeded(
      shared_root, path_entry_exists, list_dir, read_file, write_file_sync,
    )
    if ok {
      ignore(rm_rf(lock_dir))
      return true
    }
  }
  let tmp_root = shared_root + ".tmp." + suffix
  ignore(rm_rf(tmp_root))
  if !seed_temp(tmp_root, create_dir_all, write_file_sync) {
    ignore(rm_rf(tmp_root))
    ignore(rm_rf(lock_dir))
    return false
  }
  if !agy_shared_cache_is_populated(
      tmp_root, path_entry_exists, list_dir, read_file,
    ) {
    ignore(rm_rf(tmp_root))
    ignore(rm_rf(lock_dir))
    return false
  }
  if !write_file_sync(agy_shared_cache_complete_path(tmp_root), "complete\n") ||
    !path_entry_exists(agy_shared_cache_complete_path(tmp_root)) {
    ignore(rm_rf(tmp_root))
    ignore(rm_rf(lock_dir))
    return false
  }
  if path_entry_exists(shared_root) && !rm_rf(shared_root) {
    ignore(rm_rf(tmp_root))
    ignore(rm_rf(lock_dir))
    return false
  }
  if !rename_file_sync(tmp_root, shared_root) {
    ignore(rm_rf(tmp_root))
    if path_entry_exists(shared_root) {
      let ok = if agy_shared_cache_is_complete(
          shared_root, path_entry_exists, list_dir, read_file,
        ) {
        true
      } else {
        mark_existing_agy_shared_cache_seeded(
          shared_root, path_entry_exists, list_dir, read_file, write_file_sync,
        )
      }
      ignore(rm_rf(lock_dir))
      return ok
    }
    ignore(rm_rf(lock_dir))
    return false
  }
  ignore(rm_rf(lock_dir))
  agy_shared_cache_is_complete(
    shared_root, path_entry_exists, list_dir, read_file,
  )
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
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  write_file_sync? : (String, String) -> Bool = @sys.write_file_sync,
  rename_file_sync? : (String, String) -> Bool = @sys.rename_file_sync,
  rm_rf? : (String) -> Bool = @sys.rm_rf,
  symlink_force? : (String, String) -> Bool = @sys.symlink_force,
  sleep_milliseconds? : (Int) -> Unit = @sys.sleep_milliseconds,
  read_file? : (String) -> String = @sys.read_file,
  pid_is_alive? : (Int) -> Bool = @sys.pid_is_alive,
  now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
  seed_temp? : (String, (String) -> Bool, (String, String) -> Bool) -> Bool = seed_agy_shared_cache_temp,
) -> Int {
  if project_dir == "" || worktree_path == "" {
    return 1
  }
  let shared_root = agy_shared_cache_root(project_dir)
  if !ensure_agy_shared_cache_seeded(
      shared_root,
      worktree_path,
      path_entry_exists~,
      list_dir~,
      create_dir_all~,
      write_file_sync~,
      rename_file_sync~,
      rm_rf~,
      sleep_milliseconds~,
      read_file~,
      pid_is_alive~,
      now_ms_fn~,
      seed_temp~,
    ) {
    return 1
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
    return 1
  }
  if !symlink_shared_cache_dir_with_io(
      shared_root + "/antigravity-cli-bin",
      home + "/.gemini/antigravity-cli/bin",
      path_entry_exists,
      create_dir_all,
      rm_rf,
      symlink_force,
    ) {
    return 1
  }
  0
}

///|
pub fn run_native_agy_cache_links_command(cmd : Command) -> Int {
  if cmd.program != native_agy_cache_links_program {
    return -1
  }
  if cmd.args.length() != 2 {
    return 1
  }
  run_native_agy_cache_links_paths_with_io(cmd.args[0], cmd.args[1])
}

///|
test "native agy cache links waits for concurrent cold seed" {
  let project = "/tmp/choir-fake-project"
  let leaf_a = project + "/.choir/worktrees/leaf-a"
  let leaf_b = project + "/.choir/worktrees/leaf-b"
  let shared_root = agy_shared_cache_root(project)
  let complete = agy_shared_cache_complete_path(shared_root)
  let lock_dir = agy_shared_cache_lock_dir(shared_root)
  let paths : Map[String, Bool] = {}
  let files : Map[String, String] = {}
  let symlinks : Map[String, String] = {}
  let path_entry_exists = fn(path : String) -> Bool {
    paths.get(path).unwrap_or(false)
  }
  let list_dir = fn(path : String) -> Array[String] {
    if path.has_suffix("/ms-playwright-go") {
      ["1.57.0"]
    } else {
      []
    }
  }
  let create_dir_all = fn(path : String) -> Bool {
    paths.set(path, true)
    true
  }
  let write_file_sync = fn(path : String, content : String) -> Bool {
    paths.set(path, true)
    files.set(path, content)
    true
  }
  let rename_file_sync = fn(_from : String, to : String) -> Bool {
    if to == lock_dir {
      if path_entry_exists(lock_dir + "/holder") {
        return false
      }
      paths.set(lock_dir, true)
      paths.set(lock_dir + "/holder", true)
      files.set(
        lock_dir + "/holder",
        files.get(_from + "/holder").unwrap_or(""),
      )
      return true
    }
    if to == shared_root {
      if path_entry_exists(complete) {
        return false
      }
      paths.set(shared_root, true)
      paths.set(shared_root + "/ms-playwright-go", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/package", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/node", true)
      paths.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        true,
      )
      paths.set(shared_root + "/antigravity-cli-bin", true)
      paths.set(shared_root + "/antigravity-cli-bin/agentapi", true)
      paths.set(shared_root + "/antigravity-cli-bin/webm_encoder", true)
      paths.set(complete, true)
      files.set(shared_root + "/ms-playwright-go/1.57.0/node", "node")
      files.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        "{}",
      )
      files.set(shared_root + "/antigravity-cli-bin/agentapi", "agent")
      files.set(shared_root + "/antigravity-cli-bin/webm_encoder", "webm")
      files.set(complete, "complete\n")
      return true
    }
    true
  }
  let rm_rf = fn(path : String) -> Bool {
    paths.set(path, false)
    paths.set(path + "/holder", false)
    if path == shared_root {
      paths.set(complete, false)
      paths.set(shared_root + "/ms-playwright-go", false)
      paths.set(shared_root + "/ms-playwright-go/1.57.0", false)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/package", false)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/node", false)
      paths.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        false,
      )
      paths.set(shared_root + "/antigravity-cli-bin", false)
      paths.set(shared_root + "/antigravity-cli-bin/agentapi", false)
      paths.set(shared_root + "/antigravity-cli-bin/webm_encoder", false)
    }
    true
  }
  let symlink_force = fn(target : String, link_path : String) -> Bool {
    if !path_entry_exists(complete) || !path_entry_exists(target) {
      return false
    }
    symlinks.set(link_path, target)
    true
  }
  let sleep_milliseconds = fn(_ms : Int) -> Unit {
    paths.set(shared_root, true)
    paths.set(shared_root + "/ms-playwright-go", true)
    paths.set(shared_root + "/ms-playwright-go/1.57.0", true)
    paths.set(shared_root + "/ms-playwright-go/1.57.0/package", true)
    paths.set(shared_root + "/ms-playwright-go/1.57.0/node", true)
    paths.set(
      shared_root + "/ms-playwright-go/1.57.0/package/package.json",
      true,
    )
    paths.set(shared_root + "/antigravity-cli-bin", true)
    paths.set(shared_root + "/antigravity-cli-bin/agentapi", true)
    paths.set(shared_root + "/antigravity-cli-bin/webm_encoder", true)
    paths.set(complete, true)
    files.set(shared_root + "/ms-playwright-go/1.57.0/node", "node")
    files.set(
      shared_root + "/ms-playwright-go/1.57.0/package/package.json",
      "{}",
    )
    files.set(shared_root + "/antigravity-cli-bin/agentapi", "agent")
    files.set(shared_root + "/antigravity-cli-bin/webm_encoder", "webm")
    files.set(complete, "complete\n")
  }
  let mut seed_count = 0
  let mut nested_rc = -1
  let seed_temp = fn(
    temp_root : String,
    create_dir_all : (String) -> Bool,
    write_file_sync : (String, String) -> Bool,
  ) -> Bool {
    seed_count = seed_count + 1
    nested_rc = run_native_agy_cache_links_paths_with_io(
      project,
      leaf_b,
      path_entry_exists~,
      list_dir~,
      create_dir_all~,
      write_file_sync~,
      rename_file_sync~,
      rm_rf~,
      symlink_force~,
      sleep_milliseconds~,
      seed_temp=fn(_, _, _) {
        seed_count = seed_count + 100
        false
      },
      read_file=fn(path) { files.get(path).unwrap_or("") },
    )
    ignore(create_dir_all(temp_root + "/ms-playwright-go"))
    ignore(create_dir_all(temp_root + "/ms-playwright-go/1.57.0"))
    ignore(create_dir_all(temp_root + "/ms-playwright-go/1.57.0/package"))
    ignore(create_dir_all(temp_root + "/antigravity-cli-bin"))
    ignore(write_file_sync(temp_root + "/ms-playwright-go/1.57.0/node", "node"))
    ignore(
      write_file_sync(
        temp_root + "/ms-playwright-go/1.57.0/package/package.json",
        "{}",
      ),
    )
    ignore(
      write_file_sync(temp_root + "/antigravity-cli-bin/agentapi", "agent"),
    )
    ignore(
      write_file_sync(temp_root + "/antigravity-cli-bin/webm_encoder", "webm"),
    )
    true
  }

  let rc = run_native_agy_cache_links_paths_with_io(
    project,
    leaf_a,
    path_entry_exists~,
    list_dir~,
    create_dir_all~,
    write_file_sync~,
    rename_file_sync~,
    rm_rf~,
    symlink_force~,
    sleep_milliseconds~,
    read_file=fn(path) { files.get(path).unwrap_or("") },
    seed_temp~,
  )
  assert_eq(rc, 0)
  assert_eq(nested_rc, 0)
  assert_eq(seed_count, 1)
  assert_true(path_entry_exists(complete))
  @debug.assert_eq(
    symlinks.get(leaf_a + "/.choir/agy-home/.cache/ms-playwright-go"),
    Some(shared_root + "/ms-playwright-go"),
  )
  @debug.assert_eq(
    symlinks.get(leaf_a + "/.choir/agy-home/.gemini/antigravity-cli/bin"),
    Some(shared_root + "/antigravity-cli-bin"),
  )
  @debug.assert_eq(
    symlinks.get(leaf_b + "/.choir/agy-home/.cache/ms-playwright-go"),
    Some(shared_root + "/ms-playwright-go"),
  )
  @debug.assert_eq(
    symlinks.get(leaf_b + "/.choir/agy-home/.gemini/antigravity-cli/bin"),
    Some(shared_root + "/antigravity-cli-bin"),
  )
}

///|
test "agy shared cache temp seed does not bless empty directories" {
  let temp_root = "/tmp/choir-agy-empty-seed"
  let writes : Array[String] = []
  let create_dir_all = fn(_path : String) -> Bool { true }
  let write_file_sync = fn(path : String, _content : String) -> Bool {
    writes.push(path)
    true
  }

  ignore(seed_agy_shared_cache_temp(temp_root, create_dir_all, write_file_sync))

  assert_false(writes.contains(agy_shared_cache_complete_path(temp_root)))
}

///|
test "agy shared cache completes only after populated seed validates" {
  let shared_root = "/tmp/choir-agy-shared-cache"
  let lock_dir = agy_shared_cache_lock_dir(shared_root)
  let complete = agy_shared_cache_complete_path(shared_root)
  let paths : Map[String, Bool] = {}
  let files : Map[String, String] = {}
  let path_entry_exists = fn(path : String) -> Bool {
    paths.get(path).unwrap_or(false)
  }
  let list_dir = fn(path : String) -> Array[String] {
    if path.has_suffix("/ms-playwright-go") {
      ["1.57.0"]
    } else {
      []
    }
  }
  let create_dir_all = fn(path : String) -> Bool {
    paths.set(path, true)
    true
  }
  let write_file_sync = fn(path : String, content : String) -> Bool {
    paths.set(path, true)
    files.set(path, content)
    true
  }
  let rename_file_sync = fn(from : String, to : String) -> Bool {
    if to == lock_dir {
      paths.set(lock_dir, true)
      paths.set(lock_dir + "/holder", true)
      files.set(lock_dir + "/holder", files.get(from + "/holder").unwrap_or(""))
      true
    } else if to == shared_root {
      paths.set(shared_root, true)
      paths.set(shared_root + "/ms-playwright-go", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/package", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/node", true)
      paths.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        true,
      )
      paths.set(shared_root + "/antigravity-cli-bin", true)
      paths.set(shared_root + "/antigravity-cli-bin/agentapi", true)
      paths.set(shared_root + "/antigravity-cli-bin/webm_encoder", true)
      paths.set(complete, true)
      files.set(
        shared_root + "/ms-playwright-go/1.57.0/node",
        files.get(from + "/ms-playwright-go/1.57.0/node").unwrap_or(""),
      )
      files.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        files
        .get(from + "/ms-playwright-go/1.57.0/package/package.json")
        .unwrap_or(""),
      )
      files.set(
        shared_root + "/antigravity-cli-bin/agentapi",
        files.get(from + "/antigravity-cli-bin/agentapi").unwrap_or(""),
      )
      files.set(
        shared_root + "/antigravity-cli-bin/webm_encoder",
        files.get(from + "/antigravity-cli-bin/webm_encoder").unwrap_or(""),
      )
      files.set(
        complete,
        files.get(agy_shared_cache_complete_path(from)).unwrap_or(""),
      )
      true
    } else {
      true
    }
  }
  let rm_rf = fn(path : String) -> Bool {
    paths.set(path, false)
    paths.set(path + "/holder", false)
    true
  }
  let seed_temp = fn(
    root : String,
    create_dir_all : (String) -> Bool,
    write_file_sync : (String, String) -> Bool,
  ) -> Bool {
    ignore(create_dir_all(root + "/ms-playwright-go"))
    ignore(create_dir_all(root + "/ms-playwright-go/1.57.0"))
    ignore(create_dir_all(root + "/ms-playwright-go/1.57.0/package"))
    ignore(create_dir_all(root + "/antigravity-cli-bin"))
    ignore(write_file_sync(root + "/ms-playwright-go/1.57.0/node", "node"))
    ignore(
      write_file_sync(
        root + "/ms-playwright-go/1.57.0/package/package.json",
        "{}",
      ),
    )
    ignore(write_file_sync(root + "/antigravity-cli-bin/agentapi", "agent"))
    ignore(write_file_sync(root + "/antigravity-cli-bin/webm_encoder", "webm"))
    true
  }

  let ok = ensure_agy_shared_cache_seeded(
    shared_root,
    "/tmp/worktree",
    path_entry_exists~,
    list_dir~,
    create_dir_all~,
    write_file_sync~,
    rename_file_sync~,
    rm_rf~,
    read_file=fn(path) { files.get(path).unwrap_or("") },
    seed_temp~,
  )

  assert_true(ok)
  assert_true(path_entry_exists(complete))
  @debug.assert_eq(files.get(complete), Some("complete\n"))
}

///|
test "agy shared cache adoption is read-only for partial roots" {
  let shared_root = "/tmp/choir-agy-partial"
  let complete = agy_shared_cache_complete_path(shared_root)
  let paths : Map[String, Bool] = {}
  paths.set(shared_root, true)
  paths.set(shared_root + "/ms-playwright-go", true)
  let mut complete_writes = 0
  let write_file_sync = fn(path : String, _content : String) -> Bool {
    if path == complete {
      complete_writes = complete_writes + 1
      paths.set(path, true)
    }
    true
  }

  let ok = mark_existing_agy_shared_cache_seeded(
    shared_root,
    fn(path) { paths.get(path).unwrap_or(false) },
    fn(_) { [] },
    fn(_) { "" },
    write_file_sync,
  )

  assert_false(ok)
  assert_eq(complete_writes, 0)
  assert_false(paths.get(complete).unwrap_or(false))
}

///|
test "agy shared cache wait timeout does not reclaim a live lock" {
  let shared_root = "/tmp/choir-agy-live-lock"
  let complete = agy_shared_cache_complete_path(shared_root)
  let lock_dir = agy_shared_cache_lock_dir(shared_root)
  let paths : Map[String, Bool] = {}
  paths.set(lock_dir, true)
  paths.set(lock_dir + "/holder", true)
  let files : Map[String, String] = {}
  files.set(lock_dir + "/holder", "pid=42\nstarted_ms=1000\nholder=other\n")
  let mut sleep_count = 0
  let mut seed_count = 0
  let mut lock_delete_count = 0
  let path_entry_exists = fn(path : String) -> Bool {
    paths.get(path).unwrap_or(false)
  }
  let list_dir = fn(path : String) -> Array[String] {
    if path.has_suffix("/ms-playwright-go") {
      ["1.57.0"]
    } else {
      []
    }
  }
  let create_dir_all = fn(path : String) -> Bool {
    paths.set(path, true)
    true
  }
  let write_file_sync = fn(path : String, content : String) -> Bool {
    paths.set(path, true)
    files.set(path, content)
    true
  }
  let rename_file_sync = fn(from : String, to : String) -> Bool {
    if to == lock_dir {
      ignore(from)
      return false
    }
    paths.set(to, true)
    true
  }
  let rm_rf = fn(path : String) -> Bool {
    if path == lock_dir {
      lock_delete_count = lock_delete_count + 1
    }
    paths.set(path, false)
    paths.set(path + "/holder", false)
    true
  }
  let sleep_milliseconds = fn(_ms : Int) -> Unit {
    sleep_count = sleep_count + 1
    if sleep_count == 250 {
      paths.set(shared_root, true)
      paths.set(shared_root + "/ms-playwright-go", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/package", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/node", true)
      paths.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        true,
      )
      paths.set(shared_root + "/antigravity-cli-bin", true)
      paths.set(shared_root + "/antigravity-cli-bin/agentapi", true)
      paths.set(shared_root + "/antigravity-cli-bin/webm_encoder", true)
      paths.set(complete, true)
      files.set(shared_root + "/ms-playwright-go/1.57.0/node", "node")
      files.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        "{}",
      )
      files.set(shared_root + "/antigravity-cli-bin/agentapi", "agent")
      files.set(shared_root + "/antigravity-cli-bin/webm_encoder", "webm")
    }
  }
  let seed_temp = fn(_, _, _) {
    seed_count = seed_count + 1
    false
  }

  let ok = ensure_agy_shared_cache_seeded(
    shared_root,
    "/tmp/worktree",
    path_entry_exists~,
    list_dir~,
    create_dir_all~,
    write_file_sync~,
    rename_file_sync~,
    rm_rf~,
    sleep_milliseconds~,
    read_file=fn(path) { files.get(path).unwrap_or("") },
    pid_is_alive=fn(pid) { pid == 42 },
    now_ms_fn=fn() { 1000L },
    seed_temp~,
  )

  assert_true(ok)
  assert_true(sleep_count >= 250)
  assert_eq(seed_count, 0)
  assert_eq(lock_delete_count, 0)
}

///|
test "agy shared cache stale reclaim rechecks unchanged holder" {
  let shared_root = "/tmp/choir-agy-changing-lock"
  let complete = agy_shared_cache_complete_path(shared_root)
  let lock_dir = agy_shared_cache_lock_dir(shared_root)
  let stale_holder = "pid=111\nstarted_ms=0\nholder=old\n"
  let fresh_holder = "pid=222\nstarted_ms=1000\nholder=new\n"
  let paths : Map[String, Bool] = {}
  paths.set(lock_dir, true)
  paths.set(lock_dir + "/holder", true)
  let files : Map[String, String] = {}
  files.set(lock_dir + "/holder", stale_holder)
  let mut read_count = 0
  let mut lock_delete_count = 0
  let mut sleep_count = 0
  let path_entry_exists = fn(path : String) -> Bool {
    paths.get(path).unwrap_or(false)
  }
  let list_dir = fn(path : String) -> Array[String] {
    if path.has_suffix("/ms-playwright-go") {
      ["1.57.0"]
    } else {
      []
    }
  }
  let create_dir_all = fn(path : String) -> Bool {
    paths.set(path, true)
    true
  }
  let write_file_sync = fn(path : String, content : String) -> Bool {
    paths.set(path, true)
    files.set(path, content)
    true
  }
  let rename_file_sync = fn(_from : String, to : String) -> Bool {
    if to == lock_dir {
      return false
    }
    paths.set(to, true)
    true
  }
  let rm_rf = fn(path : String) -> Bool {
    if path == lock_dir {
      lock_delete_count = lock_delete_count + 1
    }
    paths.set(path, false)
    true
  }
  let read_file = fn(path : String) -> String {
    if path == lock_dir + "/holder" {
      read_count = read_count + 1
      if read_count > 1 {
        files.set(path, fresh_holder)
      }
    }
    files.get(path).unwrap_or("")
  }
  let sleep_milliseconds = fn(_ms : Int) -> Unit {
    sleep_count = sleep_count + 1
    if sleep_count == 3 {
      paths.set(shared_root, true)
      paths.set(shared_root + "/ms-playwright-go", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/package", true)
      paths.set(shared_root + "/ms-playwright-go/1.57.0/node", true)
      paths.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        true,
      )
      paths.set(shared_root + "/antigravity-cli-bin", true)
      paths.set(shared_root + "/antigravity-cli-bin/agentapi", true)
      paths.set(shared_root + "/antigravity-cli-bin/webm_encoder", true)
      paths.set(complete, true)
      files.set(shared_root + "/ms-playwright-go/1.57.0/node", "node")
      files.set(
        shared_root + "/ms-playwright-go/1.57.0/package/package.json",
        "{}",
      )
      files.set(shared_root + "/antigravity-cli-bin/agentapi", "agent")
      files.set(shared_root + "/antigravity-cli-bin/webm_encoder", "webm")
    }
  }

  let ok = ensure_agy_shared_cache_seeded(
    shared_root,
    "/tmp/worktree",
    path_entry_exists~,
    list_dir~,
    create_dir_all~,
    write_file_sync~,
    rename_file_sync~,
    rm_rf~,
    sleep_milliseconds~,
    read_file~,
    pid_is_alive=fn(pid) { pid == 222 },
    now_ms_fn=fn() { 1000L },
    seed_temp=fn(_, _, _) { false },
  )

  assert_true(ok)
  assert_eq(lock_delete_count, 0)
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
  {
    program: "gh",
    args: ["pr", "edit", pr_number.to_string(), "--add-reviewer", reviewer],
    workdir: Some(project_dir),
  }
}
