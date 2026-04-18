///|
/// Build the `ClaudeCodeSettings` blob passed via `claude --settings <tempfile>`.
/// Synthesized per-invocation so bare `claude` runs see none of Choir's config.
fn build_claude_settings_json(
  role : @types.Role,
  session_name : String,
) -> String {
  let role_str = @config.role_to_string(role)
  let mcp = {
    "choir": {
      "type": "stdio".to_json(),
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role_str, "--name", session_name].to_json(),
    }.to_json(),
  }
  let settings : Map[String, Json] = {
    "statusLine": {
      "type": "command".to_json(),
      "command": "choir statusline".to_json(),
    }.to_json(),
    "mcpServers": mcp.to_json(),
  }
  settings.to_json().stringify()
}

///|
fn claude_wrapper_tmpdir() -> String {
  match @sys.getenv("TMPDIR") {
    Some(dir) => if dir == "" { "/tmp" } else { dir }
    None => "/tmp"
  }
}

///|
fn claude_wrapper_settings_tempfile_path(
  tmpdir : String,
  pid : Int,
  nanos : Int64,
) -> String {
  tmpdir +
  "/choir-claude-settings-" +
  pid.to_string() +
  "-" +
  nanos.to_string() +
  ".json"
}

///|
fn claude_wrapper_session_name(pid : Int, nanos : Int64) -> String {
  "user-" + pid.to_string() + "-" + nanos.to_string()
}

///|
/// Spawn `claude` with a freshly synthesized `--settings <tempfile>` so statusline and choir MCP
/// wiring only apply to this invocation. Stops polluting project `.claude/settings.json`.
fn claude_wrapper_run() -> Unit {
  let args = @env.args()
  let forward : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    forward.push(args[i])
  }
  let pid = @sys.get_pid()
  let nanos = @env.now().reinterpret_as_int64()
  let tmpdir = claude_wrapper_tmpdir()
  let settings_path = claude_wrapper_settings_tempfile_path(tmpdir, pid, nanos)
  let session_name = claude_wrapper_session_name(pid, nanos)
  let body = build_claude_settings_json(@types.Role::TL, session_name)
  if !@sys.write_file_sync(settings_path, body) {
    @sys.write_stderr(
      "choir claude: failed to write settings tempfile " + settings_path + "\n",
    )
    @sys.exit(1)
    return
  }
  let claude_args : Array[String] = ["--settings", settings_path]
  for a in forward {
    claude_args.push(a)
  }
  let cmd : @workspace.Command = {
    program: "claude",
    args: claude_args,
    workdir: None,
  }
  @async.run_async_main(async fn() {
    let code = @exec.run(cmd) catch { _ => -1 }
    ignore(@sys.rm_rf(settings_path))
    @sys.exit(code)
  })
}

///|
test "build_claude_settings_json emits statusline and choir MCP stdio entry" {
  let body = build_claude_settings_json(@types.Role::TL, "user-123-456")
  let parsed = @json.parse(body) catch {
    _ => {
      fail("settings json did not parse")
      return
    }
  }
  guard parsed is Object(top) else {
    fail("settings json root is not an object")
    return
  }
  guard top.get("statusLine") is Some(Object(status)) else {
    fail("statusLine missing or not an object")
    return
  }
  assert_eq(status.get("type"), Some("command".to_json()))
  assert_eq(status.get("command"), Some("choir statusline".to_json()))
  guard top.get("mcpServers") is Some(Object(servers)) else {
    fail("mcpServers missing or not an object")
    return
  }
  guard servers.get("choir") is Some(Object(choir)) else {
    fail("mcpServers.choir missing or not an object")
    return
  }
  assert_eq(choir.get("type"), Some("stdio".to_json()))
  assert_eq(choir.get("command"), Some("choir".to_json()))
  guard choir.get("args") is Some(Array(args_json)) else {
    fail("mcpServers.choir.args missing or not an array")
    return
  }
  assert_eq(args_json.length(), 5)
  assert_eq(args_json[0], "mcp-stdio".to_json())
  assert_eq(args_json[1], "--role".to_json())
  assert_eq(args_json[2], "tl".to_json())
  assert_eq(args_json[3], "--name".to_json())
  assert_eq(args_json[4], "user-123-456".to_json())
}

///|
test "claude_wrapper_settings_tempfile_path is distinct for distinct inputs" {
  let a = claude_wrapper_settings_tempfile_path("/tmp", 1000, 1L)
  let b = claude_wrapper_settings_tempfile_path("/tmp", 1000, 2L)
  let c = claude_wrapper_settings_tempfile_path("/tmp", 1001, 1L)
  assert_true(a != b)
  assert_true(a != c)
  assert_true(b != c)
  assert_true(a.has_prefix("/tmp/choir-claude-settings-"))
  assert_true(a.has_suffix(".json"))
}

///|
test "claude_wrapper_tmpdir falls back to /tmp when TMPDIR is unset or empty" {
  let dir = claude_wrapper_tmpdir()
  assert_true(dir != "")
}
