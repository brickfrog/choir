///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
struct TaskFile {
  id : String
  title : String
  status : String
  assignee : String
  notes : String
} derive(Show, Eq)

///|
fn parse_int(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut res = 0
  for c in s {
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

///|
fn get_arg_or_alias(
  args : Map[String, String],
  key : String,
  fallback_key : String,
  default : String,
) -> String {
  match args.get(key) {
    Some(v) => if v == "" { default } else { v }
    None =>
      match args.get(fallback_key) {
        Some(v) => if v == "" { default } else { v }
        None => default
      }
  }
}

///|
fn parse_truthy_spawn_flag(s : String) -> Bool {
  let lowered = s.trim().to_lower()
  lowered == "true" || lowered == "1" || lowered == "yes"
}

///|
fn lookup_parent_session_id(
  project_dir : String,
  args : Map[String, String],
) -> String? {
  match args.get("parent_session_id") {
    Some(v) => if v.trim() != "" { return Some(v.trim().to_string()) }
    None => ()
  }
  if not(parse_truthy_spawn_flag(args.get("fork_session").unwrap_or("false"))) {
    return None
  }
  let caller_id = args.get("caller_id").unwrap_or("")
  if caller_id == "" {
    return None
  }
  let path = project_dir +
    "/.choir/sessions/claude/" +
    caller_id +
    ".session_id"
  let session_id = @io.read_file(path).trim().to_string()
  if session_id == "" {
    None
  } else {
    Some(session_id)
  }
}

///|
fn is_alphanumeric_or_dash(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_'
}

///|
fn validate_slug(s : String) -> Result[Unit, String] {
  if s == "" {
    return Err("slug cannot be empty")
  }
  for c in s {
    if not(is_alphanumeric_or_dash(c)) {
      return Err("invalid character in slug: " + c.to_string())
    }
  }
  Ok(())
}

///|
fn validate_branch(s : String) -> Result[Unit, String] {
  if s == "" {
    return Err("branch cannot be empty")
  }
  for c in s {
    if not(is_alphanumeric_or_dash(c)) && c != '.' {
      return Err("invalid character in branch: " + c.to_string())
    }
  }
  if s.contains("..") {
    return Err("branch cannot contain '..'")
  }
  Ok(())
}

///|
fn validate_kv_key(s : String) -> Result[Unit, String] {
  if s == "" {
    return Err("key cannot be empty")
  }
  if s.contains("..") {
    return Err("key cannot contain '..'")
  }
  if s[0] == '/' {
    return Err("key cannot start with '/'")
  }
  for c in s {
    if not(
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '_' ||
        c == '/' ||
        c == '.',
      ) {
      return Err("invalid character in key: " + c.to_string())
    }
  }
  Ok(())
}

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
  let mut found : @plugin.PluginDef? = None
  for plugin in plugins {
    if plugin.handles(req.name) {
      found = Some(plugin)
      break
    }
  }
  match found {
    None => @types.Response::Err("tool not found: " + req.name)
    Some(plugin) => {
      let agent_id = plugin_request_agent_id(req)
      let request_json = @plugin.build_request(
        req.name,
        req.args,
        agent_id,
        req.role.to_string(),
      )
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
        Ok(result) => @types.Response::Ok(result)
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
  match delivery {
    @message.DeliveryMethod::TeamsInbox(path, json) => {
      let cmd = @workspace.Command::{
        program: "sh",
        args: ["-c", "printf '%s\\n' '" + json + "' >> " + path],
        workdir: Some("."),
      }
      ignore(runner([cmd]) catch { e => return Err(e.to_string()) })
      Ok(())
    }
    @message.DeliveryMethod::TmuxStdin(target, text) => {
      let cmd = @workspace.tmux_send_keys(target, text)
      ignore(runner([cmd]) catch { e => return Err(e.to_string()) })
      Ok(())
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
fn skip_json_ws(s : String, start : Int) -> Int {
  let mut i = start
  while i < s.length() &&
        (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') {
    i = i + 1
  }
  i
}

///|
fn parse_json_string_literal(s : String, start : Int) -> (String, Int)? {
  if start >= s.length() || s[start] != '"' {
    return None
  }
  let buf = StringBuilder::new()
  let mut i = start + 1
  while i < s.length() {
    let c = Int::unsafe_to_char(s[i].to_int())
    if c == '"' {
      return Some((buf.to_string(), i + 1))
    }
    if c == '\\' {
      i = i + 1
      if i >= s.length() {
        return None
      }
      let escaped = Int::unsafe_to_char(s[i].to_int())
      match escaped {
        '"' => buf.write_char('"')
        '\\' => buf.write_char('\\')
        'n' => buf.write_char('\n')
        'r' => buf.write_char('\r')
        't' => buf.write_char('\t')
        other => buf.write_char(other)
      }
    } else {
      buf.write_char(c)
    }
    i = i + 1
  }
  None
}

///|
fn parse_string_map_json(content : String) -> Map[String, String]? {
  let map : Map[String, String] = {}
  let mut i = skip_json_ws(content, 0)
  if i >= content.length() || content[i] != '{' {
    return None
  }
  i = i + 1
  for {
    i = skip_json_ws(content, i)
    if i >= content.length() {
      return None
    }
    if content[i] == '}' {
      return Some(map)
    }
    let (key, next_i) = match parse_json_string_literal(content, i) {
      Some(pair) => pair
      None => return None
    }
    i = skip_json_ws(content, next_i)
    if i >= content.length() || content[i] != ':' {
      return None
    }
    i = skip_json_ws(content, i + 1)
    let (value, value_end) = match parse_json_string_literal(content, i) {
      Some(pair) => pair
      None => return None
    }
    map.set(key, value)
    i = skip_json_ws(content, value_end)
    if i >= content.length() {
      return None
    }
    if content[i] == '}' {
      return Some(map)
    }
    if content[i] != ',' {
      return None
    }
    i = i + 1
  }
}

///|
fn parse_task_file(content : String) -> Result[TaskFile, String] {
  let fields = match parse_string_map_json(content) {
    Some(map) => map
    None => return Err("invalid task json")
  }
  let id = match fields.get("id") {
    Some(v) => v
    None => return Err("missing id")
  }
  let title = match fields.get("title") {
    Some(v) => v
    None => return Err("missing title")
  }
  let status = match fields.get("status") {
    Some(v) => v
    None => return Err("missing status")
  }
  let assignee = match fields.get("assignee") {
    Some(v) => v
    None => return Err("missing assignee")
  }
  let notes = match fields.get("notes") {
    Some(v) => v
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
fn validate_task_status(status : String) -> Result[Unit, String] {
  match status {
    "todo" | "in_progress" | "done" => Ok(())
    _ => Err("invalid status: " + status)
  }
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
  @types.Response::Ok({ "status": "ok", "tasks": buf.to_string() })
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
      return @types.Response::Ok({ "status": "ok", "keys": "[]" })
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
  @types.Response::Ok({ "status": "ok", "keys": buf.to_string() })
}

///|
fn parse_agent_type(s : String) -> Result[@types.AgentType, String] {
  match s {
    "claude" => Ok(@types.AgentType::Claude)
    "gemini" => Ok(@types.AgentType::Gemini)
    "moon_pilot" => Ok(@types.AgentType::MoonPilot)
    "moonpilot" => Ok(@types.AgentType::MoonPilot)
    _ => Err("invalid agent_type: " + s)
  }
}

///|
pub async fn dispatch(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
) -> @types.Response {
  match call.name {
    "register" =>
      match registry {
        Some(reg) => {
          let agent_id = match call.args.get("agent_id") {
            Some(v) => v
            None => return @types.Response::Err("missing agent_id")
          }
          let role = call.role
          let agent_type = match call.args.get("agent_type") {
            Some(v) =>
              match parse_agent_type(v) {
                Ok(agent_type) => agent_type
                Err(e) => return @types.Response::Err(e)
              }
            None =>
              match role {
                @types.Role::Root => @types.AgentType::Claude
                @types.Role::TL => @types.AgentType::Claude
                @types.Role::Dev => @types.AgentType::Gemini
                @types.Role::Worker => @types.AgentType::Gemini
              }
          }
          let agent = @types.Agent::{
            agent_id,
            role,
            agent_type,
            state: @types.AgentState::Active,
            parent: match call.args.get("parent_id") {
              Some(v) => if v == "" { None } else { Some(v) }
              None => None
            },
            tmux_target: match call.args.get("tmux_target") {
              Some(v) => if v == "" { None } else { Some(v) }
              None => None
            },
            host: @types.Host::Local,
            workspace: call.args.get("workspace").unwrap_or(""),
            branch: call.args.get("branch").unwrap_or(""),
          }
          match reg.insert(agent) {
            Ok(_) =>
              @types.Response::Ok({
                "status": "registered",
                "agent_id": agent_id,
              })
            Err(e) => @types.Response::Err(e.message())
          }
        }
        None => @types.Response::Ok({ "status": "registered" })
      }
    "fork_wave" => {
      let count_str = match call.args.get("count") {
        Some(v) => v
        None => return @types.Response::Err("missing count")
      }
      let task = render_leaf_spawn_prompt(call.args)
      let parent_branch = get_arg_or_alias(
        call.args,
        "parent_branch",
        "branch",
        "main",
      )
      let parent_session_id = lookup_parent_session_id(project_dir, call.args)
      let slug_prefix = match call.args.get("slug_prefix") {
        Some(v) => if v == "" { "wave" } else { v }
        None => "wave"
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      match validate_slug(slug_prefix) {
        Err(e) => return @types.Response::Err("invalid slug_prefix: " + e)
        Ok(_) => ()
      }
      let count = match parse_int(count_str) {
        Some(c) => c
        None => return @types.Response::Err("invalid count: " + count_str)
      }
      let caller_id = call.args.get("caller_id").unwrap_or("main")
      let agent_ids = StringBuilder::new()
      let cmds : Array[@workspace.Command] = []
      for i = 0; i < count; i = i + 1 {
        let slug = slug_prefix + "-" + i.to_string()
        let agent_id = parent_branch + "." + slug
        if i > 0 {
          agent_ids.write_string(",")
        }
        agent_ids.write_string(agent_id)
        let spec = @types.SpawnSpec::{
          slug,
          role: @types.Role::Dev,
          agent_type: @types.AgentType::Claude,
          task,
          isolation: @types.IsolationMode::Worktree,
          parent_id: caller_id,
          parent_branch,
        }
        for
          cmd in @workspace.spawn_commands(
            spec,
            project_dir,
            session,
            parent_session_id~,
            extra_mcp_servers_json~,
            shell_command~,
          ) {
          cmds.push(cmd)
        }
      }
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::Ok({
            "status": "spawned",
            "count": count.to_string(),
            "agent_ids": agent_ids.to_string(),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "fork_session" => {
      let name = match call.args.get("name") {
        Some(v) => v
        None => return @types.Response::Err("missing name")
      }
      match validate_slug(name) {
        Err(e) => return @types.Response::Err("invalid name: " + e)
        Ok(_) => ()
      }
      let session_dir = project_dir + "/.choir/sessions/" + name
      let context_path = session_dir + "/context.json"
      let created_sec = @poller.now_sec()
      let context_json = "{\"name\":\"" +
        escape_json_string(name) +
        "\",\"created_sec\":\"" +
        created_sec.to_string() +
        "\"}"
      if @io.write_file_sync(context_path, context_json) {
        @types.Response::Ok({
          "status": "ok",
          "session_dir": session_dir,
          "name": name,
        })
      } else {
        @types.Response::Err("failed to create session: " + name)
      }
    }
    "file_pr" => {
      let branch = get_arg_or_alias(call.args, "branch", "agent_id", "")
      if branch == "" {
        return @types.Response::Err("missing branch")
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => if v == "" { "main" } else { v }
        None => "main"
      }
      match validate_branch(branch) {
        Err(e) => return @types.Response::Err("invalid branch: " + e)
        Ok(_) => ()
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      let tracked_agent_id = get_arg_or_alias(
        call.args,
        "agent_id",
        "caller_id",
        branch,
      )
      match run_strict(runner, [@workspace.git_push(branch)]) {
        Err(e) => @types.Response::Err(e)
        Ok(_) =>
          match ensure_pr(branch, parent_branch, project_dir) {
            Err(e) => @types.Response::Err(e)
            Ok(pr) => {
              let mut tracked = false
              match poller_state {
                Some(ps) => {
                  ps.track(pr.number, tracked_agent_id, @poller.now_sec())
                  tracked = true
                }
                None => ()
              }
              @types.Response::Ok({
                "status": "pr_created",
                "pr_number": pr.number.to_string(),
                "pr_url": pr.url,
                "tracked": if tracked {
                  "true"
                } else {
                  "false"
                },
              })
            }
          }
      }
    }
    "merge_pr" => {
      let pr_str = match call.args.get("pr_number") {
        Some(v) => v
        None => return @types.Response::Err("missing pr_number")
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => if v == "" { "main" } else { v }
        None => "main"
      }
      let caller_id = match call.args.get("caller_id") {
        Some(v) => if v == "" { "server" } else { v }
        None => "server"
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      match parse_int(pr_str) {
        Some(pr_number) => {
          let cmds = merge_pr_commands(pr_number)
          let mutex_name = "branch:" + parent_branch
          match mutex_registry {
            Some(reg) => {
              let now = @poller.now_sec()
              let (acquired, _) = reg.acquire(mutex_name, caller_id, 120L, now)
              if not(acquired) {
                ignore(reg.release(mutex_name, caller_id))
                return @types.Response::Err(
                  "merge serialization lock held by another agent, retry shortly",
                )
              }
              let merge_result = run_strict(runner, cmds)
              ignore(reg.release(mutex_name, caller_id))
              match merge_result {
                Ok(_) => {
                  match poller_state {
                    Some(ps) => ps.untrack(pr_number)
                    None => ()
                  }
                  @types.Response::Ok({ "status": "merged" })
                }
                Err(e) => @types.Response::Err(e)
              }
            }
            None =>
              match run_strict(runner, cmds) {
                Ok(_) => {
                  match poller_state {
                    Some(ps) => ps.untrack(pr_number)
                    None => ()
                  }
                  @types.Response::Ok({ "status": "merged" })
                }
                Err(e) => @types.Response::Err(e)
              }
          }
        }
        None => @types.Response::Err("invalid pr_number: " + pr_str)
      }
    }
    "track_pr" => {
      let pr_str = match call.args.get("pr_number") {
        Some(v) => v
        None => return @types.Response::Err("missing pr_number")
      }
      let agent_id = match call.args.get("agent_id") {
        Some(v) =>
          if v == "" {
            return @types.Response::Err("missing agent_id")
          } else {
            v
          }
        None => return @types.Response::Err("missing agent_id")
      }
      let pr_number = match parse_int(pr_str) {
        Some(value) => value
        None => return @types.Response::Err("invalid pr_number: " + pr_str)
      }
      match poller_state {
        Some(ps) => {
          ps.track(pr_number, agent_id, @poller.now_sec())
          @types.Response::Ok({ "status": "tracked" })
        }
        None => @types.Response::Err("poller unavailable")
      }
    }
    "notify_parent" => {
      let caller_id = match call.args.get("caller_id") {
        Some(v) => v
        None => return @types.Response::Err("missing caller_id")
      }
      let message = call.args.get("message").unwrap_or("")
      let status = call.args.get("status").unwrap_or("info")
      match registry {
        Some(reg) =>
          match reg.get_parent(caller_id) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent, caller_id, message, status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) => @types.Response::Ok({ "status": "notified" })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None => @types.Response::Ok({ "status": "notified" })
      }
    }
    "send_message" => {
      let target_id = match call.args.get("target_id") {
        Some(v) => v
        None => return @types.Response::Err("missing target_id")
      }
      let message = call.args.get("message").unwrap_or("")
      let status = call.args.get("status").unwrap_or("info")
      let sender_id = call.args.get("sender_id").unwrap_or("unknown")
      match registry {
        Some(reg) =>
          match reg.get(target_id) {
            Ok(agent) => {
              let delivery = @message.plan_delivery(
                agent, sender_id, message, status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) => @types.Response::Ok({ "status": "sent" })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None => @types.Response::Ok({ "status": "sent" })
      }
    }
    "shutdown" => {
      let caller_id = match call.args.get("caller_id") {
        Some(v) => v
        None => return @types.Response::Ok({ "status": "shutdown" }) // best-effort
      }
      match poller_state {
        Some(ps) =>
          match ps.critical_phase_pr_number(caller_id) {
            Some(pr_number) =>
              return @types.Response::Err(
                "cannot shutdown: PR #" +
                pr_number.to_string() +
                " has changes requested — push fixes first",
              )
            None => ()
          }
        None => ()
      }
      // 1. Notify parent if registry available
      match registry {
        Some(reg) =>
          match reg.get_parent(caller_id) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent, caller_id, "agent shutdown", "success",
              )
              let _ = execute_delivery(delivery, runner) // best-effort, ignore failure
              ()
            }
            Err(_) => ()
          }
        None => ()
      }
      // 2. Kill tmux pane and remove from registry
      match registry {
        Some(reg) => {
          match reg.get(caller_id) {
            Ok(agent) => {
              if agent.workspace.contains(".choir/worktrees/") {
                let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
                ()
              }
              match agent.tmux_target {
                Some(tmux_target) => {
                  let kill_cmd = @workspace.tmux_kill_pane(tmux_target)
                  let _ = runner([kill_cmd])
                  ()
                }
                None => ()
              }
            }
            Err(_) => ()
          }
          let _ = reg.remove(caller_id)
          ()
        }
        None => ()
      }
      @types.Response::Ok({ "status": "shutdown" })
    }
    "kv_get" => {
      let key = match call.args.get("key") {
        Some(v) => v
        None => return @types.Response::Err("missing key")
      }
      match validate_kv_key(key) {
        Ok(_) => ()
        Err(e) => return @types.Response::Err(e)
      }
      let value = @io.read_file(kv_file_path(project_dir, key))
      if value == "" {
        @types.Response::Ok({ "value": "null" })
      } else {
        @types.Response::Ok({ "value": value })
      }
    }
    "kv_set" => {
      let key = match call.args.get("key") {
        Some(v) => v
        None => return @types.Response::Err("missing key")
      }
      let value = match call.args.get("value") {
        Some(v) => v
        None => return @types.Response::Err("missing value")
      }
      match validate_kv_key(key) {
        Ok(_) => ()
        Err(e) => return @types.Response::Err(e)
      }
      let path = kv_file_path(project_dir, key)
      if @io.write_file_sync(path, value) {
        @types.Response::Ok({ "status": "ok" })
      } else {
        @types.Response::Err("failed to write kv file: " + path)
      }
    }
    "kv_delete" => {
      let key = match call.args.get("key") {
        Some(v) => v
        None => return @types.Response::Err("missing key")
      }
      match validate_kv_key(key) {
        Ok(_) => ()
        Err(e) => return @types.Response::Err(e)
      }
      let path = kv_file_path(project_dir, key)
      ignore(@io.delete_file_sync(path))
      @types.Response::Ok({ "status": "ok" })
    }
    "kv_list" => handle_kv_list(project_dir, runner)
    "mutex_acquire" => {
      let name = match call.args.get("name") {
        Some(v) => v
        None => return @types.Response::Err("missing name")
      }
      let agent_id = match call.args.get("agent_id") {
        Some(v) => v
        None => return @types.Response::Err("missing agent_id")
      }
      let ttl_str = call.args.get("ttl_sec").unwrap_or("300")
      let ttl_sec = match parse_int(ttl_str) {
        Some(value) => value.to_int64()
        None => return @types.Response::Err("invalid ttl_sec: " + ttl_str)
      }
      match mutex_registry {
        Some(reg) => {
          let (acquired, queue_position) = reg.acquire(
            name,
            agent_id,
            ttl_sec,
            @poller.now_sec(),
          )
          @types.Response::Ok({
            "acquired": if acquired {
              "true"
            } else {
              "false"
            },
            "queue_position": queue_position.to_string(),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    }
    "mutex_release" => {
      let name = match call.args.get("name") {
        Some(v) => v
        None => return @types.Response::Err("missing name")
      }
      let agent_id = match call.args.get("agent_id") {
        Some(v) => v
        None => return @types.Response::Err("missing agent_id")
      }
      match mutex_registry {
        Some(reg) => {
          let (holder, _) = reg.status(name)
          let was_waiting = reg.is_waiting(name, agent_id)
          let next_waiter = reg.release(name, agent_id)
          let released = holder == Some(agent_id) || was_waiting
          @types.Response::Ok({
            "released": if released {
              "true"
            } else {
              "false"
            },
            "next_waiter": next_waiter.unwrap_or(""),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    }
    "mutex_status" => {
      let name = match call.args.get("name") {
        Some(v) => v
        None => return @types.Response::Err("missing name")
      }
      match mutex_registry {
        Some(reg) => {
          let (holder, queue) = reg.status(name)
          @types.Response::Ok({
            "holder": holder.unwrap_or(""),
            "queue_length": queue.length().to_string(),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    }
    "task_list" => handle_task_list(project_dir, runner)
    "task_get" => {
      let id = match call.args.get("id") {
        Some(v) => v
        None => return @types.Response::Err("missing id")
      }
      match read_task_file(project_dir, id) {
        Ok(task) =>
          @types.Response::Ok({
            "status": "ok",
            "task": task_file_to_json(task),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "task_create" => {
      let id = match call.args.get("id") {
        Some(v) => v
        None => return @types.Response::Err("missing id")
      }
      let title = match call.args.get("title") {
        Some(v) => v
        None => return @types.Response::Err("missing title")
      }
      match validate_slug(id) {
        Err(e) => return @types.Response::Err("invalid id: " + e)
        Ok(_) => ()
      }
      let existing = @io.read_file(task_file_path(project_dir, id))
      if existing != "" {
        return @types.Response::Err("task already exists: " + id)
      }
      let status = match call.args.get("status") {
        Some(v) =>
          match validate_task_status(v) {
            Ok(_) => v
            Err(e) => return @types.Response::Err(e)
          }
        None => "todo"
      }
      let task = TaskFile::{
        id,
        title,
        status,
        assignee: call.args.get("assignee").unwrap_or(""),
        notes: call.args.get("notes").unwrap_or(""),
      }
      let content = task_file_to_json(task)
      let path = task_file_path(project_dir, id)
      if @io.write_file_sync(path, content) {
        @types.Response::Ok({ "status": "ok", "task": content })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    "task_update" => {
      let id = match call.args.get("id") {
        Some(v) => v
        None => return @types.Response::Err("missing id")
      }
      let task = match read_task_file(project_dir, id) {
        Ok(value) => value
        Err(e) => return @types.Response::Err(e)
      }
      let status = match call.args.get("status") {
        Some(v) =>
          match validate_task_status(v) {
            Ok(_) => v
            Err(e) => return @types.Response::Err(e)
          }
        None => task.status
      }
      let updated = {
        ..task,
        status,
        assignee: call.args.get("assignee").unwrap_or(task.assignee),
        notes: call.args.get("notes").unwrap_or(task.notes),
      }
      let content = task_file_to_json(updated)
      let path = task_file_path(project_dir, id)
      if @io.write_file_sync(path, content) {
        @types.Response::Ok({ "status": "ok", "task": content })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    "spawn_gemini" => {
      let task = render_leaf_spawn_prompt(call.args)
      let caller_id = call.args.get("caller_id").unwrap_or("main")
      let slug = get_arg_or_alias(call.args, "slug", "branch", "gemini-leaf")
      let parent_branch = get_arg_or_alias(
        call.args,
        "parent_branch",
        "base_branch",
        "main",
      )
      match validate_slug(slug) {
        Err(e) => return @types.Response::Err("invalid slug: " + e)
        Ok(_) => ()
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      let spec = @types.SpawnSpec::{
        slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Gemini,
        task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: caller_id,
        parent_branch,
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::Ok({
            "status": "spawned",
            "agent_id": @workspace.branch_name(parent_branch, slug),
            "slug": slug,
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "spawn_moon_pilot" => {
      let task = render_leaf_spawn_prompt(call.args)
      let slug = get_arg_or_alias(
        call.args,
        "slug",
        "branch",
        "moon-pilot-leaf",
      )
      let parent_branch = get_arg_or_alias(
        call.args,
        "parent_branch",
        "base_branch",
        "main",
      )
      match validate_slug(slug) {
        Err(e) => return @types.Response::Err("invalid slug: " + e)
        Ok(_) => ()
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      let spec = @types.SpawnSpec::{
        slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::MoonPilot,
        task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: call.args.get("caller_id").unwrap_or(""),
        parent_branch,
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::Ok({
            "status": "spawned",
            "agent_id": @workspace.branch_name(parent_branch, slug),
            "slug": slug,
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "spawn_remote" => {
      let task = render_leaf_spawn_prompt(call.args)
      let slug = get_arg_or_alias(call.args, "slug", "branch", "remote-leaf")
      let parent_branch = get_arg_or_alias(
        call.args,
        "parent_branch",
        "base_branch",
        "main",
      )
      let ssh_target = match call.args.get("ssh_target") {
        Some(v) => v
        None => return @types.Response::Err("missing ssh_target")
      }
      let repo_url = match call.args.get("repo_url") {
        Some(v) => v
        None => return @types.Response::Err("missing repo_url")
      }
      let tcp_addr = match call.args.get("tcp_addr") {
        Some(v) => v
        None => return @types.Response::Err("missing tcp_addr")
      }
      match validate_slug(slug) {
        Err(e) => return @types.Response::Err("invalid slug: " + e)
        Ok(_) => ()
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      let spec = @types.SpawnSpec::{
        slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: call.args.get("caller_id").unwrap_or(""),
        parent_branch,
      }
      let cmds = @workspace.remote_spawn_commands(
        spec,
        ssh_target,
        repo_url,
        tcp_addr,
        parent_session_id=lookup_parent_session_id(project_dir, call.args),
        extra_mcp_servers_json~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::Ok({
            "status": "spawned",
            "agent_id": @workspace.branch_name(parent_branch, slug),
            "slug": slug,
            "host": ssh_target,
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "spawn_worker" => {
      let task = render_worker_spawn_prompt(call.args)
      let caller_id = call.args.get("caller_id").unwrap_or("main")
      let slug = get_arg_or_alias(
        call.args,
        "slug",
        "agent_id",
        "inline-worker",
      )
      let agent_type_str = match call.args.get("agent_type") {
        Some(v) => if v == "" { "gemini" } else { v }
        None => "gemini"
      }
      match validate_slug(slug) {
        Err(e) => return @types.Response::Err("invalid slug: " + e)
        Ok(_) => ()
      }
      let agent_type = match parse_agent_type(agent_type_str) {
        Ok(value) => value
        Err(e) => return @types.Response::Err(e)
      }
      let spec = @types.SpawnSpec::{
        slug,
        role: @types.Role::Worker,
        agent_type,
        task,
        isolation: @types.IsolationMode::Inline,
        parent_id: caller_id,
        parent_branch: "main",
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
      )
      match run_strict(runner, cmds) {
        Ok(_) => @types.Response::Ok({ "status": "spawned" })
        Err(e) => @types.Response::Err(e)
      }
    }
    "reply" => {
      let id = match call.args.get("id") {
        Some(v) => v
        None => return @types.Response::Err("missing id")
      }
      if id == "" {
        return @types.Response::Err("id cannot be empty")
      }
      let cancel = call.args.get("cancel").unwrap_or("false") == "true"
      let payload = call.args.get("payload").unwrap_or("")
      let value = if cancel { "cancel" } else { payload }
      let key = "reply/" + id
      match validate_kv_key(key) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      let path = kv_file_path(project_dir, key)
      if @io.write_file_sync(path, value) {
        @types.Response::Ok({ "status": "ok", "id": id })
      } else {
        @types.Response::Err("failed to write reply: " + id)
      }
    }
    _ => @types.Response::Err("unknown tool")
  }
}

///|
pub async fn handle_request(
  registry : ToolRegistry,
  req : @types.Request,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  agent_registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  plugins_json? : String? = None,
) -> @types.Response {
  match registry.lookup(req.role, req.name) {
    Err(e) =>
      match e {
        @types.ExoError::ToolNotFound(_) =>
          dispatch_to_plugin(req, plugins_json, runner)
        _ => @types.Response::Err(e.message())
      }
    Ok(_) =>
      dispatch(
        { role: req.role, name: req.name, args: req.args },
        project_dir~,
        session~,
        runner~,
        ensure_pr~,
        extra_mcp_servers_json~,
        shell_command~,
        registry=agent_registry,
        mutex_registry~,
        poller_state~,
      )
  }
}
