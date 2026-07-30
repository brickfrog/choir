///|
test "strip_terminal_responses removes OSC replies and keeps SGR" {
  let raw = "before \u{1b}[31mred\u{1b}[0m \u{1b}]11;rgb:0a0a/0f0f/1414\u{1b}\\after"
  let got = @terminal.strip_terminal_responses(raw)
  assert_eq(got, "before \u{1b}[31mred\u{1b}[0m after")
}

///|
test "strip_terminal_responses removes BEL terminated OSC replies" {
  let raw = "a\u{1b}]10;rgb:ffff/ffff/ffff\u{07}b\u{1b}]4;2;rgb:0000/1111/2222\u{07}c"
  assert_eq(@terminal.strip_terminal_responses(raw), "abc")
}

///|
test "strip_terminal_responses removes CSI Primary DA replies" {
  assert_eq(@terminal.strip_terminal_responses("x\u{1b}[?62;4;52cy"), "xy")
}

///|
test "strip_terminal_responses removes CSI Cursor Position Reports" {
  assert_eq(@terminal.strip_terminal_responses("x\u{1b}[61;1Ry"), "xy")
}

///|
test "strip_terminal_responses preserves unknown escapes and normal text" {
  let raw = "plain \u{1b}[?25l hidden \u{1b}[32mgreen\u{1b}[0m"
  assert_eq(@terminal.strip_terminal_responses(raw), raw)
}

///|
test "strip_terminal_responses leaves normal text unchanged" {
  assert_eq(
    @terminal.strip_terminal_responses("plain log line"),
    "plain log line",
  )
}
