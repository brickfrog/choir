//|

///|
pub(all) struct GoalAssurancePersistenceRequest {
  record : GoalAssuranceRecord
  expected_store_version : Int?
  goal_precondition : @storage.StateRecordPrecondition
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct GoalAssurancePersistenceReceipt {
  store_version : Int
  record_digest : @control.Digest
  outcome : GoalAssurancePersistenceOutcome
} derive(Debug, Eq)

///|
pub(all) enum GoalAssurancePersistenceOutcome {
  GoalAssurancePersistenceCompleted(@storage.StateTransactionOutcome)
  GoalAssuranceGoalPreconditionConflict
} derive(Debug, Eq)

///|
pub(all) struct StoredGoalAssuranceRecord {
  state_record : @storage.StateRecord
  record : GoalAssuranceRecord
} derive(Debug, Eq)

///|
fn goal_assurance_state_key(
  goal_id : @control.GoalId,
) -> @storage.StateRecordKey {
  let digest = @storage.artifact_digest(@utf8.encode(goal_id.0))
  @storage.StateRecordKey("goal-assurance:" + @storage.digest_text(digest))
}

///|
fn goal_assurance_event_key(
  record : GoalAssuranceRecord,
) -> @storage.SemanticEventKey {
  let digest = @storage.artifact_digest(@utf8.encode(record.goal_id.0))
  @storage.SemanticEventKey(
    "goal-assurance:" +
    @storage.digest_text(digest) +
    ":state:" +
    record.durable_version.to_string(),
  )
}

///|
fn goal_assurance_witness_state_key(
  effect_id : String,
) -> @storage.StateRecordKey {
  @storage.StateRecordKey("goal-assurance-witness:" + effect_id)
}

///|
fn goal_assurance_witness_event_key(
  effect_id : String,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey("goal-assurance-witness:" + effect_id)
}

///|
pub fn persist_goal_assurance_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : GoalAssurancePersistenceRequest,
) -> Result[GoalAssurancePersistenceReceipt, @types.ChoirError] {
  let content = goal_assurance_record_bytes(request.record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(goal_assurance_error("record exceeds repository limit"))
  }
  let expected_durable_version = match request.expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if request.record.durable_version != expected_durable_version {
    return Err(goal_assurance_error("record durable version is inconsistent"))
  }
  let record_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: record_digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalAssuranceRecord(
        request.record.goal_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != record_digest || adopted.byte_length != content.length() {
    return Err(goal_assurance_error("artifact receipt is false"))
  }
  let guarded = match
    (adapters.state.commit_guarded)(repository.state_store, {
      transaction: {
        state: {
          key: goal_assurance_state_key(request.record.goal_id),
          expected_version: request.expected_store_version,
          next_version: expected_durable_version,
          fencing_epoch: request.record.fencing_epoch,
          value_digest: record_digest,
        },
        outbox: {
          semantic_key: goal_assurance_event_key(request.record),
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
    ) => GoalAssurancePersistenceCompleted(value)
    @storage.GuardedStateTransactionOutcome::GuardedStateTransactionPreconditionConflict =>
      GoalAssuranceGoalPreconditionConflict
  }
  Ok({ store_version: expected_durable_version, record_digest, outcome })
}

///|
pub fn load_goal_assurance_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[StoredGoalAssuranceRecord?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_assurance_state_key(goal_id),
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
    return Err(goal_assurance_error("content disagrees with durable state"))
  }
  let record = match decode_goal_assurance_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state.key != goal_assurance_state_key(record.goal_id) ||
    state.version != record.durable_version ||
    state.fencing_epoch != record.fencing_epoch {
    return Err(goal_assurance_error("state identity is inconsistent"))
  }
  Ok(Some({ state_record: state, record }))
}

///|
pub fn load_goal_assurance_effect_witness(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  intent : GoalAssuranceEffectIntent,
) -> Result[GoalAssuranceEffectWitness?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_assurance_witness_state_key(intent.effect_id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let record = match state {
    Some(value) => value
    None => return Ok(None)
  }
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: record.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witness = match decode_goal_assurance_effect_witness(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if witness.effect_id != intent.effect_id ||
    witness.request_digest != intent.request_digest ||
    record.fencing_epoch.0 <= 0L {
    Err(goal_assurance_error("effect witness disagrees with its intent"))
  } else {
    Ok(Some(witness))
  }
}

///|
pub fn record_goal_assurance_effect_witness(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  record : GoalAssuranceRecord,
  intent : GoalAssuranceEffectIntent,
  observation : GoalAssuranceEffectObservation,
  observed_at : Int64,
) -> Result[GoalAssuranceEffectWitness, @types.ChoirError] {
  if record.pending_effect != Some(intent) ||
    intent.lifecycle != GoalAssuranceEffectMayHaveOccurred ||
    observed_at <= 0L {
    return Err(goal_assurance_error("effect witness has no authorized intent"))
  }
  let witness : GoalAssuranceEffectWitness = {
    effect_id: intent.effect_id,
    request_digest: intent.request_digest,
    observation,
    observation_digest: goal_assurance_observation_digest(observation),
    observed_at,
  }
  let witness_conflict = fn(detail : String) {
    match intent.kind {
      DispatchGoalVerification(_, _, _) | DispatchGoalAudit(_, _, _) =>
        @types.ChoirError::provider_protocol_violation(detail)
      _ => goal_assurance_error(detail)
    }
  }
  let content = goal_assurance_effect_witness_bytes(witness)
  let digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactEffectWitness(
        record.goal_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
        record.goal_id,
      ),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != digest || adopted.byte_length != content.length() {
    return Err(goal_assurance_error("effect witness artifact receipt is false"))
  }
  match load_goal_assurance_effect_witness(repository, adapters, intent) {
    Ok(Some(existing)) =>
      return if existing == witness {
        Ok(existing)
      } else {
        Err(
          witness_conflict(
            "Goal assurance effect witness identity was reused with different semantics",
          ),
        )
      }
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  let outcome = match
    (adapters.state.commit)(repository.state_store, {
      state: {
        key: goal_assurance_witness_state_key(intent.effect_id),
        expected_version: None,
        next_version: 1,
        fencing_epoch: record.fencing_epoch,
        value_digest: digest,
      },
      outbox: {
        semantic_key: goal_assurance_witness_event_key(intent.effect_id),
        payload_digest: digest,
      },
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost
    | @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      match load_goal_assurance_effect_witness(repository, adapters, intent) {
        Ok(Some(stored)) if stored == witness => Ok(stored)
        Ok(Some(_)) =>
          Err(
            witness_conflict(
              "Goal assurance effect witness commit resolved to different semantics",
            ),
          )
        Ok(None) =>
          Err(goal_assurance_error("effect witness was not recovered"))
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      Err(goal_assurance_error("effect witness fencing conflict"))
    @storage.StateTransactionOutcome::StateTransactionSemanticConflict =>
      Err(
        witness_conflict(
          "Goal assurance effect witness semantic key was reused",
        ),
      )
    @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(_) =>
      Err(goal_assurance_error("effect witness transaction rolled back"))
  }
}
