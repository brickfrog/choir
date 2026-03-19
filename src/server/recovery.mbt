///|
priv struct OpenPR {
  pr_number : Int
  branch : String
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
  for {
    let number_idx = index_of(output, "\"number\":", start~)
    if number_idx == -1 {
      break
    }
    let number_start = skip_json_ws(output, number_idx + 9)
    let mut number_end = number_start
    while number_end < output.length() &&
          output[number_end] >= '0' &&
          output[number_end] <= '9' {
      number_end = number_end + 1
    }
    let number_str = output[number_start:number_end].to_string() catch {
      _ => ""
    }
    let branch = match
      find_json_string_field(output, "headRefName", start=number_end) {
      Some((value, next_start)) => {
        start = next_start
        value
      }
      None => break
    }
    match parse_int(number_str) {
      Some(number) => prs.push({ pr_number: number, branch })
      None => ()
    }
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
fn recover_role(project_dir : String, slug : String) -> @types.Role {
  let config_path = project_dir +
    "/.choir/worktrees/" +
    slug +
    "/.choir/config.local.toml"
  let content = @io.read_file(config_path)
  match @config.parse_config_local(content) {
    Ok(role) => role
    Err(_) => @types.Role::TL
  }
}

///|
pub async fn recover_state(state : ServerState, session : String) -> Unit {
  let project_dir = state.config.project_dir
  let worktree_output = capture_stdout(
    "sh",
    ["-c", "ls .choir/worktrees/ 2>/dev/null"],
    cwd=Some(project_dir),
  )
  let tmux_output = capture_stdout(
    "sh",
    [
      "-c",
      "tmux list-windows -t " + session + " -F \"#{window_name}\" 2>/dev/null",
    ],
    cwd=Some(project_dir),
  )
  let tmux_windows = split_lines(tmux_output)
  for slug in split_lines(worktree_output) {
    let alive = tmux_windows.contains(slug)
    let agent : @types.Agent = {
      agent_id: slug,
      role: recover_role(project_dir, slug),
      agent_type: @types.AgentType::Claude,
      state: if alive {
        @types.AgentState::Active
      } else {
        @types.AgentState::Done
      },
      parent: None,
      tmux_target: if alive {
        Some(session + ":" + slug)
      } else {
        None
      },
      host: @types.Host::Local,
      workspace: ".choir/worktrees/" + slug,
      branch: slug,
    }
    match state.registry.insert(agent) {
      Ok(_) =>
        if not(alive) {
          match state.registry.set_alive(slug, false) {
            Ok(_) => ()
            Err(_) => ()
          }
        }
      Err(_) => ()
    }
  }

  let open_pr_output = capture_stdout(
    "sh",
    ["-c", "gh pr list --json number,headRefName --state open 2>/dev/null"],
    cwd=Some(project_dir),
  )
  let now = @poller.now_sec()
  for pr in parse_open_prs(open_pr_output) {
    match state.registry.get(pr.branch) {
      Ok(_) => state.poller.track(pr.pr_number, pr.branch, now)
      Err(_) => ()
    }
  }
}
