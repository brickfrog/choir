///|
pub(all) struct PullRequestInfo {
  number : Int
  url : String
  state : String
} derive(Show, Eq)

///|
pub fn parse_pull_request_info(data : String) -> PullRequestInfo? {
  let json = @json.parse(data) catch { _ => return None }
  guard json is Object(obj) else { return None }
  let number = match obj.get("number") {
    Some(Number(n, ..)) => n.to_int()
    _ => return None
  }
  let url = match obj.get("url") {
    Some(String(v)) => v
    _ => return None
  }
  let state = match obj.get("state") {
    Some(String(v)) => v
    _ => return None
  }
  Some({ number, url, state })
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
    branch[last_dot + 1:].to_string()
  } else {
    branch
  }
}

///|
pub fn gh_pr_create_command(
  branch : String,
  parent_branch : String,
  title? : String? = None,
  body? : String? = None,
) -> @workspace.Command {
  let pr_title = match title {
    Some(t) => t
    None => slug_from_branch(branch)
  }
  let pr_body = match body {
    Some(b) => b
    None => ""
  }
  {
    program: "gh",
    args: [
      "pr", "create", "--base", parent_branch, "--head", branch, "--title", pr_title,
      "--body", pr_body,
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
fn parse_non_negative_int(s : String) -> Int? {
  let trimmed = s.trim().to_string()
  if trimmed == "" {
    return None
  }
  let mut res = 0
  for c in trimmed {
    if c < '0' || c > '9' {
      return None
    }
    res = res * 10 + (c.to_int() - '0'.to_int())
  }
  Some(res)
}

///|
pub fn parse_left_right_counts(output : String) -> (Int, Int)? {
  let trimmed = output.trim().to_string()
  let mut tab_index = -1
  for i = 0; i < trimmed.length(); i = i + 1 {
    if trimmed[i] == '\t' {
      tab_index = i
      break
    }
  }
  if tab_index <= 0 || tab_index >= trimmed.length() - 1 {
    return None
  }
  let left = trimmed[:tab_index].to_string()
  let right = trimmed[tab_index + 1:].to_string()
  match (parse_non_negative_int(left), parse_non_negative_int(right)) {
    (Some(left), Some(right)) => Some((left, right))
    _ => None
  }
}

///|
async fn capture_command_output(cmd : @workspace.Command) -> (Int, String) {
  let (reader, writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let shell_cmd = @exec.command_to_shell_string(cmd) + " 2>&1"
  let pid = @process.spawn_orphan("sh", ["-c", shell_cmd], stdout=writer) catch {
    _ => {
      reader.close()
      return (-1, "")
    }
  }
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = reader.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  reader.close()
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  let output = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
  (exit_code, output)
}

///|
pub async fn ensure_branch_has_unique_commits(
  branch : String,
  parent_branch : String,
  project_dir : String,
) -> Result[Unit, String] {
  let cmd : @workspace.Command = {
    program: "git",
    args: [
      "rev-list",
      "--left-right",
      "--count",
      parent_branch + "..." + branch,
    ],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture_command_output(cmd)
  if exit_code != 0 {
    let message = output.trim().to_string()
    if message != "" {
      return Err(message)
    } else {
      return Err("failed to inspect branch state before filing PR: " + branch)
    }
  }
  match parse_left_right_counts(output) {
    Some((_, ahead)) =>
      if ahead > 0 {
        Ok(())
      } else {
        Err("cannot file PR: branch has no commits ahead of " + parent_branch)
      }
    None => Err("failed to parse branch state before filing PR: " + branch)
  }
}

///|
pub async fn ensure_pull_request(
  branch : String,
  parent_branch : String,
  project_dir : String,
  title : String?,
  body : String?,
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
  match ensure_branch_has_unique_commits(branch, parent_branch, project_dir) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  let create_cmd = {
    ..gh_pr_create_command(branch, parent_branch, title~, body~),
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
      trimmed[prefix.length():].to_string()
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
pub fn merge_pr_command(pr_number : Int) -> @workspace.Command {
  {
    program: "gh",
    args: ["pr", "merge", pr_number.to_string(), "--merge"],
    workdir: None,
  }
}

///|
pub fn merge_pr_commands(pr_number : Int) -> Array[@workspace.Command] {
  [merge_pr_command(pr_number), @workspace.git_fetch()]
}
