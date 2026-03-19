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
extern "C" fn c_stdout_write(buf : Bytes, size : Int) = "choir_stdout_write"

///|
extern "C" fn c_exit(code : Int) = "choir_exit"

///|
extern "C" fn c_argc() -> Int = "choir_argc"

///|
#borrow(out)
extern "C" fn c_argv_get(n : Int, out : Bytes, out_size : Int) -> Int = "choir_argv_get"

///|
extern "C" fn c_getpid() -> Int = "choir_getpid"

///|
#borrow(buf)
extern "C" fn c_getcwd(buf : Bytes, buf_size : Int) -> Int = "choir_getcwd"

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
pub fn read_stdin_line(max_size : Int) -> (Bytes, Int) {
  let buf = Bytes::new(max_size)
  let len = c_stdin_read_line(buf, max_size)
  (buf, len)
}

///|
pub fn exit(code : Int) -> Unit {
  c_exit(code)
}

///|
pub fn get_args() -> Array[String] {
  let count = c_argc()
  let args : Array[String] = []
  for i = 0; i < count; i = i + 1 {
    let buf = Bytes::new(4096)
    let len = c_argv_get(i, buf, 4096)
    if len > 0 {
      args.push(@utf8.decode_lossy(buf[:len]))
    }
  }
  args
}

///|
pub fn get_pid() -> Int {
  c_getpid()
}

///|
pub fn write_pid_file(path : String) -> Unit {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_write_pid_file(path_bytes)
}

///|
pub fn system(cmd : String) -> Int {
  let bytes = string_to_null_terminated_bytes(cmd)
  c_system(bytes)
}

///|
/// Spawn `<self_exe> serve` as a detached background daemon.
pub fn spawn_serve(self_exe : String) -> Bool {
  let exe_bytes = string_to_null_terminated_bytes(self_exe)
  c_spawn_serve(exe_bytes, exe_bytes.length() - 1) == 0
}

///|
/// Poll for a socket file to appear (200ms intervals). Returns true if found.
pub fn wait_for_socket(path : String, max_tries : Int) -> Bool {
  let path_bytes = string_to_null_terminated_bytes(path)
  c_wait_for_socket(path_bytes, max_tries) == 0
}

///|
pub fn getcwd() -> String {
  let buf = Bytes::new(4096)
  let len = c_getcwd(buf, 4096)
  if len <= 0 {
    return "."
  }
  @utf8.decode_lossy(buf[:len])
}
