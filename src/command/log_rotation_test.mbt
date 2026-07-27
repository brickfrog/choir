///|
fn rotation_policy(
  maximum_bytes? : Int = 100,
  retained_generations? : Int = 3,
) -> @command.LogRotationPolicy {
  { maximum_bytes, retained_generations }
}

///|
test "a log under its cap is left alone" {
  let plan = @command.plan_log_rotation(
    "/w/.choir/logs/serve.log",
    99,
    rotation_policy(),
  )
  assert_true(@command.log_rotation_plan_is_empty(plan))
}

///|
/// The renames have to run oldest first. Rolling .1 to .2 before .2 has moved
/// destroys a generation, and the bug would only show up as a gap in history
/// long after the fact.
test "rotation shifts generations from the oldest backwards" {
  let plan = @command.plan_log_rotation("/w/serve.log", 100, rotation_policy())
  @debug.assert_eq(plan.discard, ["/w/serve.log.3"])
  @debug.assert_eq(plan.rotate, [
    ("/w/serve.log.2", "/w/serve.log.3"),
    ("/w/serve.log.1", "/w/serve.log.2"),
    ("/w/serve.log", "/w/serve.log.1"),
  ])
  // No rename writes over a path that a later rename still has to read.
  let written : Array[String] = []
  for step in plan.rotate {
    assert_false(written.contains(step.0))
    written.push(step.1)
  }
}

///|
test "a policy that keeps nothing discards rather than rolls" {
  let plan = @command.plan_log_rotation(
    "/w/serve.log",
    100,
    rotation_policy(retained_generations=0),
  )
  @debug.assert_eq(plan.discard, ["/w/serve.log"])
  @debug.assert_eq(plan.rotate, [])
}

///|
test "keeping one generation replaces it rather than growing the set" {
  let plan = @command.plan_log_rotation(
    "/w/serve.log",
    100,
    rotation_policy(retained_generations=1),
  )
  @debug.assert_eq(plan.discard, ["/w/serve.log.1"])
  @debug.assert_eq(plan.rotate, [("/w/serve.log", "/w/serve.log.1")])
}

///|
/// A size that could not be measured reports zero. Rotating on that would roll
/// on every single write and destroy the log the moment measurement broke.
test "an unmeasurable or disabled log never rotates" {
  assert_true(
    @command.log_rotation_plan_is_empty(
      @command.plan_log_rotation("/w/serve.log", 0, rotation_policy()),
    ),
  )
  assert_true(
    @command.log_rotation_plan_is_empty(
      @command.plan_log_rotation(
        "/w/serve.log",
        1_000_000,
        rotation_policy(maximum_bytes=0),
      ),
    ),
  )
  assert_true(
    @command.log_rotation_plan_is_empty(
      @command.plan_log_rotation("", 1_000_000, rotation_policy()),
    ),
  )
}

///|
test "the default policy bounds a rolled set rather than one file" {
  let policy = @command.default_log_rotation_policy()
  assert_true(policy.maximum_bytes > 0)
  assert_true(policy.retained_generations > 0)
  let plan = @command.plan_log_rotation(
    "/w/serve.log",
    policy.maximum_bytes,
    policy,
  )
  // Every retained generation is accounted for: one discard plus one rename
  // per surviving generation.
  assert_eq(
    plan.rotate.length() + plan.discard.length(),
    policy.retained_generations + 1,
  )
}
