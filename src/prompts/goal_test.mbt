///|
test "Goal prompt falls back to the current Conductor contract" {
  let body = @prompts.load_goal_prompt("/repo", path_exists=fn(_) { false }, read_file=fn(
    _,
  ) {
    abort("missing prompt must not be read")
  })
  assert_true(body.has_prefix("---\nname: goal\n"))
  assert_true(body.contains("complete open blocking-dependency closure"))
  assert_true(body.contains("call `goal_submit` exactly once"))
  assert_true(body.contains("Never probe `goal_submit`"))
  assert_true(body.contains("Omit `provider`"))
  assert_true(
    body.contains("user's current message explicitly requests Claude"),
  )
  assert_true(body.contains("Never babysit a Goal with a polling loop"))
  assert_true(
    body.contains("Never retry or resubmit within the same user request"),
  )
  assert_true(
    body.contains("treat it as that Goal even when a Bead has the same ID"),
  )
  assert_true(body.contains("The conversation is the product interface"))
  assert_true(body.contains("call `goal_answer`"))
  assert_false(body.contains("User-input answers are CLI-only"))
  assert_true(body.contains("The completion mode is immutable"))
  assert_true(body.contains("`evidence_only_binding_digest`"))
  assert_true(
    body.contains("never invent or nest them under a `mutation` object"),
  )
  assert_true(body.contains("\"exact_paths\":[\"src/example.mbt\"]"))
  assert_true(body.contains("Never guess or submit Git refs"))
  assert_false(body.contains("`base_ref`"))
  assert_false(body.contains("`integration_target_ref`"))
  assert_true(body.contains("`choird` is the sole workflow authority"))
}

///|
test "Goal prompt permits one project override" {
  let expected_path = "/repo/.choir/prompts/skills/goal.md"
  let body = @prompts.load_goal_prompt(
    "/repo",
    path_exists=fn(path) { path == expected_path },
    read_file=fn(_) { "project Goal prompt\n" },
  )
  assert_eq(body, "project Goal prompt\n")
}
