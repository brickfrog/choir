///|
pub(all) struct ProcessTableEntry {
  pid : Int
  ppid : Int
  cmdline : String
} derive(Debug, Eq)

///|
fn process_table_ppid_from_proc_stat(stat : String) -> Int? {
  let mut close = -1
  for i = 0; i < stat.length(); i = i + 1 {
    if stat[i] == ')' {
      close = i
    }
  }
  if close < 0 || close + 1 >= stat.length() {
    return None
  }
  let rest = stat[close + 1:].trim().to_owned()
  let fields : Array[String] = []
  for raw in rest.split(" ") {
    let field = raw.trim().to_owned()
    if field != "" {
      fields.push(field)
    }
  }
  if fields.length() < 2 {
    return None
  }
  Some(@string.parse_int(fields[1])) catch {
    _ => None
  }
}

///|
fn orphan_choir_mcp_stdio_pids_from_processes(
  processes : Array[ProcessTableEntry],
) -> Array[Int] {
  let pids : Array[Int] = []
  for proc in processes {
    if proc.ppid == 1 &&
      proc.cmdline.contains("choir") &&
      proc.cmdline.contains("mcp-stdio") {
      pids.push(proc.pid)
    }
  }
  pids
}

///|
test "process table stat parser reads ppid after command field" {
  @debug.assert_eq(
    process_table_ppid_from_proc_stat("123 (choir mcp) S 1 2 3"),
    Some(1),
  )
  @debug.assert_eq(
    process_table_ppid_from_proc_stat("124 (name with ) paren) S 77 2 3"),
    Some(77),
  )
  @debug.assert_eq(process_table_ppid_from_proc_stat("bad stat"), None)
}

///|
test "orphan_choir_mcp_stdio_pids_from_processes filters narrowly" {
  let pids = orphan_choir_mcp_stdio_pids_from_processes([
    {
      pid: 11,
      ppid: 1,
      cmdline: "choir\u{0000}mcp-stdio\u{0000}--name\u{0000}a",
    },
    { pid: 12, ppid: 2, cmdline: "choir mcp-stdio --name live-parent" },
    { pid: 13, ppid: 1, cmdline: "choir serve" },
    { pid: 14, ppid: 1, cmdline: "other mcp-stdio" },
    { pid: 15, ppid: 1, cmdline: "/usr/bin/choir --raw-stdio mcp-stdio" },
  ])
  @debug.assert_eq(pids, [11, 15])
}

///|
test "list_orphan_choir_mcp_stdio_pids accepts injected process table" {
  let pids = list_orphan_choir_mcp_stdio_pids(list_processes=fn() {
    [
      { pid: 21, ppid: 1, cmdline: "choir mcp-stdio --name orphan" },
      { pid: 22, ppid: 1, cmdline: "choir serve" },
      { pid: 23, ppid: 9, cmdline: "choir mcp-stdio --name child" },
    ]
  })
  @debug.assert_eq(pids, [21])
}
