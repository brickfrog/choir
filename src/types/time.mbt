///|
fn parse_n_digits(s : String, off : Int, count : Int) -> Int64? {
  let mut v = 0L
  for k = 0; k < count; k = k + 1 {
    let c = s[off + k].to_int()
    if c < 0x30 || c > 0x39 {
      return None
    }
    v = v * 10L + (c - 0x30).to_int64()
  }
  Some(v)
}

///|
fn has_char_at(s : String, off : Int, code : Int) -> Bool {
  s[off].to_int() == code
}

///|
fn is_leap_year(year : Int64) -> Bool {
  (year % 4L == 0L && year % 100L != 0L) || year % 400L == 0L
}

///|
fn days_in_month(year : Int64, month : Int64) -> Int64 {
  if month == 2L {
    if is_leap_year(year) {
      29L
    } else {
      28L
    }
  } else if month == 4L || month == 6L || month == 9L || month == 11L {
    30L
  } else {
    31L
  }
}

///|
pub fn non_negative_i64(value : Int64) -> Int64 {
  if value < 0L {
    0L
  } else {
    value
  }
}

///|
/// Parse GitHub's canonical UTC timestamp layout (`YYYY-MM-DDTHH:MM:SSZ`)
/// into unix epoch seconds. This is not a general ISO-8601 parser: offsets,
/// fractional seconds, and non-UTC suffixes return `None`.
pub fn parse_iso8601_to_unix_seconds_opt(raw : String) -> Int64? {
  if raw.length() != 20 {
    return None
  }
  if !has_char_at(raw, 4, 0x2d) ||
    !has_char_at(raw, 7, 0x2d) ||
    !has_char_at(raw, 10, 0x54) ||
    !has_char_at(raw, 13, 0x3a) ||
    !has_char_at(raw, 16, 0x3a) ||
    !has_char_at(raw, 19, 0x5a) {
    return None
  }
  let year = match parse_n_digits(raw, 0, 4) {
    Some(v) => v
    None => return None
  }
  let month = match parse_n_digits(raw, 5, 2) {
    Some(v) => v
    None => return None
  }
  let day = match parse_n_digits(raw, 8, 2) {
    Some(v) => v
    None => return None
  }
  let hour = match parse_n_digits(raw, 11, 2) {
    Some(v) => v
    None => return None
  }
  let minute = match parse_n_digits(raw, 14, 2) {
    Some(v) => v
    None => return None
  }
  let second = match parse_n_digits(raw, 17, 2) {
    Some(v) => v
    None => return None
  }
  if month < 1L || month > 12L {
    return None
  }
  if day < 1L || day > days_in_month(year, month) {
    return None
  }
  if hour < 0L ||
    hour > 23L ||
    minute < 0L ||
    minute > 59L ||
    second < 0L ||
    second > 59L {
    return None
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
  Some(days * 86400L + hour * 3600L + minute * 60L + second)
}

///|
/// Parse GitHub's canonical UTC timestamp layout (`YYYY-MM-DDTHH:MM:SSZ`)
/// into unix epoch seconds. Returns 0 on parse failure for older callers that
/// use 0 as an "unknown timestamp" sentinel.
pub fn parse_iso8601_to_unix_seconds(raw : String) -> Int64 {
  match parse_iso8601_to_unix_seconds_opt(raw) {
    Some(v) => v
    None => 0L
  }
}
