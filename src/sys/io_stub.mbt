///| Non-native stubs: Choir targets native; wasm/js builds still type-check this package.

/// Reference @utf8 so `moonbitlang/core/encoding/utf8` is not unused when only this file builds.

///|
pub fn read_file(_path : String) -> String {
  ignore(@utf8.encode(_path).length())
  ""
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
