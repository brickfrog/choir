///|
pub(all) struct MigrationSupersessionAuthorization {
  supersession : @migration.MigrationSupersession
  supersession_artifact_digest : @control.Digest
  canceling_record : GoalExecutionRecord
} derive(Debug, Eq)

///|
fn migration_revision_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("migration revision: " + detail)
}

///|
pub fn authorize_migration_goal_supersession(
  execution : GoalExecutionRecord,
  impact_set : @migration.MigrationContractRevisionImpactSet,
  integrated_part_ids : Array[@control.PartId],
  observed_goal_head : @control.GitOid,
  requested_at : Int64,
) -> Result[MigrationSupersessionAuthorization, @types.ChoirError] {
  if impact_set.application !=
    @migration.MigrationContractRevisionApplication::MigrationRevisionRequiresGoalSupersession ||
    observed_goal_head.0 == "" {
    return Err(migration_revision_error("supersession is not required"))
  }
  for index, part_id in integrated_part_ids {
    if part_id.0 == "" || integrated_part_ids[index + 1:].contains(part_id) {
      return Err(migration_revision_error("integrated Part set is invalid"))
    }
  }
  if impact_set.impacted_parts.any(fn(impact) {
      impact.was_integrated != integrated_part_ids.contains(impact.part_id)
    }) {
    return Err(migration_revision_error("integrated Part evidence is stale"))
  }
  let impacted_integrated = impact_set.impacted_parts
    .filter(fn(impact) { impact.was_integrated })
    .map(fn(impact) { impact.part_id })
  impacted_integrated.sort()
  if impacted_integrated.length() == 0 {
    return Err(migration_revision_error("no integrated Part is impacted"))
  }
  let supersession : @migration.MigrationSupersession = {
    prior_goal_id: execution.goal.id,
    previous_contract_ref: impact_set.previous_contract_ref,
    next_contract_ref: impact_set.next_contract_ref,
    impacted_integrated_part_ids: impacted_integrated,
    observed_goal_head,
    cutoff_sequence: @control.EventSequence(
      execution.durable_version.to_int64() + 1L,
    ),
  }
  match @migration.validate_migration_supersession(supersession) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let supersession_artifact_digest = @migration.migration_supersession_digest(
    supersession,
  )
  let decision = match
    request_goal_execution_cancellation(
      execution,
      requested_at,
      cause=GoalCancellationCause::GoalCancellationSupersededByContractRevision(
        supersession_artifact_digest,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard decision
    is GoalCancellationDecision::GoalCancellationRequested(canceling_record) &&
    canceling_record.cancellation_request is Some(request) &&
    request.cutoff_sequence == supersession.cutoff_sequence else {
    return Err(migration_revision_error("supersession lost its terminal race"))
  }
  Ok({ supersession, supersession_artifact_digest, canceling_record })
}

///|
pub fn validate_migration_continuation_terminal(
  continuation : @migration.MigrationContinuationRef,
  supersession : @migration.MigrationSupersession,
  prior_execution : GoalExecutionRecord,
  terminal_goal_head : @control.GitOid,
  expected_new_base : @control.GitOid,
) -> Result[Unit, @types.ChoirError] {
  match @migration.validate_migration_continuation_ref(continuation) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @migration.validate_migration_supersession(supersession) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if continuation.prior_goal_id != supersession.prior_goal_id ||
    continuation.prior_goal_id != prior_execution.goal.id ||
    continuation.supersession_artifact_digest !=
    @migration.migration_supersession_digest(supersession) ||
    continuation.next_contract_ref != supersession.next_contract_ref ||
    continuation.terminal_preserved_head != terminal_goal_head ||
    expected_new_base != terminal_goal_head ||
    prior_execution.state != GoalExecutionState::GoalExecutionCanceled ||
    prior_execution.goal.lifecycle !=
    @control.GoalLifecycle::GoalCanceled(continuation.cancellation_summary_id) ||
    !goal_source_release_dispositions_are_known(prior_execution) {
    return Err(migration_revision_error("continuation provenance is stale"))
  }
  guard prior_execution.cancellation_request is Some(request) &&
    request.cutoff_sequence == supersession.cutoff_sequence &&
    request.cause ==
    GoalCancellationCause::GoalCancellationSupersededByContractRevision(
      continuation.supersession_artifact_digest,
    ) else {
    return Err(migration_revision_error("supersession cancellation is stale"))
  }
  Ok(())
}
