///| Durable compare-and-set storage for the WorkOrder executor portfolio.

///|
fn work_order_executor_schedule_key() -> @storage.StateRecordKey {
  @storage.StateRecordKey(
    durable_record_key_prefix(DurableWorkOrderExecutorSchedule) + "portfolio",
  )
}

///|
fn work_order_executor_schedule_event_key(
  record : WorkOrderExecutorScheduleRecord,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "work-order-executor:portfolio:state:" + record.durable_version.to_string(),
  )
}

///|
pub(all) struct StoredWorkOrderExecutorScheduleRecord {
  state_record : @storage.StateRecord
  record : WorkOrderExecutorScheduleRecord
} derive(Debug, Eq)

///|
pub(all) struct WorkOrderExecutorDispatchBatch {
  record : WorkOrderExecutorScheduleRecord
  leases : Array[WorkOrderExecutorLease]
} derive(Debug, Eq)

///|
fn load_work_order_executor_schedule_from_state(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  state_record : @storage.StateRecord,
) -> Result[StoredWorkOrderExecutorScheduleRecord, @types.ChoirError] {
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
      work_order_executor_error("content disagrees with durable state"),
    )
  }
  let record = match decode_work_order_executor_schedule_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state_record.key != work_order_executor_schedule_key() ||
    state_record.version != record.durable_version ||
    state_record.fencing_epoch != record.fencing_epoch {
    return Err(work_order_executor_error("state identity is inconsistent"))
  }
  Ok({ state_record, record })
}

///|
pub fn load_work_order_executor_schedule_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
) -> Result[StoredWorkOrderExecutorScheduleRecord?, @types.ChoirError] {
  match
    (adapters.state.read_state)(
      repository.state_store,
      work_order_executor_schedule_key(),
    ) {
    Ok(Some(state)) =>
      match
        load_work_order_executor_schedule_from_state(
          repository, adapters, state,
        ) {
        Ok(value) => Ok(Some(value))
        Err(error) => Err(error)
      }
    Ok(None) => Ok(None)
    Err(error) => Err(error)
  }
}

///|
fn persist_work_order_executor_schedule_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  record : WorkOrderExecutorScheduleRecord,
  expected_store_version : Int?,
) -> Result[@storage.StateTransactionOutcome, @types.ChoirError] {
  let expected_durable_version = match expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if record.durable_version != expected_durable_version {
    return Err(
      work_order_executor_error("record durable version is inconsistent"),
    )
  }
  let content = work_order_executor_schedule_record_bytes(record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(work_order_executor_error("record exceeds repository limit"))
  }
  let digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactWorkOrderExecutorSchedule,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != digest || adopted.byte_length != content.length() {
    return Err(work_order_executor_error("artifact receipt is false"))
  }
  (adapters.state.commit)(repository.state_store, {
    state: {
      key: work_order_executor_schedule_key(),
      expected_version: expected_store_version,
      next_version: expected_durable_version,
      fencing_epoch: record.fencing_epoch,
      value_digest: digest,
    },
    outbox: {
      semantic_key: work_order_executor_schedule_event_key(record),
      payload_digest: digest,
    },
    fault_point: None,
  })
}

///|
fn active_work_order_executor_candidates(
  records : Array[StoredWorkOrderRecord],
) -> Array[WorkOrderId] {
  let candidates : Array[WorkOrderId] = []
  for stored in records {
    if stored.record.lifecycle == WorkOrderLifecycle::WorkOrderActive {
      candidates.push(stored.record.id)
    }
  }
  candidates
}

///|
pub fn acquire_work_order_executor_dispatches(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  capacity : Int,
  now : Int64,
  fencing_epoch : @control.FencingEpoch,
) -> Result[WorkOrderExecutorDispatchBatch, @types.ChoirError] {
  for attempt = 0; attempt < 64; attempt = attempt + 1 {
    let owners = match list_work_order_records(repository, adapters) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let stored = match
      load_work_order_executor_schedule_record(repository, adapters) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (current, expected_version) = match stored {
      Some(value) => (value.record, Some(value.state_record.version))
      None => (empty_work_order_executor_schedule_record(fencing_epoch), None)
    }
    let plan = match
      plan_work_order_executor_dispatches(
        current,
        active_work_order_executor_candidates(owners),
        capacity,
        now,
        fencing_epoch,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if plan.record == current {
      return Ok({ record: current, leases: [] })
    }
    let outcome = match
      persist_work_order_executor_schedule_record(
        repository,
        adapters,
        plan.record,
        expected_version,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match outcome {
      @storage.StateTransactionOutcome::StateTransactionCommitted
      | @storage.StateTransactionOutcome::StateTransactionReplayed
      | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
        match load_work_order_executor_schedule_record(repository, adapters) {
          Ok(Some(observed)) if observed.record == plan.record =>
            return Ok({ record: observed.record, leases: plan.leases })
          Ok(_) =>
            return Err(
              work_order_executor_error("dispatch plan did not reload"),
            )
          Err(error) => return Err(error)
        }
      @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
        continue
      @storage.StateTransactionOutcome::StateTransactionStaleFence =>
        return Err(
          work_order_executor_error("a newer generation owns the schedule"),
        )
      _ => return Err(work_order_executor_error("dispatch transaction failed"))
    }
  }
  Err(work_order_executor_error("dispatch compare-and-set retry exhausted"))
}

///|
pub fn work_order_executor_lease_is_authorized(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  lease : WorkOrderExecutorLease,
) -> Result[Bool, @types.ChoirError] {
  match load_work_order_executor_schedule_record(repository, adapters) {
    Ok(Some(stored)) =>
      Ok(work_order_executor_lease_is_held(stored.record, lease))
    Ok(None) => Ok(false)
    Err(error) => Err(error)
  }
}

///|
pub fn persist_work_order_executor_completion(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  lease : WorkOrderExecutorLease,
  outcome : WorkOrderExecutionJobTickOutcome,
  now : Int64,
) -> Result[WorkOrderExecutionJob, @types.ChoirError] {
  for attempt = 0; attempt < 64; attempt = attempt + 1 {
    let stored = match
      load_work_order_executor_schedule_record(repository, adapters) {
      Ok(Some(value)) => value
      Ok(None) => return Err(work_order_executor_error("schedule is absent"))
      Err(error) => return Err(error)
    }
    if stored.record.fencing_epoch != lease.fencing_epoch {
      return Err(
        work_order_executor_error("a newer generation owns the schedule"),
      )
    }
    let next = match
      complete_work_order_executor_dispatch(
        stored.record,
        lease.id,
        outcome,
        now,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if next == stored.record {
      match work_order_execution_job_for_work_order(next, lease.work_order_id) {
        Some(job) => return Ok(job)
        None => return Err(work_order_executor_error("completed job is absent"))
      }
    }
    let transaction = match
      persist_work_order_executor_schedule_record(
        repository,
        adapters,
        next,
        Some(stored.state_record.version),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match transaction {
      @storage.StateTransactionOutcome::StateTransactionCommitted
      | @storage.StateTransactionOutcome::StateTransactionReplayed
      | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
        match load_work_order_executor_schedule_record(repository, adapters) {
          Ok(Some(observed)) if observed.record == next =>
            match
              work_order_execution_job_for_work_order(
                observed.record,
                lease.work_order_id,
              ) {
              Some(job) => return Ok(job)
              None =>
                return Err(work_order_executor_error("completed job is absent"))
            }
          Ok(_) =>
            return Err(
              work_order_executor_error("completed schedule did not reload"),
            )
          Err(error) => return Err(error)
        }
      @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
        continue
      @storage.StateTransactionOutcome::StateTransactionStaleFence =>
        return Err(
          work_order_executor_error("a newer generation owns the schedule"),
        )
      _ =>
        return Err(work_order_executor_error("completion transaction failed"))
    }
  }
  Err(work_order_executor_error("completion compare-and-set retry exhausted"))
}
