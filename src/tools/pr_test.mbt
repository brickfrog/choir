///|
#borrow(cmd)
extern "C" fn c_system_pr_test(cmd : Bytes) -> Int = "system"

///|
fn string_to_null_terminated_bytes_pr_test(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn run_shell_pr_test(script : String) -> Unit {
  ignore(
    c_system_pr_test(
      string_to_null_terminated_bytes_pr_test("sh -c '" + script + "'"),
    ),
  )
}

///|
test "file_pr_commands produces correct git push and gh pr create" {
  let cmds = file_pr_commands("feature", "main")
  assert_eq(cmds.length(), 2)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[0].args, [
    "push", "--force-with-lease", "-u", "origin", "feature",
  ])
  assert_eq(cmds[1].args, [
    "pr", "create", "--base", "main", "--head", "feature", "--title", "feature",
    "--body", "",
  ])
}

///|
test "gh_pr_create_command uses slug for title not full branch" {
  let cmd = gh_pr_create_command("master.test-0", "master")
  assert_eq(cmd.args[7], "test-0")
  assert_eq(cmd.args[5], "master.test-0")
}

///|
test "parse_left_right_counts parses git rev-list output" {
  assert_eq(parse_left_right_counts("0\t1\n"), Some((0, 1)))
  assert_eq(parse_left_right_counts("12\t34"), Some((12, 34)))
  assert_eq(parse_left_right_counts(""), None)
  assert_eq(parse_left_right_counts("oops"), None)
}

///|
async fn mock_ensure_pr(
  branch : String,
  parent_branch : String,
  _project_dir : String,
  _title : String?,
  _body : String?,
) -> Result[PullRequestInfo, String] {
  @async.sleep(0)
  if branch == "fail" {
    Err("lookup failed")
  } else {
    Ok({
      number: if parent_branch == "release" {
        77
      } else {
        22
      },
      url: "https://example.test/pr/" + branch,
      state: "OPEN",
    })
  }
}

///|
async fn mock_branch_ready(
  _branch : String,
  _parent_branch : String,
  _project_dir : String,
) -> Result[Unit, String] {
  @async.sleep(0)
  Ok(())
}

///|
test "parse_pull_request_info extracts number and url" {
  let parsed = parse_pull_request_info(
    "{\"number\":22,\"url\":\"https://example.test/pr/feature\",\"state\":\"OPEN\"}",
  )
  match parsed {
    Some(pr) => {
      assert_eq(pr.number, 22)
      assert_eq(pr.url, "https://example.test/pr/feature")
      assert_eq(pr.state, "OPEN")
    }
    None => fail("expected pull request info")
  }
}

///|
test "merge_pr_commands produces correct gh pr merge and git fetch" {
  let cmds = merge_pr_commands(123)
  assert_eq(cmds.length(), 2)
  assert_eq(cmds[0].program, "gh")
  assert_eq(cmds[0].args, ["pr", "merge", "123", "--merge"])
  assert_eq(cmds[1].program, "git")
  assert_eq(cmds[1].args, ["fetch"])
}

///|
async test "ensure_pull_request errors when branch has no commits ahead" {
  let project_dir = "/tmp/choir-pr-no-ahead"
  run_shell_pr_test(
    "rm -rf /tmp/choir-pr-no-ahead && mkdir -p /tmp/choir-pr-no-ahead && " +
    "cd /tmp/choir-pr-no-ahead && " +
    "git init -b main >/dev/null 2>&1 && " +
    "git config user.email test@example.com && " +
    "git config user.name test && " +
    "printf 'seed\\n' > README.md && " +
    "git add README.md && " +
    "git commit -m init >/dev/null 2>&1 && " +
    "git branch -f feature main",
  )
  let res = ensure_pull_request("feature", "main", project_dir, None, None)
  match res {
    Ok(_) => fail("expected no-ahead branch to fail")
    Err(msg) =>
      assert_eq(
        msg, "cannot file PR: branch 'feature' has no commits ahead of parent branch 'main'. Commit your changes before filing a PR.",
      )
  }
  run_shell_pr_test("rm -rf /tmp/choir-pr-no-ahead")
}

///|
async test "dispatch file_pr returns Ok" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "branch": "feat", "parent_branch": "main" },
  }
  let res = dispatch_call(
    call,
    runner=mock_runner,
    ensure_branch_ready=mock_branch_ready,
    ensure_pr=mock_ensure_pr,
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("pr_created"))
      assert_eq(m.get("pr_number"), Some("22"))
      assert_eq(m.get("pr_url"), Some("https://example.test/pr/feat"))
      assert_eq(m.get("tracked"), Some("false"))
      assert_eq(m.get_json("pr_number"), Some((22).to_json()))
      assert_eq(m.get_json("tracked"), Some(false.to_json()))
    }
    Err(_) => assert_true(false)
  }
}

///|
async test "dispatch file_pr fails before push when branch is not ahead" {
  let project_dir = "/tmp/choir-dispatch-file-pr-no-ahead"
  run_shell_pr_test(
    "rm -rf /tmp/choir-dispatch-file-pr-no-ahead && mkdir -p /tmp/choir-dispatch-file-pr-no-ahead && " +
    "cd /tmp/choir-dispatch-file-pr-no-ahead && " +
    "git init -b main >/dev/null 2>&1 && " +
    "git config user.email test@example.com && " +
    "git config user.name test && " +
    "printf 'seed\\n' > README.md && " +
    "git add README.md && " +
    "git commit -m init >/dev/null 2>&1 && " +
    "git branch -f feature main",
  )
  let recorded : Array[@workspace.Command] = []
  let res = dispatch_call(
    {
      role: @types.Role::Dev,
      name: "file_pr",
      args: { "branch": "feature", "parent_branch": "main" },
    },
    project_dir~,
    runner=async fn(cmds) {
      @async.sleep(0)
      for cmd in cmds {
        recorded.push(cmd)
      }
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    },
  )
  match res {
    Ok(_) => fail("expected no-ahead branch to fail")
    Err(msg) =>
      assert_eq(
        msg, "cannot file PR: branch 'feature' has no commits ahead of parent branch 'main'. Commit your changes before filing a PR.",
      )
  }
  assert_eq(recorded.length(), 0)
  run_shell_pr_test("rm -rf /tmp/choir-dispatch-file-pr-no-ahead")
}

///|
async test "dispatch file_pr auto_tracks returned pr number" {
  let poller = @poller.PollerState::new()
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "branch": "feat", "parent_branch": "main" },
  }
  let res = dispatch_call(
    call,
    runner=mock_runner,
    ensure_branch_ready=mock_branch_ready,
    ensure_pr=mock_ensure_pr,
    poller_state=Some(poller),
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("tracked"), Some("true"))
      assert_eq(m.get_json("tracked"), Some(true.to_json()))
    }
    Err(_) => assert_true(false)
  }
  match poller.get(22) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "feat")
      assert_eq(tracked.branch, "feat")
      assert_eq(tracked.parent_branch, "main")
      assert_eq(tracked.pr_url, "https://example.test/pr/feat")
    }
    None => fail("expected tracked PR")
  }
}

///|
async test "dispatch file_pr preserves tracked review state for existing PR" {
  let poller = @poller.PollerState::new()
  poller.restore({
    pr_number: 22,
    agent_id: "feat",
    branch: "feat",
    parent_branch: "main",
    pr_url: "https://example.test/pr/feat",
    first_seen: 100L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "Please add tests",
    last_sha: "sha1",
    notified_parent: false,
    last_ci_failed: false,
    last_timeout_at: 0L,
  })
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "branch": "feat", "parent_branch": "main" },
  }
  let res = dispatch_call(
    call,
    runner=mock_runner,
    ensure_branch_ready=mock_branch_ready,
    ensure_pr=mock_ensure_pr,
    poller_state=Some(poller),
  )
  match res {
    Ok(m) => assert_eq(m.get("tracked"), Some("true"))
    Err(_) => fail("expected file_pr to succeed")
  }
  match poller.get(22) {
    Some(tracked) => {
      assert_eq(
        tracked.last_review_state,
        @poller.ReviewState::ChangesRequested,
      )
      assert_eq(tracked.last_review_bodies, "Please add tests")
      assert_eq(tracked.last_sha, "sha1")
      assert_false(tracked.notified_parent)
    }
    None => fail("expected tracked PR")
  }
  let events = []
  poller.tick_with(
    200L,
    900L,
    fn(_pr_number) {
      (
        @poller.ReviewState::ChangesRequested,
        "sha2",
        false,
        "Please add tests",
        true,
      )
    },
    fn(event, _agent_id) { events.push(event) },
  )
  assert_eq(events, [@poller.PollEvent::FixesPushed(22)])
}

///|
async test "dispatch file_pr accepts agent_id alias for branch" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "agent_id": "main.child", "parent_branch": "release" },
  }
  let res = dispatch_call(
    call,
    runner=mock_runner,
    ensure_branch_ready=mock_branch_ready,
    ensure_pr=mock_ensure_pr,
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("pr_number"), Some("77"))
      assert_eq(m.get("pr_url"), Some("https://example.test/pr/main.child"))
    }
    Err(_) => assert_true(false)
  }
}

///|
async test "dispatch file_pr missing branch returns Err" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "parent_branch": "main" },
  }
  let res = dispatch_call(
    call,
    runner=mock_runner,
    ensure_branch_ready=mock_branch_ready,
    ensure_pr=mock_ensure_pr,
  )
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "missing branch")
  }
}

///|
async test "dispatch file_pr surfaces ensure_pr failures" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "branch": "fail", "parent_branch": "main" },
  }
  let res = dispatch_call(
    call,
    runner=mock_runner,
    ensure_branch_ready=mock_branch_ready,
    ensure_pr=mock_ensure_pr,
  )
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "lookup failed")
  }
}

///|
async test "dispatch merge_pr returns Ok" {
  let poller = @poller.PollerState::new()
  poller.track(
    456, "agent-1", "main.agent-1", "main", "https://example.test/pr/456", 100,
  )
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: { "pr_number": "456" },
  }
  let res = dispatch_call(call, runner=mock_runner, poller_state=Some(poller))
  match res {
    Ok(m) => assert_eq(m.get("status"), Some("merged"))
    Err(_) => assert_true(false)
  }
  assert_eq(poller.get(456), None)
}

///|
async test "dispatch merge_pr invalid pr_number returns Err" {
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: { "pr_number": "abc" },
  }
  let res = dispatch_call(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "invalid pr_number: abc")
  }
}

///|
async test "dispatch merge_pr missing pr_number returns Err" {
  let call : ToolCall = { role: @types.Role::TL, name: "merge_pr", args: {} }
  let res = dispatch_call(call, runner=mock_runner)
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "missing pr_number")
  }
}

///|
async test "dispatch merge_pr blocks when ChangesRequested" {
  let poller = @poller.PollerState::new()
  poller.track(
    789, "agent-1", "main.agent-1", "main", "https://example.test/pr/789", 100,
  )
  match poller.get(789) {
    Some(tracked) =>
      tracked.last_review_state = @poller.ReviewState::ChangesRequested
    None => assert_true(false)
  }
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: { "pr_number": "789" },
  }
  let res = dispatch_call(call, runner=mock_runner, poller_state=Some(poller))
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.contains("ChangesRequested"))
  }
  // PR should still be tracked (merge was blocked)
  assert_true(poller.get(789) != None)
}

///|
async test "dispatch merge_pr force bypasses ChangesRequested guard" {
  let poller = @poller.PollerState::new()
  poller.track(
    790, "agent-1", "main.agent-1", "main", "https://example.test/pr/790", 100,
  )
  match poller.get(790) {
    Some(tracked) =>
      tracked.last_review_state = @poller.ReviewState::ChangesRequested
    None => assert_true(false)
  }
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: { "pr_number": "790", "force": "true" },
  }
  let res = dispatch_call(call, runner=mock_runner, poller_state=Some(poller))
  match res {
    Ok(m) => assert_eq(m.get("status"), Some("merged"))
    Err(_) => assert_true(false)
  }
}

///|
async test "dispatch track_pr stores tracked PR" {
  let poller = @poller.PollerState::new()
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "track_pr",
    args: { "pr_number": "22", "agent_id": "agent-22" },
  }
  let res = dispatch_call(call, runner=mock_runner, poller_state=Some(poller))
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("tracked"))
      assert_eq(m.get("branch"), Some("agent-22"))
      assert_eq(m.get("parent_branch"), Some("main"))
      assert_eq(m.get("pr_url"), Some(""))
      assert_eq(m.get_json("status"), Some("tracked".to_json()))
    }
    Err(_) => assert_true(false)
  }
  match poller.get(22) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "agent-22")
      assert_eq(tracked.branch, "agent-22")
      assert_eq(tracked.parent_branch, "main")
      assert_eq(tracked.pr_url, "")
      assert_true(tracked.first_seen > 0L)
    }
    None => fail("expected tracked PR")
  }
}
