///|
pub(all) struct GoalPullRequestPersistenceRequest {
  record : GoalPullRequestRecord
  expected_store_version : Int?
  goal_precondition : @storage.StateRecordPrecondition
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct GoalPullRequestPersistenceReceipt {
  store_version : Int
  record_digest : @control.Digest
  outcome : GoalPullRequestPersistenceOutcome
} derive(Debug, Eq)

///|
pub(all) enum GoalPullRequestPersistenceOutcome {
  GoalPullRequestPersistenceCompleted(@storage.StateTransactionOutcome)
  GoalPullRequestGoalPreconditionConflict
} derive(Debug, Eq)

///|
pub(all) struct StoredGoalPullRequestRecord {
  state_record : @storage.StateRecord
  record : GoalPullRequestRecord
} derive(Debug, Eq)

///|
fn goal_pull_request_state_key(
  goal_id : @control.GoalId,
) -> @storage.StateRecordKey {
  let digest = @storage.artifact_digest(@utf8.encode(goal_id.0))
  @storage.StateRecordKey("goal-pull-request:" + @storage.digest_text(digest))
}

///|
fn goal_pull_request_event_key(
  record : GoalPullRequestRecord,
) -> @storage.SemanticEventKey {
  let digest = @storage.artifact_digest(@utf8.encode(record.goal_id.0))
  @storage.SemanticEventKey(
    "goal-pull-request:" +
    @storage.digest_text(digest) +
    ":state:" +
    record.durable_version.to_string(),
  )
}

///|
pub fn persist_goal_pull_request_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : GoalPullRequestPersistenceRequest,
) -> Result[GoalPullRequestPersistenceReceipt, @types.ChoirError] {
  let content = goal_pull_request_record_bytes(request.record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(goal_pull_request_error("record exceeds repository limit"))
  }
  let expected_durable_version = match request.expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if request.record.durable_version != expected_durable_version {
    return Err(
      goal_pull_request_error("record durable version is inconsistent"),
    )
  }
  let record_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: record_digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalPullRequestRecord(
        request.record.goal_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != record_digest || adopted.byte_length != content.length() {
    return Err(goal_pull_request_error("artifact receipt is false"))
  }
  let guarded = match
    (adapters.state.commit_guarded)(repository.state_store, {
      transaction: {
        state: {
          key: goal_pull_request_state_key(request.record.goal_id),
          expected_version: request.expected_store_version,
          next_version: expected_durable_version,
          fencing_epoch: request.record.fencing_epoch,
          value_digest: record_digest,
        },
        outbox: {
          semantic_key: goal_pull_request_event_key(request.record),
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
    ) => GoalPullRequestPersistenceCompleted(value)
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict =>
      GoalPullRequestGoalPreconditionConflict
  }
  Ok({ store_version: expected_durable_version, record_digest, outcome })
}

///|
pub fn load_goal_pull_request_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[StoredGoalPullRequestRecord?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_pull_request_state_key(goal_id),
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
    return Err(goal_pull_request_error("content disagrees with durable state"))
  }
  let record = match decode_goal_pull_request_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state.key != goal_pull_request_state_key(record.goal_id) ||
    state.version != record.durable_version ||
    state.fencing_epoch != record.fencing_epoch {
    return Err(goal_pull_request_error("state identity is inconsistent"))
  }
  Ok(Some({ state_record: state, record }))
}
