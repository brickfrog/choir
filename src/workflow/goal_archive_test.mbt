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
fn archive_digest(value : String) -> @control.Digest {
  @storage.artifact_digest(@utf8.encode(value))
}

///|
fn archive_subject(
  state : @workflow.GoalExecutionState,
  pause? : @workflow.GoalPause? = None,
) -> @workflow.GoalArchiveSubject {
  {
    goal_id: archive_goal_id,
    state,
    pause,
    goal_ref: @workflow.goal_execution_ref(archive_goal_id),
  }
}

///|
fn archive_observation(
  subject : @workflow.GoalArchiveSubject,
  observed_refs? : Array[@workflow.GitRefName] = [],
  retention_ledger? : Array[@storage.ArtifactRetentionEntry] = [],
  runtime_root_present? : Bool = false,
  now? : Int64 = 1_000L,
) -> @workflow.GoalArchiveObservation {
  { subject, observed_refs, retention_ledger, runtime_root_present, now }
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
  // Another Goal's witness, a Part-keyed witness whose Bead a later Goal may
  // reselect, the integration target, and a branch that happens to sit inside
  // this Goal's namespace: none of them are this Goal's to release.
  let other_goal = @workflow.GitRefName(
    archive_seal_witness_prefix(@control.GoalId("goal-other")) +
    "sealed/intent-b",
  )
  let part_witness = @workflow.GitRefName("refs/choir/witness/choir-part")
  let integration = @workflow.GitRefName("refs/heads/main")
  let namespaced_branch = @workflow.GitRefName(
    "refs/heads/choir/goals/unexpected",
  )
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionSucceeded),
      observed_refs=[
        branch, initialized, seal_witness, other_goal, part_witness, integration,
        namespaced_branch,
      ],
    ),
  )
  assert_eq(plan.release_refs, [initialized, seal_witness])
  assert_eq(plan.retain_refs, [branch])
  assert_eq(plan.state, @workflow.GoalExecutionState::GoalExecutionSucceeded)
  assert_eq(plan.goal_id, archive_goal_id)
}

///|
test "a canceled Goal archives exactly like a succeeded one" {
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionCanceled),
      runtime_root_present=true,
    ),
  )
  assert_eq(plan.state, @workflow.GoalExecutionState::GoalExecutionCanceled)
  assert_true(plan.release_runtime_root)
}

///|
test "an archive names no runtime root the host did not observe" {
  let plan = archive_plan(
    archive_observation(
      archive_subject(@workflow.GoalExecutionState::GoalExecutionSucceeded),
    ),
  )
  assert_false(plan.release_runtime_root)
  assert_eq(plan.release_refs, [])
  assert_eq(plan.release_artifacts, [])
}

///|
test "an archive releases only content nothing else still retains" {
  let mine = archive_digest("mine")
  let shared_with_live_goal = archive_digest("shared-live")
  let shared_with_terminal_goal = archive_digest("shared-terminal")
  let permanent = archive_digest("permanent")
  let timed = archive_digest("timed")
  let unexpired = archive_digest("unexpired")
  let someone_else = archive_digest("someone-else")
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
