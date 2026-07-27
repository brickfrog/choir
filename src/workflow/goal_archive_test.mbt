///|
let archive_goal_id : @control.GoalId = @control.GoalId("goal-archive")

///|
/// The witness namespaces are recomputed here from the same formulas the
/// producers use, so a change to either one fails this test rather than
/// silently leaving an archive that names refs nothing writes.
fn archive_branch_witness_prefix(goal_id : @control.GoalId) -> String {
  "refs/choir/goals/" +
  @storage.digest_text(
    @storage.artifact_digest(
      @utf8.encode("choir.goal-execution.v1\u{00}" + goal_id.0),
    ),
  ) +
  "/"
}

///|
fn archive_seal_witness_prefix(goal_id : @control.GoalId) -> String {
  "refs/choir/goals/" +
  @storage.digest_text(@storage.artifact_digest(@utf8.encode(goal_id.0))) +
  "/"
}

///|
fn archive_digest(value : String) -> String {
  @storage.digest_text(@storage.artifact_digest(@utf8.encode(value)))
}

///|
fn archive_content_digest(value : String) -> @control.Digest {
  @storage.artifact_digest(@utf8.encode(value))
}

///|
/// A terminal Goal record whose id is the one under archive. Which state it is
/// terminal in has its own tests; here it only has to get past the gate.
fn archive_execution_record() -> @workflow.GoalExecutionRecord {
  let base = submission_execution()
  {
    ..base,
    goal: { ..base.goal, id: archive_goal_id },
    state: @workflow.GoalExecutionState::GoalExecutionSucceeded,
  }
}

///|
/// One Part driven to an observed integration witness, so both the intent and
/// the receipt that name a witness ref are real.
fn archive_part_snapshot(
  goal_id : @control.GoalId,
  intent_ref? : String? = None,
  receipt_ref? : String? = None,
) -> @workflow.PartWorkflowSnapshot raise {
  let authorized = drive_to_integration_authorized()
  guard authorized.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  let integrated = apply_observation(
    authorized,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  guard integrated.integration_intent is Some(intent) else {
    fail("an integrated Part has no intent")
  }
  guard integrated.integration_receipt is Some(receipt) else {
    fail("an integrated Part has no receipt")
  }
  {
    ..integrated,
    goal: { ..integrated.goal, id: goal_id },
    integration_intent: intent_ref.map(fn(reference) {
      { ..intent, git_witness_ref: reference }
    }),
    integration_receipt: receipt_ref.map(fn(reference) {
      { ..receipt, witness_ref: reference }
    }),
  }
}

///|
fn archive_subject(
  state : @workflow.GoalExecutionState,
  pause? : @workflow.GoalPause? = None,
  part_witness_refs? : Array[@workflow.GitRefName] = [],
) -> @workflow.GoalArchiveSubject {
  {
    goal_id: archive_goal_id,
    state,
    pause,
    goal_ref: @workflow.goal_execution_ref(archive_goal_id),
    part_witness_refs,
  }
}

///|
fn archive_observation(
  subject : @workflow.GoalArchiveSubject,
  observed_refs? : Array[@workflow.GitRefName] = [],
  retention_ledger? : Array[@storage.ArtifactRetentionEntry] = [],
  now? : Int64 = 1_000L,
) -> @workflow.GoalArchiveObservation {
  { subject, observed_refs, retention_ledger, now }
}

///|
fn archive_refusal(
  state : @workflow.GoalExecutionState,
  pause? : @workflow.GoalPause? = None,
) -> @workflow.GoalArchiveRefusal raise {
  match
    @workflow.plan_goal_archive(
      archive_observation(archive_subject(state, pause~)),
      fn(_) { true },
    ) {
    @workflow.GoalArchiveDecision::GoalArchiveRefused(refusal) => refusal
    @workflow.GoalArchiveDecision::GoalArchivePlanned(_) =>
      fail("a non-terminal Goal was planned for archival")
  }
}

///|
fn archive_plan(
  observation : @workflow.GoalArchiveObservation,
  goal_terminal? : (@control.GoalId) -> Bool = fn(_) { true },
) -> @workflow.GoalArchivePlan raise {
  match @workflow.plan_goal_archive(observation, goal_terminal) {
    @workflow.GoalArchiveDecision::GoalArchivePlanned(plan) => plan
    @workflow.GoalArchiveDecision::GoalArchiveRefused(_) =>
      fail("a terminal Goal was refused archival")
  }
}

///|
test "archive refuses every Goal that is still moving" {
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionQueued),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
      @workflow.GoalExecutionState::GoalExecutionQueued,
    ),
  )
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionRunning),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
      @workflow.GoalExecutionState::GoalExecutionRunning,
    ),
  )
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionAssuring),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
      @workflow.GoalExecutionState::GoalExecutionAssuring,
    ),
  )
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionAssured),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
      @workflow.GoalExecutionState::GoalExecutionAssured,
    ),
  )
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionCanceling),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
      @workflow.GoalExecutionState::GoalExecutionCanceling,
    ),
  )
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionBlocked),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalBlocked,
  )
}

///|
test "archive refuses a paused Goal by the reason it is paused" {
  let uncertain : @workflow.GoalPause = {
    reason: @workflow.GoalPauseReason::GoalPauseRecoveryUncertain,
    resume_state: @workflow.GoalExecutionState::GoalExecutionRunning,
  }
  assert_eq(
    archive_refusal(
      @workflow.GoalExecutionState::GoalExecutionPaused,
      pause=Some(uncertain),
    ),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalPaused(
      Some(@workflow.GoalPauseReason::GoalPauseRecoveryUncertain),
    ),
  )
  let awaiting : @workflow.GoalPause = {
    reason: @workflow.GoalPauseReason::GoalPauseAwaitingAnswer(
      @workflow.GoalInputRequestId("request-a"),
    ),
    resume_state: @workflow.GoalExecutionState::GoalExecutionRunning,
  }
  assert_eq(
    archive_refusal(
      @workflow.GoalExecutionState::GoalExecutionPaused,
      pause=Some(awaiting),
    ),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalPaused(
      Some(
        @workflow.GoalPauseReason::GoalPauseAwaitingAnswer(
          @workflow.GoalInputRequestId("request-a"),
        ),
      ),
    ),
  )
  // A paused record that lost its reason is still paused, and still refused.
  assert_eq(
    archive_refusal(@workflow.GoalExecutionState::GoalExecutionPaused),
    @workflow.GoalArchiveRefusal::GoalArchiveGoalPaused(None),
  )
}

///|
test "each refusal names the Goal and what would make it archivable" {
  let recovery = @workflow.goal_archive_refusal_message(
    archive_goal_id,
    @workflow.GoalArchiveRefusal::GoalArchiveGoalPaused(
      Some(@workflow.GoalPauseReason::GoalPauseRecoveryUncertain),
    ),
  )
  assert_true(recovery.contains("goal-archive"))
  assert_true(recovery.contains("recovery is uncertain"))
  assert_true(recovery.contains("succeeded or canceled"))
  assert_true(
    @workflow.goal_archive_refusal_message(
      archive_goal_id,
      @workflow.GoalArchiveRefusal::GoalArchiveGoalPaused(
        Some(
          @workflow.GoalPauseReason::GoalPauseAwaitingAnswer(
            @workflow.GoalInputRequestId("request-a"),
          ),
        ),
      ),
    ).contains("request-a"),
  )
  assert_true(
    @workflow.goal_archive_refusal_message(
      archive_goal_id,
      @workflow.GoalArchiveRefusal::GoalArchiveGoalBlocked,
    ).contains("blocked"),
  )
  assert_true(
    @workflow.goal_archive_refusal_message(
      archive_goal_id,
      @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
        @workflow.GoalExecutionState::GoalExecutionRunning,
      ),
    ).contains("running"),
  )
}

///|
test "an archive releases this Goal's witnesses and keeps its branch" {
  let branch = @workflow.goal_execution_ref(archive_goal_id)
  let initialized = @workflow.GitRefName(
    archive_branch_witness_prefix(archive_goal_id) + "initialized",
  )
  let seal_witness = @workflow.GitRefName(
    archive_seal_witness_prefix(archive_goal_id) + "sealed/intent-a",
  )
  // Another Goal's witness and a branch that happens to sit inside the Goal
  // namespace are what the host actually enumerates alongside this Goal's own
  // refs; neither is this Goal's to release. The integration target is outside
  // the namespaces the host lists at all, so it only guards against a widened
  // enumeration.
  let other_goal = @workflow.GitRefName(
    archive_seal_witness_prefix(@control.GoalId("goal-other")) +
    "sealed/intent-b",
  )
  let namespaced_branch = @workflow.GitRefName(
    "refs/heads/choir/goals/unexpected",
  )
  // Two Part-keyed integration witnesses. Their names are digests that say
  // nothing about which Goal minted them, so the only one released is the one
  // this Goal's own Part recorded.
  let mine = @workflow.GitRefName("refs/choir/witness/" + archive_digest("a"))
  let theirs = @workflow.GitRefName("refs/choir/witness/" + archive_digest("b"))
  let integration = @workflow.GitRefName("refs/heads/main")
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionSucceeded, part_witness_refs=[
        mine,
      ]),
      observed_refs=[
        branch, initialized, seal_witness, other_goal, namespaced_branch, mine, theirs,
        integration,
      ],
    ),
  )
  assert_eq(plan.release_refs, [initialized, seal_witness, mine])
  assert_eq(plan.retain_refs, [branch])
  assert_eq(plan.state, @workflow.GoalExecutionState::GoalExecutionSucceeded)
  assert_eq(plan.goal_id, archive_goal_id)
}

///|
/// The witness refs come out of the Goal's own Parts, because their names carry
/// no Goal. A snapshot naming a different Goal contributes nothing, and a
/// snapshot with neither an intent nor a receipt contributes nothing: releasing
/// a ref this Goal did not record would delete another Goal's idempotency
/// witness.
test "witness refs are read from this Goal's Parts and no other's" {
  let record = archive_execution_record()
  let mine = "refs/choir/witness/" + archive_digest("mine")
  let intent_only = "refs/choir/witness/" + archive_digest("intent")
  let theirs = "refs/choir/witness/" + archive_digest("theirs")
  let subject = @workflow.goal_archive_subject(record, [
    archive_part_snapshot(archive_goal_id, receipt_ref=Some(mine)),
    archive_part_snapshot(archive_goal_id, intent_ref=Some(intent_only)),
    archive_part_snapshot(archive_goal_id),
    archive_part_snapshot(
      @control.GoalId("goal-other"),
      receipt_ref=Some(theirs),
    ),
  ])
  assert_eq(subject.part_witness_refs, [
    @workflow.GitRefName(mine),
    @workflow.GitRefName(intent_only),
  ])
  // And the plan releases exactly those, out of everything the host listed.
  assert_eq(
    archive_plan(
      archive_observation(subject, observed_refs=[
        @workflow.GitRefName(mine),
        @workflow.GitRefName(theirs),
        @workflow.GitRefName(intent_only),
      ]),
    ).release_refs,
    [@workflow.GitRefName(mine), @workflow.GitRefName(intent_only)],
  )
}

///|
/// The witness refs are the only part of the release set that comes from a
/// durable string rather than from the Goal id, and nothing types those strings
/// as witnesses: `IntegrationIntent::git_witness_ref` and
/// `IntegrationReceipt::witness_ref` are bare `String`s. A record naming the
/// Goal's own branch must not turn the branch into something the archive
/// deletes, so the subject drops every recorded ref outside the witness
/// namespace.
test "a recorded ref outside the witness namespace is not a witness" {
  let record = archive_execution_record()
  let branch = record.goal_ref.0
  let witness = "refs/choir/witness/" + archive_digest("real")
  let subject = @workflow.goal_archive_subject(record, [
    archive_part_snapshot(archive_goal_id, receipt_ref=Some(branch)),
    archive_part_snapshot(
      archive_goal_id,
      intent_ref=Some("refs/heads/main"),
      receipt_ref=Some(witness),
    ),
  ])
  assert_eq(subject.part_witness_refs, [@workflow.GitRefName(witness)])
  let plan = archive_plan(
    archive_observation(subject, observed_refs=[
      @workflow.GitRefName(branch),
      @workflow.GitRefName("refs/heads/main"),
      @workflow.GitRefName(witness),
    ]),
  )
  assert_eq(plan.release_refs, [@workflow.GitRefName(witness)])
  assert_eq(plan.retain_refs, [@workflow.GitRefName(branch)])
}

///|
/// And the branch is retained even when the subject already carries it as a
/// witness, because the plan answers for the branch before it asks whether
/// anything else made the ref releasable.
test "the Goal branch is retained even when named as a witness ref" {
  let branch = @workflow.goal_execution_ref(archive_goal_id)
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionSucceeded, part_witness_refs=[
        branch,
      ]),
      observed_refs=[branch],
    ),
  )
  assert_eq(plan.retain_refs, [branch])
  assert_eq(plan.release_refs, [])
}

///|
test "a canceled Goal archives exactly like a succeeded one" {
  let branch = @workflow.goal_execution_ref(archive_goal_id)
  let initialized = @workflow.GitRefName(
    archive_branch_witness_prefix(archive_goal_id) + "initialized",
  )
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionCanceled),
      observed_refs=[branch, initialized],
    ),
  )
  assert_eq(plan.state, @workflow.GoalExecutionState::GoalExecutionCanceled)
  assert_eq(plan.release_refs, [initialized])
  assert_eq(plan.retain_refs, [branch])
}

///|
test "an archive names nothing the host did not observe" {
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionSucceeded),
    ),
  )
  assert_eq(plan.release_refs, [])
  assert_eq(plan.retain_refs, [])
  assert_eq(plan.release_artifacts, [])
  assert_eq(plan.retain_artifacts, [])
}

///|
test "an archive releases only content nothing else still retains" {
  let mine = archive_content_digest("mine")
  let shared_with_live_goal = archive_content_digest("shared-live")
  let shared_with_terminal_goal = archive_content_digest("shared-terminal")
  let permanent = archive_content_digest("permanent")
  let timed = archive_content_digest("timed")
  let unexpired = archive_content_digest("unexpired")
  let someone_else = archive_content_digest("someone-else")
  let live_goal = @control.GoalId("goal-live")
  let ledger : Array[@storage.ArtifactRetentionEntry] = [
    { digest: mine, retentions: [ArtifactUntilGoalTerminal(archive_goal_id)] },
    {
      digest: shared_with_live_goal,
      retentions: [
        ArtifactUntilGoalTerminal(archive_goal_id),
        ArtifactUntilGoalTerminal(live_goal),
      ],
    },
    {
      digest: shared_with_terminal_goal,
      retentions: [
        ArtifactUntilGoalTerminal(archive_goal_id),
        ArtifactUntilGoalTerminal(@control.GoalId("goal-done")),
      ],
    },
    {
      digest: permanent,
      retentions: [
        ArtifactUntilGoalTerminal(archive_goal_id),
        ArtifactPermanent,
      ],
    },
    {
      digest: timed,
      retentions: [
        ArtifactUntilGoalTerminal(archive_goal_id),
        ArtifactUntilTimestamp(500L),
      ],
    },
    {
      digest: unexpired,
      retentions: [
        ArtifactUntilGoalTerminal(archive_goal_id),
        ArtifactUntilTimestamp(9_000L),
      ],
    },
    { digest: someone_else, retentions: [ArtifactUntilGoalTerminal(live_goal)] },
  ]
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionSucceeded),
      retention_ledger=ledger,
      now=1_000L,
    ),
    goal_terminal=fn(goal_id) { goal_id != live_goal },
  )
  assert_eq(plan.release_artifacts, [mine, shared_with_terminal_goal, timed])
  // Content another Goal is still working under, content adopted permanently,
  // and content whose deadline has not arrived all survive the archive.
  assert_eq(plan.retain_artifacts, [shared_with_live_goal, permanent, unexpired])
  // Content this Goal never reached is neither released nor reported: the
  // archive of one Goal says nothing about another Goal's storage.
  assert_false(plan.release_artifacts.contains(someone_else))
  assert_false(plan.retain_artifacts.contains(someone_else))
}
