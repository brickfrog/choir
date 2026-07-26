///|
pub(all) struct GoalExecutionRunnerAdapters {
  initialize : async (GoalExecutionRecord) -> Result[Bool, @types.ChoirError]
  execute : async (GoalExecutionRecord, Array[PartWorkflowSnapshot]) -> Result[
    Unit,
    @types.ChoirError,
  ]
  assure : async (GoalExecutionRecord, Array[PartWorkflowSnapshot]) -> Result[
    GoalAssuranceTickOutcome,
    @types.ChoirError,
  ]
  finalize : async (GoalExecutionRecord, Array[PartWorkflowSnapshot]) -> Result[
    GoalFinalizationTickOutcome,
    @types.ChoirError,
  ]
  cancel : async (GoalExecutionRecord, Array[PartWorkflowSnapshot]) -> Result[
    GoalCancellationDisposition,
    @types.ChoirError,
  ]
}

///|
/// How far a cancellation tick got. Cancellation may only commit once nothing
/// remote retains authority over the Goal; an exact pull request that merged
/// first wins instead, and the Goal succeeds.
pub(all) enum GoalCancellationDisposition {
  GoalCancellationPending
  GoalCancellationNeutralized
  GoalCancellationSupersededByDelivery(GoalPullRequestRecord)
} derive(Debug, Eq)

///|
pub(all) enum GoalAssuranceTickOutcome {
  GoalAssurancePending
  GoalAssuranceComplete
  GoalAssuranceBlocked
  GoalAssuranceRepairing
  GoalAssuranceRepairFailed(GoalAssuranceRepairKind, @control.Digest, Int64)
} derive(Debug, Eq)

///|
/// Which Goal-level gate exhausted its bounded repair. The kind selects the
/// typed cancellation cause, so retained evidence names the gate that failed.
pub(all) enum GoalAssuranceRepairKind {
  GoalAssuranceAuditRepair
  GoalAssuranceVerificationRepair
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalExecutionTickResult {
  GoalExecutionTickIdle
  GoalExecutionTickAdvanced(GoalExecutionRecord)
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_execution_transaction_persisted(
  outcome : @storage.StateTransactionOutcome,
) -> Bool {
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost => true
    _ => false
  }
}

///|
fn rotate_goal_records(
  records : Array[StoredGoalExecutionRecord],
  after : @control.GoalId?,
) -> Array[StoredGoalExecutionRecord] {
  let pivot = match after {
    None => return records
    Some(id) => {
      let mut found = -1
      for index = 0; index < records.length(); index = index + 1 {
        if records[index].record.goal.id == id {
          found = index
          break
        }
      }
      if found < 0 {
        return records
      }
      found
    }
  }
  let rotated : Array[StoredGoalExecutionRecord] = []
  for index = pivot + 1; index < records.length(); index = index + 1 {
    rotated.push(records[index])
  }
  for index = 0; index <= pivot; index = index + 1 {
    rotated.push(records[index])
  }
  rotated
}

///|
/// Pick the next Goal to tick. Cancellations always run first; otherwise the
/// scan starts just after the previously served Goal so concurrent Goals
/// round-robin instead of the first runnable Goal starving the rest.
fn runnable_goal_execution(
  records : Array[StoredGoalExecutionRecord],
  after : @control.GoalId?,
) -> StoredGoalExecutionRecord? {
  for stored in records {
    if stored.record.state == GoalExecutionState::GoalExecutionCanceling {
      return Some(stored)
    }
  }
  for stored in rotate_goal_records(records, after) {
    match stored.record.state {
      GoalExecutionState::GoalExecutionQueued
      | GoalExecutionState::GoalExecutionRunning
      | GoalExecutionState::GoalExecutionAssuring
      | GoalExecutionState::GoalExecutionAssured => return Some(stored)
      _ => ()
    }
  }
  None
}

///|
fn load_goal_execution_parts(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  record : GoalExecutionRecord,
) -> Result[Array[PartWorkflowSnapshot], @types.ChoirError] {
  let snapshots : Array[PartWorkflowSnapshot] = []
  for workflow_id in record.part_workflow_ids {
    match load_part_snapshot(repository, adapters, workflow_id) {
      Ok(Some(stored)) => {
        if stored.snapshot.goal.id != record.goal.id {
          return Err(goal_execution_error("Part belongs to another Goal"))
        }
        snapshots.push(stored.snapshot)
      }
      Ok(None) => return Err(goal_execution_error("Part workflow is absent"))
      Err(error) => return Err(error)
    }
  }
  Ok(snapshots)
}

///|
/// Delay before the next Goal execution tick.
///
/// A tick that fails for a durable reason — a host runtime that cannot start a
/// sandbox, a snapshot that no longer decodes — fails the same way immediately
/// afterwards, so a fixed one-second retry spins the machine and buries the
/// cause under a log line per second. Back off geometrically to a ceiling so a
/// persistent failure settles into a slow poll while a transient one still
/// recovers promptly.
/// How long to wait between projections of durable Goal state.
///
/// Publishing is otherwise bolted to the execute tick, and the tick runs a
/// provider Take inline: for the length of that Take nothing is projected, so
/// the Conductor and statusline show whatever state preceded it while the Part
/// silently advances through harness start, candidate, and verification. An
/// observer on its own cadence projects that movement; the report fingerprint
/// already suppresses counter-only churn, so a quiet Goal stays quiet.
pub fn goal_observation_interval_ms(active_goals : Int) -> Int {
  if active_goals > 0 {
    3000
  } else {
    15000
  }
}

///|
test "observation keeps a tighter cadence only while a Goal is active" {
  assert_eq(goal_observation_interval_ms(1), 3000)
  assert_eq(goal_observation_interval_ms(4), 3000)
  assert_eq(goal_observation_interval_ms(0), 15000)
}

///|
pub fn goal_execution_tick_delay_ms(consecutive_failures : Int) -> Int {
  let base = 1000
  let ceiling = 30000
  let mut delay = base
  for attempt = 0; attempt < consecutive_failures; attempt = attempt + 1 {
    if delay >= ceiling {
      return ceiling
    }
    delay = delay * 2
  }
  if delay > ceiling {
    ceiling
  } else {
    delay
  }
}

///|
/// Whether a run of ticks that changed nothing has gone on long enough to be
/// reported.
///
/// A tick that fails is loud; a tick that succeeds while advancing nothing is
/// silent, and a Goal can spin in that state indefinitely looking healthy. Both
/// mean the same thing to the person waiting for the work, so both are
/// surfaced. The threshold is looser than the failure one because a slow Take
/// legitimately spans many ticks without changing durable state.
pub fn goal_execution_tick_stall_is_reportable(
  ticks_without_progress : Int,
) -> Bool {
  ticks_without_progress > 0 && ticks_without_progress % 60 == 0
}

///|
/// Whether repeated tick failures have gone on long enough to be reported as a
/// standing condition rather than a passing one. A Goal whose every tick fails
/// is not making progress, and saying so is the difference between a stall the
/// operator can see and one that only exists in the log.
pub fn goal_execution_tick_failure_is_persistent(
  consecutive_failures : Int,
) -> Bool {
  consecutive_failures >= 5
}

///|
/// Emit an operator-facing health transition when a failure run first becomes
/// persistent, and again at a bounded interval while it continues.
///
/// Notifying only once left a Goal that fails every tick silent forever after
/// its fifth failure: the log filled up while the Conductor and statusline
/// showed a Goal that looked merely slow. The repeat is far coarser than the
/// backoff, so a standing stall stays visible without waking the Conductor
/// every retry.
pub fn goal_execution_tick_failure_should_notify(
  consecutive_failures : Int,
) -> Bool {
  consecutive_failures == 5 ||
  (consecutive_failures > 5 && consecutive_failures % 20 == 0)
}

///|
/// Durable state a completed execute pass implies for the Goal.
///
/// `None` means the Parts imply no state change: they are neither all
/// integrated nor blocked, which is the ordinary shape of a run with work still
/// outstanding. It is not evidence of uncertainty, and the tick holds the
/// current state rather than advancing on it.
fn goal_execution_state_from_part_lifecycles(
  lifecycles : Array[@control.PartLifecycle],
) -> GoalExecutionState? {
  if lifecycles.length() > 0 &&
    lifecycles.all(fn(lifecycle) {
      lifecycle is @control.PartLifecycle::PartIntegrated(_)
    }) {
    return Some(GoalExecutionState::GoalExecutionAssuring)
  }
  if lifecycles.any(fn(lifecycle) {
      lifecycle is @control.PartLifecycle::PartBlocked(_) ||
      lifecycle is @control.PartLifecycle::PartCanceledNotRun
    }) {
    return Some(GoalExecutionState::GoalExecutionBlocked)
  }
  None
}

///|
fn goal_execution_state_from_parts(
  snapshots : Array[PartWorkflowSnapshot],
) -> GoalExecutionState? {
  goal_execution_state_from_part_lifecycles(
    snapshots.map(fn(snapshot) { snapshot.part.lifecycle }),
  )
}

///|
fn persist_goal_execution_advance(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  previous : StoredGoalExecutionRecord,
  state : GoalExecutionState,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let next = match advance_goal_execution_state(previous.record, state) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt = match
    persist_goal_execution_record(repository, adapters, {
      record: next,
      expected_store_version: Some(previous.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !goal_execution_transaction_persisted(receipt.transaction_outcome) {
    return Err(goal_execution_error("state advance conflicted"))
  }
  match load_goal_execution_record(repository, adapters, next.goal.id) {
    Ok(Some(stored)) if stored.record == next => Ok(stored)
    Ok(_) => Err(goal_execution_error("state advance did not reload"))
    Err(error) => Err(error)
  }
}

///|
fn persist_goal_execution_epoch_adoption(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  previous : StoredGoalExecutionRecord,
  fencing_epoch : @control.FencingEpoch,
) -> Result[StoredGoalExecutionRecord, @types.ChoirError] {
  let next = match
    adopt_goal_execution_fencing_epoch(previous.record, fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt = match
    persist_goal_execution_record(repository, adapters, {
      record: next,
      expected_store_version: Some(previous.state_record.version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !goal_execution_transaction_persisted(receipt.transaction_outcome) {
    return Err(goal_execution_error("fencing adoption conflicted"))
  }
  match load_goal_execution_record(repository, adapters, next.goal.id) {
    Ok(Some(stored)) if stored.record == next => Ok(stored)
    Ok(_) => Err(goal_execution_error("fencing adoption did not reload"))
    Err(error) => Err(error)
  }
}

///|
fn handle_goal_finalization_outcome(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  selected : StoredGoalExecutionRecord,
  outcome : GoalFinalizationTickOutcome,
) -> Result[GoalExecutionTickResult, @types.ChoirError] {
  match outcome {
    GoalFinalizationTickOutcome::GoalFinalizationSucceeded =>
      match
        load_goal_execution_record(
          repository,
          repository_adapters,
          selected.record.goal.id,
        ) {
        Ok(Some(current)) if current.record.state ==
          GoalExecutionState::GoalExecutionSucceeded =>
          Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(current.record))
        Ok(_) =>
          Err(goal_execution_error("finalization did not commit success"))
        Err(error) => Err(error)
      }
    GoalFinalizationTickOutcome::GoalFinalizationPending =>
      Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(selected.record))
    GoalFinalizationTickOutcome::GoalFinalizationPublicationRemoteUnavailable
    | GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput
    | GoalFinalizationTickOutcome::GoalFinalizationDrifted
    | GoalFinalizationTickOutcome::GoalFinalizationAmbiguous => {
      let reason = match outcome {
        GoalFinalizationPublicationRemoteUnavailable =>
          GoalInputReason::GoalInputPublicationRemoteUnavailable
        GoalFinalizationNeedsUserInput =>
          GoalInputReason::GoalInputFinalizationNeedsUserInput
        GoalFinalizationDrifted => GoalInputReason::GoalInputFinalizationDrifted
        GoalFinalizationAmbiguous =>
          GoalInputReason::GoalInputFinalizationAmbiguous
        _ => abort("unreachable finalization input outcome")
      }
      let paused = match
        persist_goal_input_request(
          repository, repository_adapters, selected, reason,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(paused.record))
    }
    GoalFinalizationTickOutcome::GoalFinalizationRecoveryUncertain => {
      let paused = match
        persist_goal_execution_advance(
          repository,
          repository_adapters,
          selected,
          GoalExecutionState::GoalExecutionPaused,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(paused.record))
    }
    GoalFinalizationTickOutcome::GoalFinalizationDeliveryFailed(digest) => {
      let outcome = match
        persist_goal_cancellation_request(
          repository,
          repository_adapters,
          selected.record.goal.id,
          @env.now().reinterpret_as_int64() / 1000L,
          cause=GoalCancellationCause::GoalCancellationAutoMergeFailed(digest),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let record = match outcome {
        GoalCancellationPersisted(value) | GoalCancellationReplayed(value) =>
          value
        GoalCancellationTerminal(_) =>
          return Err(
            goal_execution_error("automatic merge cancellation lost a race"),
          )
      }
      Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(record))
    }
  }
}

///|
pub async fn run_next_goal_execution_tick(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  runner_adapters : GoalExecutionRunnerAdapters,
  fencing_epoch? : @control.FencingEpoch = @control.FencingEpoch(1L),
  after? : @control.GoalId? = None,
) -> Result[GoalExecutionTickResult, @types.ChoirError] {
  let listed = match
    list_goal_execution_records(repository, repository_adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = match runnable_goal_execution(listed, after) {
    Some(value) => value
    None => return Ok(GoalExecutionTickResult::GoalExecutionTickIdle)
  }
  // Adopt records inherited from an older daemon generation before doing any
  // work on them: the raised stored fence is what rejects writes from a
  // surviving worker of that older generation.
  let selected = if candidate.record.fencing_epoch.0 < fencing_epoch.0 {
    match
      persist_goal_execution_epoch_adoption(
        repository, repository_adapters, candidate, fencing_epoch,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    candidate
  }
  if selected.record.state == GoalExecutionState::GoalExecutionCanceling {
    let parts = match
      load_goal_execution_parts(
        repository,
        repository_adapters,
        selected.record,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let disposition = match (runner_adapters.cancel)(selected.record, parts) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let settled = match disposition {
      GoalCancellationDisposition::GoalCancellationPending =>
        return Ok(
          GoalExecutionTickResult::GoalExecutionTickAdvanced(selected.record),
        )
      GoalCancellationDisposition::GoalCancellationNeutralized =>
        persist_goal_cancellation_completion(
          repository, repository_adapters, selected,
        )
      GoalCancellationDisposition::GoalCancellationSupersededByDelivery(
        pull_request
      ) =>
        persist_goal_delivered_cancellation_success(
          repository, repository_adapters, selected, pull_request,
        )
    }
    let committed = match settled {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return Ok(
      GoalExecutionTickResult::GoalExecutionTickAdvanced(committed.record),
    )
  }
  if selected.record.state == GoalExecutionState::GoalExecutionAssured {
    let parts = match
      load_goal_execution_parts(
        repository,
        repository_adapters,
        selected.record,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match selected.record.completion_mode {
      GoalCompletionMode::GoalEvidenceOnly(_) => {
        let assurance = match
          load_goal_assurance_record(
            repository,
            repository_adapters,
            selected.record.goal.id,
          ) {
          Ok(Some(value)) => value.record
          Ok(_) =>
            return Err(
              goal_execution_error("assured evidence record is absent"),
            )
          Err(error) => return Err(error)
        }
        let authorization = match
          authorize_goal_evidence_only_completion(selected.record, assurance) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let outcome = match
          persist_goal_cancellation_request(
            repository,
            repository_adapters,
            selected.record.goal.id,
            authorization.requested_at,
            cause=authorization.cause,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let record = match outcome {
          GoalCancellationPersisted(value) | GoalCancellationReplayed(value) =>
            value
          GoalCancellationTerminal(_) =>
            return Err(
              goal_execution_error(
                "evidence-only cancellation lost terminal race",
              ),
            )
        }
        return Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(record))
      }
      GoalCompletionMode::GoalPublishable => ()
    }
    let outcome = match (runner_adapters.finalize)(selected.record, parts) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return handle_goal_finalization_outcome(
      repository, repository_adapters, selected, outcome,
    )
  }
  if selected.record.state == GoalExecutionState::GoalExecutionAssuring {
    let parts = match
      load_goal_execution_parts(
        repository,
        repository_adapters,
        selected.record,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !parts.all(fn(snapshot) {
        snapshot.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)
      }) {
      let advanced = match
        persist_goal_execution_advance(
          repository,
          repository_adapters,
          selected,
          GoalExecutionState::GoalExecutionRunning,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return Ok(
        GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced.record),
      )
    }
    let assurance = match (runner_adapters.assure)(selected.record, parts) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let next_state = match assurance {
      GoalAssurancePending =>
        return Ok(
          GoalExecutionTickResult::GoalExecutionTickAdvanced(selected.record),
        )
      GoalAssuranceComplete => GoalExecutionState::GoalExecutionAssured
      GoalAssuranceBlocked => GoalExecutionState::GoalExecutionBlocked
      GoalAssuranceRepairing => GoalExecutionState::GoalExecutionRunning
      GoalAssuranceRepairFailed(kind, digest, requested_at) => {
        let cause = match kind {
          GoalAssuranceRepairKind::GoalAssuranceAuditRepair =>
            GoalCancellationCause::GoalCancellationAuditRepairFailed(digest)
          GoalAssuranceRepairKind::GoalAssuranceVerificationRepair =>
            GoalCancellationCause::GoalCancellationVerificationRepairFailed(
              digest,
            )
        }
        let outcome = match
          persist_goal_cancellation_request(
            repository,
            repository_adapters,
            selected.record.goal.id,
            requested_at,
            cause~,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let record = match outcome {
          GoalCancellationPersisted(value) | GoalCancellationReplayed(value) =>
            value
          GoalCancellationTerminal(_) =>
            return Err(
              goal_execution_error("Goal repair cancellation lost a race"),
            )
        }
        return Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(record))
      }
    }
    let advanced = match
      persist_goal_execution_advance(
        repository, repository_adapters, selected, next_state,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return Ok(
      GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced.record),
    )
  }
  // A WorkOrder that has stopped admitting work must not sit idle: latch the
  // stop durably, then honour the captured cutoff policy. Draining leaves the
  // Goal to finish the effects it already authorized; the cutoff variant
  // installs the existing durable cancellation cutoff.
  match
    goal_execution_admits_new_agentic_work(
      selected.record,
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    WorkOrderAdmission::WorkOrderAdmitsNewWork => ()
    WorkOrderAdmission::WorkOrderExhausted(_) => {
      let latched = record_goal_work_order_stop(
        selected.record,
        @env.now().reinterpret_as_int64() / 1000L,
      )
      let stopped = if latched == selected.record {
        selected
      } else {
        match
          persist_goal_execution_transition(
            repository, repository_adapters, selected, latched,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      }
      guard stopped.record.work_order_budget is Some(budget) else {
        return Err(goal_execution_error("stopped WorkOrder lost its budget"))
      }
      match budget.cutoff_policy {
        WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary =>
          return Ok(
            GoalExecutionTickResult::GoalExecutionTickAdvanced(stopped.record),
          )
        WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff => {
          let outcome = match
            persist_goal_cancellation_request(
              repository,
              repository_adapters,
              stopped.record.goal.id,
              @env.now().reinterpret_as_int64() / 1000L,
              cause=GoalCancellationCause::GoalCancellationWorkOrderStopped(
                work_order_stop_digest(budget),
              ),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let record = match outcome {
            GoalCancellationPersisted(value)
            | GoalCancellationReplayed(value) => value
            GoalCancellationTerminal(_) => stopped.record
          }
          return Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(record))
        }
      }
    }
  }
  let running = match selected.record.state {
    GoalExecutionState::GoalExecutionQueued =>
      match
        persist_goal_execution_advance(
          repository,
          repository_adapters,
          selected,
          GoalExecutionState::GoalExecutionRunning,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    GoalExecutionState::GoalExecutionRunning => selected
    _ => return Err(goal_execution_error("selected Goal is not runnable"))
  }
  let initialized = match (runner_adapters.initialize)(running.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let current = match
    load_goal_execution_record(
      repository,
      repository_adapters,
      running.record.goal.id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Err(goal_execution_error("Goal disappeared"))
    Err(error) => return Err(error)
  }
  if current.record != running.record || !initialized {
    return Ok(
      GoalExecutionTickResult::GoalExecutionTickAdvanced(current.record),
    )
  }
  let before = match
    load_goal_execution_parts(repository, repository_adapters, current.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let before_state = goal_execution_state_from_parts(before)
  if before_state is None {
    match (runner_adapters.execute)(current.record, before) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let after = match
    load_goal_execution_parts(repository, repository_adapters, current.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Refresh the WorkOrder counters that are derived from Part state, so the
  // safety ceiling reflects the Takes this pass actually started.
  let counted = refresh_goal_work_order_counters(current.record, after)
  let current = if counted == current.record {
    current
  } else {
    match
      persist_goal_execution_transition(
        repository, repository_adapters, current, counted,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  for snapshot in after {
    if snapshot.part.lifecycle
      is @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartVerificationFailed
      ) {
      let repairs = snapshot.task_contract_history.fold(init=0, fn(
        count,
        contract,
      ) {
        if contract.repair_verification is Some(_) {
          count + 1
        } else {
          count
        }
      })
      let mut failed : @control.VerificationReceipt? = None
      for receipt in snapshot.verification_receipts {
        if receipt.subject.task_contract_revision_id ==
          snapshot.task_contract.id &&
          receipt.subject.part_id == snapshot.part.id &&
          receipt.outcome != @control.VerificationOutcome::VerificationPassed {
          failed = Some(receipt)
        }
      }
      if failed is None || repairs >= maximum_part_verification_repairs() {
        let (digest, requested_at) = match failed {
          Some(receipt) => (receipt.evidence.digest, receipt.finished_at)
          None =>
            (
              snapshot.task_contract.digest,
              current.record.durable_version.to_int64() + 1L,
            )
        }
        let outcome = match
          persist_goal_cancellation_request(
            repository,
            repository_adapters,
            current.record.goal.id,
            requested_at,
            cause=GoalCancellationCause::GoalCancellationVerificationRepairFailed(
              digest,
            ),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let record = match outcome {
          GoalCancellationPersisted(value) | GoalCancellationReplayed(value) =>
            value
          GoalCancellationTerminal(_) =>
            return Err(
              goal_execution_error(
                "verification repair cancellation lost a race",
              ),
            )
        }
        return Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(record))
      }
    }
    if snapshot.part.lifecycle
      is @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartAuditFindings
      ) {
      let repairs = snapshot.task_contract_history.fold(init=0, fn(
        count,
        contract,
      ) {
        if contract.repair_audit is Some(_) {
          count + 1
        } else {
          count
        }
      })
      let result = match snapshot.audit_result {
        Some(value) => value
        None => return Err(goal_execution_error("audit result is absent"))
      }
      let repairable = result.outcome == @control.AuditOutcome::AuditFindings &&
        result.blocking_findings_count > 0 &&
        result.findings_artifact is Some(_)
      if !repairable || repairs >= maximum_part_audit_repairs() {
        let outcome = match
          persist_goal_cancellation_request(
            repository,
            repository_adapters,
            current.record.goal.id,
            result.finished_at,
            cause=GoalCancellationCause::GoalCancellationAuditRepairFailed(
              result.result_digest,
            ),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let record = match outcome {
          GoalCancellationPersisted(value) | GoalCancellationReplayed(value) =>
            value
          GoalCancellationTerminal(_) =>
            return Err(
              goal_execution_error("audit repair cancellation lost a race"),
            )
        }
        return Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(record))
      }
    }
  }
  // Parts with work still outstanding imply no durable state change. Advancing
  // to Paused here parked the Goal under GoalPauseRecoveryUncertain whenever an
  // execute pass ended with Parts mid-flight — a host-side Take start failure,
  // for instance — and only a human resume could restart it, even though no
  // Part was uncertain and the next tick would have carried it forward.
  let next_state = match goal_execution_state_from_parts(after) {
    Some(value) => value
    None =>
      return Ok(
        GoalExecutionTickResult::GoalExecutionTickAdvanced(current.record),
      )
  }
  let advanced = match
    persist_goal_execution_advance(
      repository, repository_adapters, current, next_state,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced.record))
}

///|
test "Parts still in flight imply no Goal state change" {
  let take = @control.TakeId("take-1")
  let candidate = @control.CandidateId("candidate-1")
  let digest = @control.Digest(
    "0000000000000000000000000000000000000000000000000000000000000000",
  )
  let receipt = @control.ReceiptId("receipt-1")
  // Every mid-run shape: dispatched, built, verified, audited, promoting, and
  // a run where only some Parts have integrated.
  assert_eq(goal_execution_state_from_part_lifecycles([]), None)
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartExecuting(take),
    ]),
    None,
  )
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartCandidate(candidate),
      @control.PartLifecycle::PartVerified(candidate, digest),
    ]),
    None,
  )
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartAudited(candidate, digest, receipt),
      @control.PartLifecycle::PartPromoting(candidate, digest, receipt),
    ]),
    None,
  )
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartIntegrated(receipt),
      @control.PartLifecycle::PartCandidate(candidate),
    ]),
    None,
  )
}

///|
test "Goal state advances only on integrated or blocked Parts" {
  let candidate = @control.CandidateId("candidate-1")
  let receipt = @control.ReceiptId("receipt-1")
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartIntegrated(receipt),
      @control.PartLifecycle::PartIntegrated(receipt),
    ]),
    Some(GoalExecutionState::GoalExecutionAssuring),
  )
  // A blocked Part decides the Goal even beside Parts that are still running.
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartCandidate(candidate),
      @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartRecoveryUncertain,
      ),
    ]),
    Some(GoalExecutionState::GoalExecutionBlocked),
  )
  assert_eq(
    goal_execution_state_from_part_lifecycles([
      @control.PartLifecycle::PartCanceledNotRun,
    ]),
    Some(GoalExecutionState::GoalExecutionBlocked),
  )
}
