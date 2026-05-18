///|
/// Parse an ISO-8601 timestamp string (e.g. "2026-05-18T00:27:59Z") into
/// unix epoch seconds. Returns 0 on parse failure.
pub fn parse_iso8601_to_unix_seconds(raw : String) -> Int64 {
  if raw.length() < 19 {
    return 0L
  }
  let s = raw
  let n4 = fn(off : Int) -> Int64? {
    let mut v = 0L
    for k = 0; k < 4; k = k + 1 {
      let c = s[off + k].to_int()
      if c < 0x30 || c > 0x39 {
        return None
      }
      v = v * 10L + (c - 0x30).to_int64()
    }
    Some(v)
  }
  let n2 = fn(off : Int) -> Int64? {
    let mut v = 0L
    for k = 0; k < 2; k = k + 1 {
      let c = s[off + k].to_int()
      if c < 0x30 || c > 0x39 {
        return None
      }
      v = v * 10L + (c - 0x30).to_int64()
    }
    Some(v)
  }
  let year = match n4(0) {
    Some(v) => v
    None => return 0L
  }
  let month = match n2(5) {
    Some(v) => v
    None => return 0L
  }
  let day = match n2(8) {
    Some(v) => v
    None => return 0L
  }
  let hour = match n2(11) {
    Some(v) => v
    None => return 0L
  }
  let minute = match n2(14) {
    Some(v) => v
    None => return 0L
  }
  let second = match n2(17) {
    Some(v) => v
    None => return 0L
  }
  if month < 1L || month > 12L || day < 1L || day > 31L {
    return 0L
  }
  // Days from civil - Howard Hinnant's algorithm. Inputs in proleptic
  // Gregorian; output is days since 1970-01-01.
  let y = if month <= 2L { year - 1L } else { year }
  let era = if y >= 0L { y / 400L } else { (y - 399L) / 400L }
  let yoe = y - era * 400L
  let m_adj = if month > 2L { month - 3L } else { month + 9L }
  let doy = (153L * m_adj + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  let days = era * 146097L + doe - 719468L
  days * 86400L + hour * 3600L + minute * 60L + second
}
