///|
#borrow(path)
extern "C" fn c_get_file_size(path : Bytes) -> Int = "choir_get_file_size"

///|
#borrow(path)
extern "C" fn c_file_mtime_sec(path : Bytes) -> Int64 = "choir_file_mtime_sec"

///|
#borrow(path)
extern "C" fn c_path_entry_exists(path : Bytes) -> Int = "choir_path_entry_exists"

///|
#borrow(path)
extern "C" fn c_path_executable(path : Bytes) -> Int = "choir_path_executable"

///|
#borrow(path)
extern "C" fn c_rm_rf(path : Bytes) -> Int = "choir_rm_rf"

///|
#borrow(path, buf)
extern "C" fn c_list_dir(path : Bytes, buf : Bytes, max_size : Int) -> Int = "choir_list_dir"

///|
#borrow(path, buf)
extern "C" fn c_list_dir_all(path : Bytes, buf : Bytes, max_size : Int) -> Int = "choir_list_dir_all"

///|
#borrow(path, buf)
extern "C" fn c_read_file_to_buf(path : Bytes, buf : Bytes, size : Int) = "choir_read_file_to_buf"

///|
#borrow(path, buf)
extern "C" fn c_read_file_prefix(
  path : Bytes,
  buf : Bytes,
  max_size : Int,
) -> Int = "choir_read_file_prefix"

///|
#borrow(buf)
extern "C" fn c_stdin_read_line(buf : Bytes, max_size : Int) -> Int = "choir_stdin_read_line"

///|
#borrow(buf)
extern "C" fn c_stdin_read(buf : Bytes, max_size : Int) -> Int = "choir_stdin_read"

///|
extern "C" fn c_poll_readable_pair(
  first_fd : Int,
  second_fd : Int,
  timeout_ms : Int,
) -> Int = "choir_poll_readable_pair"

///|
extern "C" fn c_stdin_set_unbuffered() -> Int = "choir_stdin_set_unbuffered"

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
extern "C" fn c_getppid() -> Int = "choir_getppid"

///|
extern "C" fn c_kill_pid(pid : Int) -> Int = "choir_kill_pid"

///|
extern "C" fn c_kill_pgid(pgid : Int) -> Int = "choir_kill_pgid"

///|
extern "C" fn c_init_kill_server_pid_sequence(pid : Int) = "choir_init_kill_server_pid_sequence"

///|
extern "C" fn c_init_kill_server_tree_sequence(pid : Int) = "choir_init_kill_server_tree_sequence"

///|
extern "C" fn c_kill_pgid_sequence(pgid : Int) = "choir_kill_pgid_sequence"

///|
extern "C" fn c_wait_pid_reap_for_test(pid : Int) -> Int = "choir_wait_pid_reap_for_test"

///|
extern "C" fn c_pid_is_alive(pid : Int) -> Int = "choir_pid_is_alive"

///|
extern "C" fn c_pgid_is_alive(pgid : Int) -> Int = "choir_pgid_is_alive"

///|
#borrow(environment_entry, command_fragment)
extern "C" fn c_pgid_has_process_identity(
  pgid : Int,
  environment_entry : Bytes,
  command_fragment : Bytes,
) -> Int = "choir_pgid_has_process_identity"

///|
extern "C" fn c_pgid_has_non_zombie_process(pgid : Int) -> Int = "choir_pgid_has_non_zombie_process"

///|
extern "C" fn c_set_parent_death_signal_term() -> Int = "choir_set_parent_death_signal_term"

///|
#borrow(out)
extern "C" fn c_mint_local_token(out : Bytes, out_size : Int) -> Int = "choir_mint_local_token"

///|
#borrow(exe)
extern "C" fn c_spawn_serve(exe : Bytes, exe_len : Int) -> Int = "choir_spawn_serve"

///|
#borrow(exe, cwd)
extern "C" fn c_spawn_goal_worker(
  exe : Bytes,
  exe_len : Int,
  cwd : Bytes,
  cwd_len : Int,
) -> Int = "choir_spawn_goal_worker"

///|
extern "C" fn c_child_process_state(pid : Int) -> Int = "choir_child_process_state"

///|
#borrow(path)
extern "C" fn c_wait_for_socket(path : Bytes, max_tries : Int) -> Int = "choir_wait_for_socket"

///|
extern "C" fn c_sleep_milliseconds(ms : Int) = "choir_sleep_milliseconds"

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
#borrow(name, out)
extern "C" fn c_get_parent_env(
  name : Bytes,
  out : Bytes,
  out_size : Int,
) -> Int = "choir_get_parent_env"

///|
#borrow(name, value)
extern "C" fn c_setenv(name : Bytes, value : Bytes) -> Int = "choir_setenv"

///|
#borrow(name)
extern "C" fn c_unsetenv(name : Bytes) -> Int = "choir_unsetenv"

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
/// True when `c_get_file_size` returns a non-negative value — i.e., `fopen`
/// succeeded and `ftell` reported a size. On Linux this is ALSO true for
/// directories: `fopen` on a directory returns a non-null FILE*, `fseek`
/// fails, and `ftell` then returns 0, which compares >= 0. Callers that
/// must distinguish files from directories cannot rely on this function.
/// For pure existence checking that's correct for both
/// files and directories, use `path_entry_exists` (stat-based).
pub fn path_exists(path : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_get_file_size(path_bytes) >= 0
}

///|
/// Size of `path` in bytes via `fopen`+`ftell` (the same primitive as
/// `path_exists`); `-1` if `path` can't be opened. Like `path_exists`, this
/// reports `0` for directories on Linux — fine for the only caller (log
/// rotation, which checks a known regular file).
pub fn file_size(path : String) -> Int {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_get_file_size(path_bytes)
}

///|
/// Last modification time of `path` in Unix seconds, or `None` when `stat(2)`
/// fails. Used by host adapters that need cheap file freshness without reading
/// file contents.
pub fn file_mtime_sec(path : String) -> Int64? {
  let path_bytes = string_to_null_terminated_bytes(path)
  let mtime = c_file_mtime_sec(path_bytes)
  if mtime < 0L {
    None
  } else {
    Some(mtime)
  }
}

///|
/// True when `stat(2)` succeeds (path exists as a file, directory, or other node).
pub fn path_entry_exists(path : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_path_entry_exists(path_bytes) != 0
}

///|
/// True when `path` is a regular file with execute permission for this process.
pub fn path_executable(path : String) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_path_executable(path_bytes) != 0
}

///|
/// Wait for either descriptor to become readable, close, or fail. Bit 0
/// represents `first_fd`; bit 1 represents `second_fd`. A negative result is
/// a host polling failure.
pub fn poll_readable_pair(
  first_fd : Int,
  second_fd : Int,
  timeout_ms : Int,
) -> Int {
  c_poll_readable_pair(first_fd, second_fd, timeout_ms)
}

///|
/// Disable libc read-ahead before combining stdin reads with poll(2).
pub fn stdin_set_unbuffered() -> Bool {
  c_stdin_set_unbuffered() == 0
}

///|
/// Recursive delete of `path`. Returns `true` on success (including the
/// idempotent "already gone" case) and `false` on any failure. Symbolic
/// links are unlinked, not followed.
pub fn rm_rf(path : String) -> Bool {
  c_rm_rf(string_to_null_terminated_bytes(path)) == 0
}

///|
/// Entry names of `path`, skipping `.` and `..`. Returns empty array when the
/// directory cannot be opened (non-existent, permission denied, not a dir).
/// A 64 KiB buffer caps the read; directories with more entries than fit are
/// silently truncated.
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
    let name = raw.trim().to_owned()
    if name != "" {
      entries.push(name)
    }
  }
  entries
}

///|
pub fn list_dir_all(path : String) -> Array[String] {
  let path_bytes = string_to_null_terminated_bytes(path)
  let max_size = 1024 * 1024
  let buf = Bytes::new(max_size)
  let n = c_list_dir_all(path_bytes, buf, max_size)
  if n <= 0 {
    return []
  }
  let content = @utf8.decode_lossy(buf[:n])
  let entries : Array[String] = []
  for raw in content.split("\n") {
    let name = raw.trim().to_owned()
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
pub fn read_file_prefix(path : String, max_size : Int) -> String {
  if max_size <= 0 || max_size > 65536 {
    return ""
  }
  let path_bytes = string_to_null_terminated_bytes(path)
  let buf = Bytes::new(max_size)
  let size = c_read_file_prefix(path_bytes, buf, max_size)
  if size <= 0 {
    ""
  } else {
    @utf8.decode_lossy(buf[:size])
  }
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
#borrow(path)
extern "C" fn c_acquire_instance_lock(path : Bytes) -> Int = "choir_acquire_instance_lock"

///|
/// Acquire an exclusive, non-blocking `flock(2)` on `path`, creating the file
/// when absent. The descriptor is intentionally never closed so the lock is
/// held for the remaining lifetime of the process.
pub fn acquire_instance_lock(path : String) -> Bool {
  c_acquire_instance_lock(string_to_null_terminated_bytes(path)) >= 0
}

///|
#borrow(path, buf)
extern "C" fn c_read_file_into(path : Bytes, buf : Bytes, cap : Int) -> Int = "choir_read_file_into"

///|
/// Read a file's full contents as raw bytes. Returns `None` when the file is
/// unreadable or grows past the initially observed size mid-read.
pub fn read_file_bytes(path : String) -> Bytes? {
  let size = c_get_file_size(string_to_null_terminated_bytes(path))
  if size < 0 {
    return None
  }
  let buffer = Bytes::new(size)
  let got = c_read_file_into(
    string_to_null_terminated_bytes(path),
    buffer,
    size,
  )
  if got != size {
    return None
  }
  Some(buffer)
}

///|
test "instance lock is exclusive across open file descriptions" {
  let path = "/tmp/choir-io-instance-lock-test-" + get_pid().to_string()
  ignore(rm_rf(path))
  assert_true(acquire_instance_lock(path))
  // flock ownership follows the open file description, so a second acquire
  // through a fresh descriptor must fail even within the same process.
  assert_false(acquire_instance_lock(path))
  ignore(rm_rf(path))
}

///|
test "read_file_bytes returns exact file contents" {
  let path = "/tmp/choir-io-read-bytes-test-" + get_pid().to_string()
  ignore(rm_rf(path))
  assert_true(write_file_sync(path, "byte-content"))
  assert_eq(read_file_bytes(path), Some(b"byte-content"))
  assert_eq(read_file_bytes(path + "-missing"), None)
  ignore(rm_rf(path))
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
/// Parent process id, useful for worker processes that need to report the
/// supervising agent's PID to the server side for process-group cleanup.
pub fn getppid() -> Int {
  c_getppid()
}

///|
/// Send `SIGTERM` to `pid` via `kill(2)`. No-op for non-positive `pid`. Treats "no such process"
/// like `kill ... || true` (ignored).
pub fn kill_pid_best_effort(pid : Int) -> Unit {
  ignore(c_kill_pid(pid))
}

///|
/// Send `SIGTERM` to `pgid` via `kill(-pgid, SIGTERM)`. Groups `<= 1` are
/// ignored as no-op: 0 is the caller's own group and 1 triggers the broadcast
/// form (signal every process the caller can signal), both wider than the
/// bounded-pgroup-cleanup intent.
pub fn kill_pgid_best_effort(pgid : Int) -> Unit {
  ignore(c_kill_pgid(pgid))
}

///|
/// `SIGTERM`, ~300ms pause, then `SIGKILL` (init/stop server PID path; best-effort).
pub fn kill_server_pid_sequence_best_effort(pid : Int) -> Unit {
  c_init_kill_server_pid_sequence(pid)
}

///|
pub fn kill_server_tree_sequence_best_effort(pid : Int) -> Unit {
  c_init_kill_server_tree_sequence(pid)
}

///|
/// `SIGTERM` the process group, ~300ms pause, then `SIGKILL` it (best-effort).
/// Groups `<= 1` are rejected as no-op for the same reason as
/// `kill_pgid_best_effort`: 0 is the caller's own group and 1 triggers the
/// broadcast form, both wider than the bounded-pgroup-cleanup intent.
pub fn kill_pgid_sequence_best_effort(pgid : Int) -> Unit {
  c_kill_pgid_sequence(pgid)
}

///|
/// Test-only: reap a direct child via `waitpid(2)` so a follow-up
/// `pid_is_alive` probe does not see a zombie. Returns the reaped pid, or a
/// negative value on failure.
pub fn wait_pid_reap_for_test(pid : Int) -> Int {
  c_wait_pid_reap_for_test(pid)
}

///|
/// True when `kill(pid, 0)` succeeds (process exists for signaling).
pub fn pid_is_alive(pid : Int) -> Bool {
  c_pid_is_alive(pid) != 0
}

///|
/// True when `kill(-pgid, 0)` succeeds for the process group. Treats EPERM as
/// alive in the native helper and rejects groups <= 1.
pub fn pgid_is_alive(pgid : Int) -> Bool {
  c_pgid_is_alive(pgid) != 0
}

///|
pub fn pgid_has_process_identity(
  pgid : Int,
  environment_entry : String,
  command_fragment : String,
) -> Bool {
  if pgid <= 1 || environment_entry == "" || command_fragment == "" {
    return false
  }
  c_pgid_has_process_identity(
    pgid,
    string_to_null_terminated_bytes(environment_entry),
    string_to_null_terminated_bytes(command_fragment),
  ) !=
  0
}

///|
pub fn pgid_has_non_zombie_process(pgid : Int) -> Bool {
  pgid > 1 && c_pgid_has_non_zombie_process(pgid) != 0
}

///|
pub fn set_parent_death_signal_term() -> Bool {
  c_set_parent_death_signal_term() == 0
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
  if len < 4096 {
    return Some(@utf8.decode_lossy(buf[:len]))
  }
  let large_buf = Bytes::new(len + 1)
  let large_len = c_getenv(name_bytes, large_buf, len + 1)
  if large_len <= 0 {
    None
  } else {
    let copy_len = if large_len < len + 1 { large_len } else { len }
    Some(@utf8.decode_lossy(large_buf[:copy_len]))
  }
}

///|
pub fn get_parent_env(name : String) -> String? {
  let name_bytes = string_to_null_terminated_bytes(name)
  let buf = Bytes::new(4096)
  let len = c_get_parent_env(name_bytes, buf, 4096)
  if len <= 0 || len >= 4096 {
    None
  } else {
    Some(@utf8.decode_lossy(buf[:len]))
  }
}

///|
pub fn setenv(name : String, value : String) -> Bool {
  let name_bytes = string_to_null_terminated_bytes(name)
  let value_bytes = string_to_null_terminated_bytes(value)
  c_setenv(name_bytes, value_bytes) == 0
}

///|
pub fn unsetenv(name : String) -> Bool {
  let name_bytes = string_to_null_terminated_bytes(name)
  c_unsetenv(name_bytes) == 0
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
pub fn mint_local_token() -> String? {
  let out = Bytes::new(65)
  let length = c_mint_local_token(out, out.length())
  if length == 64 {
    Some(@utf8.decode_lossy(out[:length]))
  } else {
    None
  }
}

///|
pub fn spawn_serve(self_exe : String) -> Bool {
  let exe_bytes = string_to_null_terminated_bytes(self_exe)
  c_spawn_serve(exe_bytes, exe_bytes.length() - 1) == 0
}

///|
pub fn spawn_goal_worker(self_exe : String, cwd : String) -> Int {
  let exe_bytes = string_to_null_terminated_bytes(self_exe)
  let cwd_bytes = string_to_null_terminated_bytes(cwd)
  c_spawn_goal_worker(
    exe_bytes,
    exe_bytes.length() - 1,
    cwd_bytes,
    cwd_bytes.length() - 1,
  )
}

///|
pub(all) enum ChildProcessState {
  ChildProcessRunning
  ChildProcessExited(Int)
  ChildProcessUnavailable
} derive(Debug, Eq)

///|
pub fn child_process_state(pid : Int) -> ChildProcessState {
  match c_child_process_state(pid) {
    -2 => ChildProcessRunning
    -3 => ChildProcessUnavailable
    status => ChildProcessExited(status)
  }
}

///|
pub fn wait_for_socket(path : String, max_tries : Int) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_wait_for_socket(path_bytes, max_tries) == 0
}

///|
pub fn sleep_milliseconds(ms : Int) -> Unit {
  if ms > 0 {
    c_sleep_milliseconds(ms)
  }
}

///|
#borrow(path)
extern "C" fn c_redirect_stderr_append(path : Bytes) -> Int = "choir_redirect_stderr_append"

///|
/// Redirect process stderr to `path` (append, create if needed), filtering
/// terminal response escape sequences while preserving SGR color/style escapes.
/// Used by the `mcp-stdio` Codex path.
pub fn redirect_stderr_append(path : String) -> Bool {
  // The redirect itself does not create the parent dir; ensure it exists so a
  // log nested under .choir/logs/ can be opened on first write.
  let last_slash = match path.rev_find("/") {
    Some(i) => i
    None => -1
  }
  if last_slash > 0 {
    ignore(create_dir_all(path[0:last_slash].to_owned()))
  }
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
  // Changing the stub's policy would affect every directory consumer.
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
extern "C" fn c_init_cleanup_runtime_artifacts() = "choir_init_cleanup_runtime_artifacts"

///|
extern "C" fn c_init_cleanup_purge_artifacts() = "choir_init_cleanup_purge_artifacts"

///|
extern "C" fn c_register_cleanup_runtime_artifacts() = "choir_register_cleanup_runtime_artifacts"

///|
extern "C" fn c_install_sigusr1_handler() -> Int = "choir_install_sigusr1_handler"

///|
extern "C" fn c_consume_sigusr1_flag() -> Int = "choir_consume_sigusr1_flag"

///|
extern "C" fn c_raise_sigusr1_for_test() -> Int = "choir_raise_sigusr1_for_test"

///|
extern "C" fn c_unblock_sigusr1_for_test() -> Int = "choir_unblock_sigusr1_for_test"

///|
#borrow(pid_path, sidecar_path, sentinel_path)
extern "C" fn c_spawn_sigterm_unblocked_pgroup_for_test(
  pid_path : Bytes,
  sidecar_path : Bytes,
  sentinel_path : Bytes,
) -> Int = "choir_spawn_sigterm_unblocked_pgroup_for_test"

///|
#borrow(pgid_path, child_path, sentinel_path)
extern "C" fn c_spawn_leader_exited_pgroup_for_test(
  pgid_path : Bytes,
  child_path : Bytes,
  sentinel_path : Bytes,
) -> Int = "choir_spawn_leader_exited_pgroup_for_test"

///|
#borrow(root_path, child_path, sentinel_path)
extern "C" fn c_spawn_nested_sessions_for_test(
  root_path : Bytes,
  child_path : Bytes,
  sentinel_path : Bytes,
) -> Int = "choir_spawn_nested_sessions_for_test"

///|
extern "C" fn c_ignore_sigpipe() -> Int = "choir_ignore_sigpipe"

///|
extern "C" fn c_sigpipe_ignored_for_test() -> Int = "choir_sigpipe_ignored_for_test"

///|
extern "C" fn c_reset_sigpipe_default_for_test() -> Int = "choir_reset_sigpipe_default_for_test"

///|
extern "C" fn c_save_sigpipe_for_test() -> Int = "choir_save_sigpipe_for_test"

///|
extern "C" fn c_restore_sigpipe_for_test() -> Int = "choir_restore_sigpipe_for_test"

///|
extern "C" fn c_install_crash_handlers() = "choir_install_crash_handlers"

///|
#borrow(buf)
extern "C" fn c_build_server_exit_log_line(
  sig : Int,
  ts : Int,
  pid : Int,
  buf : Bytes,
  max_size : Int,
) -> Int = "choir_build_server_exit_log_line"

///|
#borrow(path)
extern "C" fn c_append_server_exit_log_line(
  path : Bytes,
  sig : Int,
  ts : Int,
  pid : Int,
) -> Int = "choir_append_server_exit_log_line"

///|
extern "C" fn c_server_exit_signal_handlers_installed() -> Int = "choir_server_exit_signal_handlers_installed"

///|
extern "C" fn c_reset_server_exit_signal_handlers() = "choir_reset_server_exit_signal_handlers"

///|
/// Unlink runtime-only markers (restart recovery state preserved). No shell.
pub fn init_cleanup_runtime_artifacts_native() -> Unit {
  c_init_cleanup_runtime_artifacts()
}

///|
/// Delete all current Choir runtime and durable state. No shell command.
pub fn init_cleanup_purge_artifacts_native() -> Unit {
  c_init_cleanup_purge_artifacts()
}

///|
/// Register SIGTERM/SIGINT cleanup that logs exit and unlinks runtime markers only (no shell command).
pub fn register_cleanup_runtime_artifacts() -> Unit {
  c_register_cleanup_runtime_artifacts()
}

///|
pub fn install_sigusr1_handler() -> Bool {
  c_install_sigusr1_handler() == 0
}

///|
pub fn consume_sigusr1_flag() -> Bool {
  c_consume_sigusr1_flag() != 0
}

///|
pub fn raise_sigusr1_for_test() -> Bool {
  c_raise_sigusr1_for_test() == 0
}

///|
pub fn unblock_sigusr1_for_test() -> Bool {
  c_unblock_sigusr1_for_test() == 0
}

///|
pub fn spawn_sigterm_unblocked_pgroup_for_test(
  pid_path : String,
  sidecar_path : String,
  sentinel_path : String,
) -> Int {
  c_spawn_sigterm_unblocked_pgroup_for_test(
    string_to_null_terminated_bytes(pid_path),
    string_to_null_terminated_bytes(sidecar_path),
    string_to_null_terminated_bytes(sentinel_path),
  )
}

///|
pub fn spawn_leader_exited_pgroup_for_test(
  pgid_path : String,
  child_path : String,
  sentinel_path : String,
) -> Int {
  c_spawn_leader_exited_pgroup_for_test(
    string_to_null_terminated_bytes(pgid_path),
    string_to_null_terminated_bytes(child_path),
    string_to_null_terminated_bytes(sentinel_path),
  )
}

///|
pub fn spawn_nested_sessions_for_test(
  root_path : String,
  child_path : String,
  sentinel_path : String,
) -> Int {
  c_spawn_nested_sessions_for_test(
    string_to_null_terminated_bytes(root_path),
    string_to_null_terminated_bytes(child_path),
    string_to_null_terminated_bytes(sentinel_path),
  )
}

///|
pub fn ignore_sigpipe() -> Bool {
  c_ignore_sigpipe() == 0
}

///|
test "ignore_sigpipe installs ignored SIGPIPE disposition" {
  let saved = c_save_sigpipe_for_test() == 0
  let reset = c_reset_sigpipe_default_for_test() == 0
  let ignored_before = c_sigpipe_ignored_for_test()
  let ignored_result = ignore_sigpipe()
  let ignored_after = c_sigpipe_ignored_for_test()
  ignore(c_restore_sigpipe_for_test())
  assert_true(saved)
  assert_true(reset)
  assert_false(ignored_before != 0)
  assert_true(ignored_result)
  assert_true(ignored_after != 0)
}

///|
/// Register crash-signal handlers that emit `.choir/logs/server-exits.log` before default crash handling.
pub fn install_crash_handlers() -> Unit {
  c_install_crash_handlers()
}

///|
test "server exit log line uses fixed signal timestamp pid format" {
  let max_size = 128
  let buf = Bytes::new(max_size)
  let len = c_build_server_exit_log_line(15, 1747000000, 12345, buf, max_size)
  assert_true(len > 0)
  assert_eq(
    @utf8.decode_lossy(buf[:len]),
    "killed_by=SIG15 sig=15 ts=1747000000 pid=12345\n",
  )
  let crash_buf = Bytes::new(max_size)
  let crash_len = c_build_server_exit_log_line(6, 0, 1, crash_buf, max_size)
  assert_true(crash_len > 0)
  assert_eq(
    @utf8.decode_lossy(crash_buf[:crash_len]),
    "killed_by=SIG6 sig=6 ts=0 pid=1\n",
  )
}

///|
test "server exit append helper writes diagnostic line" {
  let path = "/tmp/choir-server-exit-append-" + get_pid().to_string() + ".log"
  ignore(delete_file_sync(path))
  let rc = c_append_server_exit_log_line(
    string_to_null_terminated_bytes(path),
    15,
    1747000000,
    12345,
  )
  assert_eq(rc, 0)
  assert_eq(read_file(path), "killed_by=SIG15 sig=15 ts=1747000000 pid=12345\n")
  ignore(delete_file_sync(path))
}

///|
test "server exit handlers install signal dispositions without delivery" {
  c_register_cleanup_runtime_artifacts()
  c_install_crash_handlers()
  let installed = c_server_exit_signal_handlers_installed()
  c_reset_server_exit_signal_handlers()
  assert_eq(installed, 1)
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
