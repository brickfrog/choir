///|
pub async fn fetch_issue(id : String) -> ChainlinkIssue? {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "show", id, "--json"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_stdout(cmd)
  if exit_code != 0 || output == "" {
    return None
  }
  let json = @json.parse(output) catch { _ => return None }
  parse_chainlink_issue_from_json(json)
}

///|
pub async fn fetch_list(status? : String = "open") -> Array[ChainlinkIssue] {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "list", "--json", "-s", status],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_stdout(cmd)
  if exit_code != 0 || output == "" {
    return []
  }
  let json = @json.parse(output) catch { _ => return [] }
  parse_chainlink_issue_list_from_json(json)
}

///|
pub async fn fetch_ready_text() -> String {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "ready"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_merged(cmd)
  if exit_code != 0 {
    return ""
  }
  output
}

///|
pub async fn fetch_next_text() -> String {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "next"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_merged(cmd)
  if exit_code != 0 {
    let error_message = "Failed to fetch next Chainlink issue: exit code " +
      exit_code.to_string() +
      "\nOutput: " +
      output +
      "\n"
    @sys.write_stderr(error_message)
    return error_message
  }
  output
}

///|
pub async fn fetch_tree_text() -> String {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "tree"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_merged(cmd)
  if exit_code != 0 {
    return ""
  }
  output
}

///|
fn parse_subissue_id(output : String) -> Int? {
  Some(@string.parse_int(output.trim().to_string())) catch {
    _ => None
  }
}

///|
test "parse_subissue_id - valid integer" {
  assert_eq(parse_subissue_id("42\n"), Some(42))
}

///|
test "parse_subissue_id - empty output" {
  assert_eq(parse_subissue_id(""), None)
}

///|
test "parse_subissue_id - invalid integer" {
  assert_eq(parse_subissue_id("not-a-number"), None)
}

///|
pub async fn create_subissue(
  parent_id : String,
  title : String,
  description? : String = "",
) -> Int? {
  let args = ["issue", "subissue", parent_id, title]
  if description != "" {
    args.push("-d")
    args.push(description)
  }
  args.push("-q")
  let cmd : @workspace.Command = { program: "chainlink", args, workdir: None }
  let (exit_code, output) = @exec.capture_command_stdout(cmd)
  if exit_code != 0 {
    return None
  }
  parse_subissue_id(output)
}

///|
pub async fn write_plan_comment(issue_id : String, text : String) -> Unit {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "comment", issue_id, text, "--kind", "plan"],
    workdir: None,
  }
  ignore(@exec.capture_command_merged(cmd))
}

///|
pub async fn claim_lock(issue_id : String, branch : String) -> Bool {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["locks", "claim", issue_id, "--branch", branch],
    workdir: None,
  }
  let (exit_code, _) = @exec.capture_command_merged(cmd)
  exit_code == 0
}

///|
pub async fn release_lock(issue_id : String) -> Bool {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["locks", "release", issue_id],
    workdir: None,
  }
  let (exit_code, _) = @exec.capture_command_merged(cmd)
  exit_code == 0
}

///|
pub async fn write_back_pr(
  issue_id : String,
  pr_url : String,
  pr_number : Int,
) -> Unit {
  let body = "PR #" + pr_number.to_string() + ": " + pr_url
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "comment", issue_id, body, "--kind", "result"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_merged(cmd)
  if exit_code != 0 {
    @sys.write_stderr(
      "Failed to write back PR to issue " +
      issue_id +
      ": exit code " +
      exit_code.to_string() +
      "\nOutput: " +
      output +
      "\n",
    )
  }
}

///|
pub async fn write_back_merge(
  issue_id : String,
  pr_number : Int,
  branch : String,
) -> Unit {
  let body = "Merged PR #" + pr_number.to_string() + " from " + branch
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "comment", issue_id, body, "--kind", "handoff"],
    workdir: None,
  }
  let (exit_code, output) = @exec.capture_command_merged(cmd)
  if exit_code != 0 {
    @sys.write_stderr(
      "Failed to write back merge to issue " +
      issue_id +
      ": exit code " +
      exit_code.to_string() +
      "\nOutput: " +
      output +
      "\n",
    )
  }
}
