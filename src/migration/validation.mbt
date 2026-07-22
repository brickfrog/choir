///|
fn migration_validation_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("migration: " + detail)
}

///|
fn all_digests_valid(digests : Array[@control.Digest]) -> Bool {
  digests.all(fn(digest) { digest_is_valid(digest) })
}

///|
fn digests_are_unique(digests : Array[@control.Digest]) -> Bool {
  let ordered = sorted_digests(digests)
  for index = 1; index < ordered.length(); index = index + 1 {
    if ordered[index - 1] == ordered[index] {
      return false
    }
  }
  true
}

///|
pub fn validate_migration_contract_ref(
  reference : @control.MigrationContractRef,
) -> Result[Unit, @types.ChoirError] {
  if reference.contract_id.0 == "" ||
    reference.migration_lineage_id.0 == "" ||
    reference.revision <= 0 ||
    !digest_is_valid(reference.contract_artifact_digest) {
    Err(migration_validation_error("contract reference is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn validate_feasibility_report(
  report : MigrationFeasibilityReport,
) -> Result[Unit, @types.ChoirError] {
  let capacity_valid = match report.capacity_estimate {
    CapacityUnknown => true
    CapacityEvidenceRange(minimum, maximum, basis_digest) =>
      minimum >= 0 && maximum >= minimum && digest_is_valid(basis_digest)
  }
  if report.schema_version != 1 ||
    report.estimated_minimum_units < 0 ||
    report.estimated_maximum_units < report.estimated_minimum_units ||
    !all_digests_valid([
      report.source_revision,
      report.reason_artifact_digest,
      report.deterministic_scope_artifact_digest,
      report.judgment_scope_artifact_digest,
      report.judge_assessment_artifact_digest,
      report.evidence_gap_artifact_digest,
      report.expensive_check_topology_artifact_digest,
    ]) ||
    !capacity_valid {
    Err(migration_validation_error("feasibility report is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn validate_feasibility_proposal(
  proposal : MigrationFeasibilityProposal,
) -> Result[Unit, @types.ChoirError] {
  if !digest_is_valid(proposal.report_artifact_digest) {
    return Err(migration_validation_error("feasibility report is missing"))
  }
  match (proposal.outcome, proposal.proposed_contract_artifact_digest) {
    (MigrationDecline, None) => Ok(())
    (MigrationProceed, Some(digest)) if digest_is_valid(digest) => Ok(())
    (MigrationDecline, Some(_)) =>
      Err(migration_validation_error("decline cannot create a contract"))
    (MigrationProceed, None) =>
      Err(migration_validation_error("proceed requires a proposed contract"))
    _ => Err(migration_validation_error("proposed contract digest is invalid"))
  }
}

///|
pub fn validate_migration_contract(
  contract : MigrationContract,
) -> Result[Unit, @types.ChoirError] {
  let parity_valid = match contract.parity_definition_digest {
    Some(digest) => digest_is_valid(digest)
    None => true
  }
  let rehearsal_valid = match contract.rehearsal_policy {
    RehearsalNotRequired => true
    RehearsalRequired(digest) => digest_is_valid(digest)
  }
  if contract.id.0 == "" ||
    contract.migration_lineage_id.0 == "" ||
    contract.revision <= 0 ||
    !all_digests_valid([
      contract.source_revision,
      contract.feasibility_report_artifact_digest,
      contract.target_architecture_artifact_digest,
      contract.rulebook_artifact_digest,
      contract.dependency_map_artifact_digest,
      contract.gap_inventory_artifact_digest,
      contract.inventory_generator_artifact_digest,
      contract.qualified_inventory_artifact_digest,
      contract.transformation_plan_artifact_digest,
      contract.context_assembly_policy_digest,
      contract.judge_definition_digest,
      contract.judge_qualification_assurance_record_digest,
      contract.validation_plan_digest,
    ]) ||
    !parity_valid ||
    !rehearsal_valid {
    Err(migration_validation_error("contract is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn migration_contract_reference(
  contract : MigrationContract,
) -> Result[@control.MigrationContractRef, @types.ChoirError] {
  match validate_migration_contract(contract) {
    Ok(_) =>
      Ok({
        contract_id: contract.id,
        migration_lineage_id: contract.migration_lineage_id,
        revision: contract.revision,
        contract_artifact_digest: migration_contract_digest(contract),
      })
    Err(error) => Err(error)
  }
}

///|
pub fn validate_contract_acceptance(
  acceptance : MigrationContractAcceptance,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(acceptance.contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let authorization_valid = match acceptance.authorization {
    MigrationContractExplicitUserInput(digest)
    | MigrationContractPreacceptedGoalPolicy(digest) => digest_is_valid(digest)
  }
  if !authorization_valid ||
    acceptance.accepted_event_sequence.0 <= 0L ||
    acceptance.accepted_at <= 0L {
    Err(migration_validation_error("contract acceptance is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn validate_part_context_manifest(
  manifest : PartContextManifest,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(manifest.migration_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let prior_valid = match manifest.prior_take_context_digest {
    Some(digest) => digest_is_valid(digest)
    None => true
  }
  if manifest.part_task_contract_revision_id.0 == "" ||
    !all_digests_valid([
      manifest.part_task_contract_digest,
      manifest.context_assembly_policy_digest,
      manifest.dependency_neighborhood_digest,
      manifest.source_path_manifest_digest,
    ]) ||
    manifest.rulebook_section_digests.length() == 0 ||
    !all_digests_valid(manifest.rulebook_section_digests) ||
    !all_digests_valid(manifest.applicable_gap_entry_digests) ||
    !digests_are_unique(manifest.rulebook_section_digests) ||
    !digests_are_unique(manifest.applicable_gap_entry_digests) ||
    !prior_valid {
    Err(migration_validation_error("Part context manifest is invalid"))
  } else {
    Ok(())
  }
}

///|
fn finding_anchor_is_valid(anchor : MigrationFindingAnchor) -> Bool {
  match anchor {
    Rule(value) => value.0 != ""
    JudgeScenario(value) | ParityScenario(value) => value.0 != ""
    InventoryUnit(value) | OwnershipClaim(value) => value.0 != ""
    DependencyEdge(source, target) => source.0 != "" && target.0 != ""
    Contract(reference) => validate_migration_contract_ref(reference) is Ok(_)
  }
}

///|
pub fn validate_migration_finding(
  finding : MigrationFinding,
) -> Result[Unit, @types.ChoirError] {
  let expected_pattern_key = migration_finding_pattern_key(
    finding.schema_version,
    finding.class,
    finding.anchor,
  )
  if finding.schema_version != 1 ||
    finding.id.0 == "" ||
    finding.audit_take_id.0 == "" ||
    !finding_anchor_is_valid(finding.anchor) ||
    finding.pattern_key != expected_pattern_key ||
    !digest_is_valid(finding.audit_subject_digest) ||
    !digest_is_valid(finding.evidence_digest) {
    Err(migration_validation_error("finding is invalid"))
  } else {
    Ok(())
  }
}

///|
fn observation_index(
  observations : Array[MigrationFindingPatternObservation],
  key : @control.Digest,
) -> Int? {
  for index, observation in observations {
    if observation.pattern_key == key {
      return Some(index)
    }
  }
  None
}

///|
pub fn project_migration_finding_patterns(
  findings : Array[MigrationFinding],
) -> Result[Array[MigrationFindingPatternObservation], @types.ChoirError] {
  let ordered = findings.copy()
  ordered.sort_by(fn(left, right) {
    let by_pattern = left.pattern_key.compare(right.pattern_key)
    if by_pattern == 0 {
      left.id.compare(right.id)
    } else {
      by_pattern
    }
  })
  let observations : Array[MigrationFindingPatternObservation] = []
  for finding in ordered {
    match validate_migration_finding(finding) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    match observation_index(observations, finding.pattern_key) {
      Some(index) => {
        let existing = observations[index]
        if !existing.occurrence_ids.contains(finding.id) {
          observations[index] = {
            ..existing,
            occurrence_ids: existing.occurrence_ids + [finding.id],
          }
        }
      }
      None =>
        observations.push({
          pattern_key: finding.pattern_key,
          class: finding.class,
          anchor: finding.anchor,
          occurrence_ids: [finding.id],
        })
    }
  }
  Ok(observations)
}
