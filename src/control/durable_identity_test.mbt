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

///|
/// One implementation, because this decides what evidence gates accept. Four
/// packages hand-rolled it identically; a single copy drifting to accept
/// uppercase or a different length would change which receipts and artifacts
/// are admitted in one subsystem and not the others.
test "a digest is valid only as 64 lowercase hex characters" {
  let hex = "a1b2c3d4e5f6" + "0123456789abcdef".repeat(3) + "0123"
  assert_eq(hex.length(), 64)
  assert_true(@control.Digest(hex).is_valid())
  // Uppercase is rejected: digests are compared as text, so admitting both
  // spellings would make the same content hash to two different keys.
  assert_false(@control.Digest(hex.to_upper()).is_valid())
  // Length is exact in both directions.
  assert_false(@control.Digest(hex[:63].to_owned()).is_valid())
  assert_false(@control.Digest(hex + "0").is_valid())
  assert_false(@control.Digest("").is_valid())
  // Anything outside 0-9a-f is rejected, including characters that look like
  // hex to a careless reader.
  assert_false(@control.Digest(hex[:63].to_owned() + "g").is_valid())
  assert_false(@control.Digest(hex[:63].to_owned() + " ").is_valid())
}
