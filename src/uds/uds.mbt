///|
#borrow(path)
extern "C" fn uds_server_create_ffi(path : Bytes, len : Int) -> Int = "choir_uds_server_create"

///|
extern "C" fn uds_accept_ffi(server_fd : Int) -> Int = "choir_uds_accept"

///|
#borrow(path)
extern "C" fn uds_client_connect_ffi(path : Bytes, len : Int) -> Int = "choir_uds_client_connect"

///|
#borrow(buf)
extern "C" fn uds_read_ffi(
  fd : Int,
  buf : Bytes,
  offset : Int,
  len : Int,
) -> Int = "choir_uds_read"

///|
#borrow(buf)
extern "C" fn uds_write_ffi(
  fd : Int,
  buf : Bytes,
  offset : Int,
  len : Int,
) -> Int = "choir_uds_write"

///|
extern "C" fn uds_close_ffi(fd : Int) = "choir_uds_close"

///|
fn string_to_null_terminated_bytes(s : String) -> (Bytes, Int) {
  let encoded = @utf8.encode(s)
  let len = encoded.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = encoded[i]
  }
  result[len] = (0 : Byte)
  (result.unsafe_reinterpret_as_bytes(), len)
}

///|
pub fn server_create(path : String) -> Int {
  let (path_bytes, len) = string_to_null_terminated_bytes(path)
  uds_server_create_ffi(path_bytes, len)
}

///|
pub fn accept(server_fd : Int) -> Int {
  uds_accept_ffi(server_fd)
}

///|
pub fn client_connect(path : String) -> Int {
  let (path_bytes, len) = string_to_null_terminated_bytes(path)
  uds_client_connect_ffi(path_bytes, len)
}

///|
pub fn read_bytes(
  fd : Int,
  buf : FixedArray[Byte],
  offset : Int,
  len : Int,
) -> Int {
  uds_read_ffi(fd, buf.unsafe_reinterpret_as_bytes(), offset, len)
}

///|
pub fn write_bytes(fd : Int, buf : Bytes, offset : Int, len : Int) -> Int {
  uds_write_ffi(fd, buf, offset, len)
}

///|
pub fn close(fd : Int) -> Unit {
  uds_close_ffi(fd)
}
