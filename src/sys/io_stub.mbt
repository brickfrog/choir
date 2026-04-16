///| Non-native stubs: Choir targets native; wasm/js builds still type-check this package.

/// Reference @utf8 so `moonbitlang/core/encoding/utf8` is not unused when only this file builds.

///|
pub fn read_file(_path : String) -> String {
  ignore(@utf8.encode(_path).length())
  ""
}

///|
pub fn list_dir(_path : String) -> Array[String] {
  []
}

///|
pub fn write_stdout(_s : String) -> Unit {

}

///|
pub fn write_stdout_bytes(_b : Bytes) -> Unit {

}

///|
pub fn write_stderr(_s : String) -> Unit {

}

///|
pub fn read_stdin_line(_max_size : Int) -> String? {
  None
}

///|
pub fn read_stdin_exact(_size : Int) -> Bytes? {
  None
}

///|
pub fn exit(_code : Int) -> Unit {

}

///|
pub fn get_pid() -> Int {
  -1
}

///|
pub fn write_pid_file(_path : String) -> Unit {

}

///|
pub fn getenv(_name : String) -> String? {
  None
}

///|
pub fn system(_cmd : String) -> Int {
  -1
}

///|
pub fn spawn_serve(_self_exe : String) -> Bool {
  false
}

///|
pub fn wait_for_socket(_path : String, _max_tries : Int) -> Bool {
  false
}

///|
pub fn redirect_stderr_append(_path : String) -> Bool {
  false
}

///|
pub fn write_file_sync(_path : String, _content : String) -> Bool {
  false
}

///|
pub fn write_file_atomic(_path : String, _content : String) -> Bool {
  false
}

///|
pub fn append_file_sync(_path : String, _content : String) -> Bool {
  false
}

///|
pub fn delete_file_sync(_path : String) -> Bool {
  false
}

///|
pub fn spawn_zellij_pane_viewport_subscribe(
  _session : String,
  _pane_id : String,
  _snapshot_path : String,
) -> Int {
  -1
}

///|
pub fn register_cleanup(_cmd : String) -> Unit {

}

///|
pub fn worktree_bootstrap_cleanup_native(
  _project_dir : String,
  _workspace : String,
  _branch : String,
) -> Unit {

}

///|
pub fn git_fetch_origin_branch_best_effort_native(
  _project_dir : String,
  _branch : String,
) -> Unit {

}

///|
pub fn init_cleanup_runtime_artifacts_native() -> Unit {

}

///|
pub fn init_cleanup_purge_artifacts_native() -> Unit {

}

///|
pub fn register_cleanup_runtime_artifacts() -> Unit {

}

///|
pub fn create_dir_all(_path : String) -> Bool {
  false
}

///|
pub fn chmod_mode(_path : String, _mode : Int) -> Bool {
  false
}

///|
pub fn symlink_force(_target : String, _linkpath : String) -> Bool {
  false
}

///|
pub fn shell_quote(_s : String) -> String {
  "''"
}

///|
pub fn path_exists(_path : String) -> Bool {
  false
}

///|
pub fn path_entry_exists(_path : String) -> Bool {
  false
}

///|
pub fn kill_pid_best_effort(_pid : Int) -> Unit {

}

///|
pub fn kill_server_pid_sequence_best_effort(_pid : Int) -> Unit {

}

///|
pub fn pid_is_alive(_pid : Int) -> Bool {
  false
}

///|
pub fn realpath_native(path : String) -> String? {
  Some(path)
}
