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
test "parse_fork_wave_args defaults automerge to false" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, false)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
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
    Ok(fork) => assert_eq(fork.automerge, true)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses automerge yes as true" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "yes",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, true)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses automerge 1 as true" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "1",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, true)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses automerge false explicitly" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "false",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.automerge, false)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}
