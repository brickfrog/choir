///|
test "Goal prompt falls back to the current Conductor contract" {
  let body = @prompts.load_goal_prompt("/repo", path_exists=fn(_) { false }, read_file=fn(
    _,
  ) {
    abort("missing prompt must not be read")
  })
  assert_true(body.has_prefix("---\nname: goal\n"))
  assert_true(body.contains("complete open blocking-dependency closure"))
  assert_true(body.contains("Call `goal_submit` exactly once"))
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
