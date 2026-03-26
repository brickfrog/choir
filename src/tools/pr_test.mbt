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
