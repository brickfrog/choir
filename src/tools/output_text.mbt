///|
fn collapse_cr_progress(s : String) -> String {
  let out = StringBuilder::new()
  let mut line_start = 0
  let mut last_cr = -1
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == '\r' {
      last_cr = i
    } else if s[i] == '\n' {
      if last_cr >= line_start {
        out.write_string(s[last_cr + 1:i].to_owned())
      } else {
        out.write_string(s[line_start:i].to_owned())
      }
      out.write_char('\n')
      line_start = i + 1
      last_cr = -1
    }
  }
  if last_cr >= line_start {
    out.write_string(s[last_cr + 1:s.length()].to_owned())
  } else {
    out.write_string(s[line_start:s.length()].to_owned())
  }
  out.to_string()
}

///|
test "collapse_cr_progress keeps final carriage-return frame per line" {
  let raw = "compiling\n[>      ] 1/319\r[==>    ] 50/319\r[======] 319/319 done\nAll tests passed"
  assert_eq(
    collapse_cr_progress(raw),
    "compiling\n[======] 319/319 done\nAll tests passed",
  )
}

///|
test "collapse_cr_progress preserves lines without carriage returns" {
  let raw = "alpha\nbeta\n"
  assert_eq(collapse_cr_progress(raw), raw)
}
