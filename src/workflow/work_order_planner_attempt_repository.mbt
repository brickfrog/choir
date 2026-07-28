///| Compare-and-set storage for WorkOrder planner attempt evidence.

///|
fn work_order_planner_attempt_key(
  id : WorkOrderPlannerAttemptId,
) -> @storage.StateRecordKey {
  @storage.StateRecordKey(
    durable_record_key_prefix(DurableWorkOrderPlannerAttempt) + id.0,
  )
}

///|
fn work_order_planner_attempt_event_key(
  record : WorkOrderPlannerAttemptRecord,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "work-order-planner-attempt:" +
    record.id.0 +
    ":state:" +
    record.durable_version.to_string(),
  )
}

///|
pub(all) struct StoredWorkOrderPlannerAttemptRecord {
  state_record : @storage.StateRecord
  record : WorkOrderPlannerAttemptRecord
} derive(Debug, Eq)

///|
fn load_work_order_planner_attempt_from_state(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  state : @storage.StateRecord,
) -> Result[StoredWorkOrderPlannerAttemptRecord, @types.ChoirError] {
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: state.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state.value_digest {
    return Err(
      work_order_planner_attempt_error("content disagrees with durable state"),
    )
  }
  let record = match decode_work_order_planner_attempt_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state.key != work_order_planner_attempt_key(record.id) ||
    state.version != record.durable_version ||
    state.fencing_epoch != record.fencing_epoch {
    return Err(
      work_order_planner_attempt_error("state identity is inconsistent"),
    )
  }
  Ok({ state_record: state, record })
}

///|
fn load_work_order_planner_attempt_by_id(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  id : WorkOrderPlannerAttemptId,
) -> Result[StoredWorkOrderPlannerAttemptRecord?, @types.ChoirError] {
  match
    (adapters.state.read_state)(
      repository.state_store,
      work_order_planner_attempt_key(id),
    ) {
    Ok(Some(state)) =>
      match
        load_work_order_planner_attempt_from_state(repository, adapters, state) {
        Ok(value) => Ok(Some(value))
        Err(error) => Err(error)
      }
    Ok(None) => Ok(None)
    Err(error) => Err(error)
  }
}

///|
pub fn load_work_order_planner_attempt(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  round : WorkOrderPlanningRound,
) -> Result[StoredWorkOrderPlannerAttemptRecord?, @types.ChoirError] {
  load_work_order_planner_attempt_by_id(
    repository,
    adapters,
    work_order_planner_attempt_id(round),
  )
}

///|
fn commit_work_order_planner_attempt(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  record : WorkOrderPlannerAttemptRecord,
  expected_version : Int?,
) -> Result[StoredWorkOrderPlannerAttemptRecord?, @types.ChoirError] {
  let expected_next = expected_version.unwrap_or(0) + 1
  if record.durable_version != expected_next {
    return Err(
      work_order_planner_attempt_error("durable version is inconsistent"),
    )
  }
  let content = work_order_planner_attempt_record_bytes(record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(
      work_order_planner_attempt_error("record exceeds repository limit"),
    )
  }
  let digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactWorkOrderPlannerAttempt,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != digest || adopted.byte_length != content.length() {
    return Err(work_order_planner_attempt_error("artifact receipt is false"))
  }
  let outcome = match
    (adapters.state.commit)(repository.state_store, {
      state: {
        key: work_order_planner_attempt_key(record.id),
        expected_version,
        next_version: record.durable_version,
        fencing_epoch: record.fencing_epoch,
        value_digest: digest,
      },
      outbox: {
        semantic_key: work_order_planner_attempt_event_key(record),
        payload_digest: digest,
        owner_goal_id: None,
      },
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
      match
        load_work_order_planner_attempt_by_id(repository, adapters, record.id) {
        Ok(Some(value)) if value.record == record => Ok(Some(value))
        Ok(_) =>
          Err(
            work_order_planner_attempt_error("committed record did not reload"),
          )
        Err(error) => Err(error)
      }
    @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
      Ok(None)
    @storage.StateTransactionOutcome::StateTransactionStaleFence =>
      Err(
        work_order_planner_attempt_error("a newer generation owns the attempt"),
      )
    _ => Err(work_order_planner_attempt_error("attempt transaction failed"))
  }
}

///|
pub fn ensure_work_order_planner_attempt(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  work_order : WorkOrderRecord,
  round : WorkOrderPlanningRound,
  instruction_digest : @control.Digest,
  schema_digest : @control.Digest,
) -> Result[StoredWorkOrderPlannerAttemptRecord, @types.ChoirError] {
  for attempt = 0; attempt < 64; attempt = attempt + 1 {
    match load_work_order_planner_attempt(repository, adapters, round) {
      Ok(Some(stored)) => {
        if stored.record.work_order_id != work_order.id ||
          stored.record.effect_id != round.effect_id ||
          stored.record.surface != round.planner_surface ||
          stored.record.instruction_digest != instruction_digest ||
          stored.record.schema_digest != schema_digest {
          return Err(
            work_order_planner_attempt_error(
              "existing attempt disagrees with dispatch",
            ),
          )
        }
        if stored.record.fencing_epoch.0 > work_order.fencing_epoch.0 {
          return Err(
            work_order_planner_attempt_error(
              "a newer generation owns the planner attempt",
            ),
          )
        }
        if stored.record.fencing_epoch.0 < work_order.fencing_epoch.0 &&
          stored.record.lifecycle ==
          WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned {
          let adopted = {
            ..stored.record,
            durable_version: stored.record.durable_version + 1,
            fencing_epoch: work_order.fencing_epoch,
          }
          match
            commit_work_order_planner_attempt(
              repository,
              adapters,
              adopted,
              Some(stored.state_record.version),
            ) {
            Ok(Some(value)) => return Ok(value)
            Ok(None) => continue
            Err(error) => return Err(error)
          }
        }
        return Ok(stored)
      }
      Ok(None) => ()
      Err(error) => return Err(error)
    }
    let planned = match
      plan_work_order_planner_attempt(
        work_order, round, instruction_digest, schema_digest,
      ) {
      Ok(value) => { ..value, durable_version: 1 }
      Err(error) => return Err(error)
    }
    match
      commit_work_order_planner_attempt(repository, adapters, planned, None) {
      Ok(Some(value)) => return Ok(value)
      Ok(None) => continue
      Err(error) => return Err(error)
    }
  }
  Err(work_order_planner_attempt_error("attempt create retry exhausted"))
}

///|
pub fn persist_work_order_planner_attempt_transition(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : StoredWorkOrderPlannerAttemptRecord,
  next : WorkOrderPlannerAttemptRecord,
) -> Result[StoredWorkOrderPlannerAttemptRecord, @types.ChoirError] {
  if next.id != stored.record.id ||
    next.work_order_id != stored.record.work_order_id ||
    next.round_id != stored.record.round_id ||
    next.effect_id != stored.record.effect_id ||
    next.attempt_number != stored.record.attempt_number ||
    next.session_id != stored.record.session_id ||
    next.surface != stored.record.surface ||
    next.instruction_digest != stored.record.instruction_digest ||
    next.schema_digest != stored.record.schema_digest ||
    next.fencing_epoch != stored.record.fencing_epoch ||
    next.durable_version != stored.record.durable_version + 1 {
    return Err(
      work_order_planner_attempt_error("transition changes immutable identity"),
    )
  }
  match
    commit_work_order_planner_attempt(
      repository,
      adapters,
      next,
      Some(stored.state_record.version),
    ) {
    Ok(Some(value)) => Ok(value)
    Ok(None) =>
      Err(work_order_planner_attempt_error("attempt transition conflicted"))
    Err(error) => Err(error)
  }
}
