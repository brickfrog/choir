///|
test "parse_fork_wave_args defaults child_role to Dev" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.child_role, @types.Role::Dev)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args role tl" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "delegate",
    "parent_branch": "main",
    "caller_id": "root",
    "role": "tl",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.child_role, @types.Role::TL)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid role" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "role": "root",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args captures review_context" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "review_context": " plan/interpret split ",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.review_context, Some("plan/interpret split"))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults automerge override to None" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults review_mode override to None" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.review_mode, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses review_mode iterative" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "review_mode": "iterative",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.review_mode, Some(@types.ReviewMode::Iterative))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid review_mode" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "review_mode": "again",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args parses automerge true" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "true",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, Some(true))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses automerge false" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "false",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, Some(false))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid automerge value" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "maybe",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args parses issue_id" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "issue_id": " 42 ",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Ok(_))
}

///|
test "parse_fork_wave_args ignores empty issue_id" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "issue_id": "   ",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Ok(_))
}

///|
test "parse_fork_wave_args rejects missing caller_id" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Err(e) => assert_true(e.message().contains("caller_id"))
    Ok(_) => fail("expected MissingField(caller_id)")
  }
}
