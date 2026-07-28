///| Durable bounded scheduling for independent WorkOrder coordinator ticks.

///|
pub(all) struct WorkOrderExecutionJobId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct WorkOrderExecutorLeaseId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct WorkOrderExecutorLease {
  id : WorkOrderExecutorLeaseId
  job_id : WorkOrderExecutionJobId
  work_order_id : WorkOrderId
  slot : Int
  dispatch_sequence : Int64
  fencing_epoch : @control.FencingEpoch
  acquired_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderExecutionJob {
  id : WorkOrderExecutionJobId
  work_order_id : WorkOrderId
  due_at : Int64
  consecutive_failures : Int
  last_failure_digest : @control.Digest?
  last_dispatch_sequence : Int64
  last_completed_lease_id : WorkOrderExecutorLeaseId?
  last_work_order_durable_version : Int?
  ticks_without_progress : Int
  provider_reports : Array[ProviderSurfaceTickReport]
  lease : WorkOrderExecutorLease?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderExecutorScheduleRecord {
  jobs : Array[WorkOrderExecutionJob]
  next_dispatch_sequence : Int64
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderExecutorDispatchPlan {
  record : WorkOrderExecutorScheduleRecord
  leases : Array[WorkOrderExecutorLease]
} derive(Debug, Eq)

///|
pub(all) enum WorkOrderExecutionJobTickOutcome {
  WorkOrderExecutionJobTickSucceeded(Int?, Array[ProviderSurfaceTickReport])
  WorkOrderExecutionJobTickFailed(
    @control.Digest,
    Array[ProviderSurfaceTickReport]
  )
} derive(Debug, Eq)

///|
fn work_order_executor_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("WorkOrder executor: " + detail)
}

///|
pub fn work_order_execution_job_failure_digest(
  error : @types.ChoirError,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.work-order-execution-job-failure.v1\u{00}" + error.message(),
    ),
  )
}

///|
pub fn work_order_execution_job_id(
  work_order_id : WorkOrderId,
) -> WorkOrderExecutionJobId {
  WorkOrderExecutionJobId(
    "work-order-job-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.work-order-execution-job.v1\u{00}" + work_order_id.0,
        ),
      ),
    ),
  )
}

///|
fn work_order_executor_lease_id(
  job_id : WorkOrderExecutionJobId,
  fencing_epoch : @control.FencingEpoch,
  dispatch_sequence : Int64,
) -> WorkOrderExecutorLeaseId {
  WorkOrderExecutorLeaseId(
    "work-order-executor-lease-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.work-order-executor-lease.v1\u{00}" +
          job_id.0 +
          "\u{00}" +
          fencing_epoch.0.to_string() +
          "\u{00}" +
          dispatch_sequence.to_string(),
        ),
      ),
    ),
  )
}

///|
pub fn empty_work_order_executor_schedule_record(
  fencing_epoch : @control.FencingEpoch,
) -> WorkOrderExecutorScheduleRecord {
  { jobs: [], next_dispatch_sequence: 1L, durable_version: 0, fencing_epoch }
}

///|
fn work_order_provider_reports_are_valid(
  reports : Array[ProviderSurfaceTickReport],
) -> Bool {
  let surfaces : Array[@control.ProviderSurfaceId] = []
  for report in reports {
    let valid = match report.disposition {
      ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted => true
      ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(instant) =>
        instant >= 0L
    }
    if !valid || surfaces.contains(report.surface) {
      return false
    }
    surfaces.push(report.surface)
  }
  true
}

///|
fn work_order_executor_schedule_is_valid(
  record : WorkOrderExecutorScheduleRecord,
  allow_unstored? : Bool = false,
) -> Bool {
  if record.next_dispatch_sequence <= 0L ||
    record.fencing_epoch.0 <= 0L ||
    record.durable_version < 0 ||
    (!allow_unstored && record.durable_version == 0) {
    return false
  }
  let ids : Array[WorkOrderExecutionJobId] = []
  let owners : Array[WorkOrderId] = []
  let slots : Array[Int] = []
  let leases : Array[WorkOrderExecutorLeaseId] = []
  for job in record.jobs {
    if job.id != work_order_execution_job_id(job.work_order_id) ||
      ids.contains(job.id) ||
      owners.contains(job.work_order_id) ||
      job.due_at < 0L ||
      job.consecutive_failures < 0 ||
      job.last_dispatch_sequence < 0L ||
      job.ticks_without_progress < 0 ||
      !work_order_provider_reports_are_valid(job.provider_reports) {
      return false
    }
    match job.last_failure_digest {
      Some(digest) =>
        if @storage.validate_digest(digest) is Err(_) {
          return false
        }
      None => ()
    }
    match job.lease {
      Some(lease) => {
        if lease.job_id != job.id ||
          lease.work_order_id != job.work_order_id ||
          lease.slot < 0 ||
          lease.dispatch_sequence <= 0L ||
          lease.dispatch_sequence != job.last_dispatch_sequence ||
          lease.fencing_epoch != record.fencing_epoch ||
          lease.acquired_at < 0L ||
          slots.contains(lease.slot) ||
          leases.contains(lease.id) {
          return false
        }
        slots.push(lease.slot)
        leases.push(lease.id)
      }
      None => ()
    }
    ids.push(job.id)
    owners.push(job.work_order_id)
  }
  true
}

///|
pub fn work_order_executor_schedule_record_bytes(
  record : WorkOrderExecutorScheduleRecord,
) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn decode_work_order_executor_schedule_record(
  content : Bytes,
) -> Result[WorkOrderExecutorScheduleRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode(content)) catch {
    _ => return Err(work_order_executor_error("record is not valid JSON"))
  }
  let record : WorkOrderExecutorScheduleRecord = @json.from_json(json) catch {
    _ => return Err(work_order_executor_error("record shape is invalid"))
  }
  if work_order_executor_schedule_is_valid(record) {
    Ok(record)
  } else {
    Err(work_order_executor_error("record is invalid"))
  }
}

///|
fn initial_work_order_execution_job(
  work_order_id : WorkOrderId,
  now : Int64,
) -> WorkOrderExecutionJob {
  {
    id: work_order_execution_job_id(work_order_id),
    work_order_id,
    due_at: now,
    consecutive_failures: 0,
    last_failure_digest: None,
    last_dispatch_sequence: 0L,
    last_completed_lease_id: None,
    last_work_order_durable_version: None,
    ticks_without_progress: 0,
    provider_reports: [],
    lease: None,
  }
}

///|
fn work_order_candidate_contains(
  candidates : Array[WorkOrderId],
  id : WorkOrderId,
) -> Bool {
  candidates.contains(id)
}

///|
fn work_order_execution_job_for_owner(
  jobs : Array[WorkOrderExecutionJob],
  id : WorkOrderId,
) -> WorkOrderExecutionJob? {
  for job in jobs {
    if job.work_order_id == id {
      return Some(job)
    }
  }
  None
}

///|
fn reconcile_work_order_execution_jobs(
  current : WorkOrderExecutorScheduleRecord,
  candidates : Array[WorkOrderId],
  now : Int64,
  fencing_epoch : @control.FencingEpoch,
) -> Result[Array[WorkOrderExecutionJob], @types.ChoirError] {
  let seen : Array[WorkOrderId] = []
  for id in candidates {
    if id.0 == "" || seen.contains(id) {
      return Err(work_order_executor_error("job candidates are not unique"))
    }
    seen.push(id)
  }
  let jobs : Array[WorkOrderExecutionJob] = []
  for job in current.jobs {
    if work_order_candidate_contains(candidates, job.work_order_id) {
      jobs.push(
        if current.fencing_epoch.0 < fencing_epoch.0 {
          { ..job, due_at: now, provider_reports: [], lease: None }
        } else {
          job
        },
      )
    } else if job.lease is Some(_) && current.fencing_epoch == fencing_epoch {
      jobs.push(job)
    }
  }
  for id in candidates {
    if work_order_execution_job_for_owner(jobs, id) is None {
      jobs.push(initial_work_order_execution_job(id, now))
    }
  }
  Ok(jobs)
}

///|
fn next_work_order_executor_slot(
  jobs : Array[WorkOrderExecutionJob],
  capacity : Int,
) -> Int? {
  for slot = 0; slot < capacity; slot = slot + 1 {
    if !jobs.any(fn(job) {
        match job.lease {
          Some(lease) => lease.slot == slot
          None => false
        }
      }) {
      return Some(slot)
    }
  }
  None
}

///|
fn next_due_work_order_job_index(
  jobs : Array[WorkOrderExecutionJob],
  now : Int64,
) -> Int? {
  let mut selected : Int? = None
  for index, job in jobs {
    if job.lease is Some(_) || job.due_at > now {
      continue
    }
    selected = match selected {
      None => Some(index)
      Some(previous) => {
        let before = jobs[previous]
        if job.last_dispatch_sequence < before.last_dispatch_sequence ||
          (
            job.last_dispatch_sequence == before.last_dispatch_sequence &&
            job.work_order_id.0 < before.work_order_id.0
          ) {
          Some(index)
        } else {
          Some(previous)
        }
      }
    }
  }
  selected
}

///|
pub fn plan_work_order_executor_dispatches(
  current : WorkOrderExecutorScheduleRecord,
  candidates : Array[WorkOrderId],
  capacity : Int,
  now : Int64,
  fencing_epoch : @control.FencingEpoch,
) -> Result[WorkOrderExecutorDispatchPlan, @types.ChoirError] {
  if capacity <= 0 ||
    capacity > @types.maximum_goal_executor_jobs() ||
    now < 0L ||
    fencing_epoch.0 <= 0L ||
    !work_order_executor_schedule_is_valid(current, allow_unstored=true) ||
    current.fencing_epoch.0 > fencing_epoch.0 {
    return Err(work_order_executor_error("dispatch input is invalid"))
  }
  let jobs = match
    reconcile_work_order_execution_jobs(current, candidates, now, fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let leases : Array[WorkOrderExecutorLease] = []
  let mut sequence = current.next_dispatch_sequence
  for ;; {
    let slot = match next_work_order_executor_slot(jobs, capacity) {
      Some(value) => value
      None => break
    }
    let index = match next_due_work_order_job_index(jobs, now) {
      Some(value) => value
      None => break
    }
    let job = jobs[index]
    let lease : WorkOrderExecutorLease = {
      id: work_order_executor_lease_id(job.id, fencing_epoch, sequence),
      job_id: job.id,
      work_order_id: job.work_order_id,
      slot,
      dispatch_sequence: sequence,
      fencing_epoch,
      acquired_at: now,
    }
    jobs[index] = {
      ..job,
      last_dispatch_sequence: sequence,
      provider_reports: [],
      lease: Some(lease),
    }
    leases.push(lease)
    sequence = sequence + 1L
  }
  jobs.sort_by(fn(left, right) {
    left.work_order_id.0.compare(right.work_order_id.0)
  })
  let candidate : WorkOrderExecutorScheduleRecord = {
    jobs,
    next_dispatch_sequence: sequence,
    durable_version: current.durable_version,
    fencing_epoch,
  }
  let record = if candidate == current {
    current
  } else {
    { ..candidate, durable_version: current.durable_version + 1 }
  }
  if work_order_executor_schedule_is_valid(
      record,
      allow_unstored=record.durable_version == 0,
    ) {
    Ok({ record, leases })
  } else {
    Err(work_order_executor_error("planned schedule is invalid"))
  }
}

///|
fn work_order_job_failure_delay(failures : Int) -> Int64 {
  let mut delay = 1L
  for attempt = 0; attempt < failures; attempt = attempt + 1 {
    if delay >= 30L {
      return 30L
    }
    delay = delay * 2L
  }
  if delay > 30L {
    30L
  } else {
    delay
  }
}

///|
fn work_order_job_due_at(
  reports : Array[ProviderSurfaceTickReport],
  now : Int64,
) -> Int64 {
  let mut earliest : Int64? = None
  for report in reports {
    match report.disposition {
      ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted => return now + 1L
      ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(instant) =>
        earliest = match earliest {
          Some(value) => Some(if instant < value { instant } else { value })
          None => Some(instant)
        }
    }
  }
  match earliest {
    None => now + 1L
    Some(instant) =>
      if instant <= now {
        now + 1L
      } else if instant > now + 30L {
        now + 30L
      } else {
        instant
      }
  }
}

///|
pub fn complete_work_order_executor_dispatch(
  current : WorkOrderExecutorScheduleRecord,
  lease_id : WorkOrderExecutorLeaseId,
  outcome : WorkOrderExecutionJobTickOutcome,
  now : Int64,
) -> Result[WorkOrderExecutorScheduleRecord, @types.ChoirError] {
  if !work_order_executor_schedule_is_valid(current) || now < 0L {
    return Err(work_order_executor_error("completion input is invalid"))
  }
  let jobs = current.jobs.copy()
  let mut selected = -1
  for index, job in jobs {
    if job.last_completed_lease_id == Some(lease_id) {
      return Ok(current)
    }
    match job.lease {
      Some(lease) if lease.id == lease_id => {
        selected = index
        break
      }
      _ => ()
    }
  }
  if selected < 0 {
    return Err(work_order_executor_error("executor lease is not held"))
  }
  let job = jobs[selected]
  let reports = match outcome {
    WorkOrderExecutionJobTickSucceeded(_, value)
    | WorkOrderExecutionJobTickFailed(_, value) => value
  }
  if !work_order_provider_reports_are_valid(reports) {
    return Err(work_order_executor_error("provider reports are inconsistent"))
  }
  jobs[selected] = match outcome {
    WorkOrderExecutionJobTickSucceeded(version, _) => {
      let unchanged = version is Some(value) &&
        job.last_work_order_durable_version == Some(value)
      {
        ..job,
        due_at: work_order_job_due_at(reports, now),
        consecutive_failures: 0,
        last_failure_digest: None,
        last_completed_lease_id: Some(lease_id),
        last_work_order_durable_version: match version {
          Some(value) => Some(value)
          None => job.last_work_order_durable_version
        },
        ticks_without_progress: if unchanged {
          job.ticks_without_progress + 1
        } else {
          0
        },
        provider_reports: reports,
        lease: None,
      }
    }
    WorkOrderExecutionJobTickFailed(digest, _) => {
      let failures = job.consecutive_failures + 1
      {
        ..job,
        due_at: now + work_order_job_failure_delay(failures),
        consecutive_failures: failures,
        last_failure_digest: Some(digest),
        last_completed_lease_id: Some(lease_id),
        provider_reports: reports,
        lease: None,
      }
    }
  }
  let next = { ..current, jobs, durable_version: current.durable_version + 1 }
  if work_order_executor_schedule_is_valid(next) {
    Ok(next)
  } else {
    Err(work_order_executor_error("completed schedule is invalid"))
  }
}

///|
pub fn work_order_executor_lease_is_held(
  record : WorkOrderExecutorScheduleRecord,
  lease : WorkOrderExecutorLease,
) -> Bool {
  work_order_executor_schedule_is_valid(record) &&
  record.jobs.any(fn(job) { job.lease == Some(lease) })
}

///|
pub fn work_order_execution_job_for_work_order(
  record : WorkOrderExecutorScheduleRecord,
  id : WorkOrderId,
) -> WorkOrderExecutionJob? {
  work_order_execution_job_for_owner(record.jobs, id)
}
