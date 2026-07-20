///|
pub(all) enum GoalExecutionState {
  GoalExecutionQueued
  GoalExecutionRunning
  GoalExecutionAssuring
  GoalExecutionAssured
  GoalExecutionPaused
  GoalExecutionBlocked
  GoalExecutionCanceling
  GoalExecutionSucceeded
  GoalExecutionCanceled
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalPauseReason {
  GoalPauseRecoveryUncertain
  GoalPauseRequested
  GoalPauseAwaitingAnswer(GoalInputRequestId)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalInputRequestId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum GoalInputReason {
  GoalInputPublicationRemoteUnavailable
  GoalInputFinalizationNeedsUserInput
  GoalInputFinalizationDrifted
  GoalInputFinalizationAmbiguous
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalInputRequest {
  id : GoalInputRequestId
  goal_id : @control.GoalId
  reason : GoalInputReason
  created_at_version : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalInputAnswer {
  request_id : GoalInputRequestId
  answer_artifact : @control.ArtifactReference
  answered_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPause {
  reason : GoalPauseReason
  resume_state : GoalExecutionState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalPolicyChange {
  GoalPolicyInitial
  GoalPolicySetMaximumParallelParts(Int)
  GoalPolicyPause
  GoalPolicyResume
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPolicyRevision {
  id : @control.RevisionId
  goal_id : @control.GoalId
  parent_revision_id : @control.RevisionId?
  ordinal : Int
  change : GoalPolicyChange
  maximum_parallel_parts : Int
  digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalCancellationRequest {
  goal_id : @control.GoalId
  cutoff_sequence : @control.EventSequence
  requested_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalBranchInitIntentId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum GoalBranchInitLifecycle {
  GoalBranchInitPlanned
  GoalBranchInitAuthorized
  GoalBranchInitReceipted
  GoalBranchInitIntegrityBlocked
  GoalBranchInitUncertain
  GoalBranchInitAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalBranchInitReceipt {
  intent_id : GoalBranchInitIntentId
  idempotency_key : @control.Digest
  repository_id : RepositoryId
  goal_ref : GitRefName
  initialized_oid : @control.GitOid
  initialization_witness_ref : GitRefName
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalBranchInitialization {
  intent_id : GoalBranchInitIntentId
  goal_id : @control.GoalId
  repository_id : RepositoryId
  goal_ref : GitRefName
  captured_base_oid : @control.GitOid
  initialization_witness_ref : GitRefName
  idempotency_key : @control.Digest
  lifecycle : GoalBranchInitLifecycle
  receipt : GoalBranchInitReceipt?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalBranchInitObservation {
  GoalBranchInitRefsAbsent
  GoalBranchInitRefsAtBase
  GoalBranchInitBranchOnly
  GoalBranchInitWitnessOnly
  GoalBranchInitRefsDiverged
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalBranchInitReconciliation {
  GoalBranchInitObservationRecorded(GoalExecutionRecord)
  GoalBranchInitExactRetryAuthorized(GoalExecutionRecord)
} derive(Debug, Eq)

///|
pub(all) struct GoalExecutionRecord {
  goal : @control.Goal
  repository_id : RepositoryId
  selection_decision_digest : @control.Digest
  base_ref : GitRefName
  base_commit_oid : @control.GitOid
  base_tree_oid : @control.GitOid
  integration_target_ref : GitRefName
  goal_ref : GitRefName
  branch_initialization : GoalBranchInitialization
  maximum_parallel_parts : Int
  policy_revisions : Array[GoalPolicyRevision]
  part_workflow_ids : Array[String]
  state : GoalExecutionState
  pause : GoalPause?
  active_input_request : GoalInputRequest?
  input_answers : Array[GoalInputAnswer]
  cancellation_request : GoalCancellationRequest?
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_execution_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal execution: " + detail)
}

///|
fn goal_execution_identity_digest(goal_id : @control.GoalId) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode("choir.goal-execution.v1\u{00}" + goal_id.0),
  )
}

///|
fn goal_branch_initialization_identity(
  goal_id : @control.GoalId,
  repository_id : RepositoryId,
  goal_ref : GitRefName,
  base_oid : @control.GitOid,
) -> (GoalBranchInitIntentId, @control.Digest, GitRefName) {
  let witness_ref = GitRefName(
    "refs/choir/goals/" +
    @storage.digest_text(goal_execution_identity_digest(goal_id)) +
    "/initialized",
  )
  let digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.goal-branch-initialization.v1\u{00}" +
      [
        goal_id.to_json(),
        repository_id.to_json(),
        goal_ref.to_json(),
        base_oid.to_json(),
        witness_ref.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  (
    GoalBranchInitIntentId("branch-init-" + @storage.digest_text(digest)),
    digest,
    witness_ref,
  )
}

///|
pub fn initial_goal_branch_initialization(
  goal_id : @control.GoalId,
  repository_id : RepositoryId,
  goal_ref : GitRefName,
  base_oid : @control.GitOid,
) -> GoalBranchInitialization {
  let (intent_id, idempotency_key, initialization_witness_ref) = goal_branch_initialization_identity(
    goal_id, repository_id, goal_ref, base_oid,
  )
  {
    intent_id,
    goal_id,
    repository_id,
    goal_ref,
    captured_base_oid: base_oid,
    initialization_witness_ref,
    idempotency_key,
    lifecycle: GoalBranchInitLifecycle::GoalBranchInitPlanned,
    receipt: None,
  }
}

///|
fn goal_branch_initialization_shape_is_valid(
  record : GoalExecutionRecord,
) -> Bool {
  let expected = initial_goal_branch_initialization(
    record.goal.id,
    record.repository_id,
    record.goal_ref,
    record.base_commit_oid,
  )
  let initialization = record.branch_initialization
  let identity_valid = initialization.intent_id == expected.intent_id &&
    initialization.goal_id == record.goal.id &&
    initialization.repository_id == record.repository_id &&
    initialization.goal_ref == record.goal_ref &&
    initialization.captured_base_oid == record.base_commit_oid &&
    initialization.initialization_witness_ref ==
    expected.initialization_witness_ref &&
    initialization.idempotency_key == expected.idempotency_key
  let receipt_valid = match (initialization.lifecycle, initialization.receipt) {
    (GoalBranchInitReceipted, Some(receipt)) =>
      receipt.intent_id == initialization.intent_id &&
      receipt.idempotency_key == initialization.idempotency_key &&
      receipt.repository_id == initialization.repository_id &&
      receipt.goal_ref == initialization.goal_ref &&
      receipt.initialized_oid == initialization.captured_base_oid &&
      receipt.initialization_witness_ref ==
      initialization.initialization_witness_ref &&
      receipt.observed_at > 0L
    (GoalBranchInitReceipted, None) => false
    (_, None) => true
    (_, Some(_)) => false
  }
  let lifecycle_valid = match record.state {
    GoalExecutionQueued => initialization.lifecycle == GoalBranchInitPlanned
    GoalExecutionRunning | GoalExecutionPaused | GoalExecutionBlocked => true
    GoalExecutionCanceling | GoalExecutionCanceled =>
      match initialization.lifecycle {
        GoalBranchInitAuthorized
        | GoalBranchInitReceipted
        | GoalBranchInitIntegrityBlocked
        | GoalBranchInitUncertain
        | GoalBranchInitAbandonedByCancellation => true
        GoalBranchInitPlanned => false
      }
    GoalExecutionAssuring | GoalExecutionAssured | GoalExecutionSucceeded =>
      initialization.lifecycle == GoalBranchInitReceipted
  }
  identity_valid && receipt_valid && lifecycle_valid
}

///|
fn goal_policy_revision_digest(
  goal_id : @control.GoalId,
  parent_revision_id : @control.RevisionId?,
  ordinal : Int,
  change : GoalPolicyChange,
  maximum_parallel_parts : Int,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.goal-policy-revision.v1\u{00}" +
      [
        goal_id.to_json(),
        parent_revision_id.to_json(),
        ordinal.to_json(),
        change.to_json(),
        maximum_parallel_parts.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
}

///|
fn goal_policy_revision_id(digest : @control.Digest) -> @control.RevisionId {
  @control.RevisionId("goal-policy-" + @storage.digest_text(digest))
}

///|
pub fn initial_goal_policy_revision(
  goal_id : @control.GoalId,
  maximum_parallel_parts : Int,
) -> GoalPolicyRevision {
  let digest = goal_policy_revision_digest(
    goal_id,
    None,
    1,
    GoalPolicyChange::GoalPolicyInitial,
    maximum_parallel_parts,
  )
  {
    id: goal_policy_revision_id(digest),
    goal_id,
    parent_revision_id: None,
    ordinal: 1,
    change: GoalPolicyChange::GoalPolicyInitial,
    maximum_parallel_parts,
    digest,
  }
}

///|
fn next_goal_policy_revision(
  record : GoalExecutionRecord,
  change : GoalPolicyChange,
  maximum_parallel_parts : Int,
) -> GoalPolicyRevision {
  let previous = record.policy_revisions[record.policy_revisions.length() - 1]
  let ordinal = previous.ordinal + 1
  let digest = goal_policy_revision_digest(
    record.goal.id,
    Some(previous.id),
    ordinal,
    change,
    maximum_parallel_parts,
  )
  {
    id: goal_policy_revision_id(digest),
    goal_id: record.goal.id,
    parent_revision_id: Some(previous.id),
    ordinal,
    change,
    maximum_parallel_parts,
    digest,
  }
}

///|
fn goal_policy_revision_is_valid(
  revision : GoalPolicyRevision,
  goal_id : @control.GoalId,
  expected_parent : @control.RevisionId?,
  expected_ordinal : Int,
) -> Bool {
  let digest = goal_policy_revision_digest(
    revision.goal_id,
    revision.parent_revision_id,
    revision.ordinal,
    revision.change,
    revision.maximum_parallel_parts,
  )
  revision.goal_id == goal_id &&
  revision.parent_revision_id == expected_parent &&
  revision.ordinal == expected_ordinal &&
  revision.maximum_parallel_parts > 0 &&
  revision.digest == digest &&
  revision.id == goal_policy_revision_id(digest)
}

///|
fn goal_execution_policy_shape_is_valid(record : GoalExecutionRecord) -> Bool {
  if record.policy_revisions.length() == 0 {
    return false
  }
  let mut expected_parent : @control.RevisionId? = None
  for index = 0; index < record.policy_revisions.length(); index = index + 1 {
    let revision = record.policy_revisions[index]
    if !goal_policy_revision_is_valid(
        revision,
        record.goal.id,
        expected_parent,
        index + 1,
      ) {
      return false
    }
    if index == 0 && revision.change != GoalPolicyChange::GoalPolicyInitial {
      return false
    }
    if index > 0 && revision.change == GoalPolicyChange::GoalPolicyInitial {
      return false
    }
    expected_parent = Some(revision.id)
  }
  record.policy_revisions[record.policy_revisions.length() - 1].maximum_parallel_parts ==
  record.maximum_parallel_parts
}

///|
fn goal_execution_pause_shape_is_valid(record : GoalExecutionRecord) -> Bool {
  match (record.state, record.pause, record.active_input_request) {
    (
      GoalExecutionPaused,
      Some({ reason: GoalPauseAwaitingAnswer(request_id), resume_state }),
      Some(request),
    ) =>
      resume_state != GoalExecutionState::GoalExecutionPaused &&
      resume_state != GoalExecutionState::GoalExecutionCanceling &&
      resume_state != GoalExecutionState::GoalExecutionSucceeded &&
      resume_state != GoalExecutionState::GoalExecutionCanceled &&
      request.id == request_id &&
      request.goal_id == record.goal.id &&
      request.created_at_version > 0 &&
      request.created_at_version < record.durable_version
    (GoalExecutionPaused, Some(pause), None) => {
      let resume_is_terminal = match pause.resume_state {
        GoalExecutionCanceling
        | GoalExecutionSucceeded
        | GoalExecutionCanceled => true
        _ => false
      }
      pause.resume_state != GoalExecutionState::GoalExecutionPaused &&
      !resume_is_terminal
    }
    (GoalExecutionPaused, None, _) => false
    (GoalExecutionPaused, Some(_), Some(_)) => false
    (_, None, None) => true
    (_, _, _) => false
  }
}

///|
fn goal_execution_input_answers_are_valid(record : GoalExecutionRecord) -> Bool {
  for index = 0; index < record.input_answers.length(); index = index + 1 {
    let answer = record.input_answers[index]
    if answer.answered_at <= 0L ||
      @storage.validate_digest(answer.answer_artifact.digest) is Err(_) ||
      answer.answer_artifact.artifact_id !=
      "sha256:" + @storage.digest_text(answer.answer_artifact.digest) {
      return false
    }
    for previous = 0; previous < index; previous = previous + 1 {
      if record.input_answers[previous].request_id == answer.request_id {
        return false
      }
    }
  }
  true
}

///|
fn goal_execution_lifecycle(
  goal_id : @control.GoalId,
  state : GoalExecutionState,
  pause : GoalPause?,
  cancellation_request : GoalCancellationRequest?,
) -> @control.GoalLifecycle {
  let identity = @storage.digest_text(goal_execution_identity_digest(goal_id))
  match state {
    GoalExecutionQueued
    | GoalExecutionRunning
    | GoalExecutionAssuring
    | GoalExecutionAssured =>
      @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalRunning,
      )
    GoalExecutionPaused =>
      match pause {
        Some({ reason: GoalPauseRequested | GoalPauseAwaitingAnswer(_), .. }) =>
          @control.GoalLifecycle::GoalActive(
            @control.GoalActiveCondition::GoalNeedsInput,
          )
        _ =>
          @control.GoalLifecycle::GoalActive(
            @control.GoalActiveCondition::GoalRecoveryUncertain,
          )
      }
    GoalExecutionBlocked =>
      @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalIntegrityBlocked,
      )
    GoalExecutionCanceling =>
      match cancellation_request {
        Some(request) =>
          @control.GoalLifecycle::GoalCanceling(request.cutoff_sequence)
        None =>
          @control.GoalLifecycle::GoalCanceling(@control.EventSequence(0L))
      }
    GoalExecutionSucceeded =>
      @control.GoalLifecycle::GoalSucceeded(
        @control.FinalizationId("finalization-" + identity),
      )
    GoalExecutionCanceled =>
      @control.GoalLifecycle::GoalCanceled(
        @control.CancellationSummaryId("cancellation-" + identity),
      )
  }
}

///|
pub fn goal_execution_ref(goal_id : @control.GoalId) -> GitRefName {
  GitRefName(
    "refs/heads/choir/goals/" +
    @storage.digest_text(goal_execution_identity_digest(goal_id)),
  )
}

///|
pub fn goal_execution_record_from_selection(
  decision : GoalSelectionDecision,
  selection_decision_digest : @control.Digest,
  part_workflow_ids : Array[String],
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  if decision.outcome != GoalSelectionOutcome::GoalSelectionAccepted ||
    selection_decision_digest != goal_selection_decision_digest(decision) {
    return Err(goal_execution_error("selection is not accepted and durable"))
  }
  let goal = match decision.goal {
    Some(value) => value
    None => return Err(goal_execution_error("accepted Goal is absent"))
  }
  let goal_ref = goal_execution_ref(goal.id)
  if goal.lifecycle !=
    goal_execution_lifecycle(
      goal.id,
      GoalExecutionState::GoalExecutionQueued,
      None,
      None,
    ) {
    return Err(goal_execution_error("accepted Goal lifecycle is inconsistent"))
  }
  if part_workflow_ids.length() == 0 ||
    part_workflow_ids.length() != decision.accepted_parts.length() ||
    part_workflow_ids.any(fn(id) { id == "" }) {
    return Err(goal_execution_error("Part workflow bindings are incomplete"))
  }
  Ok({
    goal,
    repository_id: decision.proposal.repository_id,
    selection_decision_digest,
    base_ref: decision.proposal.base_ref,
    base_commit_oid: decision.proposal.expected_base_commit_oid,
    base_tree_oid: decision.proposal.expected_base_tree_oid,
    integration_target_ref: decision.proposal.integration_target_ref,
    goal_ref,
    branch_initialization: initial_goal_branch_initialization(
      goal.id,
      decision.proposal.repository_id,
      goal_ref,
      decision.proposal.expected_base_commit_oid,
    ),
    maximum_parallel_parts: decision.proposal.maximum_parallel_parts,
    policy_revisions: [
      initial_goal_policy_revision(
        goal.id,
        decision.proposal.maximum_parallel_parts,
      ),
    ],
    part_workflow_ids,
    state: GoalExecutionState::GoalExecutionQueued,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
  })
}

///|
pub fn goal_execution_record_bytes(record : GoalExecutionRecord) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn goal_execution_record_digest(
  record : GoalExecutionRecord,
) -> @control.Digest {
  @storage.artifact_digest(goal_execution_record_bytes(record))
}

///|
pub fn decode_goal_execution_record(
  content : Bytes,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_execution_error("record is not valid JSON"))
  }
  let record : GoalExecutionRecord = @json.from_json(json) catch {
    _ => return Err(goal_execution_error("record has the wrong schema"))
  }
  if record.goal.id.0 == "" ||
    record.goal_ref != goal_execution_ref(record.goal.id) ||
    record.maximum_parallel_parts <= 0 ||
    !goal_execution_policy_shape_is_valid(record) ||
    record.part_workflow_ids.length() == 0 ||
    record.part_workflow_ids.any(fn(id) { id == "" }) ||
    record.durable_version <= 0 ||
    record.fencing_epoch.0 <= 0L ||
    record.goal.lifecycle !=
    goal_execution_lifecycle(
      record.goal.id,
      record.state,
      record.pause,
      record.cancellation_request,
    ) ||
    !goal_execution_pause_shape_is_valid(record) ||
    !goal_execution_input_answers_are_valid(record) ||
    !goal_execution_cancellation_shape_is_valid(record) ||
    !goal_branch_initialization_shape_is_valid(record) ||
    @storage.validate_digest(record.selection_decision_digest) is Err(_) {
    Err(goal_execution_error("record identity is invalid"))
  } else {
    Ok(record)
  }
}

///|
fn goal_execution_cancellation_shape_is_valid(
  record : GoalExecutionRecord,
) -> Bool {
  match (record.state, record.cancellation_request) {
    (GoalExecutionCanceling | GoalExecutionCanceled, Some(request)) =>
      request.goal_id == record.goal.id &&
      request.cutoff_sequence.0 > 0L &&
      request.requested_at > 0L
    (GoalExecutionCanceling | GoalExecutionCanceled, None) => false
    (_, None) => true
    (_, Some(_)) => false
  }
}

///|
pub fn goal_execution_is_terminal(record : GoalExecutionRecord) -> Bool {
  match record.state {
    GoalExecutionState::GoalExecutionSucceeded
    | GoalExecutionState::GoalExecutionCanceled => true
    _ => false
  }
}

///|
pub fn authorize_goal_branch_initialization(
  record : GoalExecutionRecord,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  if record.state != GoalExecutionRunning ||
    record.cancellation_request is Some(_) ||
    record.branch_initialization.lifecycle != GoalBranchInitPlanned ||
    !goal_branch_initialization_shape_is_valid(record) {
    return Err(
      goal_execution_error("branch initialization is not authorizable"),
    )
  }
  Ok({
    ..record,
    branch_initialization: {
      ..record.branch_initialization,
      lifecycle: GoalBranchInitAuthorized,
    },
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn reconcile_goal_branch_initialization(
  record : GoalExecutionRecord,
  observation : GoalBranchInitObservation,
  observed_at : Int64,
) -> Result[GoalBranchInitReconciliation, @types.ChoirError] {
  let initialization = record.branch_initialization
  if initialization.lifecycle == GoalBranchInitReceipted &&
    observation == GoalBranchInitRefsAtBase {
    return Ok(GoalBranchInitObservationRecorded(record))
  }
  if initialization.lifecycle != GoalBranchInitAuthorized || observed_at <= 0L {
    return Err(goal_execution_error("branch initialization is not authorized"))
  }
  match observation {
    GoalBranchInitRefsAbsent => Ok(GoalBranchInitExactRetryAuthorized(record))
    GoalBranchInitRefsAtBase => {
      let receipt : GoalBranchInitReceipt = {
        intent_id: initialization.intent_id,
        idempotency_key: initialization.idempotency_key,
        repository_id: initialization.repository_id,
        goal_ref: initialization.goal_ref,
        initialized_oid: initialization.captured_base_oid,
        initialization_witness_ref: initialization.initialization_witness_ref,
        observed_at,
      }
      Ok(
        GoalBranchInitObservationRecorded({
          ..record,
          branch_initialization: {
            ..initialization,
            lifecycle: GoalBranchInitReceipted,
            receipt: Some(receipt),
          },
          durable_version: record.durable_version + 1,
        }),
      )
    }
    GoalBranchInitBranchOnly | GoalBranchInitWitnessOnly => {
      let state = if record.state == GoalExecutionCanceling {
        record.state
      } else {
        GoalExecutionBlocked
      }
      let lifecycle = goal_execution_lifecycle(
        record.goal.id,
        state,
        None,
        record.cancellation_request,
      )
      Ok(
        GoalBranchInitObservationRecorded({
          ..record,
          goal: { ..record.goal, lifecycle, },
          branch_initialization: {
            ..initialization,
            lifecycle: GoalBranchInitIntegrityBlocked,
          },
          state,
          pause: None,
          durable_version: record.durable_version + 1,
        }),
      )
    }
    GoalBranchInitRefsDiverged => {
      let state = if record.state == GoalExecutionCanceling {
        record.state
      } else {
        GoalExecutionPaused
      }
      let pause = if state == GoalExecutionPaused {
        Some({
          reason: GoalPauseRecoveryUncertain,
          resume_state: GoalExecutionRunning,
        })
      } else {
        None
      }
      let lifecycle = goal_execution_lifecycle(
        record.goal.id,
        state,
        pause,
        record.cancellation_request,
      )
      Ok(
        GoalBranchInitObservationRecorded({
          ..record,
          goal: { ..record.goal, lifecycle, },
          branch_initialization: {
            ..initialization,
            lifecycle: GoalBranchInitUncertain,
          },
          state,
          pause,
          durable_version: record.durable_version + 1,
        }),
      )
    }
  }
}

///|
pub fn goal_branch_initialization_disposition_is_known(
  record : GoalExecutionRecord,
) -> Bool {
  match record.branch_initialization.lifecycle {
    GoalBranchInitReceipted
    | GoalBranchInitIntegrityBlocked
    | GoalBranchInitUncertain
    | GoalBranchInitAbandonedByCancellation => true
    _ => false
  }
}

///|
pub fn advance_goal_execution_state(
  record : GoalExecutionRecord,
  state : GoalExecutionState,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  if goal_execution_is_terminal(record) {
    return Err(goal_execution_error("terminal record cannot advance"))
  }
  if record.active_input_request is Some(_) {
    return Err(goal_execution_error("Goal awaiting an answer cannot advance"))
  }
  if (
      state == GoalExecutionAssuring ||
      state == GoalExecutionAssured ||
      state == GoalExecutionSucceeded
    ) &&
    record.branch_initialization.lifecycle != GoalBranchInitReceipted {
    return Err(
      goal_execution_error("Goal branch initialization is not receipted"),
    )
  }
  let allowed = match (record.state, state) {
    (GoalExecutionQueued, GoalExecutionRunning)
    | (GoalExecutionRunning, GoalExecutionAssuring)
    | (GoalExecutionRunning, GoalExecutionPaused)
    | (GoalExecutionRunning, GoalExecutionBlocked)
    | (GoalExecutionAssuring, GoalExecutionAssured)
    | (GoalExecutionAssuring, GoalExecutionPaused)
    | (GoalExecutionAssuring, GoalExecutionBlocked)
    | (GoalExecutionAssured, GoalExecutionSucceeded)
    | (GoalExecutionAssured, GoalExecutionPaused)
    | (GoalExecutionPaused, GoalExecutionRunning)
    | (GoalExecutionBlocked, GoalExecutionRunning) => true
    _ => false
  }
  if !allowed {
    return Err(goal_execution_error("state transition is invalid"))
  }
  let pause = if state == GoalExecutionState::GoalExecutionPaused {
    Some({
      reason: GoalPauseReason::GoalPauseRecoveryUncertain,
      resume_state: record.state,
    })
  } else {
    None
  }
  let lifecycle = goal_execution_lifecycle(
    record.goal.id,
    state,
    pause,
    record.cancellation_request,
  )
  Ok({
    ..record,
    goal: { ..record.goal, lifecycle, },
    state,
    pause,
    active_input_request: None,
    durable_version: record.durable_version + 1,
  })
}

///|
pub(all) enum GoalSteeringDecision {
  GoalSteeringApplied(GoalExecutionRecord, GoalPolicyRevision)
  GoalSteeringUnchanged(GoalExecutionRecord)
  GoalSteeringAlreadyTerminal(GoalExecutionState)
} derive(Debug, Eq)

///|
pub fn steer_goal_execution(
  record : GoalExecutionRecord,
  change : GoalPolicyChange,
) -> Result[GoalSteeringDecision, @types.ChoirError] {
  if !goal_execution_policy_shape_is_valid(record) ||
    !goal_execution_pause_shape_is_valid(record) {
    return Err(goal_execution_error("policy state is inconsistent"))
  }
  match record.state {
    GoalExecutionSucceeded | GoalExecutionCanceled =>
      return Ok(GoalSteeringAlreadyTerminal(record.state))
    GoalExecutionCanceling =>
      return Err(goal_execution_error("canceling Goal cannot be steered"))
    _ => ()
  }
  let (maximum_parallel_parts, state, pause) = match change {
    GoalPolicyInitial =>
      return Err(goal_execution_error("initial policy cannot be replayed"))
    GoalPolicySetMaximumParallelParts(value) => {
      if value <= 0 {
        return Err(goal_execution_error("maximum parallel Parts is invalid"))
      }
      if value == record.maximum_parallel_parts {
        return Ok(GoalSteeringUnchanged(record))
      }
      (value, record.state, record.pause)
    }
    GoalPolicyPause =>
      if record.state == GoalExecutionState::GoalExecutionPaused {
        return Ok(GoalSteeringUnchanged(record))
      } else {
        (
          record.maximum_parallel_parts,
          GoalExecutionState::GoalExecutionPaused,
          Some({
            reason: GoalPauseReason::GoalPauseRequested,
            resume_state: record.state,
          }),
        )
      }
    GoalPolicyResume =>
      match (record.state, record.pause) {
        (GoalExecutionPaused, Some({ reason: GoalPauseAwaitingAnswer(_), .. })) =>
          return Err(
            goal_execution_error(
              "Goal awaiting an answer cannot bypass its request",
            ),
          )
        (GoalExecutionPaused, Some(pause)) =>
          (record.maximum_parallel_parts, pause.resume_state, None)
        _ => return Ok(GoalSteeringUnchanged(record))
      }
  }
  let revision = next_goal_policy_revision(
    record, change, maximum_parallel_parts,
  )
  let revisions = record.policy_revisions.copy()
  revisions.push(revision)
  let lifecycle = goal_execution_lifecycle(
    record.goal.id,
    state,
    pause,
    record.cancellation_request,
  )
  let next = {
    ..record,
    goal: { ..record.goal, lifecycle, },
    maximum_parallel_parts,
    policy_revisions: revisions,
    state,
    pause,
    durable_version: record.durable_version + 1,
  }
  if !goal_execution_policy_shape_is_valid(next) ||
    !goal_execution_pause_shape_is_valid(next) {
    Err(goal_execution_error("policy revision is invalid"))
  } else {
    Ok(GoalSteeringApplied(next, revision))
  }
}

///|
fn goal_input_request_id(
  record : GoalExecutionRecord,
  reason : GoalInputReason,
) -> GoalInputRequestId {
  let digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.goal-input-request.v1\u{00}" +
      [
        record.goal.id.to_json(),
        record.durable_version.to_json(),
        reason.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  GoalInputRequestId("goal-input-" + @storage.digest_text(digest))
}

///|
pub(all) enum GoalInputRequestDecision {
  GoalInputRequestCreated(GoalExecutionRecord, GoalInputRequest)
  GoalInputRequestReplayed(GoalExecutionRecord, GoalInputRequest)
} derive(Debug, Eq)

///|
pub fn request_goal_execution_input(
  record : GoalExecutionRecord,
  reason : GoalInputReason,
) -> Result[GoalInputRequestDecision, @types.ChoirError] {
  match (record.state, record.active_input_request, record.pause) {
    (
      GoalExecutionPaused,
      Some(request),
      Some({ reason: GoalPauseAwaitingAnswer(request_id), .. }),
    ) if request.id == request_id && request.reason == reason =>
      return Ok(GoalInputRequestReplayed(record, request))
    (GoalExecutionPaused, Some(_), _) =>
      return Err(goal_execution_error("Goal already awaits another answer"))
    (GoalExecutionPaused, None, _) =>
      return Err(goal_execution_error("paused Goal cannot request input"))
    (
      GoalExecutionSucceeded
      | GoalExecutionCanceled
      | GoalExecutionCanceling,
      _,
      _,
    ) => return Err(goal_execution_error("terminal Goal cannot request input"))
    _ => ()
  }
  if record.state != GoalExecutionState::GoalExecutionAssured {
    return Err(
      goal_execution_error("finalization input requires an assured Goal"),
    )
  }
  let request : GoalInputRequest = {
    id: goal_input_request_id(record, reason),
    goal_id: record.goal.id,
    reason,
    created_at_version: record.durable_version,
  }
  let pause : GoalPause = {
    reason: GoalPauseAwaitingAnswer(request.id),
    resume_state: record.state,
  }
  let next = {
    ..record,
    goal: {
      ..record.goal,
      lifecycle: goal_execution_lifecycle(
        record.goal.id,
        GoalExecutionState::GoalExecutionPaused,
        Some(pause),
        record.cancellation_request,
      ),
    },
    state: GoalExecutionState::GoalExecutionPaused,
    pause: Some(pause),
    active_input_request: Some(request),
    durable_version: record.durable_version + 1,
  }
  if goal_execution_pause_shape_is_valid(next) {
    Ok(GoalInputRequestCreated(next, request))
  } else {
    Err(goal_execution_error("input request is inconsistent"))
  }
}

///|
pub(all) enum GoalInputAnswerDecision {
  GoalInputAnswerApplied(GoalExecutionRecord, GoalInputAnswer)
  GoalInputAnswerReplayed(GoalExecutionRecord, GoalInputAnswer)
} derive(Debug, Eq)

///|
pub fn answer_goal_execution_input(
  record : GoalExecutionRecord,
  request_id : GoalInputRequestId,
  answer_artifact : @control.ArtifactReference,
  answered_at : Int64,
) -> Result[GoalInputAnswerDecision, @types.ChoirError] {
  for existing in record.input_answers {
    if existing.request_id == request_id {
      if existing.answer_artifact == answer_artifact {
        return Ok(GoalInputAnswerReplayed(record, existing))
      }
      return Err(goal_execution_error("input request answer conflicts"))
    }
  }
  if answered_at <= 0L ||
    @storage.validate_digest(answer_artifact.digest) is Err(_) ||
    answer_artifact.artifact_id !=
    "sha256:" + @storage.digest_text(answer_artifact.digest) {
    return Err(goal_execution_error("input answer artifact is invalid"))
  }
  guard record.active_input_request is Some(request) &&
    request.id == request_id &&
    record.state == GoalExecutionState::GoalExecutionPaused &&
    record.pause is Some(pause) &&
    pause.reason == GoalPauseReason::GoalPauseAwaitingAnswer(request_id) else {
    return Err(goal_execution_error("input request is not active"))
  }
  let answer : GoalInputAnswer = { request_id, answer_artifact, answered_at }
  let answers = record.input_answers.copy()
  answers.push(answer)
  let next = {
    ..record,
    goal: {
      ..record.goal,
      lifecycle: goal_execution_lifecycle(
        record.goal.id,
        pause.resume_state,
        None,
        record.cancellation_request,
      ),
    },
    state: pause.resume_state,
    pause: None,
    active_input_request: None,
    input_answers: answers,
    durable_version: record.durable_version + 1,
  }
  if goal_execution_pause_shape_is_valid(next) &&
    goal_execution_input_answers_are_valid(next) {
    Ok(GoalInputAnswerApplied(next, answer))
  } else {
    Err(goal_execution_error("input answer is inconsistent"))
  }
}

///|
pub(all) enum GoalCancellationDecision {
  GoalCancellationRequested(GoalExecutionRecord)
  GoalCancellationAlreadyCanceling(GoalExecutionRecord)
  GoalCancellationAlreadyTerminal(GoalExecutionState)
} derive(Debug, Eq)

///|
pub fn request_goal_execution_cancellation(
  record : GoalExecutionRecord,
  requested_at : Int64,
) -> Result[GoalCancellationDecision, @types.ChoirError] {
  if requested_at <= 0L {
    return Err(goal_execution_error("cancellation time is invalid"))
  }
  match record.state {
    GoalExecutionCanceling =>
      if goal_execution_cancellation_shape_is_valid(record) {
        Ok(GoalCancellationAlreadyCanceling(record))
      } else {
        Err(goal_execution_error("cancellation request is inconsistent"))
      }
    GoalExecutionSucceeded | GoalExecutionCanceled =>
      Ok(GoalCancellationAlreadyTerminal(record.state))
    _ => {
      let request : GoalCancellationRequest = {
        goal_id: record.goal.id,
        cutoff_sequence: @control.EventSequence(
          record.durable_version.to_int64() + 1L,
        ),
        requested_at,
      }
      let goal = match
        @control.transition_goal(
          record.goal,
          @control.GoalTransition::RequestGoalCancellation(
            request.cutoff_sequence,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let branch_initialization = if record.branch_initialization.lifecycle ==
        GoalBranchInitPlanned {
        {
          ..record.branch_initialization,
          lifecycle: GoalBranchInitAbandonedByCancellation,
        }
      } else {
        record.branch_initialization
      }
      Ok(
        GoalCancellationRequested({
          ..record,
          goal,
          branch_initialization,
          state: GoalExecutionCanceling,
          pause: None,
          active_input_request: None,
          cancellation_request: Some(request),
          durable_version: record.durable_version + 1,
        }),
      )
    }
  }
}

///|
pub fn commit_goal_execution_cancellation(
  record : GoalExecutionRecord,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  if record.state != GoalExecutionCanceling ||
    !goal_execution_cancellation_shape_is_valid(record) ||
    !goal_branch_initialization_disposition_is_known(record) {
    return Err(goal_execution_error("Goal has no durable cancellation cutoff"))
  }
  let identity = @storage.digest_text(
    goal_execution_identity_digest(record.goal.id),
  )
  let goal = match
    @control.transition_goal(
      record.goal,
      @control.GoalTransition::CommitGoalCancellation(
        @control.CancellationSummaryId("cancellation-" + identity),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..record,
    goal,
    state: GoalExecutionCanceled,
    durable_version: record.durable_version + 1,
  })
}
