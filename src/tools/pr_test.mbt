///|
test "file_pr_commands produces correct git push and gh pr create" {
  let cmds = file_pr_commands("feature", "main")
  assert_eq(cmds.length(), 2)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[0].args, ["push", "-u", "origin", "feature"])
  assert_eq(cmds[1].args, [
    "pr", "create", "--base", "main", "--head", "feature", "--title", "feature",
    "--body", "",
  ])
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
test "dispatch file_pr returns Ok" {
  @async.with_event_loop(_ => {
    let call : ToolCall = {
      role: @types.Role::Dev,
      name: "file_pr",
      args: { "branch": "feat", "parent_branch": "main" },
    }
    let res = dispatch(call, runner=mock_runner)
    match res {
      Ok(m) => assert_eq(m.get("status"), Some("pr_created"))
      Err(_) => assert_true(false)
    }
  })
}

///|
test "dispatch file_pr missing branch returns Err" {
  @async.with_event_loop(_ => {
    let call : ToolCall = {
      role: @types.Role::Dev,
      name: "file_pr",
      args: { "parent_branch": "main" },
    }
    let res = dispatch(call, runner=mock_runner)
    match res {
      Ok(_) => assert_true(false)
      Err(msg) => assert_eq(msg, "missing branch")
    }
  })
}

///|
test "dispatch merge_pr returns Ok" {
  @async.with_event_loop(_ => {
    let poller = @poller.PollerState::new()
    poller.track(456, "agent-1", 100)
    let call : ToolCall = {
      role: @types.Role::TL,
      name: "merge_pr",
      args: { "pr_number": "456" },
    }
    let res = dispatch(call, runner=mock_runner, poller_state=Some(poller))
    match res {
      Ok(m) => assert_eq(m.get("status"), Some("merged"))
      Err(_) => assert_true(false)
    }
    assert_eq(poller.get(456), None)
  })
}

///|
test "dispatch merge_pr invalid pr_number returns Err" {
  @async.with_event_loop(_ => {
    let call : ToolCall = {
      role: @types.Role::TL,
      name: "merge_pr",
      args: { "pr_number": "abc" },
    }
    let res = dispatch(call, runner=mock_runner)
    match res {
      Ok(_) => assert_true(false)
      Err(msg) => assert_eq(msg, "invalid pr_number: abc")
    }
  })
}

///|
test "dispatch merge_pr missing pr_number returns Err" {
  @async.with_event_loop(_ => {
    let call : ToolCall = { role: @types.Role::TL, name: "merge_pr", args: {} }
    let res = dispatch(call, runner=mock_runner)
    match res {
      Ok(_) => assert_true(false)
      Err(msg) => assert_eq(msg, "missing pr_number")
    }
  })
}

///|
test "dispatch track_pr stores tracked PR" {
  @async.with_event_loop(_ => {
    let poller = @poller.PollerState::new()
    let call : ToolCall = {
      role: @types.Role::Dev,
      name: "track_pr",
      args: { "pr_number": "22", "agent_id": "agent-22" },
    }
    let res = dispatch(call, runner=mock_runner, poller_state=Some(poller))
    match res {
      Ok(m) => assert_eq(m.get("status"), Some("tracked"))
      Err(_) => assert_true(false)
    }
    match poller.get(22) {
      Some(tracked) => {
        assert_eq(tracked.agent_id, "agent-22")
        assert_true(tracked.first_seen > 0L)
      }
      None => fail("expected tracked PR")
    }
  })
}
