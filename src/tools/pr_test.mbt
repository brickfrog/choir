///|
test "parse_left_right_counts parses tab separated counts" {
  match parse_left_right_counts("2\t5\n") {
    Some((left, right)) => {
      assert_eq(left, 2)
      assert_eq(right, 5)
    }
    None => fail("expected Some")
  }
}

///|
test "parse_left_right_counts rejects missing tab" {
  assert_true(parse_left_right_counts("2 5") is None)
}

///|
test "parse_left_right_counts rejects non numeric" {
  assert_true(parse_left_right_counts("x\t5") is None)
}

///|
test "not ahead preflight message names branch and parent" {
  let msg = FilePrPreflightError::NotAheadOfParent("main.leaf", "main").to_user_message()
  assert_true(msg.contains("main.leaf"))
  assert_true(msg.contains("main"))
  assert_true(msg.contains("no commits ahead"))
}

///|
test "empty diff preflight message names branch and parent" {
  let msg = FilePrPreflightError::EmptyDiffVsParent("feat.x", "main").to_user_message()
  assert_true(msg.contains("feat.x"))
  assert_true(msg.contains("main"))
  assert_true(msg.contains("no file changes"))
}

///|
test "wrong branch checkout message mentions HEAD mismatch" {
  let msg = FilePrPreflightError::WrongBranchCheckedOut("main.a", "main.b").to_user_message()
  assert_true(msg.contains("HEAD"))
  assert_true(msg.contains("main.a"))
  assert_true(msg.contains("main.b"))
}

///|
test "uncommitted changes message instructs commit or stash" {
  let msg = FilePrPreflightError::UncommittedChanges(" M foo.txt").to_user_message()
  assert_true(msg.contains("uncommitted"))
  assert_true(msg.contains("Pending changes"))
  assert_true(msg.contains("foo.txt"))
}

///|
test "missing origin remote message is actionable" {
  let msg = FilePrPreflightError::MissingOriginGitRemote(
    "error: No such remote 'origin'",
  ).to_user_message()
  assert_true(msg.contains("origin"))
}

///|
test "gh auth failed message mentions gh auth login" {
  let msg = FilePrPreflightError::GhAuthFailed("not logged in").to_user_message()
  assert_true(msg.contains("gh auth login"))
}

///|
fn preflight_mock_step(cmd : @workspace.Command) -> Int {
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "auth" &&
    cmd.args[1] == "status" {
    return 6
  }
  if cmd.program != "git" || cmd.args.length() == 0 {
    return -1
  }
  match cmd.args[0] {
    "rev-parse" =>
      if cmd.args.length() >= 2 && cmd.args[1] == "--verify" {
        0
      } else if cmd.args.length() >= 2 && cmd.args[1] == "--abbrev-ref" {
        1
      } else {
        -1
      }
    "status" => 2
    "remote" => 3
    "rev-list" => 4
    "diff" => 5
    _ => -1
  }
}

///|
async fn mock_preflight_all_ok(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  let branch = "t.leaf"
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, branch + "\n")
    2 => (0, "")
    3 => (0, "git@github.com:brickfrog/choir.git\n")
    4 => (0, "0\t1\n")
    5 => (1, "")
    6 => (0, "")
    _ => (-1, "mock_preflight_all_ok: unhandled step")
  }
}

///|
async test "file_pr_preflight_with_capture succeeds on mock happy path" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_all_ok,
  )
  assert_true(got is Ok(_))
}

///|
async fn mock_preflight_wrong_head(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "other-branch\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture fails when HEAD mismatches" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_wrong_head,
  )
  match got {
    Err(FilePrPreflightError::WrongBranchCheckedOut(expected, got)) => {
      assert_eq(expected, "t.leaf")
      assert_eq(got, "other-branch")
    }
    _ => fail("expected WrongBranchCheckedOut")
  }
}

///|
async fn mock_preflight_dirty(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "t.leaf\n")
    2 => (0, " M x.txt\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture fails on dirty status" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_dirty,
  )
  match got {
    Err(FilePrPreflightError::UncommittedChanges(detail)) =>
      assert_true(detail.contains("x.txt"))
    _ => fail("expected UncommittedChanges")
  }
}

///|
async fn mock_preflight_not_ahead(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "t.leaf\n")
    2 => (0, "")
    3 => (0, "origin\n")
    4 => (0, "0\t0\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture fails when not ahead of parent" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_not_ahead,
  )
  match got {
    Err(FilePrPreflightError::NotAheadOfParent(b, p)) => {
      assert_eq(b, "t.leaf")
      assert_eq(p, "main")
    }
    _ => fail("expected NotAheadOfParent")
  }
}

///|
async fn mock_preflight_empty_diff(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "t.leaf\n")
    2 => (0, "")
    3 => (0, "origin\n")
    4 => (0, "0\t1\n")
    5 => (0, "")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture fails when diff is empty" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_empty_diff,
  )
  match got {
    Err(FilePrPreflightError::EmptyDiffVsParent(_, _)) => ()
    _ => fail("expected EmptyDiffVsParent")
  }
}

///|
async fn mock_preflight_diff_git_error(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "t.leaf\n")
    2 => (0, "")
    3 => (0, "origin\n")
    4 => (0, "0\t1\n")
    5 => (128, "fatal: ambiguous argument 'bad'\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture surfaces git diff stderr on failure" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_diff_git_error,
  )
  match got {
    Err(e) => {
      let msg = e.to_user_message()
      assert_true(msg.contains("git diff"))
      assert_true(msg.contains("128"))
      assert_true(msg.contains("ambiguous"))
    }
    Ok(_) => fail("expected error")
  }
}

///|
async fn mock_preflight_spawn_fail_verify(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (-1, "")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture maps spawn failure to GitCommandFailed" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_spawn_fail_verify,
  )
  match got {
    Err(FilePrPreflightError::GitCommandFailed(step, detail)) => {
      assert_true(step.contains("rev-parse"))
      assert_true(detail.contains("spawn"))
    }
    _ => fail("expected GitCommandFailed")
  }
}

///|
async fn mock_preflight_spawn_fail_verify_with_stderr(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (-1, "resource temporarily unavailable\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture includes stderr when runner fails with output" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_spawn_fail_verify_with_stderr,
  )
  match got {
    Err(FilePrPreflightError::GitCommandFailed(_, detail)) =>
      assert_true(detail.contains("resource temporarily unavailable"))
    _ => fail("expected GitCommandFailed with stderr")
  }
}

///|
async fn mock_preflight_branch_missing(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (128, "fatal: Needed a single revision\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture reports missing local branch" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_branch_missing,
  )
  match got {
    Err(FilePrPreflightError::BranchMissing(b, msg)) => {
      assert_eq(b, "t.leaf")
      assert_true(msg.contains("fatal"))
    }
    _ => fail("expected BranchMissing")
  }
}

///|
async fn mock_preflight_missing_origin(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "t.leaf\n")
    2 => (0, "")
    3 => (2, "error: No such remote 'origin'\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture reports missing origin remote" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_missing_origin,
  )
  match got {
    Err(FilePrPreflightError::MissingOriginGitRemote(msg)) =>
      assert_true(msg.contains("origin"))
    _ => fail("expected MissingOriginGitRemote")
  }
}

///|
async fn mock_preflight_gh_fail(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  match preflight_mock_step(cmd) {
    0 => (0, "")
    1 => (0, "t.leaf\n")
    2 => (0, "")
    3 => (0, "origin\n")
    4 => (0, "0\t1\n")
    5 => (1, "")
    6 => (1, "You are not logged\n")
    _ => (0, "")
  }
}

///|
async test "file_pr_preflight_with_capture fails on gh auth" {
  let got = file_pr_preflight_with_capture(
    "t.leaf", "main", "/repo", mock_preflight_gh_fail,
  )
  match got {
    Err(FilePrPreflightError::GhAuthFailed(msg)) =>
      assert_true(msg.contains("not logged"))
    _ => fail("expected GhAuthFailed")
  }
}
