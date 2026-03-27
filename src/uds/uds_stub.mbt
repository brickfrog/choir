///| Non-native stubs: UDS is native-only; stubs satisfy wasm/js package graph.

///|
pub fn server_create(_path : String) -> Int {
  -1
}

///|
pub fn accept(_server_fd : Int) -> Int {
  -1
}

///|
pub fn accept_nonblocking(_server_fd : Int) -> Int {
  -1
}

///|
pub fn client_connect(_path : String) -> Int {
  -1
}

///|
pub fn read_bytes(
  _fd : Int,
  _buf : FixedArray[Byte],
  _offset : Int,
  _len : Int,
) -> Int {
  -1
}

///|
pub fn read_bytes_nonblocking(
  _fd : Int,
  _buf : FixedArray[Byte],
  _offset : Int,
  _len : Int,
) -> Int {
  -1
}

///|
pub fn write_bytes(_fd : Int, _buf : Bytes, _offset : Int, _len : Int) -> Int {
  -1
}

///|
pub fn set_nonblocking(_fd : Int) -> Bool {
  false
}

///|
pub fn close(_fd : Int) -> Unit {
  ignore(_fd)
}

///|
pub fn http_post(_sock_path : String, _body : String) -> Int {
  -1
}
