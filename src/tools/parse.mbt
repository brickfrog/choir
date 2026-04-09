///|
pub(all) enum ParseError {
  MissingField(field~ : String)
  InvalidValue(field~ : String, value~ : String)
  InvalidFormat(field~ : String, message~ : String)
  UnknownTool(name~ : String)
  UnknownRole(value~ : String)
  UnknownAgentType(value~ : String)
  UnknownTaskStatus(value~ : String)
  UnknownStatus(value~ : String)
} derive(Debug, Eq)

///|
pub fn ParseError::message(self : ParseError) -> String {
  match self {
    MissingField(field~) => "missing " + field
    InvalidValue(field~, value~) => "invalid " + field + ": " + value
    InvalidFormat(field~, message~) => "invalid " + field + ": " + message
    UnknownTool(name~) => "unknown tool: " + name
    UnknownRole(value~) => "invalid role: " + value
    UnknownAgentType(value~) => "invalid agent_type: " + value
    UnknownTaskStatus(value~) => "invalid task status: " + value
    UnknownStatus(value~) => "invalid status: " + value
  }
}

///|
fn parse_int(s : String) -> Int? {
  Some(@string.parse_int(s.trim().to_string())) catch {
    _ => None
  }
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
  if !tool_args_get_bool(args, "fork_session") {
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
  let session_id = @sys.read_file(path).trim().to_string()
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
fn validate_slug(s : String) -> Result[Unit, @types.ChoirError] {
  if s == "" {
    return Err(@types.ChoirError::validation_error("slug cannot be empty"))
  }
  for c in s {
    if !is_alphanumeric_or_dash(c) {
      return Err(
        @types.ChoirError::validation_error(
          "invalid character in slug: " + c.to_string(),
        ),
      )
    }
  }
  Ok(())
}

///|
fn validate_branch(s : String) -> Result[Unit, @types.ChoirError] {
  if s == "" {
    return Err(@types.ChoirError::validation_error("branch cannot be empty"))
  }
  for c in s {
    if !is_alphanumeric_or_dash(c) && c != '.' {
      return Err(
        @types.ChoirError::validation_error(
          "invalid character in branch: " + c.to_string(),
        ),
      )
    }
  }
  if s.contains("..") {
    return Err(
      @types.ChoirError::validation_error("branch cannot contain '..'"),
    )
  }
  Ok(())
}

///|
fn validate_kv_key(s : String) -> Result[Unit, @types.ChoirError] {
  if s == "" {
    return Err(@types.ChoirError::validation_error("key cannot be empty"))
  }
  if s.contains("..") {
    return Err(@types.ChoirError::validation_error("key cannot contain '..'"))
  }
  if s[0] == '/' {
    return Err(@types.ChoirError::validation_error("key cannot start with '/'"))
  }
  for c in s {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '/' ||
      c == '.') {
      return Err(
        @types.ChoirError::validation_error(
          "invalid character in key: " + c.to_string(),
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn parse_file_pr_args(args : ToolArgs) -> Result[FilePrArgs, ParseError] {
  let branch = get_arg_or_alias(args, "branch", "agent_id", "")
  if branch == "" {
    return Err(ParseError::MissingField(field="branch"))
  }
  let parent_branch = match tool_args_get(args, "parent_branch") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  match validate_branch(branch) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="branch",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  match parent_branch {
    Some(pb) =>
      match validate_branch(pb) {
        Ok(_) => ()
        Err(e) =>
          return Err(
            ParseError::InvalidFormat(
              field="parent_branch",
              message=e.validation_detail_or_message(),
            ),
          )
      }
    None => ()
  }
  let title = match tool_args_get(args, "title") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let body = match tool_args_get(args, "body") {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
  let review_context = match tool_args_get(args, "review_context") {
    Some(v) => {
      let t = v.trim().to_string()
      if t == "" {
        None
      } else {
        Some(t)
      }
    }
    None => None
  }
  Ok({
    branch,
    parent_branch,
    tracked_agent_id: get_arg_or_alias(args, "agent_id", "caller_id", branch),
    title,
    body,
    review_context,
  })
}

///|
fn parse_track_pr_args(args : ToolArgs) -> Result[TrackPrArgs, ParseError] {
  let pr_str = tool_args_get(args, "pr_number").unwrap_or("")
  if pr_str == "" {
    return Err(ParseError::MissingField(field="pr_number"))
  }
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err(ParseError::MissingField(field="agent_id"))
  }
  let pr_number = match tool_args_get_int(args, "pr_number") {
    Some(value) => value
    None =>
      return Err(ParseError::InvalidValue(field="pr_number", value=pr_str))
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
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="branch",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="parent_branch",
          message=e.validation_detail_or_message(),
        ),
      )
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
        let task = trimmed[i + 1:j].to_string()
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
pub fn slugify_task(task : String, index : Int) -> String {
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
    result[0:result.length() - 1].to_string()
  } else {
    result
  }
}

///|
fn prompt_spec_with_task(spec : PromptSpec, task : String) -> PromptSpec {
  let trimmed = task.trim().to_string()
  {
    ..spec,
    task: trimmed,
    task_contract: { ..spec.task_contract, goal: trimmed },
  }
}

///|
fn parse_rescue_leaf_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[RescueLeafArgs, ParseError] {
  let prompt_spec = prompt_spec_from_tool_args(args)
  let task = prompt_spec.task
  if task == "" {
    return Err(ParseError::MissingField(field="task"))
  }
  let caller_id = match tool_args_get(args, "caller_id") {
    Some(v) =>
      if v == "" {
        return Err(ParseError::MissingField(field="caller_id"))
      } else {
        v
      }
    None => return Err(ParseError::MissingField(field="caller_id"))
  }
  let from_agent_id = tool_args_get(args, "from_agent_id").unwrap_or("")
  if from_agent_id == "" {
    return Err(ParseError::MissingField(field="from_agent_id"))
  }
  match validate_branch(from_agent_id) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="from_agent_id",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let new_slug = match tool_args_get(args, "new_slug") {
    Some(v) =>
      if v == "" {
        return Err(ParseError::MissingField(field="new_slug"))
      } else {
        v
      }
    None => return Err(ParseError::MissingField(field="new_slug"))
  }
  match validate_slug(new_slug) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="new_slug",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let agent_type_str = tool_args_get(args, "agent_type").unwrap_or(
    "cursor_agent",
  )
  let normalized = if agent_type_str == "" {
    "cursor_agent"
  } else {
    agent_type_str
  }
  let agent_type = match parse_agent_type(normalized) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let parent_session_id = lookup_parent_session_id(project_dir, args)
  Ok({
    task,
    task_contract: prompt_spec.task_contract,
    caller_id,
    from_agent_id,
    new_slug,
    agent_type,
    parent_session_id,
  })
}

///|
fn parse_spawn_gemini_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[SpawnGeminiArgs, ParseError] {
  let prompt_spec = prompt_spec_from_tool_args(args)
  let task = prompt_spec.task
  if task == "" {
    return Err(ParseError::MissingField(field="task"))
  }
  let caller_id = tool_args_get(args, "caller_id").unwrap_or("main")
  let slug = match tool_args_get(args, "slug") {
    Some(v) => if v == "" { slugify_task(task, 0) } else { v }
    None => slugify_task(task, 0)
  }
  match validate_slug(slug) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="slug",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let parent_branch = tool_args_get(args, "parent_branch").unwrap_or("main")
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="parent_branch",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let parent_session_id = lookup_parent_session_id(project_dir, args)
  Ok({
    task,
    task_contract: prompt_spec.task_contract,
    caller_id,
    slug,
    parent_branch,
    parent_session_id,
  })
}

///|
pub fn parse_fork_wave_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[ForkWaveArgs, ParseError] {
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
      return Err(ParseError::MissingField(field="count"))
    }
    match tool_args_get_int(args, "count") {
      Some(c) => c
      None =>
        return Err(
          ParseError::InvalidValue(
            field="count",
            value=tool_args_get(args, "count").unwrap_or(""),
          ),
        )
    }
  }
  let default_read_first = @workspace.resolve_context_paths(project_dir, "dev")
  let base_spec = prompt_spec_from_tool_args(args)
  let task_contracts : Array[@types.TaskContract] = []
  let tasks = if per_leaf_tasks.length() > 0 {
    // Render each per-leaf task through the prompt builder
    let rendered : Array[String] = []
    for task in per_leaf_tasks {
      let spec = prompt_spec_with_task(base_spec, task)
      rendered.push(
        render_leaf_spawn_prompt_with_defaults(spec, default_read_first),
      )
      task_contracts.push(spec.task_contract)
    }
    rendered
  } else {
    // Shared task — same prompt for all leaves
    let shared = render_leaf_spawn_prompt_with_defaults(
      base_spec, default_read_first,
    )
    let arr : Array[String] = []
    for i = 0; i < count; i = i + 1 {
      arr.push(shared)
      task_contracts.push(base_spec.task_contract)
    }
    arr
  }
  let parent_branch = get_arg_or_alias(args, "parent_branch", "branch", "main")
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="parent_branch",
          message=e.validation_detail_or_message(),
        ),
      )
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
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="slug_prefix",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let role_raw = tool_args_get(args, "role").unwrap_or("dev")
  let normalized_role = role_raw.trim().to_lower().to_string()
  let role_norm = if normalized_role == "" { "dev" } else { normalized_role }
  let child_role = match role_norm {
    "dev" => @types.Role::Dev
    "tl" => @types.Role::TL
    _ => return Err(ParseError::UnknownRole(value=role_raw))
  }
  let review_context = match tool_args_get(args, "review_context") {
    Some(v) => {
      let t = v.trim().to_string()
      if t == "" {
        None
      } else {
        Some(t)
      }
    }
    None => None
  }
  let automerge = match tool_args_get(args, "automerge") {
    Some(v) => parse_truthy_spawn_flag(v)
    None => false
  }
  Ok({
    count,
    tasks,
    task_contracts,
    has_per_leaf_tasks: per_leaf_tasks.length() > 0,
    parent_branch,
    caller_id: tool_args_get(args, "caller_id").unwrap_or("main"),
    slug_prefix: normalized_slug_prefix,
    agent_type,
    child_role,
    parent_session_id: lookup_parent_session_id(project_dir, args),
    review_context,
    automerge,
  })
}

///|
fn parse_leaf_spawn_args(
  project_dir : String,
  args : ToolArgs,
  default_slug : String,
) -> Result[LeafSpawnArgs, ParseError] {
  let prompt_spec = prompt_spec_from_tool_args(args)
  let slug = get_arg_or_alias(args, "slug", "branch", default_slug)
  let parent_branch = get_arg_or_alias(
    args, "parent_branch", "base_branch", "main",
  )
  match validate_slug(slug) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="slug",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  match validate_branch(parent_branch) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="parent_branch",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  Ok({
    task: render_leaf_spawn_prompt_with_defaults(
      prompt_spec,
      @workspace.resolve_context_paths(project_dir, "dev"),
    ),
    task_contract: prompt_spec.task_contract,
    caller_id: tool_args_get(args, "caller_id").unwrap_or("main"),
    slug,
    parent_branch,
  })
}

///|
fn parse_worker_spawn_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[WorkerSpawnArgs, ParseError] {
  let prompt_spec = prompt_spec_from_tool_args(args)
  match prompt_spec.worker_type {
    "research" => ()
    "review" => ()
    _ =>
      return Err(
        ParseError::InvalidValue(
          field="worker_type",
          value=prompt_spec.worker_type,
        ),
      )
  }
  let slug = get_arg_or_alias(args, "slug", "agent_id", "inline-worker")
  match validate_slug(slug) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="slug",
          message=e.validation_detail_or_message(),
        ),
      )
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
    task: render_worker_spawn_prompt_with_defaults(
      prompt_spec,
      @workspace.resolve_context_paths(project_dir, "worker"),
    ),
    task_contract: prompt_spec.task_contract,
    caller_id: tool_args_get(args, "caller_id").unwrap_or("main"),
    slug,
    agent_type,
  })
}

///|
fn parse_remote_spawn_args(
  project_dir : String,
  args : ToolArgs,
) -> Result[RemoteSpawnArgs, ParseError] {
  let leaf_args = match
    parse_leaf_spawn_args(project_dir, args, "remote-leaf") {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let ssh_target = tool_args_get(args, "ssh_target").unwrap_or("")
  if ssh_target == "" {
    return Err(ParseError::MissingField(field="ssh_target"))
  }
  let repo_url = tool_args_get(args, "repo_url").unwrap_or("")
  if repo_url == "" {
    return Err(ParseError::MissingField(field="repo_url"))
  }
  let tcp_addr = tool_args_get(args, "tcp_addr").unwrap_or("")
  if tcp_addr == "" {
    return Err(ParseError::MissingField(field="tcp_addr"))
  }
  Ok({
    task: leaf_args.task,
    task_contract: leaf_args.task_contract,
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
fn parse_task_create_args(
  args : ToolArgs,
) -> Result[TaskCreateArgs, ParseError] {
  let id = tool_args_get(args, "id").unwrap_or("")
  if id == "" {
    return Err(ParseError::MissingField(field="id"))
  }
  let title = tool_args_get(args, "title").unwrap_or("")
  if title == "" {
    return Err(ParseError::MissingField(field="title"))
  }
  match validate_slug(id) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="id",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let status = tool_args_get(args, "status").unwrap_or("todo")
  let normalized_status = if status == "" { "todo" } else { status }
  let task_status = match validate_task_status(normalized_status) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  Ok({
    id,
    title,
    status: task_status,
    assignee: tool_args_get(args, "assignee").unwrap_or(""),
    notes: tool_args_get(args, "notes").unwrap_or(""),
  })
}

///|
fn parse_task_update_args(
  args : ToolArgs,
) -> Result[TaskUpdateArgs, ParseError] {
  let id = tool_args_get(args, "id").unwrap_or("")
  if id == "" {
    return Err(ParseError::MissingField(field="id"))
  }
  let status = match tool_args_get(args, "status") {
    Some(v) =>
      if v == "" {
        None
      } else {
        match validate_task_status(v) {
          Ok(s) => Some(s)
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
) -> Result[RegisterArgs, ParseError] {
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err(ParseError::MissingField(field="agent_id"))
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
  let spawn_depth = match tool_args_get(args, "spawn_depth") {
    None => 0
    Some(s) => {
      let t = s.trim().to_string()
      if t == "" {
        0
      } else {
        match parse_int(t) {
          Some(d) =>
            if d < 0 || d > 1 {
              return Err(
                ParseError::InvalidFormat(
                  field="spawn_depth",
                  message="must be 0 or 1",
                ),
              )
            } else {
              d
            }
          None =>
            return Err(ParseError::InvalidValue(field="spawn_depth", value=s))
        }
      }
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
      Some(v) => if v == "" { None } else { @types.LocalTarget::parse(v) }
      None => None
    },
    workspace: tool_args_get(args, "workspace").unwrap_or(""),
    branch: tool_args_get(args, "branch").unwrap_or(""),
    spawn_depth,
  })
}

///|
fn parse_kv_key_args(args : ToolArgs) -> Result[KvKeyArgs, ParseError] {
  let key = tool_args_get(args, "key").unwrap_or("")
  if key == "" {
    return Err(ParseError::MissingField(field="key"))
  }
  match validate_kv_key(key) {
    Ok(_) => Ok({ key, })
    Err(e) =>
      Err(
        ParseError::InvalidFormat(
          field="key",
          message=e.validation_detail_or_message(),
        ),
      )
  }
}

///|
fn parse_kv_set_args(args : ToolArgs) -> Result[KvSetArgs, ParseError] {
  let key_args = match parse_kv_key_args(args) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let value = match tool_args_get(args, "value") {
    Some(v) => v
    None => return Err(ParseError::MissingField(field="value"))
  }
  Ok({ key: key_args.key, value })
}

///|
fn parse_mutex_acquire_args(
  args : ToolArgs,
) -> Result[MutexAcquireArgs, ParseError] {
  let name = tool_args_get(args, "name").unwrap_or("")
  if name == "" {
    return Err(ParseError::MissingField(field="name"))
  }
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err(ParseError::MissingField(field="agent_id"))
  }
  let ttl_str = tool_args_get(args, "ttl_sec").unwrap_or("300")
  let ttl_sec = if ttl_str == "" ||
    (ttl_str == "300" && !args.values.contains("ttl_sec")) {
    300L
  } else {
    match tool_args_get_int(args, "ttl_sec") {
      Some(value) => value.to_int64()
      None =>
        return Err(ParseError::InvalidValue(field="ttl_sec", value=ttl_str))
    }
  }
  Ok({ name, agent_id, ttl_sec })
}

///|
fn parse_mutex_name_args(args : ToolArgs) -> Result[MutexNameArgs, ParseError] {
  let name = tool_args_get(args, "name").unwrap_or("")
  if name == "" {
    return Err(ParseError::MissingField(field="name"))
  }
  Ok({ name, })
}

///|
fn parse_mutex_release_args(
  args : ToolArgs,
) -> Result[MutexReleaseArgs, ParseError] {
  let name_args = match parse_mutex_name_args(args) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
  if agent_id == "" {
    return Err(ParseError::MissingField(field="agent_id"))
  }
  Ok({ name: name_args.name, agent_id })
}

///|
fn validate_thread_id(s : String) -> Result[Unit, @types.ChoirError] {
  if s == "" {
    return Err(@types.ChoirError::validation_error("thread_id cannot be empty"))
  }
  for c in s {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-' ||
      c == '='
    if !ok {
      return Err(
        @types.ChoirError::validation_error(
          "invalid character in thread_id: " + c.to_string(),
        ),
      )
    }
  }
  Ok(())
}

///|
fn parse_resolve_review_thread_args(
  args : ToolArgs,
) -> Result[ResolveReviewThreadArgs, ParseError] {
  let thread_id = tool_args_get(args, "thread_id").unwrap_or("")
  if thread_id == "" {
    return Err(ParseError::MissingField(field="thread_id"))
  }
  match validate_thread_id(thread_id) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="thread_id",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  let caller_id = match tool_args_get(args, "caller_id") {
    Some(v) => if v == "" { "server" } else { v }
    None => "server"
  }
  Ok({ thread_id, caller_id })
}

///|
fn parse_merge_pr_args(args : ToolArgs) -> Result[MergePrArgs, ParseError] {
  let pr_str = tool_args_get(args, "pr_number").unwrap_or("")
  if pr_str == "" {
    return Err(ParseError::MissingField(field="pr_number"))
  }
  let pr_number = match tool_args_get_int(args, "pr_number") {
    Some(value) => value
    None =>
      return Err(ParseError::InvalidValue(field="pr_number", value=pr_str))
  }
  let parent_branch = tool_args_get(args, "parent_branch").unwrap_or("main")
  let normalized_parent_branch = if parent_branch == "" {
    "main"
  } else {
    parent_branch
  }
  match validate_branch(normalized_parent_branch) {
    Ok(_) => ()
    Err(e) =>
      return Err(
        ParseError::InvalidFormat(
          field="parent_branch",
          message=e.validation_detail_or_message(),
        ),
      )
  }
  Ok({
    pr_number,
    parent_branch: normalized_parent_branch,
    caller_id: match tool_args_get(args, "caller_id") {
      Some(v) => if v == "" { "server" } else { v }
      None => "server"
    },
    force: match tool_args_get(args, "force") {
      Some(v) => {
        let lowered = v.trim().to_lower()
        lowered == "true" || lowered == "1" || lowered == "yes"
      }
      None => false
    },
  })
}

///|
fn validate_status(status : String) -> Result[@types.Status, ParseError] {
  match @types.Status::try_parse_wire(status) {
    Ok(s) => Ok(s)
    Err(_) => Err(ParseError::UnknownStatus(value=status))
  }
}

///|
fn parse_caller_message_args(
  args : ToolArgs,
) -> Result[CallerMessageArgs, ParseError] {
  let caller_id = tool_args_get(args, "caller_id").unwrap_or("")
  if caller_id == "" {
    return Err(ParseError::MissingField(field="caller_id"))
  }
  let status = match
    validate_status(tool_args_get(args, "status").unwrap_or("info")) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  Ok({
    caller_id,
    message: tool_args_get(args, "message").unwrap_or(""),
    status,
  })
}

///|
fn parse_send_message_args(
  args : ToolArgs,
) -> Result[SendMessageArgs, ParseError] {
  let target_id = tool_args_get(args, "target_id").unwrap_or("")
  if target_id == "" {
    return Err(ParseError::MissingField(field="target_id"))
  }
  let status = match
    validate_status(tool_args_get(args, "status").unwrap_or("info")) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  Ok({
    target_id,
    sender_id: tool_args_get(args, "sender_id").unwrap_or("unknown"),
    message: tool_args_get(args, "message").unwrap_or(""),
    status,
  })
}

///|
fn parse_shutdown_args(args : ToolArgs) -> ShutdownArgs {
  { caller_id: tool_args_get(args, "caller_id") }
}

///|
fn parse_id_args(args : ToolArgs) -> Result[IdArgs, ParseError] {
  let id = tool_args_get(args, "id").unwrap_or("")
  if id == "" {
    return Err(ParseError::MissingField(field="id"))
  }
  Ok({ id, })
}

///|
fn parse_session_name_args(
  args : ToolArgs,
) -> Result[SessionNameArgs, ParseError] {
  let name = tool_args_get(args, "name").unwrap_or("")
  if name == "" {
    return Err(ParseError::MissingField(field="name"))
  }
  match validate_slug(name) {
    Ok(_) => Ok({ name, })
    Err(e) =>
      Err(
        ParseError::InvalidFormat(
          field="name",
          message=e.validation_detail_or_message(),
        ),
      )
  }
}

///|
fn validate_task_status(
  status : String,
) -> Result[@types.TaskStatus, ParseError] {
  match @types.TaskStatus::try_parse_wire(status) {
    Ok(s) => Ok(s)
    Err(_) => Err(ParseError::UnknownTaskStatus(value=status))
  }
}

///|
fn parse_agent_type(s : String) -> Result[@types.AgentType, ParseError] {
  match s {
    "claude" => Ok(@types.AgentType::Claude)
    "gemini" => Ok(@types.AgentType::Gemini)
    "moon_pilot" => Ok(@types.AgentType::MoonPilot)
    "moonpilot" => Ok(@types.AgentType::MoonPilot)
    "codex" => Ok(@types.AgentType::Codex)
    "cursor_agent" => Ok(@types.AgentType::CursorAgent)
    "cursoragent" => Ok(@types.AgentType::CursorAgent)
    _ => Err(ParseError::UnknownAgentType(value=s))
  }
}

///|
fn parse_reply_args(args : ToolArgs) -> Result[ReplyArgs, ParseError] {
  let id = match tool_args_get(args, "id") {
    Some(v) => v
    None => return Err(ParseError::MissingField(field="id"))
  }
  if id == "" {
    return Err(ParseError::InvalidFormat(field="id", message="cannot be empty"))
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
) -> Result[ToolRequest, ParseError] {
  match name {
    "register" =>
      parse_register_args(_role, args).map(fn(a) { ToolRequest::Register(a) })
    "spawn_gemini" =>
      parse_spawn_gemini_args(_project_dir, args).map(fn(a) {
        ToolRequest::SpawnGemini(a)
      })
    "rescue_leaf" =>
      parse_rescue_leaf_args(_project_dir, args).map(fn(a) {
        ToolRequest::RescueLeaf(a)
      })
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
      parse_worker_spawn_args(_project_dir, args).map(fn(a) {
        ToolRequest::SpawnWorker(a)
      })
    "kill_agent" => {
      let agent_id = tool_args_get(args, "agent_id").unwrap_or("")
      if agent_id == "" {
        Err(ParseError::MissingField(field="agent_id"))
      } else {
        let reason = tool_args_get(args, "reason").unwrap_or("killed by parent")
        Ok(ToolRequest::KillAgent({ agent_id, reason }))
      }
    }
    "agent_list" => {
      let parent_id = match tool_args_get(args, "parent_id") {
        Some(v) =>
          if v.trim() == "" {
            None
          } else {
            Some(v.trim().to_string())
          }
        None => None
      }
      let include_inactive = tool_args_get_bool(args, "include_inactive")
      Ok(ToolRequest::AgentList({ parent_id, include_inactive }))
    }
    "cancel_wave" => {
      let force = tool_args_get_bool(args, "force")
      Ok(ToolRequest::CancelWave({ force, }))
    }
    "resolve_review_thread" =>
      parse_resolve_review_thread_args(args).map(fn(a) {
        ToolRequest::ResolveReviewThread(a)
      })
    _ => Err(ParseError::UnknownTool(name~))
  }
}

///|
test "parse_leaf_spawn_args only injects existing context paths" {
  let project_dir = "/tmp/choir-parse-leaf-context-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  ignore(@sys.system("mkdir -p \"" + project_dir + "/.choir/context\""))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/context/common.md",
      "# common\n",
    ),
  )
  let parsed = parse_leaf_spawn_args(
    project_dir,
    tool_args_from_map({ "task": "ship it", "caller_id": "root" }),
    "leaf-a",
  ).unwrap()
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  assert_true(parsed.task.contains("/.choir/context/common.md"))
  assert_false(parsed.task.contains("/.choir/context/dev.md"))
}

///|
test "parse_worker_spawn_args only injects existing context paths" {
  let project_dir = "/tmp/choir-parse-worker-context-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  ignore(@sys.system("mkdir -p \"" + project_dir + "/.choir/context\""))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/context/common.md",
      "# common\n",
    ),
  )
  let parsed = parse_worker_spawn_args(
    project_dir,
    tool_args_from_map({ "task": "report findings", "caller_id": "root" }),
  ).unwrap()
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  assert_true(parsed.task.contains("/.choir/context/common.md"))
  assert_false(parsed.task.contains("/.choir/context/worker.md"))
}

///|
test "parse_fork_wave_args merges nested contract object with top-level task" {
  let args : ToolArgs = {
    values: {
      "count": (1).to_json(),
      "caller_id": "root".to_json(),
      "parent_branch": "main".to_json(),
      "task": "Ship feature".to_json(),
      "contract": {
        "scope": ["src/tools", "src/poller"].to_json(),
        "acceptance_checks": ["All tests pass"].to_json(),
        "verify": ["moon test --target native"].to_json(),
      }.to_json(),
    },
  }
  match parse_fork_wave_args(".", args) {
    Ok(parsed) => {
      assert_eq(parsed.task_contracts.length(), 1)
      assert_eq(parsed.task_contracts[0].goal, "Ship feature")
      assert_eq(parsed.task_contracts[0].scope, ["src/tools", "src/poller"])
      assert_eq(parsed.task_contracts[0].verify, ["moon test --target native"])
      assert_true(parsed.tasks[0].contains("## SCOPE"))
      assert_true(parsed.tasks[0].contains("All tests pass"))
    }
    Err(e) => fail("unexpected parse error: " + e.message())
  }
}

///|
test "parse_resolve_review_thread_args requires thread_id" {
  match parse_resolve_review_thread_args(tool_args_from_map({})) {
    Err(ParseError::MissingField(field~)) => assert_eq(field, "thread_id")
    _ => fail("expected MissingField(thread_id)")
  }
}

///|
test "parse_resolve_review_thread_args rejects double-quote in thread_id" {
  match
    parse_resolve_review_thread_args(
      tool_args_from_map({ "thread_id": "abc\"def" }),
    ) {
    Err(ParseError::InvalidFormat(field~, ..)) => assert_eq(field, "thread_id")
    _ => fail("expected InvalidFormat(thread_id)")
  }
}

///|
test "parse_resolve_review_thread_args accepts valid thread_id" {
  match
    parse_resolve_review_thread_args(
      tool_args_from_map({
        "thread_id": "PRRT_kwDOABcdef",
        "caller_id": "agent-1",
      }),
    ) {
    Ok(args) => {
      assert_eq(args.thread_id, "PRRT_kwDOABcdef")
      assert_eq(args.caller_id, "agent-1")
    }
    Err(e) => fail("unexpected error: " + e.message())
  }
}

///|
pub impl Show for ParseError with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
