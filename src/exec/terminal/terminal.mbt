///|
fn is_digit(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn osc_end(s : String, start : Int) -> Int? {
  let n = s.length()
  if start + 3 >= n || s[start] != '\u{1b}' || s[start + 1] != ']' {
    return None
  }
  let payload = if s[start + 2] == '4' && s[start + 3] == ';' {
    start + 4
  } else if start + 4 < n &&
    s[start + 2] == '1' &&
    (s[start + 3] == '0' || s[start + 3] == '1') &&
    s[start + 4] == ';' {
    start + 5
  } else {
    return None
  }
  let mut j = payload
  while j < n {
    if s[j] == '\u{07}' {
      return Some(j + 1)
    }
    if j + 1 < n && s[j] == '\u{1b}' && s[j + 1] == '\\' {
      return Some(j + 2)
    }
    j = j + 1
  }
  None
}

///|
fn response_end(s : String, start : Int) -> Int? {
  match osc_end(s, start) {
    Some(e) => Some(e)
    None => {
      let n = s.length()
      if start + 3 < n &&
        s[start] == '\u{1b}' &&
        s[start + 1] == '[' &&
        s[start + 2] == '?' {
        let mut j = start + 3
        let mut digit = false
        while j < n && (is_digit(s[j]) || s[j] == ';') {
          if is_digit(s[j]) {
            digit = true
          }
          j = j + 1
        }
        if digit && j < n && s[j] == 'c' {
          return Some(j + 1)
        }
      }
      if start + 4 < n && s[start] == '\u{1b}' && s[start + 1] == '[' {
        let mut j = start + 2
        let row = j
        while j < n && is_digit(s[j]) {
          j = j + 1
        }
        if j > row && j < n && s[j] == ';' {
          j = j + 1
          let col = j
          while j < n && is_digit(s[j]) {
            j = j + 1
          }
          if j > col && j < n && s[j] == 'R' {
            return Some(j + 1)
          }
        }
      }
      None
    }
  }
}

///|
pub fn strip_terminal_responses(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < s.length() {
    if s[i] == '\u{1b}' {
      match response_end(s, i) {
        Some(e) => {
          i = e
          continue
        }
        None => ()
      }
    }
    buf.write_char(Int::unsafe_to_char(s[i].to_int()))
    i = i + 1
  }
  buf.to_string()
}
