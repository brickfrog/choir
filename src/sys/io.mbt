///|
#borrow(path)
extern "C" fn c_get_file_size(path : Bytes) -> Int = "choir_get_file_size"

///|
#borrow(path)
extern "C" fn c_path_entry_exists(path : Bytes) -> Int = "choir_path_entry_exists"

///|
#borrow(path)
extern "C" fn c_rm_rf(path : Bytes) -> Int = "choir_rm_rf"

///|
#borrow(path, buf)
extern "C" fn c_list_dir(path : Bytes, buf : Bytes, max_size : Int) -> Int = "choir_list_dir"

///|
#borrow(path, buf)
extern "C" fn c_read_file_to_buf(path : Bytes, buf : Bytes, size : Int) = "choir_read_file_to_buf"

///|
#borrow(buf)
extern "C" fn c_stdin_read_line(buf : Bytes, max_size : Int) -> Int = "choir_stdin_read_line"

///|
#borrow(buf)
extern "C" fn c_stdin_read(buf : Bytes, max_size : Int) -> Int = "choir_stdin_read"

///|
#borrow(buf)
extern "C" fn c_stdout_write(buf : Bytes, size : Int) = "choir_stdout_write"

///|
#borrow(buf)
extern "C" fn c_stderr_write(buf : Bytes, size : Int) = "choir_stderr_write"

///|
extern "C" fn c_exit(code : Int) = "choir_exit"

///|
extern "C" fn c_getpid() -> Int = "choir_getpid"

///|
extern "C" fn c_kill_pid(pid : Int) -> Int = "choir_kill_pid"

///|
extern "C" fn c_init_kill_server_pid_sequence(pid : Int) = "choir_init_kill_server_pid_sequence"

///|
extern "C" fn c_pid_is_alive(pid : Int) -> Int = "choir_pid_is_alive"

///|
#borrow(prefix, buf)
extern "C" fn c_list_pids_with_cwd_prefix(
  prefix : Bytes,
  buf : Bytes,
  max_size : Int,
) -> Int = "choir_list_pids_with_cwd_prefix"

///|
#borrow(exe)
extern "C" fn c_spawn_serve(exe : Bytes, exe_len : Int) -> Int = "choir_spawn_serve"

///|
#borrow(path)
extern "C" fn c_wait_for_socket(path : Bytes, max_tries : Int) -> Int = "choir_wait_for_socket"

///|
#borrow(cmd)
extern "C" fn c_system(cmd : Bytes) -> Int = "choir_system"

///|
#borrow(path, out)
extern "C" fn c_realpath(path : Bytes, out : Bytes, out_size : Int) -> Int = "choir_realpath"

///|
#borrow(path)
extern "C" fn c_write_pid_file(path : Bytes) -> Unit = "choir_write_pid_file"

///|
#borrow(name, out)
extern "C" fn c_getenv(name : Bytes, out : Bytes, out_size : Int) -> Int = "choir_getenv"

///|
fn string_to_null_terminated_bytes(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
/// True when `path` can be opened for reading as a regular file (`fopen` succeeds).
/// Directories and missing paths yield false.
pub fn path_exists(path : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_get_file_size(path_bytes) >= 0
}

///|
/// True when `stat(2)` succeeds (path exists as a file, directory, or other node).
pub fn path_entry_exists(path : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_path_entry_exists(path_bytes) != 0
}

///|
/// Recursive delete of `path`. Returns `true` on success (including the
/// idempotent "already gone" case) and `false` on any failure. Symbolic
/// links are unlinked, not followed. Intended for test scaffolding under
/// `/tmp` — not a substitute for git-aware worktree removal.
pub fn rm_rf(path : String) -> Bool {
  c_rm_rf(string_to_null_terminated_bytes(path)) == 0
}

///|
/// Entry names of `path`, skipping `.` and `..`. Returns empty array when the
/// directory cannot be opened (non-existent, permission denied, not a dir).
/// A 64 KiB buffer caps the read; directories with more entries than fit are
/// silently truncated — callers here operate on `.choir/kv` and `.choir/worktrees`
/// which stay well under that.
pub fn list_dir(path : String) -> Array[String] {
  let path_bytes = string_to_null_terminated_bytes(path)
  let max_size = 65536
  let buf = Bytes::new(max_size)
  let n = c_list_dir(path_bytes, buf, max_size)
  if n <= 0 {
    return []
  }
  let content = @utf8.decode_lossy(buf[:n])
  let entries : Array[String] = []
  for raw in content.split("\n") {
    let name = raw.trim().to_string()
    if name != "" {
      entries.push(name)
    }
  }
  entries
}

///|
pub fn read_file(path : String) -> String {
  let path_bytes = string_to_null_terminated_bytes(path)
  let size = c_get_file_size(path_bytes)
  if size < 0 {
    return ""
  }
  let buf = Bytes::new(size)
  c_read_file_to_buf(path_bytes, buf, size)
  @utf8.decode_lossy(buf)
}

///|
pub fn write_stdout(s : String) -> Unit {
  let b = @utf8.encode(s)
  c_stdout_write(b, b.length())
}

///|
pub fn write_stdout_bytes(b : Bytes) -> Unit {
  c_stdout_write(b, b.length())
}

///|
pub fn write_stderr(s : String) -> Unit {
  let b = @utf8.encode(s)
  c_stderr_write(b, b.length())
}

///|
fn read_stdin_chunk(max_size : Int) -> (Bytes, Int, Bool, Bool) {
  let buf = Bytes::new(max_size)
  let status = c_stdin_read_line(buf, max_size)
  if status == -1 {
    return (buf, 0, false, true)
  }
  if status >= 0 {
    return (buf, status, false, false)
  }
  (buf, -(status + 1), true, false)
}

///|
pub fn read_stdin_line(max_size : Int) -> String? {
  let line = StringBuilder::new()
  let mut saw_data = false
  for ;; {
    let (buf, len, has_more, eof) = read_stdin_chunk(max_size)
    if eof {
      return if saw_data { Some(line.to_string()) } else { None }
    }
    line.write_string(@utf8.decode_lossy(buf[:len]))
    saw_data = true
    if !has_more {
      return Some(line.to_string())
    }
  }
  None
}

///|
pub fn read_stdin_exact(size : Int) -> Bytes? {
  if size < 0 {
    return None
  }
  if size == 0 {
    return Some(Bytes::new(0))
  }
  let result = FixedArray::make(size, (0 : Byte))
  let mut offset = 0
  for ;; {
    if offset >= size {
      break
    }
    let remaining = size - offset
    let chunk_size = if remaining < 4096 { remaining } else { 4096 }
    let chunk = Bytes::new(chunk_size)
    let n = c_stdin_read(chunk, chunk_size)
    if n <= 0 {
      return None
    }
    for i = 0; i < n; i = i + 1 {
      result[offset + i] = chunk[i]
    }
    offset = offset + n
  }
  Some(result.unsafe_reinterpret_as_bytes())
}

///|
pub fn exit(code : Int) -> Unit {
  c_exit(code)
}

///|
pub fn get_pid() -> Int {
  c_getpid()
}

///|
/// Send `SIGTERM` to `pid` via `kill(2)`. No-op for non-positive `pid`. Treats "no such process"
/// like `kill ... || true` (ignored).
pub fn kill_pid_best_effort(pid : Int) -> Unit {
  ignore(c_kill_pid(pid))
}

///|
/// `SIGTERM`, ~300ms pause, then `SIGKILL` (init/stop server PID path; best-effort).
pub fn kill_server_pid_sequence_best_effort(pid : Int) -> Unit {
  c_init_kill_server_pid_sequence(pid)
}

///|
/// True when `kill(pid, 0)` succeeds (process exists for signaling).
pub fn pid_is_alive(pid : Int) -> Bool {
  c_pid_is_alive(pid) != 0
}

///|
/// Upper bound on the per-call PID-scan cap. 1024 matching processes is far
/// beyond anything a real kill_agent invocation could produce and keeps the
/// internal buffer allocation to 16 KiB.
const LIST_PIDS_WITH_CWD_PREFIX_HARD_CAP : Int = 1024

///|
/// Linux-only: PIDs of live processes whose `/proc/{pid}/cwd` symlink resolves
/// under `prefix`. Matches exact, `prefix + "/..."`, and the `" (deleted)"`
/// variants of both (the kernel appends `" (deleted)"` when the inode has been
/// unlinked — e.g., after `git worktree remove`). Self-PID is always skipped,
/// and an empty `prefix` is rejected (returning `[]`) since it would otherwise
/// match nearly every cwd on the system.
///
/// The returned array is capped at `min(max, 1024)` entries — the C helper
/// writes decimal PIDs into a 16-byte-per-entry buffer, and this wrapper
/// additionally stops parsing once the cap is reached so short PIDs (e.g.
/// "1\n") cannot exceed it. Returns an empty array when `/proc` cannot be
/// opened (non-Linux host, chroot without /proc, etc.).
pub fn list_pids_with_cwd_prefix(
  prefix : String,
  max? : Int = 64,
) -> Array[Int] {
  if max <= 0 || prefix == "" {
    return []
  }
  let effective_max = if max > LIST_PIDS_WITH_CWD_PREFIX_HARD_CAP {
    LIST_PIDS_WITH_CWD_PREFIX_HARD_CAP
  } else {
    max
  }
  let prefix_bytes = string_to_null_terminated_bytes(prefix)
  let buf_size = effective_max * 16
  let buf = Bytes::new(buf_size)
  let n = c_list_pids_with_cwd_prefix(prefix_bytes, buf, buf_size)
  if n <= 0 {
    return []
  }
  let content = @utf8.decode_lossy(buf[:n])
  let pids : Array[Int] = []
  for raw in content.split("\n") {
    if pids.length() >= effective_max {
      break
    }
    let trimmed = raw.trim().to_string()
    if trimmed == "" {
      continue
    }
    let parsed = Some(@string.parse_int(trimmed)) catch { _ => None }
    match parsed {
      Some(v) => pids.push(v)
      None => ()
    }
  }
  pids
}

///|
pub fn write_pid_file(path : String) -> Unit {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_write_pid_file(path_bytes)
}

///|
pub fn getenv(name : String) -> String? {
  let name_bytes = string_to_null_terminated_bytes(name)
  let buf = Bytes::new(4096)
  let len = c_getenv(name_bytes, buf, 4096)
  if len <= 0 {
    return None
  }
  Some(@utf8.decode_lossy(buf[:len]))
}

///|
pub fn system(cmd : String) -> Int {
  let bytes = string_to_null_terminated_bytes(cmd)
  c_system(bytes)
}

///|
pub fn realpath_native(path : String) -> String? {
  let path_bytes = string_to_null_terminated_bytes(path)
  let out = Bytes::new(4096)
  let len = c_realpath(path_bytes, out, 4096)
  if len <= 0 {
    return None
  }
  Some(@utf8.decode_lossy(out[:len]))
}

///|
pub fn spawn_serve(self_exe : String) -> Bool {
  let exe_bytes = string_to_null_terminated_bytes(self_exe)
  c_spawn_serve(exe_bytes, exe_bytes.length() - 1) == 0
}

///|
pub fn wait_for_socket(path : String, max_tries : Int) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_wait_for_socket(path_bytes, max_tries) == 0
}

///|
#borrow(path)
extern "C" fn c_redirect_stderr_append(path : Bytes) -> Int = "choir_redirect_stderr_append"

///|
/// Redirect the process stderr to `path` (append, create if needed). Used by `mcp-stdio` Codex path.
pub fn redirect_stderr_append(path : String) -> Bool {
  c_redirect_stderr_append(string_to_null_terminated_bytes(path)) == 0
}

///|
#borrow(path, content)
extern "C" fn c_write_file_sync(
  path : Bytes,
  content : Bytes,
  content_len : Int,
) -> Int = "choir_write_file_sync"

///|
#borrow(from_path, to_path)
extern "C" fn c_rename_file_sync(from_path : Bytes, to_path : Bytes) -> Int = "choir_rename_file_sync"

///|
#borrow(path)
extern "C" fn c_delete_file_sync(path : Bytes) -> Int = "choir_delete_file_sync"

///|
#borrow(path)
extern "C" fn c_chmod_mode(path : Bytes, mode : Int) -> Int = "choir_chmod_mode"

///|
#borrow(target, linkpath)
extern "C" fn c_symlink_force(target : Bytes, linkpath : Bytes) -> Int = "choir_symlink_force"

///|
#borrow(session, pane_id, snapshot_path)
extern "C" fn c_spawn_zellij_pane_viewport_subscribe(
  session : Bytes,
  pane_id : Bytes,
  snapshot_path : Bytes,
) -> Int = "choir_spawn_zellij_pane_viewport_subscribe"

///|
pub fn write_file_sync(path : String, content : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  let content_bytes = @utf8.encode(content)
  c_write_file_sync(path_bytes, content_bytes, content_bytes.length()) == 0
}

///|
pub fn rename_file_sync(from_path : String, to_path : String) -> Bool {
  let from_bytes = string_to_null_terminated_bytes(from_path)
  let to_bytes = string_to_null_terminated_bytes(to_path)
  c_rename_file_sync(from_bytes, to_bytes) == 0
}

///|
pub fn write_file_atomic(path : String, content : String) -> Bool {
  let tmp_path = path + ".tmp." + c_getpid().to_string()
  if !write_file_sync(tmp_path, content) {
    return false
  }
  let from_bytes = string_to_null_terminated_bytes(tmp_path)
  let to_bytes = string_to_null_terminated_bytes(path)
  if c_rename_file_sync(from_bytes, to_bytes) != 0 {
    ignore(c_delete_file_sync(from_bytes))
    return false
  }
  true
}

///|
#borrow(path, content)
extern "C" fn c_append_file_sync(
  path : Bytes,
  content : Bytes,
  content_len : Int,
) -> Int = "choir_append_file_sync"

///|
#borrow(path)
extern "C" fn c_create_dir_all(path : Bytes) -> Int = "choir_create_dir_all"

///|
pub fn create_dir_all(path : String) -> Bool {
  c_create_dir_all(string_to_null_terminated_bytes(path)) == 0
}

///|
pub fn is_dir(path : String) -> Bool {
  if !path_entry_exists(path) {
    return false
  }
  let path_bytes = string_to_null_terminated_bytes(path)
  let buf = Bytes::new(1)
  c_list_dir(path_bytes, buf, 1) >= 0
}

///|
pub fn copy_dir_recursive(src : String, dst : String) -> Bool {
  // AUDIT: copy_dir_recursive inherits `list_dir`'s behavior of skipping all
  // dot-prefixed entries (see choir_list_dir in src/sys/stub.c), not just
  // `.`/`..`. Hidden files inside a skill dir are therefore not copied. This
  // is acceptable for SKILL.md-based skills which use conventional filenames.
  // Changing the stub's policy would affect other callers (KV scan, worktree
  // walks) and is out of scope for this PR.
  if !is_dir(src) {
    return false
  }
  if !create_dir_all(dst) {
    return false
  }
  let entries = list_dir(src)
  let mut success = true
  for entry in entries {
    let src_path = src + "/" + entry
    let dst_path = dst + "/" + entry
    if is_dir(src_path) {
      if !copy_dir_recursive(src_path, dst_path) {
        success = false
      }
    } else {
      let content = read_file(src_path)
      if !write_file_sync(dst_path, content) {
        success = false
      }
    }
  }
  success
}

///|
test "copy_dir_recursive copies files and directories correctly" {
  let pid_str = get_pid().to_string()
  let src = "/tmp/choir-io-copy-test-src-" + pid_str
  let dst = "/tmp/choir-io-copy-test-dst-" + pid_str
  ignore(rm_rf(src))
  ignore(rm_rf(dst))

  assert_true(create_dir_all(src + "/subdir"))
  assert_true(write_file_sync(src + "/file.txt", "hello"))
  assert_true(write_file_sync(src + "/subdir/subfile.txt", "world"))
  assert_true(write_file_sync(src + "/.dotfile", "dot"))

  if !copy_dir_recursive(src, dst) {
    fail("copy_dir_recursive returned false")
  }

  if !path_exists(dst + "/file.txt") {
    fail("dst/file.txt does not exist")
  }
  if !path_exists(dst + "/subdir/subfile.txt") {
    fail("dst/subdir/subfile.txt does not exist")
  }
  // .dotfile should NOT exist because list_dir skips it
  if path_exists(dst + "/.dotfile") {
    fail("dst/.dotfile should NOT exist")
  }
  assert_eq(read_file(dst + "/file.txt"), "hello")
  assert_eq(read_file(dst + "/subdir/subfile.txt"), "world")

  assert_false(copy_dir_recursive(src + "/file.txt", dst + "/invalid"))
  assert_false(
    copy_dir_recursive("/nonexistent/path/for/choir/test", dst + "/invalid2"),
  )

  ignore(rm_rf(src))
  ignore(rm_rf(dst))
}

///|
pub fn append_file_sync(path : String, content : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  let content_bytes = @utf8.encode(content)
  c_append_file_sync(path_bytes, content_bytes, content_bytes.length()) == 0
}

///|
pub fn delete_file_sync(path : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_delete_file_sync(path_bytes) == 0
}

///|
/// Set `path` mode bits (`chmod(2)`). Returns false on failure.
pub fn chmod_mode(path : String, mode : Int) -> Bool {
  c_chmod_mode(string_to_null_terminated_bytes(path), mode) == 0
}

///|
/// Replace `linkpath` with a symlink to `target` (`unlink` then `symlink(2)`).
pub fn symlink_force(target : String, linkpath : String) -> Bool {
  c_symlink_force(
    string_to_null_terminated_bytes(target),
    string_to_null_terminated_bytes(linkpath),
  ) ==
  0
}

///|
/// Fork a supervisor that runs `zellij subscribe pane-viewport --format json`, mirrors each stdout
/// line into `snapshot_path`, and returns the supervisor PID for `kill_pid_best_effort`, or a
/// non-positive value on failure.
pub fn spawn_zellij_pane_viewport_subscribe(
  session : String,
  pane_id : String,
  snapshot_path : String,
) -> Int {
  c_spawn_zellij_pane_viewport_subscribe(
    string_to_null_terminated_bytes(session),
    string_to_null_terminated_bytes(pane_id),
    string_to_null_terminated_bytes(snapshot_path),
  )
}

///|
#borrow(pd, ws, br)
extern "C" fn c_worktree_bootstrap_cleanup(pd : Bytes, ws : Bytes, br : Bytes) = "choir_worktree_bootstrap_cleanup"

///|
extern "C" fn c_init_cleanup_runtime_artifacts() = "choir_init_cleanup_runtime_artifacts"

///|
extern "C" fn c_init_cleanup_purge_artifacts() = "choir_init_cleanup_purge_artifacts"

///|
extern "C" fn c_register_cleanup_runtime_artifacts() = "choir_register_cleanup_runtime_artifacts"

///|
#borrow(pd, br)
extern "C" fn c_git_fetch_origin_branch_best_effort(pd : Bytes, br : Bytes) = "choir_git_fetch_origin_branch_best_effort"

///|
/// Best-effort worktree cleanup before spawn (`git -C` / `rm` via `execvp`, stderr discarded).
pub fn worktree_bootstrap_cleanup_native(
  project_dir : String,
  workspace : String,
  branch : String,
) -> Unit {
  c_worktree_bootstrap_cleanup(
    string_to_null_terminated_bytes(project_dir),
    string_to_null_terminated_bytes(workspace),
    string_to_null_terminated_bytes(branch),
  )
}

///|
/// Best-effort `git fetch origin <branch>` with the same stderr warnings as the former `sh -c` helper.
pub fn git_fetch_origin_branch_best_effort_native(
  project_dir : String,
  branch : String,
) -> Unit {
  c_git_fetch_origin_branch_best_effort(
    string_to_null_terminated_bytes(project_dir),
    string_to_null_terminated_bytes(branch),
  )
}

///|
/// Unlink runtime-only markers (restart recovery state preserved). No shell.
pub fn init_cleanup_runtime_artifacts_native() -> Unit {
  c_init_cleanup_runtime_artifacts()
}

///|
/// Broader destructive cleanup: worktrees, inline, kv prefixes, poller state. No `sh -c`.
pub fn init_cleanup_purge_artifacts_native() -> Unit {
  c_init_cleanup_purge_artifacts()
}

///|
/// Register SIGTERM/SIGINT cleanup that unlinks runtime markers only (no shell command).
pub fn register_cleanup_runtime_artifacts() -> Unit {
  c_register_cleanup_runtime_artifacts()
}

///|
/// POSIX single-quote style for embedding in `sh -c` (same as exec.quote).
pub fn shell_quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\'')
  for c in s {
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
/// Empty-prefix guard: the C helper bails out before touching `/proc`, and
/// the MoonBit wrapper rejects the empty string up front. A buggy caller
/// that leaks a blank workspace must never trigger a system-wide scan.
test "list_pids_with_cwd_prefix rejects empty prefix" {
  assert_eq(list_pids_with_cwd_prefix(""), [])
}
