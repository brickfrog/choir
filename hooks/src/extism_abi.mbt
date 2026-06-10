///|
priv struct HostMemory {
  offset : Int64
  length : Int64
}

///|
fn extism_input_length() -> Int64 = "extism:host/env" "input_length"

///|
fn extism_input_load_u8(offset : Int64) -> Byte = "extism:host/env" "input_load_u8"

///|
fn extism_length(offset : Int64) -> Int64 = "extism:host/env" "length"

///|
fn extism_alloc(length : Int64) -> Int64 = "extism:host/env" "alloc"

///|
fn extism_free(offset : Int64) = "extism:host/env" "free"

///|
fn extism_output_set(offset : Int64, length : Int64) = "extism:host/env" "output_set"

///|
fn extism_config_get(offset : Int64) -> Int64 = "extism:host/env" "config_get"

///|
fn extism_store_u8(offset : Int64, byte : Byte) = "extism:host/env" "store_u8"

///|
fn extism_load_u8(offset : Int64) -> Byte = "extism:host/env" "load_u8"

///|
fn host_read_bytes(offset : Int64, length : Int64) -> Bytes {
  let bytes = FixedArray::makei(length.to_int(), fn(i) {
    extism_load_u8(offset + i.to_int64())
  })
  Bytes::from_array(bytes)
}

///|
fn host_write_bytes(bytes : Bytes) -> HostMemory {
  let length = bytes.length().to_int64()
  let offset = extism_alloc(length)
  for i = 0; i < length.to_int(); i = i + 1 {
    extism_store_u8(offset + i.to_int64(), bytes[i])
  }
  { offset, length }
}

///|
fn host_input_string() -> String {
  let length = extism_input_length()
  let bytes = FixedArray::makei(length.to_int(), fn(i) {
    extism_input_load_u8(i.to_int64())
  })
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
fn host_output_string(output : String) -> Unit {
  let mem = host_write_bytes(@utf8.encode(output))
  extism_output_set(mem.offset, mem.length)
}

///|
fn host_config_get(key : String) -> String? {
  let key_mem = host_write_bytes(@utf8.encode(key))
  let offset = extism_config_get(key_mem.offset)
  extism_free(key_mem.offset)
  if offset == 0L {
    return None
  }
  let length = extism_length(offset)
  if length == 0L {
    return None
  }
  let value = host_read_bytes(offset, length)
  extism_free(offset)
  Some(@utf8.decode_lossy(value))
}
