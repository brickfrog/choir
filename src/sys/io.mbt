///|
#borrow(path)
extern "C" fn c_get_file_size(path : Bytes) -> Int = "choir_get_file_size"

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
#borrow(exe)
extern "C" fn c_spawn_serve(exe : Bytes, exe_len : Int) -> Int = "choir_spawn_serve"

///|
#borrow(path)
extern "C" fn c_wait_for_socket(path : Bytes, max_tries : Int) -> Int = "choir_wait_for_socket"

///|
#borrow(cmd)
extern "C" fn c_system(cmd : Bytes) -> Int = "choir_system"

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
#borrow(cmd)
extern "C" fn c_register_cleanup(cmd : Bytes) = "choir_register_cleanup"

///|
pub fn create_dir_all(path : String) -> Bool {
  c_create_dir_all(string_to_null_terminated_bytes(path)) == 0
}

///|
/// Register a shell command to run on SIGTERM/SIGINT before exit.
pub fn register_cleanup(cmd : String) -> Unit {
  c_register_cleanup(string_to_null_terminated_bytes(cmd))
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
