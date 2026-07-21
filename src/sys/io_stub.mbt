///| Non-native stubs: Choir targets native; wasm/js builds still type-check this package.

/// Reference @utf8 so `moonbitlang/core/encoding/utf8` is not unused when only this file builds.

///|
pub fn read_file(_path : String) -> String {
  ignore(@utf8.encode(_path).length())
  ""
}

///|
pub fn read_file_prefix(_path : String, _max_size : Int) -> String {
  ""
}

///|
pub fn list_dir(_path : String) -> Array[String] {
  []
}

///|
pub fn list_dir_all(_path : String) -> Array[String] {
  []
}

///|
pub fn rm_rf(_path : String) -> Bool {
  false
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
pub fn get_parent_env(_name : String) -> String? {
  None
}

///|
pub fn setenv(_name : String, _value : String) -> Bool {
  false
}

///|
pub fn unsetenv(_name : String) -> Bool {
  false
}

///|
pub fn system(_cmd : String) -> Int {
  -1
}

///|
pub fn mint_local_token() -> String? {
  None
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
pub fn sleep_milliseconds(_ms : Int) -> Unit {

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
pub fn rename_file_sync(_from_path : String, _to_path : String) -> Bool {
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
pub fn register_cleanup(_cmd : String) -> Unit {

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
pub fn install_sigusr1_handler() -> Bool {
  false
}

///|
pub fn consume_sigusr1_flag() -> Bool {
  false
}

///|
pub fn raise_sigusr1_for_test() -> Bool {
  false
}

///|
pub fn unblock_sigusr1_for_test() -> Bool {
  false
}

///|
pub fn spawn_sigterm_unblocked_pgroup_for_test(
  _pid_path : String,
  _sidecar_path : String,
  _sentinel_path : String,
) -> Int {
  -1
}

///|
pub fn spawn_leader_exited_pgroup_for_test(
  _pgid_path : String,
  _child_path : String,
  _sentinel_path : String,
) -> Int {
  -1
}

///|
pub fn ignore_sigpipe() -> Bool {
  false
}

///|
pub fn install_crash_handlers() -> Unit {

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
pub fn getppid() -> Int {
  -1
}

///|
pub fn path_exists(_path : String) -> Bool {
  false
}

///|
pub fn file_size(_path : String) -> Int {
  -1
}

///|
pub fn file_mtime_sec(_path : String) -> Int64? {
  None
}

///|
pub fn path_entry_exists(_path : String) -> Bool {
  false
}

///|
pub fn path_executable(_path : String) -> Bool {
  false
}

///|
pub fn kill_pid_best_effort(_pid : Int) -> Unit {

}

///|
pub fn kill_pgid_best_effort(_pgid : Int) -> Unit {

}

///|
pub fn kill_server_pid_sequence_best_effort(_pid : Int) -> Unit {

}

///|
pub fn kill_pgid_sequence_best_effort(_pgid : Int) -> Unit {

}

///|
pub fn wait_pid_reap_for_test(_pid : Int) -> Int {
  -1
}

///|
pub fn pid_is_alive(_pid : Int) -> Bool {
  false
}

///|
pub fn pgid_is_alive(_pgid : Int) -> Bool {
  false
}

///|
pub fn pgid_has_process_identity(
  _pgid : Int,
  _environment_entry : String,
  _command_fragment : String,
) -> Bool {
  false
}

///|
pub fn pgid_has_non_zombie_process(_pgid : Int) -> Bool {
  false
}

///|
pub fn set_parent_death_signal_term() -> Bool {
  false
}

///|
pub fn realpath_native(path : String) -> String? {
  Some(path)
}
