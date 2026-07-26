///|
/// Effect ids are only ever derived from the owner that scopes them, so both
/// minters must agree on the separator. A key spelled differently by one
/// caller loads no durable witness, and the effect waits forever.
test "effect ids are minted inside their owner's namespace" {
  let workflow = @control.WorkflowId("goal-part-abc")
  let goal = @control.GoalId("goal-1")
  assert_eq(
    workflow.effect("take-2:audit"),
    @control.EffectId("goal-part-abc:take-2:audit"),
  )
  assert_eq(
    goal.effect("assurance:verification"),
    @control.EffectId("goal-1:assurance:verification"),
  )
}

///|
/// Distinct owners never collide, and the same owner and suffix always
/// reproduce the same key across daemon restarts.
test "effect id derivation is stable and owner-scoped" {
  let first = @control.WorkflowId("workflow-a")
  let second = @control.WorkflowId("workflow-b")
  assert_eq(first.effect("start"), first.effect("start"))
  assert_true(first.effect("start") != second.effect("start"))
}

///|
/// Both wrappers are durable state, so they must round-trip and must encode
/// the way the identities they sit beside already do — the storage layer has
/// no per-identity handling to fall back on.
test "durable identities round-trip in the shape their siblings use" {
  let workflow = @control.WorkflowId("workflow-a")
  let effect = workflow.effect("start")
  let decoded_workflow : @control.WorkflowId = @json.from_json(
    workflow.to_json(),
  )
  let decoded_effect : @control.EffectId = @json.from_json(effect.to_json())
  assert_eq(decoded_workflow, workflow)
  assert_eq(decoded_effect, effect)
  assert_eq(
    workflow.to_json().stringify().replace(old="WorkflowId", new="_"),
    @control.GoalId("workflow-a")
    .to_json()
    .stringify()
    .replace(old="GoalId", new="_"),
  )
}
