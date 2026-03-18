///|
test "file_pr_commands produces correct git push and gh pr create" {
  let cmds = file_pr_commands("feature", "main")
  assert_eq(cmds.length(), 2)
  assert_eq(cmds[0].program, "git")
  assert_eq(cmds[0].args, ["push", "-u", "origin", "feature"])
  assert_eq(cmds[1].program, "gh")
  assert_eq(
    cmds[1].args,
    [
      "pr",
      "create",
      "--base",
      "main",
      "--head",
      "feature",
      "--title",
      "feature",
      "--body",
      "",
    ],
  )
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
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "branch": "feat", "parent_branch": "main" },
  }
  let res = dispatch(call)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("pr_created"))
      assert_eq(m.get("cmd_count"), Some("2"))
    }
    Err(_) => assert_true(false)
  }
}

///|
test "dispatch file_pr missing branch returns Err" {
  let call : ToolCall = {
    role: @types.Role::Dev,
    name: "file_pr",
    args: { "parent_branch": "main" },
  }
  let res = dispatch(call)
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "missing branch")
  }
}

///|
test "dispatch merge_pr returns Ok" {
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: { "pr_number": "456" },
  }
  let res = dispatch(call)
  match res {
    Ok(m) => {
      assert_eq(m.get("status"), Some("merged"))
      assert_eq(m.get("cmd_count"), Some("2"))
    }
    Err(_) => assert_true(false)
  }
}

///|
test "dispatch merge_pr invalid pr_number returns Err" {
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: { "pr_number": "abc" },
  }
  let res = dispatch(call)
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "invalid pr_number: abc")
  }
}

///|
test "dispatch merge_pr missing pr_number returns Err" {
  let call : ToolCall = {
    role: @types.Role::TL,
    name: "merge_pr",
    args: {},
  }
  let res = dispatch(call)
  match res {
    Ok(_) => assert_true(false)
    Err(msg) => assert_eq(msg, "missing pr_number")
  }
}
