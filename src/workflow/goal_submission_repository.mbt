///|
pub(all) struct GoalSelectionPersistenceRequest {
  decision : GoalSelectionDecision
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct GoalSelectionPersistenceReceipt {
  decision_digest : @control.Digest
  transaction_outcome : @storage.StateTransactionOutcome
} derive(Debug, Eq)

///|
pub(all) struct StoredGoalSelectionDecision {
  state_record : @storage.StateRecord
  decision : GoalSelectionDecision
} derive(Debug, Eq)

///|
fn goal_selection_state_key(
  goal_id : @control.GoalId,
) -> @storage.StateRecordKey {
  let key_digest = @storage.artifact_digest(@utf8.encode(goal_id.0))
  @storage.StateRecordKey("goal-selection:" + @storage.digest_text(key_digest))
}

///|
fn goal_selection_event_key(
  goal_id : @control.GoalId,
) -> @storage.SemanticEventKey {
  let key_digest = @storage.artifact_digest(@utf8.encode(goal_id.0))
  @storage.SemanticEventKey(
    "goal-selection:" + @storage.digest_text(key_digest) + ":accepted",
  )
}

///|
pub fn persist_goal_selection_decision(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : GoalSelectionPersistenceRequest,
) -> Result[GoalSelectionPersistenceReceipt, @types.ChoirError] {
  let content = goal_selection_decision_bytes(request.decision)
  if content.length() > repository.max_snapshot_bytes {
    return Err(
      goal_submission_error("selection decision exceeds repository limit"),
    )
  }
  let decision_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: decision_digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalSelectionDecision(
        request.decision.proposal.goal_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != decision_digest ||
    adopted.byte_length != content.length() {
    return Err(goal_submission_error("selection artifact receipt is false"))
  }
  let transaction_outcome = match
    (adapters.state.commit)(repository.state_store, {
      state: {
        key: goal_selection_state_key(request.decision.proposal.goal_id),
        expected_version: None,
        next_version: 1,
        fencing_epoch: @control.FencingEpoch(1L),
        value_digest: decision_digest,
      },
      outbox: {
        semantic_key: goal_selection_event_key(
          request.decision.proposal.goal_id,
        ),
        payload_digest: decision_digest,
      },
      fault_point: request.fault_point,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ decision_digest, transaction_outcome })
}

///|
pub fn load_goal_selection_decision(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[StoredGoalSelectionDecision?, @types.ChoirError] {
  let state_record = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_selection_state_key(goal_id),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: state_record.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state_record.value_digest {
    return Err(
      goal_submission_error("selection content disagrees with durable state"),
    )
  }
  let decision = match decode_goal_selection_decision(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if decision.proposal.goal_id != goal_id {
    Err(goal_submission_error("selection Goal identity is inconsistent"))
  } else {
    Ok(Some({ state_record, decision }))
  }
}
