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
  buf.to_unchecked_string(offset=0, length=size)
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
