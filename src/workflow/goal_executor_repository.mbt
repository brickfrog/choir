///| Durable storage and compare-and-set execution for the Goal portfolio.

///|
fn goal_executor_schedule_key() -> @storage.StateRecordKey {
  @storage.StateRecordKey(
    durable_record_key_prefix(DurableGoalExecutorSchedule) + "portfolio",
  )
}

///|
fn goal_executor_schedule_event_key(
  record : GoalExecutorScheduleRecord,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "goal-executor:portfolio:state:" + record.durable_version.to_string(),
  )
}

///|
pub(all) struct StoredGoalExecutorScheduleRecord {
  state_record : @storage.StateRecord
  record : GoalExecutorScheduleRecord
} derive(Debug, Eq)

///|
pub(all) struct GoalExecutorDispatchBatch {
  record : GoalExecutorScheduleRecord
  leases : Array[GoalExecutorLease]
} derive(Debug, Eq)

///|
fn load_goal_executor_schedule_from_state(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  state_record : @storage.StateRecord,
) -> Result[StoredGoalExecutorScheduleRecord, @types.ChoirError] {
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: state_record.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state_record.value_digest {
    return Err(goal_executor_error("content disagrees with durable state"))
  }
  let record = match decode_goal_executor_schedule_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state_record.key != goal_executor_schedule_key() ||
    state_record.version != record.durable_version ||
    state_record.fencing_epoch != record.fencing_epoch {
    return Err(goal_executor_error("state identity is inconsistent"))
  }
  Ok({ state_record, record })
}

///|
pub fn load_goal_executor_schedule_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
) -> Result[StoredGoalExecutorScheduleRecord?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      goal_executor_schedule_key(),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  match load_goal_executor_schedule_from_state(repository, adapters, state) {
    Ok(value) => Ok(Some(value))
    Err(error) => Err(error)
  }
}

///|
fn persist_goal_executor_schedule_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  record : GoalExecutorScheduleRecord,
  expected_store_version : Int?,
) -> Result[@storage.StateTransactionOutcome, @types.ChoirError] {
  let expected_durable_version = match expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if record.durable_version != expected_durable_version {
    return Err(goal_executor_error("record durable version is inconsistent"))
  }
  let content = goal_executor_schedule_record_bytes(record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(goal_executor_error("record exceeds repository limit"))
  }
  let record_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: record_digest,
      provenance: @storage.ArtifactProvenance::ArtifactGoalExecutorSchedule,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != record_digest || adopted.byte_length != content.length() {
    return Err(goal_executor_error("artifact receipt is false"))
  }
  (adapters.state.commit)(repository.state_store, {
    state: {
      key: goal_executor_schedule_key(),
      expected_version: expected_store_version,
      next_version: expected_durable_version,
      fencing_epoch: record.fencing_epoch,
      value_digest: record_digest,
    },
    outbox: {
      semantic_key: goal_executor_schedule_event_key(record),
      payload_digest: record_digest,
      owner_goal_id: None,
    },
    fault_point: None,
  })
}

///|
fn goal_executor_candidates(
  records : Array[StoredGoalExecutionRecord],
) -> Array[GoalExecutionJobCandidate] {
  let candidates : Array[GoalExecutionJobCandidate] = []
  for stored in records {
    match
      goal_execution_job_candidate(stored.record.goal.id, stored.record.state) {
      Some(value) => candidates.push(value)
      None => ()
    }
  }
  candidates
}

///|
/// Reconcile active Goals and atomically lease every available executor slot.
///
/// Compare-and-set conflicts are retried against the new whole portfolio
/// record. No dispatch escapes until its exact lease is observed committed.
pub fn acquire_goal_executor_dispatches(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  capacity : Int,
  now : Int64,
  fencing_epoch : @control.FencingEpoch,
) -> Result[GoalExecutorDispatchBatch, @types.ChoirError] {
  for attempt = 0; attempt < 64; attempt = attempt + 1 {
    let executions = match list_goal_execution_records(repository, adapters) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let stored = match
      load_goal_executor_schedule_record(repository, adapters) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (current, expected_store_version) = match stored {
      Some(value) => (value.record, Some(value.state_record.version))
      None => (empty_goal_executor_schedule_record(fencing_epoch), None)
    }
    let plan = match
      plan_goal_executor_dispatches(
        current,
        goal_executor_candidates(executions),
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
      persist_goal_executor_schedule_record(
        repository,
        adapters,
        plan.record,
        expected_store_version,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match outcome {
      @storage.StateTransactionOutcome::StateTransactionCommitted
      | @storage.StateTransactionOutcome::StateTransactionReplayed
      | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
        match load_goal_executor_schedule_record(repository, adapters) {
          Ok(Some(observed)) if observed.record == plan.record =>
            return Ok({ record: observed.record, leases: plan.leases })
          Ok(_) =>
            return Err(goal_executor_error("dispatch plan did not reload"))
          Err(error) => return Err(error)
        }
      @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
        continue
      @storage.StateTransactionOutcome::StateTransactionStaleFence =>
        return Err(goal_executor_error("a newer generation owns the schedule"))
      _ => return Err(goal_executor_error("dispatch transaction failed"))
    }
  }
  Err(goal_executor_error("dispatch compare-and-set retry exhausted"))
}

///|
pub fn goal_executor_lease_is_authorized(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  lease : GoalExecutorLease,
) -> Result[Bool, @types.ChoirError] {
  match load_goal_executor_schedule_record(repository, adapters) {
    Ok(Some(stored)) => Ok(goal_executor_lease_is_held(stored.record, lease))
    Ok(None) => Ok(false)
    Err(error) => Err(error)
  }
}

///|
/// Persist one job's completion without losing unrelated concurrent
/// completions or newly leased jobs.
pub fn persist_goal_executor_completion(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  lease : GoalExecutorLease,
  outcome : GoalExecutionJobTickOutcome,
  now : Int64,
) -> Result[GoalExecutionJob, @types.ChoirError] {
  for attempt = 0; attempt < 64; attempt = attempt + 1 {
    let stored = match
      load_goal_executor_schedule_record(repository, adapters) {
      Ok(Some(value)) => value
      Ok(None) => return Err(goal_executor_error("schedule is absent"))
      Err(error) => return Err(error)
    }
    if stored.record.fencing_epoch != lease.fencing_epoch {
      return Err(goal_executor_error("a newer generation owns the schedule"))
    }
    let next = match
      complete_goal_executor_dispatch(stored.record, lease.id, outcome, now) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if next == stored.record {
      match goal_execution_job_for_goal(next, lease.goal_id) {
        Some(job) => return Ok(job)
        None => return Err(goal_executor_error("completed job is absent"))
      }
    }
    let transaction = match
      persist_goal_executor_schedule_record(
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
        match load_goal_executor_schedule_record(repository, adapters) {
          Ok(Some(observed)) if observed.record == next =>
            match goal_execution_job_for_goal(observed.record, lease.goal_id) {
              Some(job) => return Ok(job)
              None => return Err(goal_executor_error("completed job is absent"))
            }
          Ok(_) =>
            return Err(goal_executor_error("completed schedule did not reload"))
          Err(error) => return Err(error)
        }
      @storage.StateTransactionOutcome::StateTransactionVersionConflict =>
        continue
      @storage.StateTransactionOutcome::StateTransactionStaleFence =>
        return Err(goal_executor_error("a newer generation owns the schedule"))
      _ => return Err(goal_executor_error("completion transaction failed"))
    }
  }
  Err(goal_executor_error("completion compare-and-set retry exhausted"))
}

///|
pub fn load_goal_execution_job(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[GoalExecutionJob?, @types.ChoirError] {
  match load_goal_executor_schedule_record(repository, adapters) {
    Ok(Some(stored)) => Ok(goal_execution_job_for_goal(stored.record, goal_id))
    Ok(None) => Ok(None)
    Err(error) => Err(error)
  }
}
