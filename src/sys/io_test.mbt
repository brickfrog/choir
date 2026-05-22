///|
test "list_choir_mcp_stdio_pids_for_agent accepts injected process table" {
  let pids = list_choir_mcp_stdio_pids_for_agent(
    "main.audit-on-file-pr-abc-1",
    list_processes=fn() {
      [
        {
          pid: 41,
          ppid: 9,
          cmdline: "choir mcp-stdio --name main.audit-on-file-pr-abc-1",
        },
        {
          pid: 42,
          ppid: 9,
          cmdline: "choir mcp-stdio --name main.audit-on-file-pr-abc-12",
        },
      ]
    },
  )
  @debug.assert_eq(pids, [41])
}
