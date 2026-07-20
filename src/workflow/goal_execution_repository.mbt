///|
pub(all) struct GoalExecutionPersistenceRequest {
  record : GoalExecutionRecord
  expected_store_version : Int?
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct GoalExecutionPersistenceReceipt {
  store_version : Int
  record_digest : @control.Digest
  transaction_outcome : @storage.StateTransactionOutcome
} derive(Debug, Eq)

///|
pub(all) struct StoredGoalExecutionRecord {
  state_record : @storage.StateRecord
  record : GoalExecutionRecord
} derive(Debug, Eq)

///|
pub(all) enum GoalCancellationPersistenceResult {
  GoalCancellationPersisted(GoalExecutionRecord)
  GoalCancellationReplayed(GoalExecutionRecord)
  GoalCancellationTerminal(GoalExecutionState)
} derive(Debug, Eq)

///|
pub(all) enum GoalSteeringPersistenceResult {
  GoalSteeringPersisted(GoalExecutionRecord, GoalPolicyRevision)
  GoalSteeringReplayed(GoalExecutionRecord)
  GoalSteeringNoChange(GoalExecutionRecord)
  GoalSteeringTerminal(GoalExecutionState)
} derive(Debug, Eq)

///|
pub(all) enum GoalInputAnswerPersistenceResult {
  GoalInputAnswerPersisted(GoalExecutionRecord, GoalInputAnswer)
  GoalInputAnswerPersistenceReplayed(GoalExecutionRecord, GoalInputAnswer)
} derive(Debug, Eq)

///|
fn goal_execution_state_key(
  goal_id : @control.GoalId,
) -> @storage.StateRecordKey {
  let digest = @storage.artifact_digest(@utf8.encode(goal_id.0))
  @storage.StateRecordKey("goal-run:" + @storage.digest_text(digest))
}

///|
pub fn goal_execution_state_precondition(
  record : GoalExecutionRecord,
) -> @storage.StateRecordPrecondition {
  {
    record: {
      key: goal_execution_state_key(record.goal.id),
      version: record.durable_version,
      fencing_epoch: record.fencing_epoch,
      value_digest: goal_execution_record_digest(record),
    },
  }
}

///|
fn goal_execution_event_key(
  record : GoalExecutionRecord,
) -> @storage.SemanticEventKey {
  let digest = @storage.artifact_digest(@utf8.encode(record.goal.id.0))
  @storage.SemanticEventKey(
    "goal-run:" +
    @storage.digest_text(digest) +
    ":state:" +
    record.durable_version.to_string(),
  )
}

///|
pub fn persist_goal_execution_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : GoalExecutionPersistenceRequest,
) -> Result[GoalExecutionPersistenceReceipt, @types.ChoirError] {
  let content = goal_execution_record_bytes(request.record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(goal_execution_error("record exceeds repository limit"))
  }
  let expected_durable_version = match request.expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if request.record.durable_version != expected_durable_version {
    return Err(goal_execution_error("record durable version is inconsistent"))
  }
  let record_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: record_digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalExecutionRecord(
        request.record.goal.id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != record_digest || adopted.byte_length != content.length() {
    return Err(goal_execution_error("artifact receipt is false"))
  }
  let transaction_outcome = match
    (adapters.state.commit)(repository.state_store, {
      state: {
        key: goal_execution_state_key(request.record.goal.id),
        expected_version: request.expected_store_version,
        next_version: expected_durable_version,
        fencing_epoch: request.record.fencing_epoch,
        value_digest: record_digest,
      },
      outbox: {
        semantic_key: goal_execution_event_key(request.record),
        payload_digest: record_digest,
      },
      fault_point: request.fault_point,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    store_version: expected_durable_version,
    record_digest,
    transaction_outcome,
  })
}

///|
fn load_goal_execution_from_state(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  state_record : @storage.StateRecord,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: state_record.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state_record.value_digest {
    return Err(goal_execution_error("content disagrees with durable state"))
  }
  let record = match decode_goal_execution_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state_record.key != goal_execution_state_key(record.goal.id) ||
    state_record.version != record.durable_version ||
    state_record.fencing_epoch != record.fencing_epoch {
    return Err(goal_execution_error("state identity is inconsistent"))
  }
  Ok({ state_record, record })
}

///|
pub fn load_goal_execution_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[StoredGoalExecutionRecord?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_execution_state_key(goal_id),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  match load_goal_execution_from_state(repository, adapters, state) {
    Ok(value) => Ok(Some(value))
    Err(error) => Err(error)
  }
}

///|
pub fn list_goal_execution_records(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
) -> Result[Array[StoredGoalExecutionRecord], @types.ChoirError] {
  let states = match
    (adapters.state.list_state)(repository.state_store, "goal-run:") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let records : Array[StoredGoalExecutionRecord] = []
  for state in states {
    match load_goal_execution_from_state(repository, adapters, state) {
      Ok(value) => records.push(value)
      Err(error) => return Err(error)
    }
  }
  Ok(records)
}

///|
pub fn persist_goal_branch_initialization_transition(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  previous : StoredGoalExecutionRecord,
  next : GoalExecutionRecord,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  if next.goal.id != previous.record.goal.id ||
    next.durable_version != previous.record.durable_version + 1 {
    return Err(
      goal_execution_error("branch initialization transition is invalid"),
    )
  }
  let receipt = match
    persist_goal_execution_record(repository, adapters, {
      record: next,
      expected_store_version: Some(previous.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
      match load_goal_execution_record(repository, adapters, next.goal.id) {
        Ok(Some(observed)) if observed.record == next => Ok(observed)
        Ok(_) =>
          Err(
            goal_execution_error(
              "branch initialization transition did not reload",
            ),
          )
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      Err(goal_execution_error("branch initialization lost a state race"))
    _ => Err(goal_execution_error("branch initialization transaction failed"))
  }
}

///|
pub fn persist_goal_cancellation_request(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
  requested_at : Int64,
) -> Result[GoalCancellationPersistenceResult, @types.ChoirError] {
  let stored = match load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(goal_execution_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  let decision = match
    request_goal_execution_cancellation(stored.record, requested_at) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match decision {
    GoalCancellationAlreadyCanceling(record) =>
      Ok(GoalCancellationReplayed(record))
    GoalCancellationAlreadyTerminal(state) =>
      Ok(GoalCancellationTerminal(state))
    GoalCancellationRequested(record) => {
      let receipt = match
        persist_goal_execution_record(repository, adapters, {
          record,
          expected_store_version: Some(stored.state_record.version),
          fault_point: None,
        }) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match receipt.transaction_outcome {
        @storage.StateTransactionOutcome::StateTransactionCommitted
        | @storage.StateTransactionOutcome::StateTransactionReplayed
        | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
          match load_goal_execution_record(repository, adapters, goal_id) {
            Ok(Some(observed)) if observed.record == record =>
              Ok(GoalCancellationPersisted(observed.record))
            Ok(Some(observed)) =>
              match
                request_goal_execution_cancellation(
                  observed.record,
                  requested_at,
                ) {
                Ok(GoalCancellationAlreadyCanceling(current)) =>
                  Ok(GoalCancellationReplayed(current))
                Ok(GoalCancellationAlreadyTerminal(state)) =>
                  Ok(GoalCancellationTerminal(state))
                _ => Err(goal_execution_error("cancellation CAS was displaced"))
              }
            Ok(None) =>
              Err(goal_execution_error("cancellation record disappeared"))
            Err(error) => Err(error)
          }
        @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
          match load_goal_execution_record(repository, adapters, goal_id) {
            Ok(Some(observed)) =>
              match
                request_goal_execution_cancellation(
                  observed.record,
                  requested_at,
                ) {
                Ok(GoalCancellationAlreadyCanceling(current)) =>
                  Ok(GoalCancellationReplayed(current))
                Ok(GoalCancellationAlreadyTerminal(state)) =>
                  Ok(GoalCancellationTerminal(state))
                _ => Err(goal_execution_error("cancellation lost a state race"))
              }
            Ok(None) =>
              Err(goal_execution_error("cancellation record disappeared"))
            Err(error) => Err(error)
          }
        _ => Err(goal_execution_error("cancellation transaction failed"))
      }
    }
  }
}

///|
fn classify_goal_steering_after_race(
  observed : GoalExecutionRecord,
  requested_change : GoalPolicyChange,
  expected_revision : GoalPolicyRevision,
) -> Result[GoalSteeringPersistenceResult, @types.ChoirError] {
  if observed.policy_revisions.any(fn(revision) {
      revision.id == expected_revision.id && revision == expected_revision
    }) {
    return Ok(GoalSteeringReplayed(observed))
  }
  match steer_goal_execution(observed, requested_change) {
    Ok(GoalSteeringUnchanged(_)) => Ok(GoalSteeringReplayed(observed))
    Ok(GoalSteeringAlreadyTerminal(state)) => Ok(GoalSteeringTerminal(state))
    Ok(GoalSteeringApplied(_, _)) =>
      Err(goal_execution_error("steering lost a state race"))
    Err(error) => Err(error)
  }
}

///|
pub fn persist_goal_steering(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
  change : GoalPolicyChange,
) -> Result[GoalSteeringPersistenceResult, @types.ChoirError] {
  let stored = match load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(goal_execution_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  let decision = match steer_goal_execution(stored.record, change) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match decision {
    GoalSteeringUnchanged(record) => Ok(GoalSteeringNoChange(record))
    GoalSteeringAlreadyTerminal(state) => Ok(GoalSteeringTerminal(state))
    GoalSteeringApplied(record, revision) => {
      let receipt = match
        persist_goal_execution_record(repository, adapters, {
          record,
          expected_store_version: Some(stored.state_record.version),
          fault_point: None,
        }) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match receipt.transaction_outcome {
        @storage.StateTransactionOutcome::StateTransactionCommitted
        | @storage.StateTransactionOutcome::StateTransactionReplayed
        | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
          match load_goal_execution_record(repository, adapters, goal_id) {
            Ok(Some(observed)) if observed.record == record =>
              Ok(GoalSteeringPersisted(observed.record, revision))
            Ok(Some(observed)) =>
              classify_goal_steering_after_race(
                observed.record,
                change,
                revision,
              )
            Ok(None) => Err(goal_execution_error("steering record disappeared"))
            Err(error) => Err(error)
          }
        @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
          match load_goal_execution_record(repository, adapters, goal_id) {
            Ok(Some(observed)) =>
              classify_goal_steering_after_race(
                observed.record,
                change,
                revision,
              )
            Ok(None) => Err(goal_execution_error("steering record disappeared"))
            Err(error) => Err(error)
          }
        _ => Err(goal_execution_error("steering transaction failed"))
      }
    }
  }
}

///|
pub fn persist_goal_input_request(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : StoredGoalExecutionRecord,
  reason : GoalInputReason,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let decision = match request_goal_execution_input(stored.record, reason) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let next = match decision {
    GoalInputRequestReplayed(_, _) => return Ok(stored)
    GoalInputRequestCreated(record, _) => record
  }
  let receipt = match
    persist_goal_execution_record(repository, adapters, {
      record: next,
      expected_store_version: Some(stored.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !goal_execution_transaction_persisted(receipt.transaction_outcome) {
    return Err(goal_execution_error("input request state advance conflicted"))
  }
  match load_goal_execution_record(repository, adapters, next.goal.id) {
    Ok(Some(observed)) if observed.record == next => Ok(observed)
    Ok(_) => Err(goal_execution_error("input request did not reload"))
    Err(error) => Err(error)
  }
}

///|
fn classify_goal_input_answer_after_race(
  observed : GoalExecutionRecord,
  request_id : GoalInputRequestId,
  answer_artifact : @control.ArtifactReference,
  answered_at : Int64,
) -> Result[GoalInputAnswerPersistenceResult, @types.ChoirError] {
  match
    answer_goal_execution_input(
      observed, request_id, answer_artifact, answered_at,
    ) {
    Ok(GoalInputAnswerReplayed(record, answer)) =>
      Ok(GoalInputAnswerPersistenceReplayed(record, answer))
    Ok(GoalInputAnswerApplied(_, _)) =>
      Err(goal_execution_error("input answer lost a state race"))
    Err(error) => Err(error)
  }
}

///|
pub fn persist_goal_input_answer(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request_id : GoalInputRequestId,
  answer_text : String,
  answered_at : Int64,
) -> Result[GoalInputAnswerPersistenceResult, @types.ChoirError] {
  let answer_content = @utf8.encode(answer_text)
  if answer_text.trim() == "" || answer_content.length() > 64 * 1024 {
    return Err(goal_execution_error("input answer is empty or too large"))
  }
  let records = match list_goal_execution_records(repository, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut target : StoredGoalExecutionRecord? = None
  for stored in records {
    let matches = stored.record.active_input_request
      .map(fn(request) { request.id == request_id })
      .unwrap_or(false) ||
      stored.record.input_answers.any(fn(answer) {
        answer.request_id == request_id
      })
    if matches {
      if target is Some(_) {
        return Err(goal_execution_error("input request identity is ambiguous"))
      }
      target = Some(stored)
    }
  }
  let stored = match target {
    Some(value) => value
    None => return Err(goal_execution_error("input request is not registered"))
  }
  let digest = @storage.artifact_digest(answer_content)
  let answer_artifact : @control.ArtifactReference = {
    artifact_id: "sha256:" + @storage.digest_text(digest),
    digest,
  }
  for existing in stored.record.input_answers {
    if existing.request_id == request_id {
      if existing.answer_artifact == answer_artifact {
        return Ok(GoalInputAnswerPersistenceReplayed(stored.record, existing))
      }
      return Err(goal_execution_error("input request answer conflicts"))
    }
  }
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content: answer_content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalInputAnswer(
        stored.record.goal.id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_id_text(adopted.artifact_id) !=
    answer_artifact.artifact_id ||
    adopted.digest != digest {
    return Err(goal_execution_error("input answer artifact receipt is false"))
  }
  let decision = match
    answer_goal_execution_input(
      stored.record,
      request_id,
      answer_artifact,
      answered_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (next, answer) = match decision {
    GoalInputAnswerReplayed(record, answer) =>
      return Ok(GoalInputAnswerPersistenceReplayed(record, answer))
    GoalInputAnswerApplied(record, answer) => (record, answer)
  }
  let receipt = match
    persist_goal_execution_record(repository, adapters, {
      record: next,
      expected_store_version: Some(stored.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.transaction_outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
      match load_goal_execution_record(repository, adapters, next.goal.id) {
        Ok(Some(observed)) if observed.record == next =>
          Ok(GoalInputAnswerPersisted(observed.record, answer))
        Ok(Some(observed)) =>
          classify_goal_input_answer_after_race(
            observed.record,
            request_id,
            answer_artifact,
            answered_at,
          )
        Ok(None) => Err(goal_execution_error("input answer record disappeared"))
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      match load_goal_execution_record(repository, adapters, next.goal.id) {
        Ok(Some(observed)) =>
          classify_goal_input_answer_after_race(
            observed.record,
            request_id,
            answer_artifact,
            answered_at,
          )
        Ok(None) => Err(goal_execution_error("input answer record disappeared"))
        Err(error) => Err(error)
      }
    _ => Err(goal_execution_error("input answer transaction failed"))
  }
}

///|
pub fn persist_goal_cancellation_completion(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : StoredGoalExecutionRecord,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let record = match commit_goal_execution_cancellation(stored.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt = match
    persist_goal_execution_record(repository, adapters, {
      record,
      expected_store_version: Some(stored.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !goal_execution_transaction_persisted(receipt.transaction_outcome) {
    return Err(goal_execution_error("cancellation completion conflicted"))
  }
  match load_goal_execution_record(repository, adapters, record.goal.id) {
    Ok(Some(observed)) if observed.record == record => Ok(observed)
    Ok(_) => Err(goal_execution_error("cancellation completion did not reload"))
    Err(error) => Err(error)
  }
}
