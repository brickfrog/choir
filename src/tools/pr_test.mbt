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
async fn mock_ensure_pr(
  branch : String,
  parent_branch : String,
  _project_dir : String,
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
async test "dispatch file_pr returns Ok" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "branch": "feat", "parent_branch": "main" },
  }
  let res = dispatch_call(call, runner=mock_runner, ensure_pr=mock_ensure_pr)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("pr_created"))
      assert_eq(m.get("pr_number"), Some("22"))
      assert_eq(m.get("pr_url"), Some("https://example.test/pr/feat"))
      assert_eq(m.get("tracked"), Some("false"))
      assert_eq(m.get_value("pr_number"), Some(@types.WireValue::Raw("22")))
      assert_eq(m.get_value("tracked"), Some(@types.WireValue::Raw("false")))
    }
    Err(_) => assert_true(false)
  }
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
    ensure_pr=mock_ensure_pr,
    poller_state=Some(poller),
  )
  match res {
    Ok(m) => {
      assert_eq(m.get("tracked"), Some("true"))
      assert_eq(m.get_value("tracked"), Some(@types.WireValue::Raw("true")))
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
async test "dispatch file_pr accepts agent_id alias for branch" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "agent_id": "main.child", "parent_branch": "release" },
  }
  let res = dispatch_call(call, runner=mock_runner, ensure_pr=mock_ensure_pr)
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
  let res = dispatch_call(call, runner=mock_runner, ensure_pr=mock_ensure_pr)
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
  let res = dispatch_call(call, runner=mock_runner, ensure_pr=mock_ensure_pr)
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
      assert_eq(
        m.get_value("status"),
        Some(@types.WireValue::String("tracked")),
      )
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
