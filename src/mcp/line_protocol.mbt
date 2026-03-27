///|
pub fn read_line_from_bytes(buf : Bytes, offset : Int) -> (String, Int)? {
  let len = buf.length()
  for i = offset; i < len; i = i + 1 {
    if buf[i] == (10 : Byte) { // '\n'
      let line_len = i - offset
      let sb = StringBuilder::new()
      for j = 0; j < line_len; j = j + 1 {
        let b = buf[offset + j]
        if b != (0 : Byte) {
          sb.write_char(Int::unsafe_to_char(b.to_int()))
        }
      }
      let mut next_offset = i + 1
      if next_offset < len && buf[next_offset] == (0 : Byte) {
        next_offset = next_offset + 1
      }
      return Some((sb.to_string(), next_offset))
    }
  }
  None
}

///|
pub fn response_to_bytes(resp : JsonRpcResponse) -> Bytes {
  let body = resp.to_json_string() + "\n"
  let body_len = @utf8.encode(body).length()
  let framed = "Content-Length: " + body_len.to_string() + "\r\n\r\n" + body
  @utf8.encode(framed)
}
