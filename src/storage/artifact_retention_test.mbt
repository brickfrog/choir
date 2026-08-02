///|
fn retention_digest(seed : String) -> @control.Digest {
  @storage.artifact_digest(@utf8.encode(seed))
}

///|
fn never_terminal(_ : @control.GoalId) -> Bool {
  false
}

///|
/// The store is content-addressed, so unrelated callers adopt the same bytes
/// under unrelated terms. Keeping one merged retention would have to pick a
/// winner, and picking wrong deletes something still in use.
test "content adopted under several terms survives until all of them expire" {
  let digest = retention_digest("shared")
  let ledger = @storage.record_artifact_retention(
    @storage.record_artifact_retention(
      [],
      digest,
      @storage.ArtifactRetention::ArtifactUntilTimestamp(100L),
    ),
    digest,
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
      @control.GoalId("goal-a"),
    ),
  )
  assert_eq(ledger.length(), 1)
  assert_eq(ledger[0].retentions.length(), 2)
  // The timestamp has passed but the Goal is still running: not collectable.
  let running = @storage.plan_artifact_sweep(ledger, 1_000L, never_terminal)
  @debug.assert_eq(running.collect, [])
  assert_eq(running.retain.length(), 1)
  // The Goal is terminal but the timestamp has not passed: still not.
  let early = @storage.plan_artifact_sweep(ledger, 99L, fn(_) { true })
  @debug.assert_eq(early.collect, [])
  // Both expired: now it goes.
  let done = @storage.plan_artifact_sweep(ledger, 1_000L, fn(_) { true })
  @debug.assert_eq(done.collect, [digest])
  @debug.assert_eq(done.retain, [])
}

///|
test "a permanent adoption outlives every other term on the same content" {
  let digest = retention_digest("permanent")
  let ledger = @storage.record_artifact_retention(
    @storage.record_artifact_retention(
      [],
      digest,
      @storage.ArtifactRetention::ArtifactUntilTimestamp(10L),
    ),
    digest,
    @storage.ArtifactRetention::ArtifactPermanent,
  )
  let plan = @storage.plan_artifact_sweep(ledger, 1_000_000L, fn(_) { true })
  @debug.assert_eq(plan.collect, [])
  assert_eq(plan.retain.length(), 1)
}

///|
test "recording the same term twice does not duplicate it" {
  let digest = retention_digest("repeat")
  let once = @storage.record_artifact_retention(
    [],
    digest,
    @storage.ArtifactRetention::ArtifactPermanent,
  )
  let twice = @storage.record_artifact_retention(
    once,
    digest,
    @storage.ArtifactRetention::ArtifactPermanent,
  )
  @debug.assert_eq(twice, once)
}

///|
/// Deleting on absent evidence is how a garbage collector eats live data.
test "an entry that lost its terms is retained rather than collected" {
  let digest = retention_digest("orphan")
  let plan = @storage.plan_artifact_sweep(
    [{ digest, retentions: [] }],
    1_000_000L,
    fn(_) { true },
  )
  @debug.assert_eq(plan.collect, [])
  assert_eq(plan.retain.length(), 1)
}

///|
test "a ledger round-trips every term it recorded" {
  let first = retention_digest("first")
  let second = retention_digest("second")
  let ledger = @storage.record_artifact_retention(
    @storage.record_artifact_retention(
      @storage.record_artifact_retention(
        [],
        first,
        @storage.ArtifactRetention::ArtifactPermanent,
      ),
      second,
      @storage.ArtifactRetention::ArtifactUntilTimestamp(4_600L),
    ),
    second,
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
      @control.GoalId("goal-b"),
    ),
  )
  let decoded = @storage.decode_artifact_retention_ledger(
    @storage.encode_artifact_retention_ledger(ledger),
  )
  @debug.assert_eq(decoded, ledger)
}

///|
test "collection revalidation never widens or guesses from absent evidence" {
  let expired = retention_digest("expired")
  let newly_live = retention_digest("newly-live")
  let absent = retention_digest("absent")
  let outside = retention_digest("outside")
  let live_goal = @control.GoalId("goal-live")
  let plan = @storage.revalidate_artifact_collection(
    [
      {
        digest: expired,
        retentions: [@storage.ArtifactRetention::ArtifactUntilTimestamp(100L)],
      },
      {
        digest: newly_live,
        retentions: [@storage.ArtifactRetention::ArtifactUntilTimestamp(100L)],
      },
      {
        digest: newly_live,
        retentions: [
          @storage.ArtifactRetention::ArtifactUntilGoalTerminal(live_goal),
        ],
      },
      {
        digest: outside,
        retentions: [@storage.ArtifactRetention::ArtifactPermanent],
      },
    ],
    [expired, newly_live, absent, expired],
    100L,
    fn(_) { false },
  )
  @debug.assert_eq(plan.collect, [expired])
  assert_eq(plan.retain.length(), 2)
  @debug.assert_eq(plan.retain[0].digest, newly_live)
  @debug.assert_eq(plan.retain[1].digest, absent)
  assert_eq(plan.retain[1].retentions.length(), 0)
}

///|
/// The ledger is appended to on every adoption, so a torn write is expected.
/// One unreadable line must cost that entry's collectability, not the file's.
test "an unreadable ledger line is skipped, not fatal" {
  let good = retention_digest("good")
  let content = @storage.encode_artifact_retention_ledger([
      {
        digest: good,
        retentions: [@storage.ArtifactRetention::ArtifactPermanent],
      },
    ]) +
    "not-a-digest permanent\n" +
    @storage.digest_text(retention_digest("truncated")) +
    " until:not-a-number\n" +
    "\n"
  let decoded = @storage.decode_artifact_retention_ledger(content)
  // The good entry survives. The malformed digest and the entry whose only
  // term was unreadable both contribute nothing, which leaves their content
  // invisible to the sweeper — unknown means retained, never collected.
  assert_eq(decoded.length(), 1)
  @debug.assert_eq(decoded[0].digest, good)
  @debug.assert_eq(
    @storage.plan_artifact_sweep(decoded, 1_000_000L, fn(_) { true }).collect,
    [],
  )
}
