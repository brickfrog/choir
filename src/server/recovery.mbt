///|
priv struct OpenPR {
  pr_number : Int
  branch : String
  base : String
  url : String
}

///|
fn index_of(str : String, sub : String, start? : Int = 0) -> Int {
  let str_len = str.length()
  let sub_len = sub.length()
  if sub_len == 0 {
    return start
  }
  for i = start; i <= str_len - sub_len; i = i + 1 {
    let mut match_found = true
    for j = 0; j < sub_len; j = j + 1 {
      if str[i + j] != sub[j] {
        match_found = false
        break
      }
    }
    if match_found {
      return i
    }
  }
  -1
}

///|
fn index_of_quote_end(str : String, start : Int) -> Int {
  for i = start; i < str.length(); i = i + 1 {
    if str[i] == '"' && (i == 0 || str[i - 1] != '\\') {
      return i
    }
  }
  -1
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
fn split_lines(output : String) -> Array[String] {
  let lines = []
  for raw in output.split("\n") {
    let line = raw.to_string().trim().to_string()
    if line != "" {
      lines.push(line)
    }
  }
  lines
}

///|
fn find_json_string_field(
  data : String,
  field : String,
  start? : Int = 0,
) -> (String, Int)? {
  let field_name = "\"" + field + "\""
  let start_idx = index_of(data, field_name, start~)
  if start_idx == -1 {
    return None
  }
  let colon_idx = index_of(data, ":", start=start_idx + field_name.length())
  if colon_idx == -1 {
    return None
  }
  let value_start = skip_json_ws(data, colon_idx + 1)
  if value_start >= data.length() || data[value_start] != '"' {
    return None
  }
  let value_end = index_of_quote_end(data, value_start + 1)
  if value_end == -1 {
    return None
  }
  Some(
    (
      data[value_start + 1:value_end].to_string() catch {
        _ => ""
      },
      value_end + 1,
    ),
  )
}

///|
fn parse_open_prs(output : String) -> Array[OpenPR] {
  let prs = []
  let mut start = 0
  while start < output.length() {
    let object_start = index_of(output, "{", start~)
    if object_start == -1 {
      break
    }
    let mut object_end = -1
    let mut depth = 0
    let mut in_quote = false
    for i = object_start; i < output.length(); i = i + 1 {
      let c = output[i]
      if c == '"' && (i == 0 || output[i - 1] != '\\') {
        in_quote = not(in_quote)
      }
      if in_quote {
        continue
      }
      if c == '{' {
        depth = depth + 1
      } else if c == '}' {
        depth = depth - 1
        if depth == 0 {
          object_end = i
          break
        }
      }
    }
    if object_end == -1 {
      break
    }
    let obj = output[object_start:object_end + 1].to_string() catch { _ => "" }
    let number_idx = index_of(obj, "\"number\":")
    if number_idx != -1 {
      let number_start = skip_json_ws(obj, number_idx + 9)
      let mut number_end = number_start
      while number_end < obj.length() &&
            obj[number_end] >= '0' &&
            obj[number_end] <= '9' {
        number_end = number_end + 1
      }
      let number_str = obj[number_start:number_end].to_string() catch {
        _ => ""
      }
      let branch = match find_json_string_field(obj, "headRefName") {
        Some((value, _)) => Some(value)
        None => None
      }
      let base = match find_json_string_field(obj, "baseRefName") {
        Some((value, _)) => Some(value)
        None => None
      }
      let url = match find_json_string_field(obj, "url") {
        Some((value, _)) => Some(value)
        None => None
      }
      match (parse_int(number_str), branch, base, url) {
        (Some(number), Some(branch), Some(base), Some(url)) =>
          prs.push({ pr_number: number, branch, base, url })
        _ => ()
      }
    }
    start = object_end + 1
  }
  prs
}

///|
async fn capture_stdout(
  program : String,
  args : Array[String],
  cwd? : String? = None,
) -> String {
  let (read_end, write_end) = @pipe.pipe() catch { _ => return "" }
  let prog = @utf8.encode(program)
  let argv = args.map(fn(arg) { @utf8.encode(arg) })
  let _exit_code = match cwd {
    Some(dir) =>
      @process.run(prog, argv, cwd=@utf8.encode(dir), stdout=write_end) catch {
        _ => -1
      }
    None => @process.run(prog, argv, stdout=write_end) catch { _ => -1 }
  }
  write_end.close()
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for {
    if total >= buf.length() {
      break
    }
    let n = read_end.read(buf, offset=total, max_len=buf.length() - total)
    if n == 0 {
      break
    }
    total = total + n
  }
  read_end.close()
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
}

///|
fn default_agent_type(role : @types.Role) -> @types.AgentType {
  match role {
    @types.Role::Root => @types.AgentType::Claude
    @types.Role::TL => @types.AgentType::Claude
    @types.Role::Dev => @types.AgentType::Gemini
    @types.Role::Worker => @types.AgentType::Gemini
  }
}

///|
fn tmux_target_window_name(target : String) -> String? {
  let idx = index_of(target, ":")
  if idx == -1 || idx + 1 >= target.length() {
    None
  } else {
    Some(target[idx + 1:target.length()].to_string() catch { _ => "" })
  }
}

///|
fn is_tmux_target_alive(
  target : String?,
  session : String,
  tmux_windows : Array[String],
) -> Bool {
  match target {
    Some(value) =>
      match tmux_target_window_name(value) {
        Some(window_name) =>
          value.has_prefix(session + ":") && tmux_windows.contains(window_name)
        None => false
      }
    None => false
  }
}

///|
fn recover_agent_from_local_config(
  project_dir : String,
  rel_workspace : String,
  fallback_slug : String,
  session : String,
  tmux_windows : Array[String],
) -> @types.Agent? {
  let config_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content = @io.read_file(config_path)
  if content == "" {
    return None
  }
  let local_cfg = match @config.parse_local_config(content) {
    Ok(cfg) => cfg
    Err(_) => return None
  }
  let role = local_cfg.role.unwrap_or(@types.Role::TL)
  let agent_id = local_cfg.agent_id.unwrap_or(fallback_slug)
  let branch = local_cfg.branch.unwrap_or(agent_id)
  let workspace = local_cfg.workspace.unwrap_or(rel_workspace)
  let alive = is_tmux_target_alive(local_cfg.tmux_target, session, tmux_windows)
  Some({
    agent_id,
    role,
    agent_type: local_cfg.agent_type.unwrap_or(default_agent_type(role)),
    state: if alive {
      @types.AgentState::Active
    } else {
      @types.AgentState::Done
    },
    parent: local_cfg.parent_id,
    tmux_target: if alive {
      local_cfg.tmux_target
    } else {
      None
    },
    host: @types.Host::Local,
    workspace,
    branch,
  })
}

///|
async fn recover_local_agents(
  state : ServerState,
  session : String,
  tmux_windows : Array[String],
  dir_name : String,
) -> Unit {
  let project_dir = state.config.project_dir
  let output = capture_stdout(
    "sh",
    ["-c", "ls .choir/" + dir_name + "/ 2>/dev/null"],
    cwd=Some(project_dir),
  )
  for slug in split_lines(output) {
    let rel_workspace = ".choir/" + dir_name + "/" + slug
    match
      recover_agent_from_local_config(
        project_dir, rel_workspace, slug, session, tmux_windows,
      ) {
      Some(agent) =>
        match state.registry.insert(agent) {
          Ok(_) =>
            if not(
                is_tmux_target_alive(agent.tmux_target, session, tmux_windows),
              ) {
              ignore(state.registry.set_alive(agent.agent_id, false))
            }
          Err(_) => ()
        }
      None => ()
    }
  }
}

///|
pub async fn recover_state(state : ServerState, session : String) -> Unit {
  let project_dir = state.config.project_dir
  let tmux_output = capture_stdout(
    "sh",
    [
      "-c",
      "tmux list-windows -t " + session + " -F \"#{window_name}\" 2>/dev/null",
    ],
    cwd=Some(project_dir),
  )
  let tmux_windows = split_lines(tmux_output)
  recover_local_agents(state, session, tmux_windows, "worktrees")
  recover_local_agents(state, session, tmux_windows, "agents")

  let open_pr_output = capture_stdout(
    "sh",
    [
      "-c", "gh pr list --json number,headRefName,baseRefName,url --state open 2>/dev/null",
    ],
    cwd=Some(project_dir),
  )
  let now = @poller.now_sec()
  for pr in parse_open_prs(open_pr_output) {
    match state.registry.get(pr.branch) {
      Ok(agent) =>
        state.poller.track(
          pr.pr_number,
          agent.agent_id,
          pr.branch,
          pr.base,
          pr.url,
          now,
        )
      Err(_) => ()
    }
  }
}

///|
test "parse_open_prs extracts branch base and url" {
  let prs = parse_open_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/12\"},{\"number\":13,\"headRefName\":\"main.subtl.leaf-b\",\"baseRefName\":\"main.subtl\",\"url\":\"https://example.test/pr/13\"}]",
  )
  assert_eq(prs.length(), 2)
  assert_eq(prs[0].pr_number, 12)
  assert_eq(prs[0].branch, "main.leaf-a")
  assert_eq(prs[0].base, "main")
  assert_eq(prs[0].url, "https://example.test/pr/12")
  assert_eq(prs[1].pr_number, 13)
  assert_eq(prs[1].branch, "main.subtl.leaf-b")
  assert_eq(prs[1].base, "main.subtl")
  assert_eq(prs[1].url, "https://example.test/pr/13")
}

///|
test "parse_open_prs ignores malformed entries" {
  let prs = parse_open_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\"},{\"number\":\"oops\",\"headRefName\":\"main.leaf-b\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/13\"}]",
  )
  assert_eq(prs.length(), 0)
}
