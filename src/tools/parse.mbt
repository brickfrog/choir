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
  let parent_branch = match tool_args_get(args, "parent_branch") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  match validate_branch(branch) {
    Ok(_) => ()
    Err(e) => return Err("invalid branch: " + e)
  }
  match parent_branch {
    Some(pb) =>
      match validate_branch(pb) {
        Ok(_) => ()
        Err(e) => return Err("invalid parent_branch: " + e)
      }
    None => ()
  }
  Ok({
    branch,
    parent_branch,
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

///|
/// Split a "tasks" value into individual task strings.
/// Accepts JSON array format ["task1","task2"] or newline-separated.
fn parse_tasks_array(raw : String) -> Array[String] {
  let trimmed = raw.trim().to_string()
  if trimmed.length() > 0 && trimmed[0] == '[' {
    // JSON array — extract quoted strings
    let tasks : Array[String] = []
    let mut i = 1
    while i < trimmed.length() {
      if trimmed[i] == '"' {
        let mut j = i + 1
        while j < trimmed.length() && trimmed[j] != '"' {
          if trimmed[j] == '\\' {
            j = j + 1
          }
          j = j + 1
        }
        let task = trimmed[i + 1:j].to_string() catch { _ => "" }
        if task != "" {
          tasks.push(task)
        }
        i = j + 1
      } else {
        i = i + 1
      }
    }
    tasks
  } else {
    // Newline-separated
    let parts : Array[String] = []
    let buf = StringBuilder::new()
    for c in trimmed {
      if c == '\n' {
        let part = buf.to_string().trim().to_string()
        if part != "" {
          parts.push(part)
        }
        buf.reset()
      } else {
        buf.write_char(c)
      }
    }
    let last = buf.to_string().trim().to_string()
    if last != "" {
      parts.push(last)
    }
    parts
  }
}

///|

///|
/// Generate a slug from task text: first few words, lowercased, hyphenated.
fn slugify_task(task : String, index : Int) -> String {
  let buf = StringBuilder::new()
  let mut word_count = 0
  let mut in_word = false
  for c in task {
    if c == ' ' || c == '\n' || c == '\t' || c == '.' || c == ',' || c == ':' {
      if in_word {
        word_count = word_count + 1
        in_word = false
        if word_count >= 4 {
          break
        }
        buf.write_char('-')
      }
    } else if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
      buf.write_char(c)
      in_word = true
    } else if c >= 'A' && c <= 'Z' {
      buf.write_char(Int::unsafe_to_char(c.to_int() + 32))
      in_word = true
    }
    // skip other chars
  }
  let result = buf.to_string()
  if result == "" {
    "leaf-" + index.to_string()
    // Trim trailing hyphen
  } else if result.has_suffix("-") {
    result[0:result.length() - 1].to_string() catch {
      _ => result
    }
  } else {
    result
  }
}

///|
fn parse_fork_wave_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[ForkWaveArgs, String] {
  // Determine tasks: either per-leaf "tasks" array or shared "task" string
  let tasks_raw = tool_args_get(args, "tasks").unwrap_or("")
  let per_leaf_tasks = if tasks_raw != "" {
    parse_tasks_array(tasks_raw)
  } else {
    []
  }
  let count = if per_leaf_tasks.length() > 0 {
    // Count derived from tasks array length
    per_leaf_tasks.length()
  } else {
    let count_str = tool_args_get(args, "count").unwrap_or("")
    if count_str == "" {
      return Err("missing count (or provide tasks array)")
    }
    match tool_args_get_int(args, "count") {
      Some(c) => c
      None => return Err("invalid count: " + count_str)
    }
  }
  let tasks = if per_leaf_tasks.length() > 0 {
    // Render each per-leaf task through the prompt builder
    let rendered : Array[String] = []
    for task in per_leaf_tasks {
      let spec = prompt_spec_from_tool_args(args)
      rendered.push(render_leaf_spawn_prompt({ ..spec, task, }))
    }
    rendered
  } else {
    // Shared task — same prompt for all leaves
    let shared = render_leaf_spawn_prompt(prompt_spec_from_tool_args(args))
    let arr : Array[String] = []
    for i = 0; i < count; i = i + 1 {
      arr.push(shared)
    }
    arr
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
    tasks,
    has_per_leaf_tasks: per_leaf_tasks.length() > 0,
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
fn validate_task_status(status : String) -> Result[Unit, String] {
  match status {
    "todo" | "in_progress" | "done" => Ok(())
    _ => Err("invalid status: " + status)
  }
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
fn parse_reply_args(args : ToolArgs) -> Result[ReplyArgs, String] {
  let id = match tool_args_get(args, "id") {
    Some(v) => v
    None => return Err("missing id")
  }
  if id == "" {
    return Err("id cannot be empty")
  }
  let cancel = tool_args_get_bool(args, "cancel")
  let payload = tool_args_get(args, "payload").unwrap_or("")
  Ok({ id, payload, cancel })
}

///|
fn parse_tool_request(
  name : String,
  _role : @types.Role,
  _project_dir : String,
  args : ToolArgs,
) -> Result[ToolRequest, String] {
  match name {
    "register" =>
      parse_register_args(_role, args).map(fn(a) { ToolRequest::Register(a) })
    "fork_wave" =>
      parse_fork_wave_args(_project_dir, args).map(fn(a) {
        ToolRequest::ForkWave(a)
      })
    "fork_session" =>
      parse_session_name_args(args).map(fn(a) { ToolRequest::ForkSession(a) })
    "file_pr" => parse_file_pr_args(args).map(fn(a) { ToolRequest::FilePr(a) })
    "merge_pr" =>
      parse_merge_pr_args(args).map(fn(a) { ToolRequest::MergePr(a) })
    "track_pr" =>
      parse_track_pr_args(args).map(fn(a) { ToolRequest::TrackPr(a) })
    "notify_parent" =>
      parse_caller_message_args(args).map(fn(a) { ToolRequest::NotifyParent(a) })
    "send_message" =>
      parse_send_message_args(args).map(fn(a) { ToolRequest::SendMessage(a) })
    "reply" => parse_reply_args(args).map(fn(a) { ToolRequest::Reply(a) })
    "shutdown" => Ok(ToolRequest::Shutdown(parse_shutdown_args(args)))
    "kv_get" => parse_kv_key_args(args).map(fn(a) { ToolRequest::KvGet(a) })
    "kv_set" => parse_kv_set_args(args).map(fn(a) { ToolRequest::KvSet(a) })
    "kv_delete" =>
      parse_kv_key_args(args).map(fn(a) { ToolRequest::KvDelete(a) })
    "kv_list" => Ok(ToolRequest::KvList)
    "mutex_acquire" =>
      parse_mutex_acquire_args(args).map(fn(a) { ToolRequest::MutexAcquire(a) })
    "mutex_release" =>
      parse_mutex_release_args(args).map(fn(a) { ToolRequest::MutexRelease(a) })
    "mutex_status" =>
      parse_mutex_name_args(args).map(fn(a) { ToolRequest::MutexStatus(a) })
    "task_list" => Ok(ToolRequest::TaskList)
    "task_get" => parse_id_args(args).map(fn(a) { ToolRequest::TaskGet(a) })
    "task_create" =>
      parse_task_create_args(args).map(fn(a) { ToolRequest::TaskCreate(a) })
    "task_update" =>
      parse_task_update_args(args).map(fn(a) { ToolRequest::TaskUpdate(a) })
    "spawn_remote" =>
      parse_remote_spawn_args(_project_dir, args).map(fn(a) {
        ToolRequest::SpawnRemote(a)
      })
    "spawn_worker" =>
      parse_worker_spawn_args(args).map(fn(a) { ToolRequest::SpawnWorker(a) })
    _ => Err("unknown tool: " + name)
  }
}
