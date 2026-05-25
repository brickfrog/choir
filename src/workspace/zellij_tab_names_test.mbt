///|
test "zellij_tab_names_in_query_output drops empty lines" {
  @debug.assert_eq(
    @workspace.zellij_tab_names_in_query_output("\nServer\n\nTL\n"),
    ["Server", "TL"],
  )
}

///|
test "zellij_tab_names_in_query_output strips ansi" {
  let esc = "\u{1b}[32m"
  let reset = "\u{1b}[0m"
  let out = "Server\n" + esc + "TL" + reset + "\n"
  @debug.assert_eq(@workspace.zellij_tab_names_in_query_output(out), [
    "Server", "TL",
  ])
}
