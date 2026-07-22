///|
fn migration_admission_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("migration admission: " + detail)
}

///|
fn validated_terminal_assurance_seal(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
) -> Result[@control.GoalBranchSeal, @types.ChoirError] {
  match decode_goal_execution_record(goal_execution_record_bytes(execution)) {
    Ok(validated) if validated == execution => ()
    _ => return Err(migration_admission_error("Goal execution is invalid"))
  }
  if assurance.goal_id != execution.goal.id ||
    assurance.goal_contract_digest != execution.goal.contract_digest ||
    assurance.stage != GoalAssuranceStage::GoalAudited {
    return Err(migration_admission_error("Goal assurance is stale"))
  }
  match decode_goal_assurance_record(goal_assurance_record_bytes(assurance)) {
    Ok(validated) if validated == assurance => ()
    _ => return Err(migration_admission_error("Goal assurance is invalid"))
  }
  guard assurance.seal is Some(seal) &&
    seal.goal_id == execution.goal.id &&
    seal.goal_contract_digest == execution.goal.contract_digest &&
    seal.seal_digest == goal_branch_seal_digest(seal) else {
    return Err(migration_admission_error("Goal seal is stale"))
  }
  Ok(seal)
}

///|
pub fn validate_judge_qualification_admission(
  contract : @migration.MigrationContract,
  reference : @migration.JudgeQualificationEvidenceRef,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
) -> Result[Unit, @types.ChoirError] {
  match @migration.validate_migration_contract(contract) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @migration.validate_judge_qualification_evidence_ref(reference) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let seal = match validated_terminal_assurance_seal(execution, assurance) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let binding = reference.binding
  if binding.qualifying_goal_id != execution.goal.id ||
    binding.qualifying_goal_contract_digest != execution.goal.contract_digest ||
    binding.goal_branch_seal_id != seal.id ||
    binding.goal_branch_seal_digest != seal.seal_digest ||
    binding.judge_definition_digest != contract.judge_definition_digest ||
    binding.source_revision != contract.source_revision ||
    reference.assurance_record_digest != goal_assurance_record_digest(assurance) ||
    reference.assurance_record_digest !=
    contract.judge_qualification_assurance_record_digest {
    return Err(migration_admission_error("judge qualification is stale"))
  }
  match reference.terminal {
    @migration.JudgeQualificationTerminal::JudgeQualificationSucceeded(id) =>
      if execution.state != GoalExecutionState::GoalExecutionSucceeded ||
        execution.completion_mode != GoalCompletionMode::GoalPublishable ||
        execution.goal.lifecycle != @control.GoalLifecycle::GoalSucceeded(id) {
        return Err(
          migration_admission_error("qualifying Goal is not succeeded"),
        )
      }
    @migration.JudgeQualificationTerminal::JudgeQualificationEvidenceOnlyCanceled(
      summary_id
    ) => {
      if execution.state != GoalExecutionState::GoalExecutionCanceled ||
        execution.completion_mode !=
        GoalCompletionMode::GoalEvidenceOnly(
          reference.completion_binding_digest,
        ) ||
        execution.goal.lifecycle !=
        @control.GoalLifecycle::GoalCanceled(summary_id) {
        return Err(
          migration_admission_error(
            "qualifying Goal is not evidence-only canceled",
          ),
        )
      }
      guard execution.cancellation_request is Some(request) &&
        request.cause ==
        GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
          reference.completion_binding_digest,
          reference.assurance_record_digest,
        ) else {
        return Err(
          migration_admission_error("qualifying cancellation cause is stale"),
        )
      }
    }
  }
  Ok(())
}

///|
pub fn validate_rehearsal_admission(
  contract_ref : @control.MigrationContractRef,
  sampled_inventory_digest : @control.Digest,
  reference : @migration.RehearsalEvidenceRef,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
) -> Result[Unit, @types.ChoirError] {
  match @migration.validate_rehearsal_evidence_ref(reference) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let _ = match validated_terminal_assurance_seal(execution, assurance) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if reference.migration_contract_ref != contract_ref ||
    reference.sampled_inventory_digest != sampled_inventory_digest ||
    reference.rehearsal_goal_id != execution.goal.id ||
    reference.assurance_record_digest != goal_assurance_record_digest(assurance) ||
    execution.state != GoalExecutionState::GoalExecutionCanceled ||
    execution.completion_mode !=
    GoalCompletionMode::GoalEvidenceOnly(reference.completion_binding_digest) ||
    execution.goal.lifecycle !=
    @control.GoalLifecycle::GoalCanceled(reference.cancellation_summary_id) {
    return Err(migration_admission_error("rehearsal evidence is stale"))
  }
  guard execution.cancellation_request is Some(request) &&
    request.cause ==
    GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
      reference.completion_binding_digest,
      reference.assurance_record_digest,
    ) else {
    return Err(migration_admission_error("rehearsal cancellation is stale"))
  }
  Ok(())
}

///|
pub fn validate_migration_production_admission(
  contract : @migration.MigrationContract,
  acceptance : @migration.MigrationContractAcceptance,
  judge_definition : @migration.MigrationJudgeDefinition,
  judge_report : @migration.JudgeQualificationReport,
  qualification : @migration.JudgeQualificationEvidenceRef,
  qualification_execution : GoalExecutionRecord,
  qualification_assurance : GoalAssuranceRecord,
  rehearsal : @migration.RehearsalEvidenceRef?,
  rehearsal_execution : GoalExecutionRecord?,
  rehearsal_assurance : GoalAssuranceRecord?,
) -> Result[@migration.MigrationProductionAdmissionRef, @types.ChoirError] {
  match @migration.validate_contract_acceptance(acceptance) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let contract_ref = match @migration.migration_contract_reference(contract) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if acceptance.contract_ref != contract_ref {
    return Err(migration_admission_error("contract acceptance is stale"))
  }
  match
    @migration.validate_judge_qualification_report(
      judge_definition, judge_report,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @migration.migration_judge_definition_digest(judge_definition) !=
    contract.judge_definition_digest ||
    judge_definition.source_revision != contract.source_revision ||
    judge_report.goal_verification_receipt_ids !=
    qualification_assurance.verification_receipts.map(fn(receipt) {
      receipt.receipt_id
    }) ||
    qualification_assurance.audit_receipt.map(fn(receipt) { receipt.receipt_id }) !=
    Some(judge_report.goal_audit_receipt_id) {
    return Err(migration_admission_error("judge evidence is stale"))
  }
  match
    validate_judge_qualification_admission(
      contract, qualification, qualification_execution, qualification_assurance,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    (
      contract.rehearsal_policy,
      rehearsal,
      rehearsal_execution,
      rehearsal_assurance,
    ) {
    (@migration.RehearsalPolicy::RehearsalNotRequired, None, None, None) => ()
    (
      @migration.RehearsalPolicy::RehearsalRequired(sample_digest),
      Some(evidence),
      Some(execution),
      Some(assurance),
    ) =>
      match
        validate_rehearsal_admission(
          contract_ref, sample_digest, evidence, execution, assurance,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    _ => return Err(migration_admission_error("rehearsal evidence is incomplete"))
  }
  Ok({
    migration_contract_ref: contract_ref,
    contract_acceptance_digest: @migration.migration_contract_acceptance_digest(
      acceptance,
    ),
    judge_definition_digest: @migration.migration_judge_definition_digest(
      judge_definition,
    ),
    judge_qualification_report_digest: @migration.judge_qualification_report_digest(
      judge_report,
    ),
    judge_qualification_evidence_ref_digest: @migration.judge_qualification_evidence_ref_digest(
      qualification,
    ),
    rehearsal_evidence_ref_digest: rehearsal.map(fn(evidence) {
      @migration.rehearsal_evidence_ref_digest(evidence)
    }),
    migration_continuation_ref_digest: None,
  })
}
