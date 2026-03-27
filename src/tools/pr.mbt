///|
/// Typed preflight failures for `file_pr` (user-facing messages via
/// `FilePrPreflightError::to_user_message`).
pub(all) enum FilePrPreflightError {
  BranchMissing(String, String)
  HeadUnreadable(String)
  WrongBranchCheckedOut(String, String)
  UncommittedChanges(String)
  MissingOriginGitRemote(String)
  NotAheadOfParent(String, String)
  EmptyDiffVsParent(String, String)
  BranchRangeUnreadable(String)
  GitCommandFailed(String, String)
  GhAuthFailed(String)
} derive(Show, Eq)

///|
pub fn FilePrPreflightError::to_user_message(
  self : FilePrPreflightError,
) -> String {
  match self {
    BranchMissing(branch, detail) =>
      if detail != "" {
        "cannot file PR: branch '" + branch + "' is missing locally: " + detail
      } else {
        "cannot file PR: branch '" + branch + "' is missing locally."
      }
    HeadUnreadable(detail) =>
      if detail != "" {
        "cannot file PR: could not read current branch (HEAD): " + detail
      } else {
        "cannot file PR: could not read current branch (HEAD)."
      }
    WrongBranchCheckedOut(expected, got) =>
      "cannot file PR: git HEAD is '" +
      got +
      "' but file_pr targets branch '" +
      expected +
      "'. Check out the correct branch in this worktree before filing a PR."
    UncommittedChanges(detail) => {
      let suffix = if detail != "" {
        "\nPending changes:\n" + detail
      } else {
        ""
      }
      "cannot file PR: working tree has uncommitted changes. Commit or stash before filing a PR." +
      suffix
    }
    MissingOriginGitRemote(detail) =>
      if detail != "" {
        "cannot file PR: git remote 'origin' is not configured or unreachable: " +
        detail
      } else {
        "cannot file PR: git remote 'origin' is not configured. Add 'origin' before filing a PR."
      }
    NotAheadOfParent(branch, parent) =>
      "cannot file PR: branch '" +
      branch +
      "' has no commits ahead of parent branch '" +
      parent +
      "'. Commit your changes before filing a PR."
    EmptyDiffVsParent(branch, parent) =>
      "cannot file PR: branch '" +
      branch +
      "' introduces no file changes relative to '" +
      parent +
      "' (only empty or already-reachable commits). Add real changes before filing a PR."
    BranchRangeUnreadable(detail) =>
      if detail != "" {
        "cannot inspect branch range for PR preflight: " + detail
      } else {
        "cannot inspect branch range for PR preflight."
      }
    GitCommandFailed(step, detail) => {
      let tail = if detail != "" { detail } else { "(no output)" }
      "file_pr preflight failed during `" + step + "`: " + tail
    }
    GhAuthFailed(detail) =>
      if detail != "" {
        "cannot file PR: GitHub CLI is not authenticated or `gh` failed. Fix `gh auth login` (or install gh) before filing. Details: " +
        detail
      } else {
        "cannot file PR: GitHub CLI is not authenticated. Run `gh auth login` before filing a PR."
      }
  }
}

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

///|
fn preflight_spawn_or_wait_failure_detail(output : String) -> String {
  let trimmed = output.trim().to_string()
  if trimmed != "" {
    "failed to run command (process error): " + trimmed
  } else {
    "failed to run command (process spawn or wait failed; no output captured)."
  }
}

///|
/// `capture_command_output` uses negative codes when spawn/pipe/wait fails.
fn preflight_is_runner_failure(exit_code : Int) -> Bool {
  exit_code < 0
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
  let (output, _) = @exec.drain_process_stdout(reader, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
async fn rev_list_left_right_counts_with_capture(
  parent_branch : String,
  branch : String,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[(Int, Int), FilePrPreflightError] {
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
  let rev_step = "git rev-list --left-right --count " +
    parent_branch +
    "..." +
    branch
  let (exit_code, output) = capture(cmd)
  if preflight_is_runner_failure(exit_code) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        rev_step,
        preflight_spawn_or_wait_failure_detail(output),
      ),
    )
  }
  if exit_code != 0 {
    let message = output.trim().to_string()
    if message != "" {
      return Err(FilePrPreflightError::BranchRangeUnreadable(message))
    }
    return Err(
      FilePrPreflightError::BranchRangeUnreadable(
        "failed to inspect branch state before filing PR: " + branch,
      ),
    )
  }
  match parse_left_right_counts(output) {
    Some(counts) => Ok(counts)
    None =>
      Err(
        FilePrPreflightError::BranchRangeUnreadable(
          "failed to parse branch state before filing PR: " + branch,
        ),
      )
  }
}

///|
async fn rev_list_left_right_counts(
  parent_branch : String,
  branch : String,
  project_dir : String,
) -> Result[(Int, Int), FilePrPreflightError] {
  rev_list_left_right_counts_with_capture(
    parent_branch, branch, project_dir, capture_command_output,
  )
}

///|
pub async fn ensure_branch_has_unique_commits(
  branch : String,
  parent_branch : String,
  project_dir : String,
) -> Result[Unit, String] {
  match rev_list_left_right_counts(parent_branch, branch, project_dir) {
    Ok((_, ahead)) =>
      if ahead > 0 {
        Ok(())
      } else {
        Err(
          FilePrPreflightError::NotAheadOfParent(branch, parent_branch).to_user_message(),
        )
      }
    Err(e) => Err(e.to_user_message())
  }
}

///|
/// Validates local branch state before `file_pr` runs `git push` / `gh`.
pub async fn file_pr_preflight_with_capture(
  branch : String,
  parent_branch : String,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, FilePrPreflightError] {
  let verify_cmd : @workspace.Command = {
    program: "git",
    args: ["rev-parse", "--verify", "refs/heads/" + branch],
    workdir: Some(project_dir),
  }
  let verify_step = "git rev-parse --verify refs/heads/" + branch
  let (vcode, vout) = capture(verify_cmd)
  if preflight_is_runner_failure(vcode) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        verify_step,
        preflight_spawn_or_wait_failure_detail(vout),
      ),
    )
  }
  if vcode != 0 {
    return Err(
      FilePrPreflightError::BranchMissing(branch, vout.trim().to_string()),
    )
  }
  let head_cmd : @workspace.Command = {
    program: "git",
    args: ["rev-parse", "--abbrev-ref", "HEAD"],
    workdir: Some(project_dir),
  }
  let (hcode, hout) = capture(head_cmd)
  if preflight_is_runner_failure(hcode) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        "git rev-parse --abbrev-ref HEAD",
        preflight_spawn_or_wait_failure_detail(hout),
      ),
    )
  }
  if hcode != 0 {
    return Err(FilePrPreflightError::HeadUnreadable(hout.trim().to_string()))
  }
  let current = hout.trim().to_string()
  if current != branch {
    return Err(FilePrPreflightError::WrongBranchCheckedOut(branch, current))
  }
  let status_cmd : @workspace.Command = {
    program: "git",
    args: ["status", "--porcelain"],
    workdir: Some(project_dir),
  }
  let (scode, sout) = capture(status_cmd)
  if preflight_is_runner_failure(scode) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        "git status --porcelain",
        preflight_spawn_or_wait_failure_detail(sout),
      ),
    )
  }
  if scode != 0 {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        "git status --porcelain",
        sout.trim().to_string(),
      ),
    )
  }
  let pending = sout.trim().to_string()
  if pending != "" {
    return Err(FilePrPreflightError::UncommittedChanges(pending))
  }
  let origin_cmd : @workspace.Command = {
    program: "git",
    args: ["remote", "get-url", "origin"],
    workdir: Some(project_dir),
  }
  let (ocode, oout) = capture(origin_cmd)
  if preflight_is_runner_failure(ocode) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        "git remote get-url origin",
        preflight_spawn_or_wait_failure_detail(oout),
      ),
    )
  }
  if ocode != 0 {
    return Err(
      FilePrPreflightError::MissingOriginGitRemote(oout.trim().to_string()),
    )
  }
  match
    rev_list_left_right_counts_with_capture(
      parent_branch, branch, project_dir, capture,
    ) {
    Ok((_, ahead)) =>
      if ahead <= 0 {
        return Err(
          FilePrPreflightError::NotAheadOfParent(branch, parent_branch),
        )
      }
    Err(e) => return Err(e)
  }
  let diff_cmd : @workspace.Command = {
    program: "git",
    args: ["diff", "--no-ext-diff", "--quiet", parent_branch + "..." + branch],
    workdir: Some(project_dir),
  }
  let diff_step = "git diff --no-ext-diff --quiet " +
    parent_branch +
    "..." +
    branch
  let (dcode, dout) = capture(diff_cmd)
  if preflight_is_runner_failure(dcode) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        diff_step,
        preflight_spawn_or_wait_failure_detail(dout),
      ),
    )
  }
  if dcode == 0 {
    return Err(FilePrPreflightError::EmptyDiffVsParent(branch, parent_branch))
  }
  if dcode != 1 {
    let trimmed = dout.trim().to_string()
    let tail = if trimmed != "" {
      "unexpected exit code " + dcode.to_string() + ": " + trimmed
    } else {
      "unexpected exit code " + dcode.to_string()
    }
    return Err(FilePrPreflightError::GitCommandFailed(diff_step, tail))
  }
  let gh_cmd : @workspace.Command = {
    program: "gh",
    args: ["auth", "status"],
    workdir: Some(project_dir),
  }
  let (gcode, gout) = capture(gh_cmd)
  if preflight_is_runner_failure(gcode) {
    return Err(
      FilePrPreflightError::GitCommandFailed(
        "gh auth status",
        preflight_spawn_or_wait_failure_detail(gout),
      ),
    )
  }
  if gcode != 0 {
    return Err(FilePrPreflightError::GhAuthFailed(gout.trim().to_string()))
  }
  Ok(())
}

///|
/// Validates local branch state before `file_pr` runs `git push` / `gh`.
pub async fn file_pr_preflight(
  branch : String,
  parent_branch : String,
  project_dir : String,
) -> Result[Unit, FilePrPreflightError] {
  file_pr_preflight_with_capture(
    branch, parent_branch, project_dir, capture_command_output,
  )
}

///|
/// `Result` form used as the default `ensure_branch_ready` hook for `file_pr`.
pub async fn ensure_branch_ready_for_file_pr(
  branch : String,
  parent_branch : String,
  project_dir : String,
) -> Result[Unit, String] {
  match file_pr_preflight(branch, parent_branch, project_dir) {
    Ok(_) => Ok(())
    Err(e) => Err(e.to_user_message())
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
