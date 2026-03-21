///|
async fn run_strict(
  runner : async (Array[@workspace.Command]) -> Array[Int],
  cmds : Array[@workspace.Command],
) -> Result[Unit, String] {
  let statuses = runner(cmds) catch { e => return Err(e.to_string()) }
  if statuses.length() > 0 {
    let last = statuses[statuses.length() - 1]
    if last != 0 {
      return Err("command failed with status " + last.to_string())
    }
  }
  Ok(())
}

///|
fn sanitize_plugin_path_component(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if is_alphanumeric_or_dash(c) || c == '.' {
      buf.write_char(c)
    } else {
      buf.write_char('_')
    }
  }
  let result = buf.to_string()
  if result == "" {
    "unknown"
  } else {
    result
  }
}

///|
fn plugin_request_agent_id(req : @types.Request) -> String {
  match req.args.get("agent_id") {
    Some(agent_id) => agent_id
    None =>
      match req.args.get("caller_id") {
        Some(agent_id) => agent_id
        None =>
          match req.args.get("sender_id") {
            Some(agent_id) => agent_id
            None => "unknown"
          }
      }
  }
}

///|
async fn dispatch_to_plugin(
  req : @types.Request,
  plugins_json : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  let json = match plugins_json {
    Some(value) => value
    None => return @types.Response::Err("tool not found: " + req.name)
  }
  let plugins = @plugin.parse_plugins_json(json)
  match @plugin.find_handler(plugins, req.name) {
    None => @types.Response::Err("tool not found: " + req.name)
    Some(plugin) => {
      let agent_id = plugin_request_agent_id(req)
      let request_json = @plugin.build_request({
        tool: req.name,
        args: req.args,
        agent_id,
        role: req.role.to_string(),
      })
      let resp_path = "/tmp/choir-plugin-" +
        sanitize_plugin_path_component(req.name) +
        "-" +
        sanitize_plugin_path_component(agent_id) +
        ".json"
      let cmd = @workspace.Command::{
        program: "sh",
        args: [
          "-c",
          "rm -f \"$3\" && printf '%s\\n' \"$2\" | timeout 10 sh -c \"$1\" > \"$3\" 2>/dev/null || true",
          "sh",
          plugin.command,
          request_json,
          resp_path,
        ],
        workdir: None,
      }
      ignore(
        runner([cmd]) catch {
          e => return @types.Response::Err(e.to_string())
        },
      )
      let resp_str = @io.read_file(resp_path)
      match @plugin.parse_response(resp_str) {
        Ok(result) => result
        Err(e) => @types.Response::Err("plugin error: " + e)
      }
    }
  }
}

///|
pub async fn execute_delivery(
  delivery : @message.DeliveryMethod,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Unit, String] {
  fn ensure_success(statuses : Array[Int]) -> Result[Unit, String] {
    if statuses.length() == 0 || statuses[0] == 0 {
      Ok(())
    } else {
      Err("delivery command failed with exit code " + statuses[0].to_string())
    }
  }
  fn resolve_home_path(path : String) -> String {
    if path.length() >= 2 && path[0] == '~' && path[1] == '/' {
      match @io.getenv("HOME") {
        Some(home) =>
          home + "/" + (path[2:path.length()].to_string() catch { _ => path })
        None => path
      }
    } else {
      path
    }
  }
  fn teams_inbox_command(path : String, json : String) -> @workspace.Command {
    {
      program: "sh",
      args: [
        "-c",
        "mkdir -p \"$(dirname \"$2\")\" && printf '%s\\n' \"$1\" >> \"$2\"",
        "sh",
        json,
        resolve_home_path(path),
      ],
      workdir: Some("."),
    }
  }
  match delivery {
    @message.DeliveryMethod::TeamsInbox(path, json) => {
      let statuses = runner([teams_inbox_command(path, json)]) catch {
        e => return Err(e.to_string())
      }
      ensure_success(statuses)
    }
    @message.DeliveryMethod::LocalTerminalInput(target, text) => {
      let cmd = @workspace.local_send_text(target, text)
      let statuses = runner([cmd]) catch { e => return Err(e.to_string()) }
      ensure_success(statuses)
    }
    @message.DeliveryMethod::TcpPush(_, _) => Ok(()) // Phase 2
    @message.DeliveryMethod::UdsHttp(sock_path, body) => {
      let result = @uds.http_post(sock_path, body)
      if result == 0 {
        Ok(())
      } else {
        Ok(())
      }
    }
  }
}

///|
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn parse_task_file(content : String) -> Result[TaskFile, String] {
  let fields = @jsonutil.parse_flat_json_value_object(content)
  if fields.length() == 0 {
    return Err("invalid task json")
  }
  let id = match fields.get("id") {
    Some(@jsonutil.JsonValueText::String(v)) => v
    Some(@jsonutil.JsonValueText::Raw(_)) => return Err("id must be a string")
    None => return Err("missing id")
  }
  let title = match fields.get("title") {
    Some(@jsonutil.JsonValueText::String(v)) => v
    Some(@jsonutil.JsonValueText::Raw(_)) =>
      return Err("title must be a string")
    None => return Err("missing title")
  }
  let status = match fields.get("status") {
    Some(@jsonutil.JsonValueText::String(v)) => v
    Some(@jsonutil.JsonValueText::Raw(_)) =>
      return Err("status must be a string")
    None => return Err("missing status")
  }
  let assignee = match fields.get("assignee") {
    Some(@jsonutil.JsonValueText::String(v)) => v
    Some(@jsonutil.JsonValueText::Raw(_)) =>
      return Err("assignee must be a string")
    None => return Err("missing assignee")
  }
  let notes = match fields.get("notes") {
    Some(@jsonutil.JsonValueText::String(v)) => v
    Some(@jsonutil.JsonValueText::Raw(_)) =>
      return Err("notes must be a string")
    None => return Err("missing notes")
  }
  Ok({ id, title, status, assignee, notes })
}

///|
fn task_file_to_json(task : TaskFile) -> String {
  "{\"id\":\"" +
  escape_json_string(task.id) +
  "\",\"title\":\"" +
  escape_json_string(task.title) +
  "\",\"status\":\"" +
  escape_json_string(task.status) +
  "\",\"assignee\":\"" +
  escape_json_string(task.assignee) +
  "\",\"notes\":\"" +
  escape_json_string(task.notes) +
  "\"}"
}

///|
fn task_file_path(project_dir : String, id : String) -> String {
  project_dir + "/.choir/tasks/" + id + ".json"
}

///|
fn kv_file_path(project_dir : String, key : String) -> String {
  project_dir + "/.choir/kv/" + key
}

///|
fn task_list_manifest_path(project_dir : String) -> String {
  project_dir + "/.choir/.task-list.paths"
}

///|
fn kv_list_manifest_path(project_dir : String) -> String {
  project_dir + "/.choir/.kv-list.paths"
}

///|
fn read_task_file(
  project_dir : String,
  id : String,
) -> Result[TaskFile, String] {
  match validate_slug(id) {
    Err(e) => return Err("invalid id: " + e)
    Ok(_) => ()
  }
  let content = @io.read_file(task_file_path(project_dir, id))
  if content == "" {
    return Err("task not found: " + id)
  }
  match parse_task_file(content) {
    Ok(task) => Ok(task)
    Err(e) => Err("invalid task file for " + id + ": " + e)
  }
}

///|
async fn list_task_files(
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Array[String], String] {
  let manifest_path = task_list_manifest_path(project_dir)
  let list_cmd = @workspace.Command::{
    program: "sh",
    args: [
      "-c", "[ -d \"$1/.choir/tasks\" ] || exit 3; find \"$1/.choir/tasks\" -maxdepth 1 -type f -name '*.json' | sort > \"$2\"",
      "sh", project_dir, manifest_path,
    ],
    workdir: None,
  }
  let statuses = runner([list_cmd]) catch { e => return Err(e.to_string()) }
  if statuses.length() > 0 {
    let status = statuses[statuses.length() - 1]
    if status == 3 {
      return Ok([])
    }
    if status != 0 {
      return Err("command failed with status " + status.to_string())
    }
  }
  let content = @io.read_file(manifest_path)
  let cleanup_cmd = @workspace.Command::{
    program: "sh",
    args: ["-c", "rm -f \"$1\"", "sh", manifest_path],
    workdir: None,
  }
  ignore(runner([cleanup_cmd]) catch { _ => [] })
  let paths = []
  if content == "" {
    return Ok(paths)
  }
  for line in content.split("\n") {
    let path = line.to_string().trim().to_string()
    if path != "" {
      paths.push(path)
    }
  }
  Ok(paths)
}

///|
async fn handle_task_list(
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  let task_paths = match list_task_files(project_dir, runner) {
    Ok(paths) => paths
    Err(e) => return @types.Response::Err(e)
  }
  let buf = StringBuilder::new()
  buf.write_char('[')
  let mut first = true
  for path in task_paths {
    let content = @io.read_file(path)
    if content == "" {
      return @types.Response::Err("failed to read task file: " + path)
    }
    let task = match parse_task_file(content) {
      Ok(value) => value
      Err(e) =>
        return @types.Response::Err("invalid task file at " + path + ": " + e)
    }
    if not(first) {
      buf.write_char(',')
    }
    buf.write_string(task_file_to_json(task))
    first = false
  }
  buf.write_char(']')
  @types.Response::ok_values({
    "status": @types.wire_string("ok"),
    "tasks": @types.wire_raw(buf.to_string()),
  })
}

///|
async fn handle_kv_list(
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  let manifest_path = kv_list_manifest_path(project_dir)
  let list_cmd = @workspace.Command::{
    program: "sh",
    args: [
      "-c", "[ -d \"$1/.choir/kv\" ] || exit 3; find \"$1/.choir/kv\" -type f | sort > \"$2\"",
      "sh", project_dir, manifest_path,
    ],
    workdir: None,
  }
  let statuses = runner([list_cmd]) catch {
    e => return @types.Response::Err(e.to_string())
  }
  if statuses.length() > 0 {
    let status = statuses[statuses.length() - 1]
    if status == 3 {
      return @types.Response::ok_values({
        "status": @types.wire_string("ok"),
        "keys": @types.wire_raw("[]"),
      })
    }
    if status != 0 {
      return @types.Response::Err(
        "command failed with status " + status.to_string(),
      )
    }
  }
  let content = @io.read_file(manifest_path)
  let cleanup_cmd = @workspace.Command::{
    program: "sh",
    args: ["-c", "rm -f \"$1\"", "sh", manifest_path],
    workdir: None,
  }
  ignore(runner([cleanup_cmd]) catch { _ => [] })
  let prefix = project_dir + "/.choir/kv/"
  let buf = StringBuilder::new()
  buf.write_char('[')
  let mut first = true
  for line in content.split("\n") {
    let path = line.to_string().trim().to_string()
    if path == "" {
      continue
    }
    let actual_prefix = path[:prefix.length()].to_string() catch { _ => "" }
    if actual_prefix != prefix {
      return @types.Response::Err("invalid kv file path: " + path)
    }
    let key = path[prefix.length():].to_string() catch { _ => "" }
    if not(first) {
      buf.write_char(',')
    }
    buf.write_char('"')
    buf.write_string(escape_json_string(key))
    buf.write_char('"')
    first = false
  }
  buf.write_char(']')
  @types.Response::ok_values({
    "status": @types.wire_string("ok"),
    "keys": @types.wire_raw(buf.to_string()),
  })
}
