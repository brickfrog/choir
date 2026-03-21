///|
pub(all) struct PullRequestInfo {
  number : Int
  url : String
  state : String
} derive(Show, Eq)

///|
fn pr_index_of(str : String, sub : String, start? : Int = 0) -> Int {
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
fn pr_index_of_quote_end(str : String, start : Int) -> Int {
  for i = start; i < str.length(); i = i + 1 {
    if str[i] == '"' && (i == 0 || str[i - 1] != '\\') {
      return i
    }
  }
  -1
}

///|
fn pr_skip_json_ws(s : String, start : Int) -> Int {
  let mut i = start
  while i < s.length() &&
        (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') {
    i = i + 1
  }
  i
}

///|
fn pr_parse_int(s : String) -> Int? {
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
fn find_json_string_field(
  data : String,
  field : String,
  start? : Int = 0,
) -> (String, Int)? {
  let field_name = "\"" + field + "\""
  let start_idx = pr_index_of(data, field_name, start~)
  if start_idx == -1 {
    return None
  }
  let colon_idx = pr_index_of(data, ":", start=start_idx + field_name.length())
  if colon_idx == -1 {
    return None
  }
  let value_start = pr_skip_json_ws(data, colon_idx + 1)
  if value_start >= data.length() || data[value_start] != '"' {
    return None
  }
  let value_end = pr_index_of_quote_end(data, value_start + 1)
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
fn parse_json_int_field(data : String, field : String) -> Int? {
  let field_name = "\"" + field + "\""
  let start_idx = pr_index_of(data, field_name)
  if start_idx == -1 {
    return None
  }
  let colon_idx = pr_index_of(data, ":", start=start_idx + field_name.length())
  if colon_idx == -1 {
    return None
  }
  let value_start = pr_skip_json_ws(data, colon_idx + 1)
  let mut value_end = value_start
  while value_end < data.length() &&
        data[value_end] >= '0' &&
        data[value_end] <= '9' {
    value_end = value_end + 1
  }
  pr_parse_int(data[value_start:value_end].to_string() catch { _ => "" })
}

///|
pub fn parse_pull_request_info(data : String) -> PullRequestInfo? {
  let number = parse_json_int_field(data, "number")
  let url = match find_json_string_field(data, "url") {
    Some((value, _)) => value
    None => return None
  }
  let state = match find_json_string_field(data, "state") {
    Some((value, _)) => value
    None => return None
  }
  match number {
    Some(value) => Some({ number: value, url, state })
    None => None
  }
}

///|
pub fn file_pr_commands(
  branch : String,
  parent_branch : String,
) -> Array[@workspace.Command] {
  [@workspace.git_push(branch), gh_pr_create_command(branch, parent_branch)]
}

///|

///|
fn slug_from_branch(branch : String) -> String {
  let mut last_dot = -1
  for i = 0; i < branch.length(); i = i + 1 {
    if branch[i] == '.' {
      last_dot = i
    }
  }
  if last_dot >= 0 {
    branch[last_dot + 1:].to_string() catch {
      _ => branch
    }
  } else {
    branch
  }
}

///|
pub fn gh_pr_create_command(
  branch : String,
  parent_branch : String,
) -> @workspace.Command {
  {
    program: "gh",
    args: [
      "pr",
      "create",
      "--base",
      parent_branch,
      "--head",
      branch,
      "--title",
      slug_from_branch(branch),
      "--body",
      "",
    ],
    workdir: None,
  }
}

///|
pub fn gh_pr_view_command(branch : String) -> @workspace.Command {
  {
    program: "gh",
    args: ["pr", "view", branch, "--json", "number,url,state"],
    workdir: None,
  }
}

///|
async fn capture_command_output(cmd : @workspace.Command) -> (Int, String) {
  let (read_end, write_end) = @pipe.pipe() catch { _ => return (-1, "") }
  let shell_cmd = @exec.command_to_shell_string(cmd) + " 2>&1"
  let exit_code = @process.run(
    @utf8.encode("sh"),
    [@utf8.encode("-c"), @utf8.encode(shell_cmd)],
    stdout=write_end,
  ) catch {
    _ => -1
  }
  write_end.close()
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = read_end.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  read_end.close()
  let output = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
  (exit_code, output)
}

///|
pub async fn ensure_pull_request(
  branch : String,
  parent_branch : String,
  project_dir : String,
) -> Result[PullRequestInfo, String] {
  let view_cmd = { ..gh_pr_view_command(branch), workdir: Some(project_dir) }
  let (view_exit, view_output) = capture_command_output(view_cmd)
  if view_exit == 0 {
    match parse_pull_request_info(view_output) {
      Some(pr) => if pr.state == "OPEN" { return Ok(pr) }
      None =>
        return Err("failed to parse gh pr view output for branch: " + branch)
    }
  }

  let create_cmd = {
    ..gh_pr_create_command(branch, parent_branch),
    workdir: Some(project_dir),
  }
  let (create_exit, create_output) = capture_command_output(create_cmd)
  if create_exit != 0 {
    let message = create_output.trim().to_string()
    if message != "" {
      return Err(message)
    } else {
      return Err("gh pr create failed for branch: " + branch)
    }
  }

  let (post_view_exit, post_view_output) = capture_command_output(view_cmd)
  if post_view_exit != 0 {
    return Err("gh pr view failed after create for branch: " + branch)
  }
  match parse_pull_request_info(post_view_output) {
    Some(pr) => Ok(pr)
    None =>
      Err(
        "failed to parse gh pr view output after create for branch: " + branch,
      )
  }
}

///|
/// Detect the repo's default branch via git symbolic-ref.
/// Falls back to "main" if detection fails.
pub async fn detect_default_branch(project_dir : String) -> String {
  let cmd : @workspace.Command = {
    program: "git",
    args: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture_command_output(cmd)
  if exit_code == 0 {
    let trimmed = output.trim().to_string()
    // Output is "origin/main" or "origin/master" — strip the "origin/" prefix
    let prefix = "origin/"
    if trimmed.has_prefix(prefix) {
      trimmed[prefix.length():].to_string() catch {
        _ => "main"
      }
    } else if trimmed != "" {
      trimmed
    } else {
      "main"
    }
  } else {
    "main"
  }
}

///|
pub fn merge_pr_commands(pr_number : Int) -> Array[@workspace.Command] {
  [
    {
      program: "gh",
      args: ["pr", "merge", pr_number.to_string(), "--merge"],
      workdir: None,
    },
    @workspace.git_fetch(),
  ]
}
