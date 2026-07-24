///|
pub(all) struct GoalFinalizationPersistenceRequest {
  record : GoalFinalizationRecord
  expected_store_version : Int?
  goal_precondition : @storage.StateRecordPrecondition
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct GoalFinalizationPersistenceReceipt {
  store_version : Int
  record_digest : @control.Digest
  outcome : GoalFinalizationPersistenceOutcome
} derive(Debug, Eq)

///|
pub(all) enum GoalFinalizationPersistenceOutcome {
  GoalFinalizationPersistenceCompleted(@storage.StateTransactionOutcome)
  GoalFinalizationGoalPreconditionConflict
} derive(Debug, Eq)

///|
pub(all) struct StoredGoalFinalizationRecord {
  state_record : @storage.StateRecord
  record : GoalFinalizationRecord
} derive(Debug, Eq)

///|
fn goal_finalization_state_key(
  goal_id : @control.GoalId,
) -> @storage.StateRecordKey {
  let digest = @storage.artifact_digest(@utf8.encode(goal_id.0))
  @storage.StateRecordKey("goal-finalization:" + @storage.digest_text(digest))
}

///|
fn goal_finalization_event_key(
  record : GoalFinalizationRecord,
) -> @storage.SemanticEventKey {
  let digest = @storage.artifact_digest(@utf8.encode(record.goal_id.0))
  @storage.SemanticEventKey(
    "goal-finalization:" +
    @storage.digest_text(digest) +
    ":observation:" +
    record.readiness.observation_sequence.to_string(),
  )
}

///|
pub fn persist_goal_finalization_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : GoalFinalizationPersistenceRequest,
) -> Result[GoalFinalizationPersistenceReceipt, @types.ChoirError] {
  let content = goal_finalization_record_bytes(request.record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(goal_finalization_error("record exceeds repository limit"))
  }
  let expected_durable_version = match request.expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if request.record.durable_version != expected_durable_version {
    return Err(
      goal_finalization_error("record durable version is inconsistent"),
    )
  }
  let record_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: record_digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalFinalizationRecord(
        request.record.goal_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != record_digest || adopted.byte_length != content.length() {
    return Err(goal_finalization_error("artifact receipt is false"))
  }
  let guarded = match
    (adapters.state.commit_guarded)(repository.state_store, {
      transaction: {
        state: {
          key: goal_finalization_state_key(request.record.goal_id),
          expected_version: request.expected_store_version,
          next_version: expected_durable_version,
          fencing_epoch: request.record.fencing_epoch,
          value_digest: record_digest,
        },
        outbox: {
          semantic_key: goal_finalization_event_key(request.record),
          payload_digest: record_digest,
        },
        fault_point: request.fault_point,
      },
      precondition: request.goal_precondition,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let outcome = match guarded {
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      value
    ) => GoalFinalizationPersistenceCompleted(value)
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict =>
      GoalFinalizationGoalPreconditionConflict
  }
  Ok({ store_version: expected_durable_version, record_digest, outcome })
}

///|
pub fn load_goal_finalization_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[StoredGoalFinalizationRecord?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_finalization_state_key(goal_id),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: state.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state.value_digest {
    return Err(goal_finalization_error("content disagrees with durable state"))
  }
  let record = match decode_goal_finalization_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state.key != goal_finalization_state_key(record.goal_id) ||
    state.version != record.durable_version ||
    state.fencing_epoch != record.fencing_epoch {
    return Err(goal_finalization_error("state identity is inconsistent"))
  }
  Ok(Some({ state_record: state, record }))
}

///|
pub fn persist_goal_execution_success(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  execution : StoredGoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
  finalization : StoredGoalFinalizationRecord,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let succeeded = match
    authorize_goal_execution_success(
      execution.record,
      assurance,
      publication,
      pull_request,
      finalization.record,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  persist_finalization_authorized_advance(
    repository, adapters, execution, finalization, succeeded,
  )
}

///|
fn persist_finalization_authorized_advance(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  execution : StoredGoalExecutionRecord,
  finalization : StoredGoalFinalizationRecord,
  succeeded : GoalExecutionRecord,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let content = goal_execution_record_bytes(succeeded)
  let digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalExecutionRecord(
        succeeded.goal.id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != digest || adopted.byte_length != content.length() {
    return Err(goal_finalization_error("success artifact receipt is false"))
  }
  let guarded = match
    (adapters.state.commit_guarded)(repository.state_store, {
      transaction: {
        state: {
          key: goal_execution_state_key(succeeded.goal.id),
          expected_version: Some(execution.state_record.version),
          next_version: succeeded.durable_version,
          fencing_epoch: succeeded.fencing_epoch,
          value_digest: digest,
        },
        outbox: {
          semantic_key: goal_execution_event_key(succeeded),
          payload_digest: digest,
        },
        fault_point: None,
      },
      precondition: { record: finalization.state_record },
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match guarded {
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionCompleted(
      @storage.StateTransactionOutcome::StateTransactionCommitted
      | @storage.StateTransactionOutcome::StateTransactionReplayed
      | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost
    ) =>
      match
        load_goal_execution_record(repository, adapters, succeeded.goal.id) {
        Ok(Some(observed)) if observed.record == succeeded => Ok(observed)
        Ok(_) => Err(goal_finalization_error("success did not reload exactly"))
        Err(error) => Err(error)
      }
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict =>
      Err(goal_finalization_error("readiness changed before success"))
    _ => Err(goal_finalization_error("success state compare-and-set failed"))
  }
}
