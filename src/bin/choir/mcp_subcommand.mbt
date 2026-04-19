///|
pub(all) enum McpTransport {
  Stdio
} derive(Debug, Eq)

///|
pub(all) struct McpServer {
  transport : McpTransport
  command : String
  args : Array[String]
}

///|
fn mcp_transport_to_string(transport : McpTransport) -> String {
  match transport {
    Stdio => "stdio"
  }
}

///|
fn show_json_parse_error(e : @json.ParseError) -> String {
  let buf = StringBuilder::new()
  buf.write_object(e)
  buf.to_string()
}

///|
/// Run `choir mcp <add|list|remove>`.
pub fn mcp_subcommand_run() -> Unit {
  let args = @env.args()
  let subcmd = if args.length() >= 3 { args[2] } else { "" }
  match subcmd {
    "add" => add_mcp(args)
    "list" => list_mcp()
    "remove" => remove_mcp(args)
    "--help" | "-h" | "" => print_mcp_help()
    _ => {
      @sys.write_stderr("choir mcp: unknown command '" + subcmd + "'\n")
      @sys.exit(1)
    }
  }
}

///|
fn print_mcp_help() -> Unit {
  @sys.write_stdout(
    (
      #|Usage: choir mcp <add|list|remove>
      #|
      #|Commands:
      #|  add <name> -- <command> [args...]   Register a user MCP server
      #|  list                                Show built-in + user MCP servers
      #|  remove <name>                       Delete a user MCP server
      #|
      #|Example:
      #|  choir mcp add linear -- npx -y @linear/mcp-server
      #|
    ),
  )
}

///|
fn add_mcp(args : Array[String]) -> Unit {
  if args.length() >= 4 && (args[3] == "--help" || args[3] == "-h") {
    @sys.write_stdout(
      (
        #|Usage: choir mcp add <name> -- <command> [args...]
        #|
        #|  Register a user MCP server.
        #|
        #|Example:
        #|  choir mcp add linear -- npx -y @linear/mcp-server
        #|
      ),
    )
    return
  }
  if args.length() < 6 || args[4] != "--" {
    @sys.write_stderr("usage: choir mcp add <name> -- <command> [args...]\n")
    @sys.exit(1)
    return
  }
  let name = args[3]
  let command = args[5]
  let srv_args : Array[String] = []
  for i = 6; i < args.length(); i = i + 1 {
    srv_args.push(args[i])
  }

  let mcp_path = match user_mcp_json_path() {
    Ok(p) => p
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }

  match user_config_home() {
    Ok(d) => ignore(@sys.create_dir_all(d))
    Err(_) => ()
  }

  match add_mcp_inner(mcp_path, name, command, srv_args) {
    Ok(_) => ()
    Err(e) => {
      @sys.write_stderr(e.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
fn add_mcp_inner(
  mcp_path : String,
  name : String,
  command : String,
  srv_args : Array[String],
) -> Result[Unit, @types.ChoirError] {
  if name == "choir" {
    return Err(
      @types.ChoirError::validation_error(
        "choir mcp: cannot add builtin 'choir' server",
      ),
    )
  }

  let mut current_servers : Map[String, McpServer] = {}
  if @sys.path_exists(mcp_path) {
    let content = @sys.read_file(mcp_path)
    if content != "" {
      match parse_mcp_config_json(content) {
        Ok(m) => current_servers = m
        Err(e) =>
          return Err(
            @types.ChoirError::config_error(
              "error parsing " + mcp_path + ": " + e.message(),
            ),
          )
      }
    }
  }

  current_servers.set(name, { transport: Stdio, command, args: srv_args })

  let servers_obj : Map[String, Json] = {}
  for k, v in current_servers {
    let srv_obj : Map[String, Json] = {
      "type": mcp_transport_to_string(v.transport).to_json(),
      "command": v.command.to_json(),
    }
    let args_json : Array[Json] = []
    for a in v.args {
      args_json.push(a.to_json())
    }
    srv_obj.set("args", args_json.to_json())
    servers_obj.set(k, srv_obj.to_json())
  }
  let root : Map[String, Json] = { "servers": servers_obj.to_json() }

  if !@sys.write_file_sync(mcp_path, root.to_json().stringify()) {
    return Err(@types.ChoirError::config_error("error writing " + mcp_path))
  }

  Ok(())
}

///|
fn list_mcp() -> Unit {
  let args = @env.args()
  if args.length() >= 4 && (args[3] == "--help" || args[3] == "-h") {
    @sys.write_stdout(
      (
        #|Usage: choir mcp list
        #|
        #|  Show built-in and user MCP servers.
        #|
        #|Example:
        #|  choir mcp list
        #|
      ),
    )
    return
  }
  @sys.write_stdout("builtin:\n")
  @sys.write_stdout(
    "  choir      — choir mcp-stdio --role <role> --name <session>\n",
  )

  let mcp_path = match user_mcp_json_path() {
    Ok(p) => p
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }

  if @sys.path_exists(mcp_path) {
    let content = @sys.read_file(mcp_path)
    if content != "" {
      match parse_mcp_config_json(content) {
        Ok(servers) => {
          let keys : Array[String] = []
          for k, _ in servers {
            keys.push(k)
          }
          keys.sort()
          if keys.length() > 0 {
            @sys.write_stdout("user:\n")
            for k in keys {
              match servers.get(k) {
                Some(v) => {
                  let args_str = if v.args.length() > 0 {
                    " " + v.args.join(" ")
                  } else {
                    ""
                  }
                  let cmd_str = v.command + args_str
                  @sys.write_stdout("  " + k + "     — " + cmd_str + "\n")
                }
                None => ()
              }
            }
          }
        }
        Err(e) => {
          @sys.write_stderr(
            "error parsing " + mcp_path + ": " + e.message() + "\n",
          )
          @sys.exit(1)
        }
      }
    }
  }
}

///|
fn remove_mcp(args : Array[String]) -> Unit {
  if args.length() >= 4 && (args[3] == "--help" || args[3] == "-h") {
    @sys.write_stdout(
      (
        #|Usage: choir mcp remove <name>
        #|
        #|  Delete a user MCP server.
        #|
        #|Example:
        #|  choir mcp remove linear
        #|
      ),
    )
    return
  }
  if args.length() < 4 {
    @sys.write_stderr("usage: choir mcp remove <name>\n")
    @sys.exit(1)
    return
  }
  let name = args[3]

  let mcp_path = match user_mcp_json_path() {
    Ok(p) => p
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }

  match remove_mcp_inner(mcp_path, name) {
    Ok(_) => ()
    Err(e) => {
      @sys.write_stderr(e.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
fn remove_mcp_inner(
  mcp_path : String,
  name : String,
) -> Result[Unit, @types.ChoirError] {
  if name == "choir" {
    return Err(
      @types.ChoirError::validation_error(
        "choir mcp: cannot remove builtin 'choir' server",
      ),
    )
  }

  if !@sys.path_exists(mcp_path) {
    return Err(
      @types.ChoirError::validation_error(
        "choir mcp: user entry does not exist",
      ),
    )
  }

  let content = @sys.read_file(mcp_path)
  if content == "" {
    return Err(
      @types.ChoirError::validation_error(
        "choir mcp: user entry does not exist",
      ),
    )
  }

  let mut current_servers : Map[String, McpServer] = {}
  match parse_mcp_config_json(content) {
    Ok(m) => current_servers = m
    Err(e) =>
      return Err(
        @types.ChoirError::config_error(
          "error parsing " + mcp_path + ": " + e.message(),
        ),
      )
  }

  if !current_servers.contains(name) {
    return Err(
      @types.ChoirError::validation_error(
        "choir mcp: user entry does not exist",
      ),
    )
  }

  current_servers.remove(name)

  let servers_obj : Map[String, Json] = {}
  for k, v in current_servers {
    let srv_obj : Map[String, Json] = {
      "type": mcp_transport_to_string(v.transport).to_json(),
      "command": v.command.to_json(),
    }
    let args_json : Array[Json] = []
    for a in v.args {
      args_json.push(a.to_json())
    }
    srv_obj.set("args", args_json.to_json())
    servers_obj.set(k, srv_obj.to_json())
  }
  let root : Map[String, Json] = { "servers": servers_obj.to_json() }

  if !@sys.write_file_sync(mcp_path, root.to_json().stringify()) {
    return Err(@types.ChoirError::config_error("error writing " + mcp_path))
  }

  Ok(())
}

///|
pub fn parse_mcp_config_json(
  s : String,
) -> Result[Map[String, McpServer], @types.ChoirError] {
  let parsed = @json.parse(s) catch {
    e =>
      return Err(
        @types.ChoirError::config_error(
          "malformed JSON in mcp config: " + show_json_parse_error(e),
        ),
      )
  }
  guard parsed is Json::Object(top) else {
    return Err(
      @types.ChoirError::config_error("mcp config root must be an object"),
    )
  }
  guard top.get("servers") is Some(Json::Object(s_obj)) else {
    return Err(
      @types.ChoirError::config_error("missing or invalid .servers object"),
    )
  }
  let result : Map[String, McpServer] = {}
  for k, v in s_obj {
    guard v is Json::Object(srv) else {
      return Err(
        @types.ChoirError::config_error(
          "server entry " + k + " must be an object",
        ),
      )
    }
    let transport = match srv.get("type") {
      Some(Json::String("stdio")) => McpTransport::Stdio
      Some(Json::String(t)) =>
        return Err(
          @types.ChoirError::config_error(
            "server " + k + " has unsupported type " + t,
          ),
        )
      _ =>
        return Err(
          @types.ChoirError::config_error(
            "server " + k + " missing or invalid type",
          ),
        )
    }
    let command = match srv.get("command") {
      Some(Json::String(c)) => c
      _ =>
        return Err(
          @types.ChoirError::config_error(
            "server " + k + " missing or invalid command",
          ),
        )
    }
    let args : Array[String] = []
    match srv.get("args") {
      Some(Json::Array(arr)) =>
        for a in arr {
          match a {
            Json::String(sa) => args.push(sa)
            _ =>
              return Err(
                @types.ChoirError::config_error(
                  "server " + k + " args must be strings",
                ),
              )
          }
        }
      Some(_) =>
        return Err(
          @types.ChoirError::config_error(
            "server " + k + " args must be an array",
          ),
        )
      None => ()
    }
    result.set(k, { transport, command, args })
  }
  Ok(result)
}

///|
pub fn merge_mcp_maps(
  builtin : Map[String, Json],
  user : Map[String, Json],
) -> Result[Map[String, Json], @types.ChoirError] {
  let result : Map[String, Json] = {}
  for k, v in builtin {
    result.set(k, v)
  }
  for k, v in user {
    if k == "choir" {
      return Err(
        @types.ChoirError::config_error(
          "user mcp server 'choir' clashes with builtin",
        ),
      )
    }
    result.set(k, v)
  }
  Ok(result)
}

///|
test "add_mcp_inner writes new server to empty file" {
  let tmp = "/tmp/choir-mcp-add-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let path = tmp + "/mcp.json"

  let res = add_mcp_inner(path, "linear", "npx", ["-y", "@linear/mcp-server"])
  match res {
    Ok(_) => ()
    Err(e) => fail("unexpected err: " + e.message())
  }

  let content = @sys.read_file(path)
  let m = parse_mcp_config_json(content).unwrap()
  let srv = m.get("linear").unwrap()
  assert_eq(srv.command, "npx")

  ignore(@sys.rm_rf(tmp))
}

///|
test "add_mcp_inner rejects choir" {
  let res = add_mcp_inner("/some/path", "choir", "cmd", [])
  match res {
    Err(e) => assert_true(e.message().contains("builtin 'choir' server"))
    Ok(_) => fail("expected err")
  }
}

///|
test "remove_mcp_inner removes server" {
  let tmp = "/tmp/choir-mcp-rm-" + @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let path = tmp + "/mcp.json"

  ignore(add_mcp_inner(path, "linear", "npx", []))

  let res = remove_mcp_inner(path, "linear")
  match res {
    Ok(_) => ()
    Err(e) => fail("unexpected err: " + e.message())
  }

  let content = @sys.read_file(path)
  let m = parse_mcp_config_json(content).unwrap()
  assert_eq(m.length(), 0)

  ignore(@sys.rm_rf(tmp))
}

///|
test "remove_mcp_inner errors on missing" {
  let res = remove_mcp_inner("/tmp/missing-mcp.json", "linear")
  match res {
    Err(e) => assert_true(e.message().contains("user entry does not exist"))
    Ok(_) => fail("expected err")
  }
}
