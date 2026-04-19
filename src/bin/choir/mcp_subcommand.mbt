///|
pub(all) struct McpServer {
  kind : String
  command : String
  args : Array[String]
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
    Err(msg) => {
      @sys.write_stderr(msg)
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
) -> Result[Unit, String] {
  if name == "choir" {
    return Err("choir mcp: cannot add builtin 'choir' server\n")
  }

  let mut current_servers : Map[String, McpServer] = {}
  if @sys.path_exists(mcp_path) {
    let content = @sys.read_file(mcp_path)
    if content != "" {
      match parse_mcp_config_json(content) {
        Ok(m) => current_servers = m
        Err(e) =>
          return Err("error parsing " + mcp_path + ": " + e.message() + "\n")
      }
    }
  }

  current_servers.set(name, { kind: "stdio", command, args: srv_args })

  let servers_obj : Map[String, Json] = {}
  for k, v in current_servers {
    let srv_obj : Map[String, Json] = {
      "type": v.kind.to_json(),
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
    return Err("error writing " + mcp_path + "\n")
  }

  Ok(())
}

///|
fn list_mcp() -> Unit {
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
    Err(msg) => {
      @sys.write_stderr(msg)
      @sys.exit(1)
    }
  }
}

///|
fn remove_mcp_inner(mcp_path : String, name : String) -> Result[Unit, String] {
  if name == "choir" {
    return Err("choir mcp: cannot remove builtin 'choir' server\n")
  }

  if !@sys.path_exists(mcp_path) {
    return Err("choir mcp: user entry does not exist\n")
  }

  let content = @sys.read_file(mcp_path)
  if content == "" {
    return Err("choir mcp: user entry does not exist\n")
  }

  let mut current_servers : Map[String, McpServer] = {}
  match parse_mcp_config_json(content) {
    Ok(m) => current_servers = m
    Err(e) =>
      return Err("error parsing " + mcp_path + ": " + e.message() + "\n")
  }

  if !current_servers.contains(name) {
    return Err("choir mcp: user entry does not exist\n")
  }

  current_servers.remove(name)

  let servers_obj : Map[String, Json] = {}
  for k, v in current_servers {
    let srv_obj : Map[String, Json] = {
      "type": v.kind.to_json(),
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
    return Err("error writing " + mcp_path + "\n")
  }

  Ok(())
}

///|
pub fn parse_mcp_config_json(
  s : String,
) -> Result[Map[String, McpServer], @types.ChoirError] {
  let parsed = @json.parse(s) catch {
    _ =>
      return Err(
        @types.ChoirError::config_error("malformed JSON in mcp config"),
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
    let kind = match srv.get("type") {
      Some(Json::String(t)) => t
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
    result.set(k, { kind, command, args })
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
test "parse_mcp_config_json valid" {
  let s = "{\"servers\":{\"linear\":{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@linear/mcp-server\"]}}}"
  let m = parse_mcp_config_json(s).unwrap()
  assert_eq(m.length(), 1)
  let srv = m.get("linear").unwrap()
  assert_eq(srv.kind, "stdio")
  assert_eq(srv.command, "npx")
  assert_eq(srv.args, ["-y", "@linear/mcp-server"])
}

///|
test "parse_mcp_config_json missing command" {
  let s = "{\"servers\":{\"linear\":{\"type\":\"stdio\"}}}"
  let res = parse_mcp_config_json(s)
  match res {
    Err(e) => assert_true(e.message().contains("missing or invalid command"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json missing type" {
  let s = "{\"servers\":{\"linear\":{\"command\":\"npx\"}}}"
  let res = parse_mcp_config_json(s)
  match res {
    Err(e) => assert_true(e.message().contains("missing or invalid type"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json malformed JSON" {
  let res = parse_mcp_config_json("{ malformed }")
  match res {
    Err(e) => assert_true(e.message().contains("malformed JSON"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json missing servers" {
  let res = parse_mcp_config_json("{}")
  match res {
    Err(e) => assert_true(e.message().contains("missing or invalid .servers"))
    Ok(_) => fail("expected error")
  }
}

///|
test "parse_mcp_config_json non-object entry" {
  let res = parse_mcp_config_json("{\"servers\":{\"a\":1}}")
  match res {
    Err(e) => assert_true(e.message().contains("must be an object"))
    Ok(_) => fail("expected error")
  }
}

///|
test "merge_mcp_maps clean merge" {
  let b : Map[String, Json] = { "a": "1".to_json() }
  let u : Map[String, Json] = { "b": "2".to_json() }
  let m = merge_mcp_maps(b, u).unwrap()
  assert_eq(m.get("a"), Some("1".to_json()))
  assert_eq(m.get("b"), Some("2".to_json()))
}

///|
test "merge_mcp_maps choir collision" {
  let b : Map[String, Json] = { "choir": "1".to_json() }
  let u : Map[String, Json] = { "choir": "2".to_json() }
  let res = merge_mcp_maps(b, u)
  match res {
    Err(e) => assert_true(e.message().contains("clashes with builtin"))
    Ok(_) => fail("expected error")
  }
}

///|
test "add_mcp_inner writes new server to empty file" {
  let tmp = "/tmp/choir-mcp-add-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let path = tmp + "/mcp.json"

  let res = add_mcp_inner(path, "linear", "npx", ["-y", "@linear/mcp-server"])
  assert_eq(res, Ok(()))

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
    Err(e) => assert_true(e.contains("builtin 'choir' server"))
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
  assert_eq(res, Ok(()))

  let content = @sys.read_file(path)
  let m = parse_mcp_config_json(content).unwrap()
  assert_eq(m.length(), 0)

  ignore(@sys.rm_rf(tmp))
}

///|
test "remove_mcp_inner errors on missing" {
  let res = remove_mcp_inner("/tmp/missing-mcp.json", "linear")
  match res {
    Err(e) => assert_true(e.contains("user entry does not exist"))
    Ok(_) => fail("expected err")
  }
}
