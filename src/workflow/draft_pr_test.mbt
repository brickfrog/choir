///|
test "Conductor pull request draft flag is typed and defaults false" {
  let prefix = "{\"proposal_id\":\"p\",\"goal_id\":\"g\",\"pull_request\":{\"title\":\"docs: explain x\",\"body\":\"Explains x and its verification.\""
  let suffix = "},\"maximum_parallel_parts\":1,\"parts\":[{\"part_id\":\"a\",\"instruction\":\"x\",\"repository_wide\":true,\"moon_args\":[\"test\"]}]}"
  let omitted = @workflow.decode_conductor_goal_draft(prefix + suffix).unwrap()
  assert_eq(omitted.pull_request_document.unwrap().draft, false)
  let drafted = @workflow.decode_conductor_goal_draft(
    prefix + ",\"draft\":true" + suffix,
  ).unwrap()
  assert_eq(drafted.pull_request_document.unwrap().draft, true)
  assert_true(
    @workflow.decode_conductor_goal_draft(
      prefix + ",\"draft\":\"true\"" + suffix,
    )
    is Err(_),
  )
}
