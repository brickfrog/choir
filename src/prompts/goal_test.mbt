///|
test "Conductor prompt delegates slash Goal ownership to the provider" {
  let body = @prompts.load_goal_prompt("/repo", path_exists=fn(_) { false }, read_file=fn(
    _,
  ) {
    abort("missing prompt must not be read")
  })
  assert_true(body.has_prefix("Interpret the user's Goal request"))
  assert_true(body.contains("provider's built-in `/goal` command"))
  assert_true(body.contains("Choir does not register or shadow that command"))
  assert_true(body.contains("command Stop hook parks an active built-in Goal"))
  assert_true(body.contains("MCP channel injects the next material state"))
  assert_false(body.contains("\nname: choir-goal\n"))
  assert_false(body.contains("\nname: goal\n"))
  assert_true(body.contains("complete open blocking-dependency closure"))
  assert_true(body.contains("call `goal_submit` exactly once"))
  assert_true(body.contains("Never probe `goal_submit`"))
  assert_true(body.contains("Omit `provider`"))
  assert_true(
    body.contains("user's current message explicitly requests Claude"),
  )
  assert_true(
    body.contains("Durable transitions arrive through the Choir channel"),
  )
  assert_true(body.contains("selects work, not a durable Goal identity"))
  assert_true(body.contains("interpret that identifier as a Bead"))
  assert_true(body.contains("Goal IDs are internal implementation details"))
  assert_true(body.contains("never ask the user to paste"))
  assert_true(body.contains("Bead identifier as `part_id`"))
  assert_true(body.contains("pass the returned internal `goal_id`"))
  assert_true(body.contains("Never ask the user for the Goal ID"))
  assert_true(body.contains("Choir, not the user or Conductor"))
  assert_true(body.contains("Choir mints the durable `goal_id`"))
  assert_true(body.contains("whether Choir accepts or rejects it"))
  assert_true(body.contains("Never call `goal_submit` a second time"))
  assert_true(body.contains("using Bash, the Choir CLI, process inspection"))
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
test "Conductor prompt permits one project override outside skill discovery" {
  let expected_path = "/repo/.choir/prompts/conductor.md"
  let body = @prompts.load_goal_prompt(
    "/repo",
    path_exists=fn(path) { path == expected_path },
    read_file=fn(_) { "project Goal prompt\n" },
  )
  assert_eq(body, "project Goal prompt\n")
}
