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

///|
pub fn validate_migration_continuation_selection(
  continuation : @migration.MigrationContinuationRef,
  supersession : @migration.MigrationSupersession,
  prior_execution : GoalExecutionRecord,
  terminal_goal_head : @control.GitOid,
  expected_new_base : @control.GitOid,
  task_contracts : Array[@control.TaskContractRevision],
) -> Result[Unit, @types.ChoirError] {
  match
    validate_migration_continuation_terminal(
      continuation, supersession, prior_execution, terminal_goal_head, expected_new_base,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if task_contracts.length() == 0 {
    return Err(migration_revision_error("continuation selection is empty"))
  }
  let continuation_digest = @migration.migration_continuation_ref_digest(
    continuation,
  )
  if task_contracts.any(fn(contract) {
      contract.base_commit_oid != expected_new_base ||
      contract.migration_contract_ref != Some(continuation.next_contract_ref) ||
      contract.migration_continuation_ref_digest != Some(continuation_digest)
    }) {
    return Err(
      migration_revision_error("continuation task contracts are inconsistent"),
    )
  }
  Ok(())
}

///|
fn migration_revision_take_is_fresh(
  prior : @control.Take,
  replacement : @control.Take,
) -> Bool {
  replacement.id != prior.id &&
  replacement.ordinal == prior.ordinal + 1 &&
  replacement.lifecycle == @control.TakeLifecycle::TakePlanned
}

///|
pub fn plan_part_migration_revision(
  snapshot : PartWorkflowSnapshot,
  impact_set : @migration.MigrationContractRevisionImpactSet,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  is_nfc : (String) -> Bool,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if impact_set.application !=
    @migration.MigrationContractRevisionApplication::MigrationRevisionAppliesInPlace ||
    snapshot.pending_effect is Some(_) ||
    snapshot.stage == PartWorkflowStage::PartIntegrated ||
    snapshot.stage == PartWorkflowStage::PartCanceled ||
    !impact_set.impacted_parts.any(fn(impact) {
      impact.part_id == snapshot.part.id && !impact.was_integrated
    }) {
    return Err(
      migration_revision_error("Part is not eligible for in-place revision"),
    )
  }
  if snapshot.task_contract.migration_contract_ref !=
    Some(impact_set.previous_contract_ref) ||
    contract.migration_contract_ref != Some(impact_set.next_contract_ref) ||
    contract.id == snapshot.task_contract.id ||
    contract.digest == snapshot.task_contract.digest ||
    contract.goal_id != snapshot.goal.id ||
    contract.part_id != snapshot.part.id ||
    contract.revision != snapshot.task_contract.revision + 1 ||
    contract.base_commit_oid != snapshot.task_contract.base_commit_oid ||
    contract.base_tree_oid != snapshot.task_contract.base_tree_oid ||
    contract.mutation_declaration != snapshot.task_contract.mutation_declaration ||
    contract.migration_continuation_ref_digest !=
    snapshot.task_contract.migration_continuation_ref_digest ||
    !migration_revision_take_is_fresh(
      snapshot.implementation_take,
      identities.implementation_take,
    ) ||
    !migration_revision_take_is_fresh(
      snapshot.verification_take,
      identities.verification_take,
    ) ||
    !migration_revision_take_is_fresh(
      snapshot.audit_take,
      identities.audit_take,
    ) {
    return Err(migration_revision_error("Part revision identity is invalid"))
  }
  let used_take_ids = snapshot.prior_takes.map(fn(take) { take.id }) +
    [
      snapshot.implementation_take.id,
      snapshot.verification_take.id,
      snapshot.audit_take.id,
    ]
  if used_take_ids.contains(identities.implementation_take.id) ||
    used_take_ids.contains(identities.verification_take.id) ||
    used_take_ids.contains(identities.audit_take.id) {
    return Err(migration_revision_error("Part revision reuses a Take"))
  }
  let context_manifest = match snapshot.part_context_manifest {
    Some(manifest) =>
      Some({
        ..manifest,
        migration_contract_ref: impact_set.next_contract_ref,
        part_task_contract_revision_id: contract.id,
        part_task_contract_digest: contract.digest,
      })
    None => return Err(migration_revision_error("migration context is absent"))
  }
  let pending_part = {
    ..snapshot.part,
    task_contract_revision_id: contract.id,
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let initialized = match
    initialize_part_workflow(
      snapshot.workflow_id,
      snapshot.goal,
      pending_part,
      contract,
      identities,
      snapshot.fencing_epoch,
      is_nfc,
      part_context_manifest=context_manifest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..initialized,
    durable_version: snapshot.durable_version + 1,
    task_contract_history: snapshot.task_contract_history + [contract],
    prior_takes: snapshot.prior_takes +
    [
      snapshot.implementation_take,
      snapshot.verification_take,
      snapshot.audit_take,
    ],
    prior_take_evidence: snapshot.prior_take_evidence +
    [
      {
        task_contract_revision_id: snapshot.task_contract.id,
        implementation_result: snapshot.implementation_result,
        candidate: snapshot.candidate,
        verification_receipts: snapshot.verification_receipts,
        verification_authorization: snapshot.verification_authorization,
        audit_result: snapshot.audit_result,
        audit_receipt: snapshot.audit_receipt,
        integration_intent: snapshot.integration_intent,
      },
    ],
    sandbox_leases: snapshot.sandbox_leases,
    harness_sessions: snapshot.harness_sessions,
    harness_events: snapshot.harness_events,
    integration_conflicts: snapshot.integration_conflicts,
    effect_receipts: snapshot.effect_receipts,
  })
}
