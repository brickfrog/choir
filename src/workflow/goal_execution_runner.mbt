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
    Bool,
    @types.ChoirError,
  ]
}

///|
pub(all) enum GoalAssuranceTickOutcome {
  GoalAssurancePending
  GoalAssuranceComplete
  GoalAssuranceBlocked
} derive(Debug, Eq)

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
fn goal_execution_state_from_parts(
  snapshots : Array[PartWorkflowSnapshot],
) -> GoalExecutionState? {
  if snapshots.length() > 0 &&
    snapshots.all(fn(snapshot) {
      snapshot.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)
    }) {
    return Some(GoalExecutionState::GoalExecutionAssuring)
  }
  if snapshots.any(fn(snapshot) {
      snapshot.part.lifecycle is @control.PartLifecycle::PartBlocked(_) ||
      snapshot.part.lifecycle is @control.PartLifecycle::PartCanceledNotRun
    }) {
    return Some(GoalExecutionState::GoalExecutionBlocked)
  }
  None
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
        Ok(_) => Err(goal_execution_error("finalization did not commit success"))
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
  }
}

///|
pub async fn run_next_goal_execution_tick(
  repository : PartWorkflowRepository,
  repository_adapters : PartWorkflowRepositoryAdapters,
  runner_adapters : GoalExecutionRunnerAdapters,
  fencing_epoch~ : @control.FencingEpoch = @control.FencingEpoch(1L),
  after~ : @control.GoalId? = None,
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
        repository,
        repository_adapters,
        candidate,
        fencing_epoch,
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
    let can_finish = match (runner_adapters.cancel)(selected.record, parts) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !can_finish {
      return Ok(
        GoalExecutionTickResult::GoalExecutionTickAdvanced(selected.record),
      )
    }
    let canceled = match
      persist_goal_cancellation_completion(
        repository, repository_adapters, selected,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return Ok(
      GoalExecutionTickResult::GoalExecutionTickAdvanced(canceled.record),
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
      return Err(goal_execution_error("assurance started before integration"))
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
  let next_state = match goal_execution_state_from_parts(after) {
    Some(value) => value
    None => GoalExecutionState::GoalExecutionPaused
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
