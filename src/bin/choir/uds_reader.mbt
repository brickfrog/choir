///|
struct UDSLineReader {
  fd : Int
  mut buf : FixedArray[Byte]
  mut read_pos : Int
  mut write_pos : Int
}

///|
fn UDSLineReader::new(fd : Int) -> UDSLineReader {
  { fd, buf: FixedArray::make(8192, (0 : Byte)), read_pos: 0, write_pos: 0 }
}

///|
fn grow_line_buffer(buf : FixedArray[Byte]) -> FixedArray[Byte] {
  let next = FixedArray::make(buf.length() * 2, (0 : Byte))
  for i = 0; i < buf.length(); i = i + 1 {
    next[i] = buf[i]
  }
  next
}

///|
fn UDSLineReader::has_complete_line(self : UDSLineReader) -> Bool {
  let bytes = self.buf.unsafe_reinterpret_as_bytes()
  for index = self.read_pos; index < self.write_pos; index = index + 1 {
    if bytes[index] == (10 : Byte) {
      return true
    }
  }
  false
}

///|
fn UDSLineReader::read_line(self : UDSLineReader) -> String {
  for ;; {
    let bytes = self.buf.unsafe_reinterpret_as_bytes()
    for i = self.read_pos; i < self.write_pos; i = i + 1 {
      if bytes[i] == (10 : Byte) {
        let line = @utf8.decode_lossy(bytes[self.read_pos:i])
        self.read_pos = i + 1
        return line
      }
    }

    if self.read_pos > 0 {
      let remaining = self.write_pos - self.read_pos
      if remaining > 0 {
        for i = 0; i < remaining; i = i + 1 {
          self.buf[i] = self.buf[self.read_pos + i]
        }
      }
      self.write_pos = remaining
      self.read_pos = 0
    }

    if self.write_pos == self.buf.length() {
      self.buf = grow_line_buffer(self.buf)
    }

    let n = @uds.read_bytes(
      self.fd,
      self.buf,
      self.write_pos,
      self.buf.length() - self.write_pos,
    )
    if n <= 0 {
      if self.write_pos > self.read_pos {
        let line = @utf8.decode_lossy(bytes[self.read_pos:self.write_pos])
        self.read_pos = self.write_pos
        return line
      }
      return ""
    }
    self.write_pos = self.write_pos + n
  }
}

///|
test "UDS line reader exposes complete frames already in its buffer" {
  let reader = UDSLineReader::new(-1)
  let buffered = @utf8.encode("response\nnotification\n")
  for index = 0; index < buffered.length(); index = index + 1 {
    reader.buf[index] = buffered[index]
  }
  reader.write_pos = buffered.length()
  assert_true(reader.has_complete_line())
  assert_eq(reader.read_line(), "response")
  assert_true(reader.has_complete_line())
  assert_eq(reader.read_line(), "notification")
  assert_false(reader.has_complete_line())
}
