///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
struct ToolArgs {
  values : Map[String, @types.WireValue]
} derive(Show)

///|
fn tool_args_from_map(args : Map[String, String]) -> ToolArgs {
  let values : Map[String, @types.WireValue] = {}
  args.each(fn(k, v) { values.set(k, @types.WireValue::String(v)) })
  { values, }
}

///|
fn tool_args_from_request_args(args : @types.RequestArgs) -> ToolArgs {
  { values: args.to_value_map() }
}

///|
fn tool_args_get(args : ToolArgs, key : String) -> String? {
  match tool_args_get_value(args, key) {
    Some(value) => Some(value.to_compat_string())
    None => None
  }
}

///|
fn tool_args_get_value(args : ToolArgs, key : String) -> @types.WireValue? {
  args.values.get(key)
}

///|
fn tool_args_to_map(args : ToolArgs) -> Map[String, String] {
  let converted : Map[String, String] = {}
  args.values.each(fn(k, v) { converted.set(k, v.to_compat_string()) })
  converted
}

///|
fn prompt_spec_from_tool_args(args : ToolArgs) -> PromptSpec {
  PromptSpec::from_map(tool_args_to_map(args))
}

///|
fn tool_args_get_int(args : ToolArgs, key : String) -> Int? {
  match tool_args_get(args, key) {
    Some(value) => parse_int(value)
    None => None
  }
}

///|
fn tool_args_get_bool(args : ToolArgs, key : String) -> Bool {
  parse_truthy_spawn_flag(tool_args_get(args, key).unwrap_or("false"))
}

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
  args : ToolArgs,
  key : String,
  fallback_key : String,
  default : String,
) -> String {
  match tool_args_get(args, key) {
    Some(v) => if v == "" { default } else { v }
    None =>
      match tool_args_get(args, fallback_key) {
        Some(v) => if v == "" { default } else { v }
        None => default
      }
  }
}

///|
struct FilePrArgs {
  branch : String
  parent_branch : String
  tracked_agent_id : String
} derive(Show, Eq)

///|
struct TrackPrArgs {
  pr_number : Int
  agent_id : String
  branch : String
  parent_branch : String
  pr_url : String
} derive(Show, Eq)

///|
struct ForkWaveArgs {
  count : Int
  task : String
  parent_branch : String
  caller_id : String
  slug_prefix : String
  agent_type : @types.AgentType
  parent_session_id : String?
} derive(Show, Eq)

///|
struct LeafSpawnArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
} derive(Show, Eq)

///|
struct WorkerSpawnArgs {
  task : String
  caller_id : String
  slug : String
  agent_type : @types.AgentType
} derive(Show, Eq)

///|
struct RemoteSpawnArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
  ssh_target : String
  repo_url : String
  tcp_addr : String
  parent_session_id : String?
} derive(Show, Eq)

///|
struct TaskCreateArgs {
  id : String
  title : String
  status : String
  assignee : String
  notes : String
} derive(Show, Eq)

///|
struct TaskUpdateArgs {
  id : String
  status : String?
  assignee : String?
  notes : String?
} derive(Show, Eq)

///|
struct RegisterArgs {
  agent_id : String
  role : @types.Role
  agent_type : @types.AgentType
  parent : String?
  terminal_target : String?
  workspace : String
  branch : String
} derive(Show, Eq)

///|
struct KvKeyArgs {
  key : String
} derive(Show, Eq)

///|
struct KvSetArgs {
  key : String
  value : String
} derive(Show, Eq)

///|
struct MutexAcquireArgs {
  name : String
  agent_id : String
  ttl_sec : Int64
} derive(Show, Eq)

///|
struct MutexNameArgs {
  name : String
} derive(Show, Eq)

///|
struct MutexReleaseArgs {
  name : String
  agent_id : String
} derive(Show, Eq)

///|
struct MergePrArgs {
  pr_number : Int
  parent_branch : String
  caller_id : String
} derive(Show, Eq)

///|
struct CallerMessageArgs {
  caller_id : String
  message : String
  status : String
} derive(Show, Eq)

///|
struct SendMessageArgs {
  target_id : String
  sender_id : String
  message : String
  status : String
} derive(Show, Eq)

///|
struct ShutdownArgs {
  caller_id : String?
} derive(Show, Eq)

///|
struct IdArgs {
  id : String
} derive(Show, Eq)

///|
struct SessionNameArgs {
  name : String
} derive(Show, Eq)

///|
fn parse_truthy_spawn_flag(s : String) -> Bool {
  let lowered = s.trim().to_lower()
  lowered == "true" || lowered == "1" || lowered == "yes"
}

///|
fn lookup_parent_session_id(project_dir : String, args : ToolArgs) -> String? {
  match tool_args_get(args, "parent_session_id") {
    Some(v) => if v.trim() != "" { return Some(v.trim().to_string()) }
    None => ()
  }
  if not(tool_args_get_bool(args, "fork_session")) {
    return None
  }
  let caller_id = tool_args_get(args, "caller_id").unwrap_or("")
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
fn parse_file_pr_args(args : ToolArgs) -> Result[FilePrArgs, String] {
  let branch = get_arg_or_alias(args, "branch", "agent_id", "")
  if branch == "" {
    return Err("missing branch")
  }
  let parent_branch = tool_args_get(args, "parent_branch").unwrap_or("main")
  let normalized_parent_branch = if parent_branch == "" {
    "main"
  } else {
    parent_branch
  }
  match validate_branch(branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid branch: " + e)
  }
  match validate_branch(normalized_parent_branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid parent_branch: " + e)
  }
  Ok({
    branch,
    parent_branch: normalized_parent_branch,
    tracked_agent_id: get_arg_or_alias(args, "agent_id", "caller_id", branch),
  })
}

///|
fn parse_track_pr_args(args : ToolArgs) -> Result[TrackPrArgs, String] {
  let pr_str = tool_args_get(args, "pr_number").unwrap_or("")
  if pr_str == "" {
    return Err("missing pr_number")
  }
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err("missing agent_id")
  }
  let pr_number = match tool_args_get_int(args, "pr_number") {
    Some(value) => value
    None => return Err("invalid pr_number: " + pr_str)
  }
  let branch = get_arg_or_alias(args, "branch", "agent_id", agent_id)
  let parent_branch = get_arg_or_alias(
    args,
    "parent_branch",
    "base",
    @workspace.parent_branch(branch).unwrap_or("main"),
  )
  match validate_branch(branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid branch: " + e)
  }
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid parent_branch: " + e)
  }
  Ok({
    pr_number,
    agent_id,
    branch,
    parent_branch,
    pr_url: tool_args_get(args, "pr_url").unwrap_or(""),
  })
}

///|
fn parse_fork_wave_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[ForkWaveArgs, String] {
  let count_str = tool_args_get(args, "count").unwrap_or("")
  if count_str == "" {
    return Err("missing count")
  }
  let count = match tool_args_get_int(args, "count") {
    Some(c) => c
    None => return Err("invalid count: " + count_str)
  }
  let parent_branch = get_arg_or_alias(args, "parent_branch", "branch", "main")
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid parent_branch: " + e)
  }
  let slug_prefix = tool_args_get(args, "slug_prefix").unwrap_or("wave")
  let normalized_slug_prefix = if slug_prefix == "" {
    "wave"
  } else {
    slug_prefix
  }
  let agent_type_str = tool_args_get(args, "agent_type").unwrap_or("gemini")
  let normalized_agent_type_str = if agent_type_str == "" {
    "gemini"
  } else {
    agent_type_str
  }
  let agent_type = match parse_agent_type(normalized_agent_type_str) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  match validate_slug(normalized_slug_prefix) {
    Ok(_) => ()
    Err(e) => return Err("invalid slug_prefix: " + e)
  }
  Ok({
    count,
    task: render_leaf_spawn_prompt(prompt_spec_from_tool_args(args)),
    parent_branch,
    caller_id: tool_args_get(args, "caller_id").unwrap_or("main"),
    slug_prefix: normalized_slug_prefix,
    agent_type,
    parent_session_id: lookup_parent_session_id(project_dir, args),
  })
}

///|
fn parse_leaf_spawn_args(
  args : ToolArgs,
  default_slug : String,
) -> Result[LeafSpawnArgs, String] {
  let slug = get_arg_or_alias(args, "slug", "branch", default_slug)
  let parent_branch = get_arg_or_alias(
    args, "parent_branch", "base_branch", "main",
  )
  match validate_slug(slug) {
    Ok(_) => ()
    Err(e) => return Err("invalid slug: " + e)
  }
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid parent_branch: " + e)
  }
  Ok({
    task: render_leaf_spawn_prompt(prompt_spec_from_tool_args(args)),
    caller_id: tool_args_get(args, "caller_id").unwrap_or("main"),
    slug,
    parent_branch,
  })
}

///|
fn parse_worker_spawn_args(args : ToolArgs) -> Result[WorkerSpawnArgs, String] {
  let prompt_spec = prompt_spec_from_tool_args(args)
  match prompt_spec.worker_type {
    "research" => ()
    "review" => ()
    _ => return Err("invalid worker type: " + prompt_spec.worker_type)
  }
  let slug = get_arg_or_alias(args, "slug", "agent_id", "inline-worker")
  match validate_slug(slug) {
    Ok(_) => ()
    Err(e) => return Err("invalid slug: " + e)
  }
  let agent_type_str = tool_args_get(args, "agent_type").unwrap_or("gemini")
  let normalized_agent_type_str = if agent_type_str == "" {
    "gemini"
  } else {
    agent_type_str
  }
  let agent_type = match parse_agent_type(normalized_agent_type_str) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  Ok({
    task: render_worker_spawn_prompt(prompt_spec),
    caller_id: tool_args_get(args, "caller_id").unwrap_or("main"),
    slug,
    agent_type,
  })
}

///|
fn parse_remote_spawn_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[RemoteSpawnArgs, String] {
  let leaf_args = match parse_leaf_spawn_args(args, "remote-leaf") {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let ssh_target = tool_args_get(args, "ssh_target").unwrap_or("")
  if ssh_target == "" {
    return Err("missing ssh_target")
  }
  let repo_url = tool_args_get(args, "repo_url").unwrap_or("")
  if repo_url == "" {
    return Err("missing repo_url")
  }
  let tcp_addr = tool_args_get(args, "tcp_addr").unwrap_or("")
  if tcp_addr == "" {
    return Err("missing tcp_addr")
  }
  Ok({
    task: leaf_args.task,
    caller_id: leaf_args.caller_id,
    slug: leaf_args.slug,
    parent_branch: leaf_args.parent_branch,
    ssh_target,
    repo_url,
    tcp_addr,
    parent_session_id: lookup_parent_session_id(project_dir, args),
  })
}

///|
fn parse_task_create_args(args : ToolArgs) -> Result[TaskCreateArgs, String] {
  let id = tool_args_get(args, "id").unwrap_or("")
  if id == "" {
    return Err("missing id")
  }
  let title = tool_args_get(args, "title").unwrap_or("")
  if title == "" {
    return Err("missing title")
  }
  match validate_slug(id) {
    Ok(_) => ()
    Err(e) => return Err("invalid id: " + e)
  }
  let status = tool_args_get(args, "status").unwrap_or("todo")
  let normalized_status = if status == "" { "todo" } else { status }
  match validate_task_status(normalized_status) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok({
    id,
    title,
    status: normalized_status,
    assignee: tool_args_get(args, "assignee").unwrap_or(""),
    notes: tool_args_get(args, "notes").unwrap_or(""),
  })
}

///|
fn parse_task_update_args(args : ToolArgs) -> Result[TaskUpdateArgs, String] {
  let id = tool_args_get(args, "id").unwrap_or("")
  if id == "" {
    return Err("missing id")
  }
  let status = match tool_args_get(args, "status") {
    Some(v) =>
      if v == "" {
        None
      } else {
        match validate_task_status(v) {
          Ok(_) => Some(v)
          Err(e) => return Err(e)
        }
      }
    None => None
  }
  Ok({
    id,
    status,
    assignee: tool_args_get(args, "assignee"),
    notes: tool_args_get(args, "notes"),
  })
}

///|
fn parse_register_args(
  role : @types.Role,
  args : ToolArgs,
) -> Result[RegisterArgs, String] {
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err("missing agent_id")
  }
  let agent_type = match tool_args_get(args, "agent_type") {
    Some(v) =>
      match parse_agent_type(v) {
        Ok(agent_type) => agent_type
        Err(e) => return Err(e)
      }
    None =>
      match role {
        @types.Role::Root => @types.AgentType::Claude
        @types.Role::TL => @types.AgentType::Claude
        @types.Role::Dev => @types.AgentType::Gemini
        @types.Role::Worker => @types.AgentType::Gemini
      }
  }
  Ok({
    agent_id,
    role,
    agent_type,
    parent: match tool_args_get(args, "parent_id") {
      Some(v) => if v == "" { None } else { Some(v) }
      None => None
    },
    terminal_target: match tool_args_get(args, "terminal_target") {
      Some(v) => if v == "" { None } else { Some(v) }
      None => None
    },
    workspace: tool_args_get(args, "workspace").unwrap_or(""),
    branch: tool_args_get(args, "branch").unwrap_or(""),
  })
}

///|
fn parse_kv_key_args(args : ToolArgs) -> Result[KvKeyArgs, String] {
  let key = tool_args_get(args, "key").unwrap_or("")
  if key == "" {
    return Err("missing key")
  }
  match validate_kv_key(key) {
    Ok(_) => Ok({ key, })
    Err(e) => Err(e)
  }
}

///|
fn parse_kv_set_args(args : ToolArgs) -> Result[KvSetArgs, String] {
  let key_args = match parse_kv_key_args(args) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let value = match tool_args_get(args, "value") {
    Some(v) => v
    None => return Err("missing value")
  }
  Ok({ key: key_args.key, value })
}

///|
fn parse_mutex_acquire_args(
  args : ToolArgs,
) -> Result[MutexAcquireArgs, String] {
  let name = tool_args_get(args, "name").unwrap_or("")
  if name == "" {
    return Err("missing name")
  }
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err("missing agent_id")
  }
  let ttl_str = tool_args_get(args, "ttl_sec").unwrap_or("300")
  let ttl_sec = if ttl_str == "" ||
    (ttl_str == "300" && not(args.values.contains("ttl_sec"))) {
    300L
  } else {
    match tool_args_get_int(args, "ttl_sec") {
      Some(value) => value.to_int64()
      None => return Err("invalid ttl_sec: " + ttl_str)
    }
  }
  Ok({ name, agent_id, ttl_sec })
}

///|
fn parse_mutex_name_args(args : ToolArgs) -> Result[MutexNameArgs, String] {
  let name = tool_args_get(args, "name").unwrap_or("")
  if name == "" {
    return Err("missing name")
  }
  Ok({ name, })
}

///|
fn parse_mutex_release_args(
  args : ToolArgs,
) -> Result[MutexReleaseArgs, String] {
  let name_args = match parse_mutex_name_args(args) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err("missing agent_id")
  }
  Ok({ name: name_args.name, agent_id })
}

///|
fn parse_merge_pr_args(args : ToolArgs) -> Result[MergePrArgs, String] {
  let pr_str = tool_args_get(args, "pr_number").unwrap_or("")
  if pr_str == "" {
    return Err("missing pr_number")
  }
  let pr_number = match tool_args_get_int(args, "pr_number") {
    Some(value) => value
    None => return Err("invalid pr_number: " + pr_str)
  }
  let parent_branch = tool_args_get(args, "parent_branch").unwrap_or("main")
  let normalized_parent_branch = if parent_branch == "" {
    "main"
  } else {
    parent_branch
  }
  match validate_branch(normalized_parent_branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid parent_branch: " + e)
  }
  Ok({
    pr_number,
    parent_branch: normalized_parent_branch,
    caller_id: match tool_args_get(args, "caller_id") {
      Some(v) => if v == "" { "server" } else { v }
      None => "server"
    },
  })
}

///|
fn parse_caller_message_args(
  args : ToolArgs,
) -> Result[CallerMessageArgs, String] {
  let caller_id = tool_args_get(args, "caller_id").unwrap_or("")
  if caller_id == "" {
    return Err("missing caller_id")
  }
  Ok({
    caller_id,
    message: tool_args_get(args, "message").unwrap_or(""),
    status: tool_args_get(args, "status").unwrap_or("info"),
  })
}

///|
fn parse_send_message_args(args : ToolArgs) -> Result[SendMessageArgs, String] {
  let target_id = tool_args_get(args, "target_id").unwrap_or("")
  if target_id == "" {
    return Err("missing target_id")
  }
  Ok({
    target_id,
    sender_id: tool_args_get(args, "sender_id").unwrap_or("unknown"),
    message: tool_args_get(args, "message").unwrap_or(""),
    status: tool_args_get(args, "status").unwrap_or("info"),
  })
}

///|
fn parse_shutdown_args(args : ToolArgs) -> ShutdownArgs {
  { caller_id: tool_args_get(args, "caller_id") }
}

///|
fn parse_id_args(args : ToolArgs) -> Result[IdArgs, String] {
  let id = tool_args_get(args, "id").unwrap_or("")
  if id == "" {
    return Err("missing id")
  }
  Ok({ id, })
}

///|
fn parse_session_name_args(args : ToolArgs) -> Result[SessionNameArgs, String] {
  let name = tool_args_get(args, "name").unwrap_or("")
  if name == "" {
    return Err("missing name")
  }
  match validate_slug(name) {
    Ok(_) => Ok({ name, })
    Err(e) => Err("invalid name: " + e)
  }
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
  terminal_backend? : @types.TerminalBackend = @types.TerminalBackend::Tmux,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  raw_args? : @types.RequestArgs? = None,
) -> @types.Response {
  let tool_args = match raw_args {
    Some(args) => tool_args_from_request_args(args)
    None => tool_args_from_map(call.args)
  }
  match call.name {
    "register" =>
      match registry {
        Some(reg) => {
          let register_args = match parse_register_args(call.role, tool_args) {
            Ok(parsed) => parsed
            Err(e) => return @types.Response::Err(e)
          }
          let agent = @types.Agent::{
            agent_id: register_args.agent_id,
            role: register_args.role,
            agent_type: register_args.agent_type,
            state: @types.AgentState::Active,
            parent: register_args.parent,
            terminal_target: register_args.terminal_target,
            host: @types.Host::Local,
            workspace: register_args.workspace,
            branch: register_args.branch,
          }
          let refreshed = reg.upsert(agent)
          @types.Response::ok_values({
            "status": @types.wire_string("registered"),
            "agent_id": @types.wire_string(register_args.agent_id),
            "refreshed": @types.wire_bool(refreshed),
          })
        }
        None =>
          @types.Response::ok_values({
            "status": @types.wire_string("registered"),
          })
      }
    "fork_wave" => {
      let fork_wave_args = match parse_fork_wave_args(project_dir, tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let agent_ids = StringBuilder::new()
      let cmds : Array[@workspace.Command] = []
      for i = 0; i < fork_wave_args.count; i = i + 1 {
        let slug = fork_wave_args.slug_prefix + "-" + i.to_string()
        let agent_id = fork_wave_args.parent_branch + "." + slug
        if i > 0 {
          agent_ids.write_string(",")
        }
        agent_ids.write_string(agent_id)
        let spec = @types.SpawnSpec::{
          slug,
          role: @types.Role::Dev,
          agent_type: fork_wave_args.agent_type,
          task: fork_wave_args.task,
          isolation: @types.IsolationMode::Worktree,
          parent_id: fork_wave_args.caller_id,
          parent_branch: fork_wave_args.parent_branch,
        }
        for
          cmd in @workspace.spawn_commands(
            spec,
            project_dir,
            session,
            terminal_backend~,
            parent_session_id=fork_wave_args.parent_session_id,
            extra_mcp_servers_json~,
            shell_command~,
            listen_uds~,
            listen_tcp~,
            tcp_auth_token~,
          ) {
          cmds.push(cmd)
        }
      }
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({
            "status": @types.wire_string("spawned"),
            "count": @types.wire_int(fork_wave_args.count),
            "agent_ids": @types.wire_string(agent_ids.to_string()),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "fork_session" => {
      let session_args = match parse_session_name_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let session_dir = project_dir + "/.choir/sessions/" + session_args.name
      let context_path = session_dir + "/context.json"
      let created_sec = @poller.now_sec()
      let context_json = "{\"name\":\"" +
        escape_json_string(session_args.name) +
        "\",\"created_sec\":\"" +
        created_sec.to_string() +
        "\"}"
      if @io.write_file_sync(context_path, context_json) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "session_dir": @types.wire_string(session_dir),
          "name": @types.wire_string(session_args.name),
        })
      } else {
        @types.Response::Err("failed to create session: " + session_args.name)
      }
    }
    "file_pr" => {
      let file_pr_args = match parse_file_pr_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let branch = file_pr_args.branch
      let parent_branch = file_pr_args.parent_branch
      let tracked_agent_id = file_pr_args.tracked_agent_id
      match run_strict(runner, [@workspace.git_push(branch)]) {
        Err(e) => @types.Response::Err(e)
        Ok(_) =>
          match ensure_pr(branch, parent_branch, project_dir) {
            Err(e) => @types.Response::Err(e)
            Ok(pr) => {
              let mut tracked = false
              match poller_state {
                Some(ps) => {
                  ps.track(
                    pr.number,
                    tracked_agent_id,
                    branch,
                    parent_branch,
                    pr.url,
                    @poller.now_sec(),
                  )
                  ignore(ps.write_state_file(project_dir))
                  tracked = true
                }
                None => ()
              }
              @types.Response::ok_values({
                "status": @types.wire_string("pr_created"),
                "pr_number": @types.wire_int(pr.number),
                "pr_url": @types.wire_string(pr.url),
                "tracked": @types.wire_bool(tracked),
              })
            }
          }
      }
    }
    "merge_pr" => {
      let merge_args = match parse_merge_pr_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let cmds = merge_pr_commands(merge_args.pr_number)
      let mutex_name = "branch:" + merge_args.parent_branch
      match mutex_registry {
        Some(reg) => {
          let now = @poller.now_sec()
          let (acquired, _) = reg.acquire(
            mutex_name,
            merge_args.caller_id,
            120L,
            now,
          )
          if not(acquired) {
            ignore(reg.release(mutex_name, merge_args.caller_id))
            return @types.Response::Err(
              "merge serialization lock held by another agent, retry shortly",
            )
          }
          let merge_result = run_strict(runner, cmds)
          ignore(reg.release(mutex_name, merge_args.caller_id))
          match merge_result {
            Ok(_) => {
              match poller_state {
                Some(ps) => {
                  ps.untrack(merge_args.pr_number)
                  ignore(ps.write_state_file(project_dir))
                }
                None => ()
              }
              @types.Response::ok_values({
                "status": @types.wire_string("merged"),
              })
            }
            Err(e) => @types.Response::Err(e)
          }
        }
        None =>
          match run_strict(runner, cmds) {
            Ok(_) => {
              match poller_state {
                Some(ps) => {
                  ps.untrack(merge_args.pr_number)
                  ignore(ps.write_state_file(project_dir))
                }
                None => ()
              }
              @types.Response::ok_values({
                "status": @types.wire_string("merged"),
              })
            }
            Err(e) => @types.Response::Err(e)
          }
      }
    }
    "track_pr" => {
      let track_pr_args = match parse_track_pr_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match poller_state {
        Some(ps) => {
          ps.track(
            track_pr_args.pr_number,
            track_pr_args.agent_id,
            track_pr_args.branch,
            track_pr_args.parent_branch,
            track_pr_args.pr_url,
            @poller.now_sec(),
          )
          ignore(ps.write_state_file(project_dir))
          @types.Response::ok_values({
            "status": @types.wire_string("tracked"),
            "branch": @types.wire_string(track_pr_args.branch),
            "parent_branch": @types.wire_string(track_pr_args.parent_branch),
            "pr_url": @types.wire_string(track_pr_args.pr_url),
          })
        }
        None => @types.Response::Err("poller unavailable")
      }
    }
    "notify_parent" => {
      let notify_args = match parse_caller_message_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match registry {
        Some(reg) =>
          match reg.get_parent(notify_args.caller_id) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent,
                notify_args.caller_id,
                notify_args.message,
                notify_args.status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) =>
                  @types.Response::ok_values({
                    "status": @types.wire_string("notified"),
                  })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None =>
          @types.Response::ok_values({
            "status": @types.wire_string("notified"),
          })
      }
    }
    "send_message" => {
      let send_args = match parse_send_message_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match registry {
        Some(reg) =>
          match reg.get(send_args.target_id) {
            Ok(agent) => {
              let delivery = @message.plan_delivery(
                agent,
                send_args.sender_id,
                send_args.message,
                send_args.status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) =>
                  @types.Response::ok_values({
                    "status": @types.wire_string("sent"),
                  })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None =>
          @types.Response::ok_values({ "status": @types.wire_string("sent") })
      }
    }
    "shutdown" => {
      let shutdown_args = parse_shutdown_args(tool_args)
      let caller_id = match shutdown_args.caller_id {
        Some(v) => v
        None =>
          return @types.Response::ok_values({
            "status": @types.wire_string("shutdown"),
          }) // best-effort
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
        Some(reg) => {
          let _ = reg.set_state(caller_id, @types.AgentState::Completing)
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
              match agent.terminal_target {
                Some(terminal_target) => {
                  let kill_cmd = @workspace.local_close_target(terminal_target)
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
      @types.Response::ok_values({ "status": @types.wire_string("shutdown") })
    }
    "kv_get" => {
      let key_args = match parse_kv_key_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let value = @io.read_file(kv_file_path(project_dir, key_args.key))
      if value == "" {
        @types.Response::ok({ "value": "null" })
      } else {
        @types.Response::ok({ "value": value })
      }
    }
    "kv_set" => {
      let kv_args = match parse_kv_set_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let path = kv_file_path(project_dir, kv_args.key)
      if @io.write_file_sync(path, kv_args.value) {
        @types.Response::ok({ "status": "ok" })
      } else {
        @types.Response::Err("failed to write kv file: " + path)
      }
    }
    "kv_delete" => {
      let key_args = match parse_kv_key_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let path = kv_file_path(project_dir, key_args.key)
      ignore(@io.delete_file_sync(path))
      @types.Response::ok({ "status": "ok" })
    }
    "kv_list" => handle_kv_list(project_dir, runner)
    "mutex_acquire" => {
      let mutex_args = match parse_mutex_acquire_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match mutex_registry {
        Some(reg) => {
          let (acquired, queue_position) = reg.acquire(
            mutex_args.name,
            mutex_args.agent_id,
            mutex_args.ttl_sec,
            @poller.now_sec(),
          )
          @types.Response::ok_values({
            "acquired": @types.wire_bool(acquired),
            "queue_position": @types.wire_int(queue_position),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    }
    "mutex_release" => {
      let mutex_args = match parse_mutex_release_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match mutex_registry {
        Some(reg) => {
          let (holder, _) = reg.status(mutex_args.name)
          let was_waiting = reg.is_waiting(mutex_args.name, mutex_args.agent_id)
          let next_waiter = reg.release(mutex_args.name, mutex_args.agent_id)
          let released = holder == Some(mutex_args.agent_id) || was_waiting
          @types.Response::ok_values({
            "released": @types.wire_bool(released),
            "next_waiter": @types.wire_string(next_waiter.unwrap_or("")),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    }
    "mutex_status" => {
      let name_args = match parse_mutex_name_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match mutex_registry {
        Some(reg) => {
          let (holder, queue) = reg.status(name_args.name)
          @types.Response::ok_values({
            "holder": @types.wire_string(holder.unwrap_or("")),
            "queue_length": @types.wire_int(queue.length()),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    }
    "task_list" => handle_task_list(project_dir, runner)
    "task_get" => {
      let id_args = match parse_id_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      match read_task_file(project_dir, id_args.id) {
        Ok(task) =>
          @types.Response::ok_values({
            "status": @types.wire_string("ok"),
            "task": @types.wire_raw(task_file_to_json(task)),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "task_create" => {
      let task_args = match parse_task_create_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let existing = @io.read_file(task_file_path(project_dir, task_args.id))
      if existing != "" {
        return match read_task_file(project_dir, task_args.id) {
          Ok(task) =>
            @types.Response::ok_values({
              "status": @types.wire_string("ok"),
              "created": @types.wire_bool(false),
              "task": @types.wire_raw(task_file_to_json(task)),
            })
          Err(e) => @types.Response::Err(e)
        }
      }
      let task = TaskFile::{
        id: task_args.id,
        title: task_args.title,
        status: task_args.status,
        assignee: task_args.assignee,
        notes: task_args.notes,
      }
      let content = task_file_to_json(task)
      let path = task_file_path(project_dir, task_args.id)
      if @io.write_file_sync(path, content) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "created": @types.wire_bool(true),
          "task": @types.wire_raw(content),
        })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    "task_update" => {
      let update_args = match parse_task_update_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let task = match read_task_file(project_dir, update_args.id) {
        Ok(value) => value
        Err(e) => return @types.Response::Err(e)
      }
      let updated = {
        ..task,
        status: update_args.status.unwrap_or(task.status),
        assignee: update_args.assignee.unwrap_or(task.assignee),
        notes: update_args.notes.unwrap_or(task.notes),
      }
      let content = task_file_to_json(updated)
      let path = task_file_path(project_dir, update_args.id)
      if @io.write_file_sync(path, content) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "task": @types.wire_raw(content),
        })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    "spawn_gemini" => {
      let spawn_args = match parse_leaf_spawn_args(tool_args, "gemini-leaf") {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let spec = @types.SpawnSpec::{
        slug: spawn_args.slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Gemini,
        task: spawn_args.task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: spawn_args.caller_id,
        parent_branch: spawn_args.parent_branch,
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        terminal_backend~,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({
            "status": @types.wire_string("spawned"),
            "agent_id": @types.wire_string(
              @workspace.branch_name(spawn_args.parent_branch, spawn_args.slug),
            ),
            "slug": @types.wire_string(spawn_args.slug),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "spawn_moon_pilot" => {
      let spawn_args = match
        parse_leaf_spawn_args(tool_args, "moon-pilot-leaf") {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let spec = @types.SpawnSpec::{
        slug: spawn_args.slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::MoonPilot,
        task: spawn_args.task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: spawn_args.caller_id,
        parent_branch: spawn_args.parent_branch,
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        terminal_backend~,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({
            "status": @types.wire_string("spawned"),
            "agent_id": @types.wire_string(
              @workspace.branch_name(spawn_args.parent_branch, spawn_args.slug),
            ),
            "slug": @types.wire_string(spawn_args.slug),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "spawn_remote" => {
      let spawn_args = match parse_remote_spawn_args(project_dir, tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let spec = @types.SpawnSpec::{
        slug: spawn_args.slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: spawn_args.task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: spawn_args.caller_id,
        parent_branch: spawn_args.parent_branch,
      }
      let cmds = @workspace.remote_spawn_commands(
        spec,
        spawn_args.ssh_target,
        spawn_args.repo_url,
        spawn_args.tcp_addr,
        parent_session_id=spawn_args.parent_session_id,
        extra_mcp_servers_json~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({
            "status": @types.wire_string("spawned"),
            "agent_id": @types.wire_string(
              @workspace.branch_name(spawn_args.parent_branch, spawn_args.slug),
            ),
            "slug": @types.wire_string(spawn_args.slug),
            "host": @types.wire_string(spawn_args.ssh_target),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "spawn_worker" => {
      let worker_args = match parse_worker_spawn_args(tool_args) {
        Ok(parsed) => parsed
        Err(e) => return @types.Response::Err(e)
      }
      let spec = @types.SpawnSpec::{
        slug: worker_args.slug,
        role: @types.Role::Worker,
        agent_type: worker_args.agent_type,
        task: worker_args.task,
        isolation: @types.IsolationMode::Inline,
        parent_id: worker_args.caller_id,
        parent_branch: "main",
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        terminal_backend~,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({ "status": @types.wire_string("spawned") })
        Err(e) => @types.Response::Err(e)
      }
    }
    "reply" => {
      let id = match tool_args_get(tool_args, "id") {
        Some(v) => v
        None => return @types.Response::Err("missing id")
      }
      if id == "" {
        return @types.Response::Err("id cannot be empty")
      }
      let cancel = tool_args_get_bool(tool_args, "cancel")
      let payload = tool_args_get(tool_args, "payload").unwrap_or("")
      let value = if cancel { "cancel" } else { payload }
      let key = "reply/" + id
      match validate_kv_key(key) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      let path = kv_file_path(project_dir, key)
      if @io.write_file_sync(path, value) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "id": @types.wire_string(id),
        })
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
  terminal_backend? : @types.TerminalBackend = @types.TerminalBackend::Tmux,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
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
        { role: req.role, name: req.name, args: req.args.to_map() },
        project_dir~,
        session~,
        terminal_backend~,
        runner~,
        ensure_pr~,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
        registry=agent_registry,
        mutex_registry~,
        poller_state~,
        raw_args=Some(req.args),
      )
  }
}

///|
test "parse_file_pr_args accepts agent_id alias" {
  let parsed = parse_file_pr_args(
    tool_args_from_map({
      "agent_id": "main.leaf-1",
      "parent_branch": "main",
      "caller_id": "ignored-parent",
    }),
  ).unwrap()
  assert_eq(parsed, {
    branch: "main.leaf-1",
    parent_branch: "main",
    tracked_agent_id: "main.leaf-1",
  })
}

///|
test "parse_track_pr_args derives parent_branch from nested branch" {
  let parsed = parse_track_pr_args(
    tool_args_from_map({
      "pr_number": "17",
      "agent_id": "main.wave-2",
      "branch": "main.wave-2",
    }),
  ).unwrap()
  assert_eq(parsed, {
    pr_number: 17,
    agent_id: "main.wave-2",
    branch: "main.wave-2",
    parent_branch: "main",
    pr_url: "",
  })
}

///|
test "parse_track_pr_args preserves pr_url" {
  let parsed = parse_track_pr_args(
    tool_args_from_map({
      "pr_number": "23",
      "agent_id": "main.leaf-proof",
      "branch": "main.leaf-proof",
      "parent_branch": "main",
      "pr_url": "https://example.test/pr/23",
    }),
  ).unwrap()
  assert_eq(parsed.pr_url, "https://example.test/pr/23")
}

///|
test "parse_track_pr_args rejects invalid parent_branch" {
  match
    parse_track_pr_args(
      tool_args_from_map({
        "pr_number": "4",
        "agent_id": "main.leaf-proof",
        "branch": "main.leaf-proof",
        "parent_branch": "bad branch",
      }),
    ) {
    Ok(_) => assert_true(false)
    Err(e) =>
      assert_eq(e, "invalid parent_branch: invalid character in branch:  ")
  }
}

///|
test "parse_leaf_spawn_args accepts branch alias and base_branch alias" {
  let parsed = parse_leaf_spawn_args(
    tool_args_from_map({
      "branch": "gem-alias",
      "base_branch": "feature.root",
      "caller_id": "main",
    }),
    "gemini-leaf",
  ).unwrap()
  assert_eq(parsed.slug, "gem-alias")
  assert_eq(parsed.parent_branch, "feature.root")
  assert_eq(parsed.caller_id, "main")
}

///|
test "parse_worker_spawn_args defaults to gemini and agent_id alias" {
  let parsed = parse_worker_spawn_args(
    tool_args_from_map({ "agent_id": "worker-a", "task": "Investigate" }),
  ).unwrap()
  assert_eq(parsed.slug, "worker-a")
  assert_eq(parsed.agent_type, @types.AgentType::Gemini)
}

///|
test "parse_remote_spawn_args requires transport fields" {
  match
    parse_remote_spawn_args(
      ".",
      tool_args_from_map({
        "slug": "remote-1",
        "repo_url": "git@github.com:org/repo.git",
        "tcp_addr": "10.0.0.1:9100",
      }),
    ) {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "missing ssh_target")
  }
}

///|
test "parse_fork_wave_args applies defaults" {
  let parsed = parse_fork_wave_args(
    ".",
    tool_args_from_map({ "count": "2", "task": "Implement feature X" }),
  ).unwrap()
  assert_eq(parsed.count, 2)
  assert_eq(parsed.slug_prefix, "wave")
  assert_eq(parsed.parent_branch, "main")
  assert_eq(parsed.caller_id, "main")
  assert_eq(parsed.agent_type, @types.AgentType::Gemini)
}

///|
test "parse_fork_wave_args accepts explicit claude fanout" {
  let parsed = parse_fork_wave_args(
    ".",
    tool_args_from_map({
      "count": "2",
      "task": "Investigate architecture",
      "agent_type": "claude",
    }),
  ).unwrap()
  assert_eq(parsed.agent_type, @types.AgentType::Claude)
}

///|
test "parse_task_create_args defaults status to todo" {
  let parsed = parse_task_create_args(
    tool_args_from_map({ "id": "task-1", "title": "Build the thing" }),
  ).unwrap()
  assert_eq(parsed.status, "todo")
  assert_eq(parsed.assignee, "")
  assert_eq(parsed.notes, "")
}

///|
test "parse_task_update_args treats empty status as absent" {
  let parsed = parse_task_update_args(
    tool_args_from_map({ "id": "task-1", "status": "", "notes": "updated" }),
  ).unwrap()
  assert_eq(parsed.id, "task-1")
  assert_eq(parsed.status, None)
  assert_eq(parsed.notes, Some("updated"))
}

///|
test "parse_task_create_args rejects invalid status" {
  match
    parse_task_create_args(
      tool_args_from_map({
        "id": "task-1",
        "title": "Build the thing",
        "status": "blocked",
      }),
    ) {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid status: blocked")
  }
}

///|
test "parse_register_args defaults agent type from role" {
  let parsed = parse_register_args(
    @types.Role::Dev,
    tool_args_from_map({ "agent_id": "leaf-0", "workspace": "/tmp/leaf-0" }),
  ).unwrap()
  assert_eq(parsed.agent_id, "leaf-0")
  assert_eq(parsed.agent_type, @types.AgentType::Gemini)
  assert_eq(parsed.workspace, "/tmp/leaf-0")
}

///|
test "parse_kv_key_args rejects invalid key" {
  match parse_kv_key_args(tool_args_from_map({ "key": "../bad" })) {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "key cannot contain '..'")
  }
}

///|
test "parse_mutex_acquire_args defaults ttl_sec" {
  let parsed = parse_mutex_acquire_args(
    tool_args_from_map({ "name": "README", "agent_id": "agent-a" }),
  ).unwrap()
  assert_eq(parsed.ttl_sec, 300L)
}

///|
test "parse_mutex_release_args requires agent id" {
  match parse_mutex_release_args(tool_args_from_map({ "name": "README" })) {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "missing agent_id")
  }
}

///|
test "parse_merge_pr_args defaults branch and caller" {
  let parsed = parse_merge_pr_args(tool_args_from_map({ "pr_number": "42" })).unwrap()
  assert_eq(parsed.pr_number, 42)
  assert_eq(parsed.parent_branch, "main")
  assert_eq(parsed.caller_id, "server")
}

///|
test "parse_caller_message_args requires caller_id" {
  match parse_caller_message_args(tool_args_from_map({ "message": "hello" })) {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "missing caller_id")
  }
}

///|
test "parse_send_message_args defaults sender and status" {
  let parsed = parse_send_message_args(
    tool_args_from_map({ "target_id": "leaf-1" }),
  ).unwrap()
  assert_eq(parsed.target_id, "leaf-1")
  assert_eq(parsed.sender_id, "unknown")
  assert_eq(parsed.status, "info")
}

///|
test "parse_session_name_args validates slug" {
  match parse_session_name_args(tool_args_from_map({ "name": "../evil" })) {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e, "invalid name: invalid character in slug: .")
  }
}

///|
test "parse_shutdown_args allows best effort empty caller" {
  let parsed = parse_shutdown_args(tool_args_from_map({}))
  assert_eq(parsed.caller_id, None)
}
