///|
test "Conductor prompt is sourced only from the embedded default" {
  // load_goal_prompt no longer consults a project override, so it must equal
  // the single embedded source regardless of project directory.
  assert_eq(@prompts.load_goal_prompt("/repo"), @prompts.default_goal_prompt())
  assert_eq(@prompts.load_goal_prompt(""), @prompts.default_goal_prompt())
}

///|
test "Conductor prompt delegates slash Goal ownership to the provider" {
  let body = @prompts.default_goal_prompt()
  assert_true(body.has_prefix("Interpret the user's Goal request"))
  assert_true(body.contains("provider's built-in `/goal` command"))
  assert_true(body.contains("Choir does not register or shadow that command"))
  assert_true(body.contains("command Stop hook parks an active built-in Goal"))
  assert_true(body.contains("MCP channel injects the next material state"))
  assert_false(body.contains("\nname: choir-goal\n"))
  assert_false(body.contains("\nname: goal\n"))
}

///|
/// The prompt shares the Conductor's attention with the MCP instructions block
/// and eleven tool descriptions that both providers already receive. Only rules
/// with no schema equivalent belong here: a rejected `goal_submit` still spends
/// the user's turn, so the one-operation budget and the ban on self-service
/// diagnosis cannot be expressed as a field constraint. Per-field submission
/// rules live in the `goal_submit` schema descriptions and are enforced by
/// `@workflow.decode_conductor_goal_draft`; assert those where they are gated.
test "Conductor prompt keeps the authority rules no schema can express" {
  let body = @prompts.default_goal_prompt()
  assert_true(
    body.contains("One user message authorizes at most one state-changing"),
  )
  assert_true(body.contains("whether Choir accepts or rejects it"))
  assert_true(body.contains("Never call `goal_submit` a second time"))
  assert_true(body.contains("using Bash, the Choir CLI, process inspection"))
  assert_true(body.contains("Never probe `goal_submit`"))
  assert_true(body.contains("complete open blocking-dependency closure"))
  assert_true(body.contains("The conversation is the product interface"))
  assert_true(body.contains("`choird` is the sole workflow authority"))
}

///|
/// Every past incident used to add a sentence here and nothing ever removed
/// one, so the prompt could only grow while the schema that actually rejects
/// bad calls stayed unread. This test is the ratchet's counterweight: crossing
/// the budget means deleting prose that a gate already enforces, not raising
/// the number. The literal-JSON assertions guard the specific regression --
/// a Part field catalog and an example Part object teaching by example what
/// the schema states by interface.
test "Conductor prompt holds its budget and teaches no shape by example" {
  let body = @prompts.default_goal_prompt()
  assert_true(body.length() < 7000)
  assert_false(body.contains("\"part_id\":"))
  assert_false(body.contains("\"exact_paths\":"))
  assert_false(body.contains("\"moon_args\":"))
  // Draft fields the decoder rejects must never reappear as prompt guidance.
  assert_false(body.contains("`mutation`"))
  assert_false(body.contains("`base_ref`"))
  assert_false(body.contains("`integration_target_ref`"))
}
