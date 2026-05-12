///|
test "goal parser detects generated bead ids without swallowing freeform slugs" {
  assert_true(goal_input_is_bead_id("choir-kqv"))
  assert_true(goal_input_is_bead_id("choir-7uc.1"))
  assert_false(goal_input_is_bead_id("always-true"))
  assert_false(goal_input_is_bead_id("ship the dashboard"))
  match GoalSource::from_input("choir-kqv") {
    Ok(GoalSource::BeadId(id)) => assert_eq(id, "choir-kqv")
    _ => fail("expected bead source")
  }
  match GoalSource::from_input("ship the dashboard") {
    Ok(GoalSource::Text(text)) => assert_eq(text, "ship the dashboard")
    _ => fail("expected text source")
  }
}

///|
test "goal new builds bead and shell checks" {
  let goal = Goal::new("choir-7uc.1", [" moon test --target native ", ""], 10L).unwrap()
  assert_eq(goal.slug, "choir-7uc.1")
  assert_true(goal.nonce.has_prefix("0000000a-"))
  assert_eq(goal.checks.length(), 2)
  assert_true(goal.checks[0] == GoalCheck::BeadStateClosed("choir-7uc.1"))
  assert_true(
    goal.checks[1] == GoalCheck::ShellCommand("moon test --target native"),
  )
}

///|
test "goal prod decision emits transitions and rate-limits unchanged open state" {
  let prior = GoalEvalResult::{
    passing: 0,
    total: 1,
    failing_summary: "shell failed: false",
    evaluated_unix_sec: 10L,
  }
  let same = { ..prior, evaluated_unix_sec: 20L }
  assert_true(
    goal_prod_decision(None, same, None, 20L) == GoalProdDecision::EmitProgress,
  )
  assert_true(
    goal_prod_decision(Some(prior), same, Some(15L), 20L) ==
    GoalProdDecision::Suppress,
  )
  assert_true(
    goal_prod_decision(Some(prior), same, Some(15L), 315L) ==
    GoalProdDecision::EmitReminder,
  )
  let changed = { ..same, passing: 1, failing_summary: "" }
  assert_true(
    goal_prod_decision(Some(prior), changed, Some(20L), 21L) ==
    GoalProdDecision::EmitComplete,
  )
  assert_true(
    goal_prod_decision(Some(changed), changed, Some(21L), 22L) ==
    GoalProdDecision::EmitComplete,
  )
}

///|
test "goal JSON roundtrip preserves exact KV key shape, nonce, and last evaluation" {
  assert_eq(goal_kv_key("choir-choir").unwrap(), "tl-goal--choir-choir.json")
  assert_eq(
    goal_kv_path("/repo", "choir-choir").unwrap(),
    "/repo/.choir/kv/tl-goal--choir-choir.json",
  )
  let eval = GoalEvalResult::{
    passing: 1,
    total: 2,
    failing_summary: "shell failed: false",
    evaluated_unix_sec: 22L,
  }
  let goal = Goal::new("ship the dashboard", ["true", "false"], 11L)
    .unwrap()
    .with_last_eval(eval)
  let decoded = Goal::from_json_string(goal.to_json_string()).unwrap()
  assert_true(decoded == goal)
  assert_eq(decoded.nonce, goal.nonce)
}

///|
test "goal KV path rejects invalid session-derived keys" {
  match goal_kv_key("") {
    Err(e) =>
      assert_true(e.message().contains("goal kv session cannot be empty"))
    Ok(_) => fail("expected empty session to be rejected")
  }
  match goal_kv_path("/repo", " \t ") {
    Err(e) =>
      assert_true(e.message().contains("goal kv session cannot be empty"))
    Ok(_) => fail("expected whitespace session to be rejected")
  }
  match goal_kv_key("../bad") {
    Err(e) => assert_true(e.message().contains("goal kv key"))
    Ok(_) => fail("expected invalid path segment to be rejected")
  }
  match goal_kv_path("/repo", "bad/session") {
    Err(e) => assert_true(e.message().contains("goal kv key"))
    Ok(_) => fail("expected nested path segment to be rejected")
  }
}

///|
test "freeform goal requires at least one verify command" {
  match Goal::new("ship the dashboard", [" ", ""], 10L) {
    Err(e) =>
      assert_true(
        e
        .message()
        .contains(
          "a freeform goal needs at least one --verify <cmd>; or pass a bead id to inherit its acceptance.",
        ),
      )
    Ok(_) => fail("expected unchecked freeform goal to be rejected")
  }
  let bead = Goal::new("choir-7uc.1", [], 10L).unwrap()
  assert_eq(bead.checks.length(), 1)
  assert_true(bead.checks[0] == GoalCheck::BeadStateClosed("choir-7uc.1"))
}

///|
test "goal JSON reports wrong checks type separately from missing checks" {
  let wrong_type = "{\"slug\":\"x\",\"nonce\":\"n1\",\"source\":{\"tag\":\"text\",\"value\":\"x\"},\"checks\":true,\"started_unix_sec\":1,\"last_eval\":null}"
  match Goal::from_json_string(wrong_type) {
    Err(e) => assert_true(e.message().contains("goal checks must be an array"))
    Ok(_) => fail("expected wrong checks type error")
  }
  let missing = "{\"slug\":\"x\",\"nonce\":\"n1\",\"source\":{\"tag\":\"text\",\"value\":\"x\"},\"started_unix_sec\":1,\"last_eval\":null}"
  match Goal::from_json_string(missing) {
    Err(e) => assert_true(e.message().contains("goal missing checks"))
    Ok(_) => fail("expected missing checks error")
  }
  let empty = "{\"slug\":\"x\",\"nonce\":\"n1\",\"source\":{\"tag\":\"text\",\"value\":\"x\"},\"checks\":[],\"started_unix_sec\":1,\"last_eval\":null}"
  match Goal::from_json_string(empty) {
    Err(e) =>
      assert_true(
        e
        .message()
        .contains(
          "a freeform goal needs at least one --verify <cmd>; or pass a bead id to inherit its acceptance.",
        ),
      )
    Ok(_) => fail("expected empty checks error")
  }
}

///|
test "goal JSON rejects empty shell command checks" {
  let empty_shell = "{\"slug\":\"x\",\"nonce\":\"n1\",\"source\":{\"tag\":\"text\",\"value\":\"x\"},\"checks\":[{\"tag\":\"shell\",\"command\":\"  \\t \"}],\"started_unix_sec\":1,\"last_eval\":null}"
  match Goal::from_json_string(empty_shell) {
    Err(e) =>
      assert_true(
        e.message().contains("shell goal check command cannot be empty"),
      )
    Ok(_) => fail("expected empty shell check command to be rejected")
  }
}

///|
test "goal JSON synthesizes missing nonce and rejects empty nonce" {
  let missing_nonce = "{\"slug\":\"x\",\"source\":{\"tag\":\"text\",\"value\":\"x\"},\"checks\":[{\"tag\":\"shell\",\"command\":\"true\"}],\"started_unix_sec\":1,\"last_eval\":null}"
  match Goal::from_json_string(missing_nonce) {
    Ok(goal) => {
      assert_eq(goal.slug, "x")
      assert_true(goal.nonce.has_prefix("00000001-"))
    }
    Err(e) => fail(e.message())
  }
  let empty_nonce = "{\"slug\":\"x\",\"nonce\":\"  \",\"source\":{\"tag\":\"text\",\"value\":\"x\"},\"checks\":[{\"tag\":\"shell\",\"command\":\"true\"}],\"started_unix_sec\":1,\"last_eval\":null}"
  match Goal::from_json_string(empty_nonce) {
    Err(e) => assert_true(e.message().contains("goal nonce cannot be empty"))
    Ok(_) => fail("expected empty nonce to be rejected")
  }
}
