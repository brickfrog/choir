///|
#borrow(path)
extern "C" fn uds_server_create_ffi(path : Bytes, len : Int) -> Int = "choir_uds_server_create"

///|
extern "C" fn uds_accept_ffi(server_fd : Int) -> Int = "choir_uds_accept"

///|
extern "C" fn uds_accept_nonblocking_ffi(server_fd : Int) -> Int = "choir_uds_accept_nonblocking"

///|
extern "C" fn uds_fd_has_cloexec_for_test_ffi(fd : Int) -> Int = "choir_uds_fd_has_cloexec_for_test"

///|
#borrow(path)
extern "C" fn uds_unlink_path_for_test_ffi(path : Bytes, len : Int) -> Int = "choir_uds_unlink_path_for_test"

///|
extern "C" fn uds_getpid_for_test_ffi() -> Int = "choir_uds_getpid_for_test"

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
extern "C" fn uds_read_nonblocking_ffi(
  fd : Int,
  buf : Bytes,
  offset : Int,
  len : Int,
) -> Int = "choir_uds_read_nonblocking"

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
extern "C" fn uds_set_nonblocking_ffi(fd : Int) -> Int = "choir_uds_set_nonblocking"

///|
extern "C" fn uds_clear_cloexec_ffi(fd : Int) -> Int = "choir_uds_clear_cloexec"

///|
#borrow(path, body)
extern "C" fn uds_http_post_ffi(
  path : Bytes,
  path_len : Int,
  body : Bytes,
  body_len : Int,
) -> Int = "choir_uds_http_post"

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
pub fn accept_nonblocking(server_fd : Int) -> Int {
  uds_accept_nonblocking_ffi(server_fd)
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
pub fn read_bytes_nonblocking(
  fd : Int,
  buf : FixedArray[Byte],
  offset : Int,
  len : Int,
) -> Int {
  uds_read_nonblocking_ffi(fd, buf.unsafe_reinterpret_as_bytes(), offset, len)
}

///|
pub fn write_bytes(fd : Int, buf : Bytes, offset : Int, len : Int) -> Int {
  uds_write_ffi(fd, buf, offset, len)
}

///|
pub fn set_nonblocking(fd : Int) -> Bool {
  uds_set_nonblocking_ffi(fd) == 0
}

///|
pub fn clear_cloexec(fd : Int) -> Bool {
  uds_clear_cloexec_ffi(fd) == 0
}

///|
pub fn close(fd : Int) -> Unit {
  uds_close_ffi(fd)
}

///|
pub fn http_post(sock_path : String, body : String) -> Int {
  let (path_bytes, path_len) = string_to_null_terminated_bytes(sock_path)
  let body_encoded = @utf8.encode(body)
  uds_http_post_ffi(path_bytes, path_len, body_encoded, body_encoded.length())
}

///|
fn uds_unlink_test_path(path : String) -> Unit {
  let (path_bytes, path_len) = string_to_null_terminated_bytes(path)
  ignore(uds_unlink_path_for_test_ffi(path_bytes, path_len))
}

///|
fn uds_test_socket_path(label : String) -> String {
  "/tmp/choir-uds-" +
  label +
  "-" +
  uds_getpid_for_test_ffi().to_string() +
  ".sock"
}

///|
fn uds_accept_for_cloexec_test(path : String, nonblocking : Bool) -> (Int, Int) {
  uds_unlink_test_path(path)
  let server_fd = server_create(path)
  let listener_flags = if server_fd >= 0 {
    uds_fd_has_cloexec_for_test_ffi(server_fd)
  } else {
    -1
  }
  let set_nonblocking_ok = if nonblocking && server_fd >= 0 {
    set_nonblocking(server_fd)
  } else {
    true
  }
  let client_fd = if server_fd >= 0 && set_nonblocking_ok {
    client_connect(path)
  } else {
    -1
  }
  let accepted_fd = if client_fd >= 0 {
    if nonblocking {
      accept_nonblocking(server_fd)
    } else {
      accept(server_fd)
    }
  } else {
    -1
  }
  let flags = if accepted_fd >= 0 {
    uds_fd_has_cloexec_for_test_ffi(accepted_fd)
  } else {
    -1
  }
  if accepted_fd >= 0 {
    close(accepted_fd)
  }
  if client_fd >= 0 {
    close(client_fd)
  }
  if server_fd >= 0 {
    close(server_fd)
  }
  uds_unlink_test_path(path)
  (listener_flags, flags)
}

///|
test "accepted UDS fd from blocking accept is close-on-exec" {
  let path = uds_test_socket_path("blocking-cloexec")
  let (listener_flags, accepted_flags) = uds_accept_for_cloexec_test(
    path, false,
  )
  assert_eq(listener_flags, 0)
  assert_eq(accepted_flags, 1)
}

///|
test "accepted UDS fd from nonblocking accept is close-on-exec" {
  let path = uds_test_socket_path("nonblocking-cloexec")
  let (listener_flags, accepted_flags) = uds_accept_for_cloexec_test(path, true)
  assert_eq(listener_flags, 0)
  assert_eq(accepted_flags, 1)
}
