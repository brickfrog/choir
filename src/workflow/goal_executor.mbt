///| Durable portfolio scheduling for independently executing Goals.
///
/// A Goal execution tick may stay inside one provider Take for an hour. The
/// portfolio therefore schedules ticks as per-Goal jobs and leases a bounded
/// executor slot to each one. The whole held set lives in one record: capacity
/// admission, fair lane rotation, and slot allocation are one compare-and-set
/// rather than a scan followed by unrelated writes.

///|
pub(all) struct GoalExecutionJobId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct GoalExecutorLeaseId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
/// Cancellation gets the first turn after a fresh start, but not every turn.
/// Persisting the next lane makes capacity-one scheduling fair across restart.
pub(all) enum GoalExecutionJobLane {
  GoalExecutionProgressLane
  GoalExecutionCancellationLane
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalExecutionJobCandidate {
  goal_id : @control.GoalId
  lane : GoalExecutionJobLane
} derive(Debug, Eq)

///|
pub(all) struct GoalExecutorLease {
  id : GoalExecutorLeaseId
  job_id : GoalExecutionJobId
  goal_id : @control.GoalId
  /// Zero-based bounded host slot. The native adapter maps it to a distinct
  /// BoxLite port, so two concurrent Goals never share one server address.
  slot : Int
  dispatch_sequence : Int64
  fencing_epoch : @control.FencingEpoch
  acquired_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalExecutionJob {
  id : GoalExecutionJobId
  goal_id : @control.GoalId
  lane : GoalExecutionJobLane
  due_at : Int64
  consecutive_failures : Int
  last_failure_digest : @control.Digest?
  last_dispatch_sequence : Int64
  last_completed_lease_id : GoalExecutorLeaseId?
  last_goal_durable_version : Int?
  ticks_without_progress : Int
  provider_reports : Array[ProviderSurfaceTickReport]
  lease : GoalExecutorLease?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalExecutorScheduleRecord {
  jobs : Array[GoalExecutionJob]
  next_dispatch_sequence : Int64
  next_lane : GoalExecutionJobLane
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalExecutorDispatchPlan {
  record : GoalExecutorScheduleRecord
  leases : Array[GoalExecutorLease]
} derive(Debug, Eq)

///|
pub(all) enum GoalExecutionJobTickOutcome {
  GoalExecutionJobTickSucceeded(Int?, Array[ProviderSurfaceTickReport])
  GoalExecutionJobTickFailed(@control.Digest, Array[ProviderSurfaceTickReport])
} derive(Debug, Eq)

///|
fn goal_executor_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal executor: " + detail)
}

///|
pub fn goal_execution_job_failure_digest(
  error : @types.ChoirError,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode("choir.goal-execution-job-failure.v1\u{00}" + error.message()),
  )
}

///|
pub fn goal_execution_job_id(goal_id : @control.GoalId) -> GoalExecutionJobId {
  GoalExecutionJobId(
    "goal-job-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode("choir.goal-execution-job.v1\u{00}" + goal_id.0),
      ),
    ),
  )
}

///|
fn goal_executor_lease_id(
  job_id : GoalExecutionJobId,
  fencing_epoch : @control.FencingEpoch,
  dispatch_sequence : Int64,
) -> GoalExecutorLeaseId {
  GoalExecutorLeaseId(
    "goal-executor-lease-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.goal-executor-lease.v1\u{00}" +
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
pub fn empty_goal_executor_schedule_record(
  fencing_epoch : @control.FencingEpoch,
) -> GoalExecutorScheduleRecord {
  {
    jobs: [],
    next_dispatch_sequence: 1L,
    next_lane: GoalExecutionJobLane::GoalExecutionCancellationLane,
    durable_version: 0,
    fencing_epoch,
  }
}

///|
pub fn goal_execution_job_candidate(
  goal_id : @control.GoalId,
  state : GoalExecutionState,
) -> GoalExecutionJobCandidate? {
  match state {
    GoalExecutionState::GoalExecutionCanceling =>
      Some({
        goal_id,
        lane: GoalExecutionJobLane::GoalExecutionCancellationLane,
      })
    GoalExecutionState::GoalExecutionQueued
    | GoalExecutionState::GoalExecutionRunning
    | GoalExecutionState::GoalExecutionAssuring
    | GoalExecutionState::GoalExecutionAssured =>
      Some({ goal_id, lane: GoalExecutionJobLane::GoalExecutionProgressLane })
    GoalExecutionState::GoalExecutionPaused
    | GoalExecutionState::GoalExecutionBlocked
    | GoalExecutionState::GoalExecutionSucceeded
    | GoalExecutionState::GoalExecutionCanceled => None
  }
}

///|
fn initial_goal_execution_job(
  candidate : GoalExecutionJobCandidate,
  now : Int64,
) -> GoalExecutionJob {
  {
    id: goal_execution_job_id(candidate.goal_id),
    goal_id: candidate.goal_id,
    lane: candidate.lane,
    due_at: now,
    consecutive_failures: 0,
    last_failure_digest: None,
    last_dispatch_sequence: 0L,
    last_completed_lease_id: None,
    last_goal_durable_version: None,
    ticks_without_progress: 0,
    provider_reports: [],
    lease: None,
  }
}

///|
fn candidate_for_goal(
  candidates : Array[GoalExecutionJobCandidate],
  goal_id : @control.GoalId,
) -> GoalExecutionJobCandidate? {
  for candidate in candidates {
    if candidate.goal_id == goal_id {
      return Some(candidate)
    }
  }
  None
}

///|
fn job_for_goal(
  jobs : Array[GoalExecutionJob],
  goal_id : @control.GoalId,
) -> GoalExecutionJob? {
  for job in jobs {
    if job.goal_id == goal_id {
      return Some(job)
    }
  }
  None
}

///|
fn opposite_goal_execution_job_lane(
  lane : GoalExecutionJobLane,
) -> GoalExecutionJobLane {
  match lane {
    GoalExecutionProgressLane => GoalExecutionCancellationLane
    GoalExecutionCancellationLane => GoalExecutionProgressLane
  }
}

///|
fn validate_goal_execution_job_candidates(
  candidates : Array[GoalExecutionJobCandidate],
) -> Result[Unit, @types.ChoirError] {
  let seen : Array[@control.GoalId] = []
  for candidate in candidates {
    if candidate.goal_id.0 == "" || seen.contains(candidate.goal_id) {
      return Err(goal_executor_error("job candidates are not unique"))
    }
    seen.push(candidate.goal_id)
  }
  Ok(())
}

///|
fn provider_reports_are_valid(
  reports : Array[ProviderSurfaceTickReport],
) -> Bool {
  let surfaces : Array[@control.ProviderSurfaceId] = []
  for report in reports {
    let instant_is_valid = match report.disposition {
      ProviderSurfaceAdmitted => true
      ProviderSurfaceDeferredUntil(instant) => instant >= 0L
    }
    if !instant_is_valid || surfaces.contains(report.surface) {
      return false
    }
    surfaces.push(report.surface)
  }
  true
}

///|
fn goal_executor_schedule_is_valid(
  record : GoalExecutorScheduleRecord,
  allow_unstored? : Bool = false,
) -> Bool {
  if record.fencing_epoch.0 <= 0L ||
    record.next_dispatch_sequence <= 0L ||
    record.durable_version < (if allow_unstored { 0 } else { 1 }) {
    return false
  }
  let goals : Array[@control.GoalId] = []
  let jobs : Array[GoalExecutionJobId] = []
  let leases : Array[GoalExecutorLeaseId] = []
  let slots : Array[Int] = []
  for job in record.jobs {
    if job.id != goal_execution_job_id(job.goal_id) ||
      job.goal_id.0 == "" ||
      goals.contains(job.goal_id) ||
      jobs.contains(job.id) ||
      job.due_at < 0L ||
      job.consecutive_failures < 0 ||
      job.last_dispatch_sequence < 0L ||
      job.last_dispatch_sequence >= record.next_dispatch_sequence ||
      job.ticks_without_progress < 0 ||
      (job.last_completed_lease_id is Some(completed) && completed.0 == "") ||
      !provider_reports_are_valid(job.provider_reports) {
      return false
    }
    goals.push(job.goal_id)
    jobs.push(job.id)
    match job.lease {
      None => ()
      Some(lease) => {
        if lease.id.0 == "" ||
          lease.id !=
          goal_executor_lease_id(
            job.id,
            lease.fencing_epoch,
            lease.dispatch_sequence,
          ) ||
          lease.job_id != job.id ||
          lease.goal_id != job.goal_id ||
          lease.slot < 0 ||
          lease.slot >= @types.maximum_goal_executor_jobs() ||
          lease.dispatch_sequence != job.last_dispatch_sequence ||
          lease.dispatch_sequence <= 0L ||
          lease.fencing_epoch != record.fencing_epoch ||
          lease.acquired_at < 0L ||
          job.last_completed_lease_id == Some(lease.id) ||
          leases.contains(lease.id) ||
          slots.contains(lease.slot) {
          return false
        }
        leases.push(lease.id)
        slots.push(lease.slot)
      }
    }
  }
  true
}

///|
pub fn goal_executor_schedule_record_bytes(
  record : GoalExecutorScheduleRecord,
) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn decode_goal_executor_schedule_record(
  content : Bytes,
) -> Result[GoalExecutorScheduleRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode(content)) catch {
    _ => return Err(goal_executor_error("record is not valid JSON"))
  }
  let record : GoalExecutorScheduleRecord = @json.from_json(json) catch {
    _ => return Err(goal_executor_error("record has the wrong schema"))
  }
  if goal_executor_schedule_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_executor_error("record identity is invalid"))
  }
}

///|
fn sorted_goal_execution_jobs(
  jobs : Array[GoalExecutionJob],
) -> Array[GoalExecutionJob] {
  let ordered = jobs.copy()
  ordered.sort_by(fn(left, right) { left.goal_id.compare(right.goal_id) })
  ordered
}

///|
fn reconcile_goal_execution_jobs(
  current : GoalExecutorScheduleRecord,
  candidates : Array[GoalExecutionJobCandidate],
  now : Int64,
  fencing_epoch : @control.FencingEpoch,
) -> Result[Array[GoalExecutionJob], @types.ChoirError] {
  let reconciled : Array[GoalExecutionJob] = []
  for job in current.jobs {
    match candidate_for_goal(candidates, job.goal_id) {
      Some(candidate) => {
        let lease = match job.lease {
          Some(value) if value.fencing_epoch.0 < fencing_epoch.0 => None
          Some(value) if value.fencing_epoch == fencing_epoch => Some(value)
          Some(_) =>
            return Err(goal_executor_error("a future generation holds a job"))
          None => None
        }
        // A live task keeps the lane it was dispatched in. If cancellation
        // arrives while that task is returning, recording the new lane early
        // would make its eventual failure look like a cancellation failure and
        // carry the old attempt's backoff into teardown.
        let lane_changed = lease is None && job.lane != candidate.lane
        reconciled.push({
          ..job,
          lane: if lease is Some(_) {
            job.lane
          } else {
            candidate.lane
          },
          due_at: if lane_changed {
            now
          } else if job.lease is Some(_) && lease is None {
            now
          } else {
            job.due_at
          },
          consecutive_failures: if lane_changed {
            0
          } else {
            job.consecutive_failures
          },
          last_failure_digest: if lane_changed {
            None
          } else {
            job.last_failure_digest
          },
          ticks_without_progress: if lane_changed {
            0
          } else {
            job.ticks_without_progress
          },
          provider_reports: if lane_changed {
            []
          } else {
            job.provider_reports
          },
          lease,
        })
      }
      None =>
        // A task may observe cancellation, pause, or terminal delivery while
        // it is still returning. Keep its live lease until that exact task
        // releases it; an unleased ineligible job has no remaining purpose.
        match job.lease {
          Some(value) if value.fencing_epoch == fencing_epoch =>
            reconciled.push(job)
          Some(value) if value.fencing_epoch.0 > fencing_epoch.0 =>
            return Err(goal_executor_error("a future generation holds a job"))
          _ => ()
        }
    }
  }
  for candidate in candidates {
    if job_for_goal(reconciled, candidate.goal_id) is None {
      reconciled.push(initial_goal_execution_job(candidate, now))
    }
  }
  Ok(sorted_goal_execution_jobs(reconciled))
}

///|
fn due_job_index_in_lane(
  jobs : Array[GoalExecutionJob],
  lane : GoalExecutionJobLane,
  now : Int64,
) -> Int? {
  let mut selected = -1
  for index = 0; index < jobs.length(); index = index + 1 {
    let job = jobs[index]
    if job.lane != lane || job.lease is Some(_) || job.due_at > now {
      continue
    }
    if selected < 0 {
      selected = index
      continue
    }
    let held = jobs[selected]
    if job.last_dispatch_sequence < held.last_dispatch_sequence ||
      (
        job.last_dispatch_sequence == held.last_dispatch_sequence &&
        job.goal_id.compare(held.goal_id) < 0
      ) {
      selected = index
    }
  }
  if selected < 0 {
    None
  } else {
    Some(selected)
  }
}

///|
fn next_due_job_index(
  jobs : Array[GoalExecutionJob],
  preferred : GoalExecutionJobLane,
  now : Int64,
) -> Int? {
  match due_job_index_in_lane(jobs, preferred, now) {
    Some(value) => Some(value)
    None =>
      due_job_index_in_lane(
        jobs,
        opposite_goal_execution_job_lane(preferred),
        now,
      )
  }
}

///|
fn next_free_executor_slot(
  jobs : Array[GoalExecutionJob],
  capacity : Int,
) -> Int? {
  for slot = 0; slot < capacity; slot = slot + 1 {
    let mut held = false
    for job in jobs {
      match job.lease {
        Some(lease) if lease.slot == slot => {
          held = true
          break
        }
        _ => ()
      }
    }
    if !held {
      return Some(slot)
    }
  }
  None
}

///|
/// Reconcile the durable per-Goal jobs and lease every executor slot that can
/// do useful work now.
///
/// The returned record changes exactly once, no matter how many jobs it
/// leases. Persisting that one record with compare-and-set is what makes the
/// configured capacity authoritative.
pub fn plan_goal_executor_dispatches(
  current : GoalExecutorScheduleRecord,
  candidates : Array[GoalExecutionJobCandidate],
  capacity : Int,
  now : Int64,
  fencing_epoch : @control.FencingEpoch,
) -> Result[GoalExecutorDispatchPlan, @types.ChoirError] {
  if capacity <= 0 || capacity > @types.maximum_goal_executor_jobs() {
    return Err(goal_executor_error("executor capacity is invalid"))
  }
  if now < 0L || fencing_epoch.0 <= 0L {
    return Err(goal_executor_error("scheduler clock or fence is invalid"))
  }
  if !goal_executor_schedule_is_valid(current, allow_unstored=true) {
    return Err(goal_executor_error("current schedule is invalid"))
  }
  if current.fencing_epoch.0 > fencing_epoch.0 {
    return Err(goal_executor_error("a newer generation owns the schedule"))
  }
  match validate_goal_execution_job_candidates(candidates) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let jobs = match
    reconcile_goal_execution_jobs(current, candidates, now, fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let leases : Array[GoalExecutorLease] = []
  let mut sequence = current.next_dispatch_sequence
  let mut next_lane = current.next_lane
  for ;; {
    let slot = match next_free_executor_slot(jobs, capacity) {
      Some(value) => value
      None => break
    }
    let index = match next_due_job_index(jobs, next_lane, now) {
      Some(value) => value
      None => break
    }
    let job = jobs[index]
    let lease : GoalExecutorLease = {
      id: goal_executor_lease_id(job.id, fencing_epoch, sequence),
      job_id: job.id,
      goal_id: job.goal_id,
      slot,
      dispatch_sequence: sequence,
      fencing_epoch,
      acquired_at: now,
    }
    jobs[index] = {
      ..job,
      last_dispatch_sequence: sequence,
      // A new attempt has not made a capacity observation yet. Retaining the
      // previous refusal while this task is actively running would publish a
      // stale wake instant beside the new attempt's held provider slot.
      provider_reports: [],
      lease: Some(lease),
    }
    leases.push(lease)
    sequence = sequence + 1L
    next_lane = opposite_goal_execution_job_lane(job.lane)
  }
  let candidate_record : GoalExecutorScheduleRecord = {
    jobs: sorted_goal_execution_jobs(jobs),
    next_dispatch_sequence: sequence,
    next_lane,
    durable_version: current.durable_version,
    fencing_epoch,
  }
  let changed = candidate_record != current
  let record = if changed {
    { ..candidate_record, durable_version: current.durable_version + 1 }
  } else {
    current
  }
  if !goal_executor_schedule_is_valid(
      record,
      allow_unstored=record.durable_version == 0,
    ) {
    return Err(goal_executor_error("planned schedule is invalid"))
  }
  Ok({ record, leases })
}

///|
fn earliest_provider_deferral(
  reports : Array[ProviderSurfaceTickReport],
) -> Int64? {
  if reports.length() == 0 {
    return None
  }
  let mut earliest : Int64? = None
  for report in reports {
    match report.disposition {
      ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted => return None
      ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(instant) =>
        earliest = match earliest {
          Some(value) => Some(if instant < value { instant } else { value })
          None => Some(instant)
        }
    }
  }
  earliest
}

///|
fn goal_executor_failure_delay_seconds(consecutive_failures : Int) -> Int64 {
  let mut delay = 1L
  for attempt = 0; attempt < consecutive_failures; attempt = attempt + 1 {
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
fn successful_goal_job_due_at(
  reports : Array[ProviderSurfaceTickReport],
  now : Int64,
) -> Int64 {
  match earliest_provider_deferral(reports) {
    None => now + 1L
    Some(instant) => {
      // Preserve the worker's existing capped re-check. A malformed or stale
      // reset instant must not park one durable job until year 5138.
      let ceiling = now + 30L
      if instant <= now {
        now + 1L
      } else if instant > ceiling {
        ceiling
      } else {
        instant
      }
    }
  }
}

///|
fn completed_goal_version(
  job : GoalExecutionJob,
  version : Int?,
) -> (Int?, Int) {
  match version {
    None => (job.last_goal_durable_version, 0)
    Some(value) =>
      if job.last_goal_durable_version == Some(value) {
        (Some(value), job.ticks_without_progress + 1)
      } else {
        (Some(value), 0)
      }
  }
}

///|
/// Release one exact executor lease and schedule only that Goal's next attempt.
///
/// Replaying the same completion is a no-op. A failure backs off this job, not
/// the portfolio; a provider refusal carries only this job to its bounded
/// due-at instant.
pub fn complete_goal_executor_dispatch(
  current : GoalExecutorScheduleRecord,
  lease_id : GoalExecutorLeaseId,
  outcome : GoalExecutionJobTickOutcome,
  now : Int64,
) -> Result[GoalExecutorScheduleRecord, @types.ChoirError] {
  if !goal_executor_schedule_is_valid(current) || now < 0L {
    return Err(goal_executor_error("completion input is invalid"))
  }
  let jobs = current.jobs.copy()
  let mut found = -1
  for index = 0; index < jobs.length(); index = index + 1 {
    let job = jobs[index]
    if job.last_completed_lease_id == Some(lease_id) {
      return Ok(current)
    }
    match job.lease {
      Some(lease) if lease.id == lease_id => {
        found = index
        break
      }
      _ => ()
    }
  }
  if found < 0 {
    return Err(goal_executor_error("executor lease is not held"))
  }
  let job = jobs[found]
  let reports = match outcome {
    GoalExecutionJobTickSucceeded(_, value)
    | GoalExecutionJobTickFailed(_, value) => value
  }
  if !provider_reports_are_valid(reports) {
    return Err(goal_executor_error("provider reports are inconsistent"))
  }
  let completed = match outcome {
    GoalExecutionJobTickSucceeded(version, _) => {
      let progress = completed_goal_version(job, version)
      {
        ..job,
        due_at: successful_goal_job_due_at(reports, now),
        consecutive_failures: 0,
        last_failure_digest: None,
        last_completed_lease_id: Some(lease_id),
        last_goal_durable_version: progress.0,
        ticks_without_progress: progress.1,
        provider_reports: reports,
        lease: None,
      }
    }
    GoalExecutionJobTickFailed(digest, _) => {
      let failures = job.consecutive_failures + 1
      {
        ..job,
        due_at: now + goal_executor_failure_delay_seconds(failures),
        consecutive_failures: failures,
        last_failure_digest: Some(digest),
        last_completed_lease_id: Some(lease_id),
        provider_reports: reports,
        lease: None,
      }
    }
  }
  jobs[found] = completed
  let next = {
    ..current,
    jobs: sorted_goal_execution_jobs(jobs),
    durable_version: current.durable_version + 1,
  }
  if goal_executor_schedule_is_valid(next) {
    Ok(next)
  } else {
    Err(goal_executor_error("completed schedule is invalid"))
  }
}

///|
pub fn goal_executor_lease_is_held(
  record : GoalExecutorScheduleRecord,
  lease : GoalExecutorLease,
) -> Bool {
  if !goal_executor_schedule_is_valid(record) {
    return false
  }
  for job in record.jobs {
    if job.lease == Some(lease) {
      return true
    }
  }
  false
}

///|
pub fn goal_execution_job_for_goal(
  record : GoalExecutorScheduleRecord,
  goal_id : @control.GoalId,
) -> GoalExecutionJob? {
  job_for_goal(record.jobs, goal_id)
}
