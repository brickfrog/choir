///|
pub(all) struct StoredWorkOrderRecord {
  state_record : @storage.StateRecord
  record : WorkOrderRecord
} derive(Debug, Eq)

///|
pub(all) struct WorkOrderPersistenceRequest {
  record : WorkOrderRecord
  expected_store_version : Int?
  fault_point : @storage.StateStoreFaultPoint?
}

///|
pub(all) struct WorkOrderPersistenceReceipt {
  record_digest : @control.Digest
  transaction_outcome : @storage.StateTransactionOutcome
} derive(Debug, Eq)

///|
fn work_order_state_key(id : WorkOrderId) -> @storage.StateRecordKey {
  @storage.StateRecordKey(
    durable_record_key_prefix(DurableWorkOrderRecord) +
    @storage.digest_text(@storage.artifact_digest(@utf8.encode(id.0))),
  )
}

///|
fn work_order_event_key(record : WorkOrderRecord) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "work-order:" +
    @storage.digest_text(@storage.artifact_digest(@utf8.encode(record.id.0))) +
    ":state:" +
    record.durable_version.to_string(),
  )
}

///|
pub fn persist_work_order_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  request : WorkOrderPersistenceRequest,
) -> Result[WorkOrderPersistenceReceipt, @types.ChoirError] {
  match validate_work_order_record(request.record) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let content = work_order_record_bytes(request.record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(work_order_error("record exceeds repository limit"))
  }
  let digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactWorkOrderRecord,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != digest || adopted.byte_length != content.length() {
    return Err(work_order_error("artifact receipt is false"))
  }
  let transaction_outcome = match
    (adapters.state.commit)(repository.state_store, {
      state: {
        key: work_order_state_key(request.record.id),
        expected_version: request.expected_store_version,
        next_version: request.record.durable_version,
        fencing_epoch: request.record.fencing_epoch,
        schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
        value_digest: digest,
      },
      outbox: {
        semantic_key: work_order_event_key(request.record),
        payload_digest: digest,
        owner_goal_id: None,
      },
      fault_point: request.fault_point,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ record_digest: digest, transaction_outcome })
}

///|
pub fn load_work_order_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  id : WorkOrderId,
) -> Result[StoredWorkOrderRecord?, @types.ChoirError] {
  let state_record = match
    (adapters.state.read_state)(
      repository.state_store,
      work_order_state_key(id),
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
    return Err(work_order_error("content disagrees with durable state"))
  }
  let record = match decode_work_order_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if record.id != id ||
    record.durable_version != state_record.version ||
    record.fencing_epoch != state_record.fencing_epoch {
    return Err(work_order_error("state identity is inconsistent"))
  }
  Ok(Some({ state_record, record }))
}

///|
pub fn persist_work_order_fencing_epoch_adoption(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  previous : StoredWorkOrderRecord,
  fencing_epoch : @control.FencingEpoch,
) -> Result[StoredWorkOrderRecord, @types.ChoirError] {
  let next = match
    adopt_work_order_fencing_epoch(previous.record, fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt = match
    persist_work_order_record(repository, adapters, {
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
      match load_work_order_record(repository, adapters, next.id) {
        Ok(Some(stored)) if stored.record == next => Ok(stored)
        Ok(_) => Err(work_order_error("fencing adoption did not reload"))
        Err(error) => Err(error)
      }
    _ => Err(work_order_error("fencing adoption conflicted"))
  }
}

///|
pub fn list_work_order_records(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
) -> Result[Array[StoredWorkOrderRecord], @types.ChoirError] {
  let states = match
    (adapters.state.list_state)(
      repository.state_store,
      durable_record_key_prefix(DurableWorkOrderRecord),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let records : Array[StoredWorkOrderRecord] = []
  for state_record in states {
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
        work_order_error("listed content disagrees with durable state"),
      )
    }
    let record = match decode_work_order_record(content) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if work_order_state_key(record.id) != state_record.key ||
      record.durable_version != state_record.version ||
      record.fencing_epoch != state_record.fencing_epoch {
      return Err(work_order_error("listed state identity is inconsistent"))
    }
    records.push({ state_record, record })
  }
  records.sort_by(fn(left, right) { left.record.id.compare(right.record.id) })
  Ok(records)
}

///|
/// Resolve a Goal's campaign authority and prove the WorkOrder contains the
/// reciprocal child binding. A missing or one-sided binding fails closed.
pub fn load_goal_work_order(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal : GoalExecutionRecord,
) -> Result[StoredWorkOrderRecord?, @types.ChoirError] {
  guard goal.work_order_id is Some(id) else { return Ok(None) }
  match load_work_order_record(repository, adapters, id) {
    Ok(Some(stored)) =>
      if stored.record.child_goals.any(fn(binding) {
          binding.goal_id == goal.goal.id &&
          binding.selection_decision_digest == goal.selection_decision_digest
        }) {
        Ok(Some(stored))
      } else {
        Err(work_order_error("Goal has no reciprocal child binding"))
      }
    Ok(None) => Err(work_order_error("Goal owner is absent"))
    Err(error) => Err(error)
  }
}

///|
pub fn persist_work_order_budget(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : StoredWorkOrderRecord,
  budget : WorkOrderBudget,
) -> Result[StoredWorkOrderRecord, @types.ChoirError] {
  if budget == stored.record.budget {
    return Ok(stored)
  }
  let lifecycle = match budget.stopped {
    Some(reason) => WorkOrderLifecycle::WorkOrderStopped(reason)
    None => stored.record.lifecycle
  }
  let next = {
    ..stored.record,
    budget,
    lifecycle,
    durable_version: stored.record.durable_version + 1,
  }
  persist_work_order_transition(repository, adapters, stored, next)
}

///|
pub fn persist_work_order_transition(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  stored : StoredWorkOrderRecord,
  next : WorkOrderRecord,
) -> Result[StoredWorkOrderRecord, @types.ChoirError] {
  if next == stored.record {
    return Ok(stored)
  }
  if next.id != stored.record.id ||
    next.fencing_epoch != stored.record.fencing_epoch ||
    next.durable_version != stored.record.durable_version + 1 {
    return Err(work_order_error("transition identity is invalid"))
  }
  let receipt = match
    persist_work_order_record(repository, adapters, {
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
      match load_work_order_record(repository, adapters, next.id) {
        Ok(Some(reloaded)) if reloaded.record == next => Ok(reloaded)
        Ok(_) => Err(work_order_error("budget transition did not reload"))
        Err(error) => Err(error)
      }
    _ => Err(work_order_error("transition conflicted"))
  }
}
