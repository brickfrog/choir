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
pub fn validate_migration_findings_artifact(
  artifact : MigrationFindingsArtifact,
) -> Result[Unit, @types.ChoirError] {
  if artifact.schema_version != 1 || artifact.findings.length() == 0 {
    return Err(migration_validation_error("findings artifact is invalid"))
  }
  let ids : Array[MigrationFindingId] = []
  for finding in artifact.findings {
    match validate_migration_finding(finding) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if ids.contains(finding.id) {
      return Err(migration_validation_error("finding identity is duplicated"))
    }
    ids.push(finding.id)
  }
  Ok(())
}

///|
pub fn decode_migration_findings_artifact(
  content : Bytes,
) -> Result[MigrationFindingsArtifact, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(migration_validation_error("findings artifact is not JSON"))
  }
  let artifact : MigrationFindingsArtifact = @json.from_json(json) catch {
    _ =>
      return Err(
        migration_validation_error("findings artifact schema is invalid"),
      )
  }
  match validate_migration_findings_artifact(artifact) {
    Ok(_) => Ok(artifact)
    Err(error) => Err(error)
  }
}

///|
pub fn project_migration_patterns_from_audit_results(
  results : Array[@control.AuditResult],
  read_artifact : (@control.ArtifactReference) -> Result[
    Bytes,
    @types.ChoirError,
  ],
) -> Result[Array[MigrationFindingPatternObservation], @types.ChoirError] {
  let findings : Array[MigrationFinding] = []
  for result in results {
    match (result.outcome, result.findings_artifact) {
      (@control.AuditOutcome::AuditPassed, None) => ()
      (@control.AuditOutcome::AuditFindings, Some(reference)) => {
        let content = match read_artifact(reference) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let observed_digest = @control.Digest(
          @crypto.bytes_to_hex_string(@crypto.sha256(content)),
        )
        if observed_digest != reference.digest {
          return Err(
            migration_validation_error("findings artifact digest is stale"),
          )
        }
        let artifact = match decode_migration_findings_artifact(content) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let mut blocking = 0
        for finding in artifact.findings {
          if finding.audit_take_id != result.audit_take_id ||
            finding.audit_subject_digest != result.subject.subject_digest {
            return Err(
              migration_validation_error("finding audit subject is stale"),
            )
          }
          if finding.severity == MigrationFindingSeverity::Blocking {
            blocking = blocking + 1
          }
          findings.push(finding)
        }
        if artifact.findings.length() != result.total_findings_count ||
          blocking != result.blocking_findings_count {
          return Err(
            migration_validation_error("finding audit counts disagree"),
          )
        }
      }
      _ =>
        return Err(
          migration_validation_error("migration audit result is invalid"),
        )
    }
  }
  project_migration_finding_patterns(findings)
}

///|
fn inventory_verification_spec_is_valid(
  spec : @control.VerificationSpec,
) -> Bool {
  spec.id.0 != "" &&
  spec.version > 0 &&
  digest_is_valid(spec.digest) &&
  digest_is_valid(spec.process_spec_digest)
}

///|
fn inventory_unit_disposition_is_valid(unit : MigrationInventoryUnit) -> Bool {
  match unit.disposition {
    Irrelevant(rule) | Mechanical(rule) =>
      rule.0 != "" && unit.transformation_rule_ids.contains(rule)
    AgentAssisted(_) => unit.proposed_verification_specs.length() > 0
    Unresolved(class) => unit.gap_classes.contains(class)
  }
}

///|
fn inventory_unit_arrays_are_unique(unit : MigrationInventoryUnit) -> Bool {
  for index, path in unit.source_paths {
    if unit.source_paths[index + 1:].contains(path) {
      return false
    }
  }
  for index, dependency in unit.dependency_keys {
    if unit.dependency_keys[index + 1:].contains(dependency) {
      return false
    }
  }
  for index, class in unit.gap_classes {
    if unit.gap_classes[index + 1:].contains(class) {
      return false
    }
  }
  for index, rule in unit.transformation_rule_ids {
    if unit.transformation_rule_ids[index + 1:].contains(rule) {
      return false
    }
  }
  for index, spec in unit.proposed_verification_specs {
    if unit.proposed_verification_specs[index + 1:].any(fn(candidate) {
        candidate.id == spec.id
      }) {
      return false
    }
  }
  true
}

///|
pub fn validate_migration_inventory(
  inventory : MigrationInventory,
  is_nfc : (String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  if inventory.schema_version != 1 ||
    inventory.source_revision.0 == "" ||
    !digest_is_valid(inventory.generator_digest) {
    return Err(migration_validation_error("migration inventory is invalid"))
  }
  let stable_keys : Array[InventoryStableKey] = []
  for unit in inventory.units {
    if unit.stable_key.0 == "" ||
      unit.stable_key.0.contains("\u{00}") ||
      unit.ownership_claim.0 == "" ||
      unit.ownership_claim.0.contains("\u{00}") ||
      unit.source_paths.length() == 0 ||
      !inventory_unit_arrays_are_unique(unit) ||
      !inventory_unit_disposition_is_valid(unit) ||
      unit.transformation_rule_ids.any(fn(rule) { rule.0 == "" }) ||
      unit.proposed_verification_specs.any(fn(spec) {
        !inventory_verification_spec_is_valid(spec)
      }) {
      return Err(
        migration_validation_error("migration inventory unit is invalid"),
      )
    }
    if stable_keys.contains(unit.stable_key) {
      return Err(
        migration_validation_error("inventory stable key is duplicated"),
      )
    }
    stable_keys.push(unit.stable_key)
    for path in unit.source_paths {
      if @control.validate_repo_path(path, is_nfc) is Err(_) {
        return Err(
          migration_validation_error("inventory source path is invalid"),
        )
      }
    }
  }
  for unit in inventory.units {
    for dependency in unit.dependency_keys {
      match dependency {
        InventoryUnitDependency(key) if key == unit.stable_key =>
          return Err(
            migration_validation_error("inventory unit depends on itself"),
          )
        InventoryUnitDependency(key) if !stable_keys.contains(key) =>
          return Err(
            migration_validation_error("inventory dependency is unresolved"),
          )
        InventoryExternalDependency(key) if key.0 == "" ||
          key.0.contains("\u{00}") =>
          return Err(
            migration_validation_error("external dependency is invalid"),
          )
        _ => ()
      }
    }
  }
  let resolved : Array[InventoryStableKey] = []
  while resolved.length() < stable_keys.length() {
    let mut progressed = false
    for unit in inventory.units {
      if resolved.contains(unit.stable_key) {
        continue
      }
      let ready = unit.dependency_keys.all(fn(dependency) {
        match dependency {
          InventoryUnitDependency(key) => resolved.contains(key)
          InventoryExternalDependency(_) => true
        }
      })
      if ready {
        resolved.push(unit.stable_key)
        progressed = true
      }
    }
    if !progressed {
      return Err(
        migration_validation_error("inventory dependency cycle exists"),
      )
    }
  }
  Ok(())
}

///|
pub fn validate_migration_inventory_two_run(
  first : MigrationInventory,
  second : MigrationInventory,
  is_nfc : (String) -> Bool,
) -> Result[@control.Digest, @types.ChoirError] {
  match validate_migration_inventory(first, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_migration_inventory(second, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if first.source_revision != second.source_revision ||
    first.generator_digest != second.generator_digest ||
    canonical_migration_inventory_bytes(first) !=
    canonical_migration_inventory_bytes(second) {
    return Err(migration_validation_error("migration inventory drifted"))
  }
  Ok(migration_inventory_digest(first))
}

///|
pub fn inventory_unit_is_initially_admissible(
  unit : MigrationInventoryUnit,
) -> Bool {
  unit.disposition is UnitDisposition::AgentAssisted(_)
}

///|
pub fn validate_qualified_migration_inventory_ref(
  reference : QualifiedMigrationInventoryRef,
) -> Result[Unit, @types.ChoirError] {
  if reference.source_revision.0 == "" ||
    !digest_is_valid(reference.generator_digest) ||
    !digest_is_valid(reference.inventory_artifact_digest) ||
    !digest_is_valid(reference.canonical_inventory_digest) ||
    !digest_is_valid(reference.execution_evidence_digest) ||
    reference.verification_receipt_id.0 == "" {
    Err(migration_validation_error("qualified inventory reference is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn qualify_migration_inventory_execution(
  first_inventory : MigrationInventory,
  second_inventory : MigrationInventory,
  first_execution : @sandbox.ProcessExecution,
  second_execution : @sandbox.ProcessExecution,
  verification_receipt_id : @control.ReceiptId,
  is_nfc : (String) -> Bool,
) -> Result[
  (QualifiedMigrationInventoryRef, MigrationInventoryExecutionEvidence),
  @types.ChoirError,
] {
  let canonical_inventory_digest = match
    validate_migration_inventory_two_run(
      first_inventory, second_inventory, is_nfc,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match @sandbox.validate_process_execution(first_execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @sandbox.validate_process_execution(second_execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  guard first_execution.disposition
    is @sandbox.ProcessExecutionDisposition::ProcessExited(
      0,
      first_output_digest
    ) &&
    second_execution.disposition
    is @sandbox.ProcessExecutionDisposition::ProcessExited(
      0,
      second_output_digest
    ) else {
    return Err(migration_validation_error("inventory generator did not pass"))
  }
  if verification_receipt_id.0 == "" ||
    first_execution.execution_id == second_execution.execution_id ||
    first_execution.validated_process_spec_digest !=
    second_execution.validated_process_spec_digest ||
    first_execution.input_artifact_set_digest !=
    second_execution.input_artifact_set_digest ||
    first_output_digest != second_output_digest {
    return Err(
      migration_validation_error("inventory execution evidence is inconsistent"),
    )
  }
  let evidence : MigrationInventoryExecutionEvidence = {
    validated_process_spec_digest: first_execution.validated_process_spec_digest,
    input_artifact_set_digest: first_execution.input_artifact_set_digest,
    first_execution_id: first_execution.execution_id,
    second_execution_id: second_execution.execution_id,
    first_inventory_artifact_digest: first_output_digest,
    second_inventory_artifact_digest: second_output_digest,
    canonical_inventory_digest,
  }
  let reference : QualifiedMigrationInventoryRef = {
    source_revision: first_inventory.source_revision,
    generator_digest: first_inventory.generator_digest,
    inventory_artifact_digest: first_output_digest,
    canonical_inventory_digest,
    execution_evidence_digest: migration_inventory_execution_evidence_digest(
      evidence,
    ),
    verification_receipt_id,
  }
  Ok((reference, evidence))
}

///|
pub fn validate_migration_judge_definition(
  definition : MigrationJudgeDefinition,
) -> Result[Unit, @types.ChoirError] {
  let substitute_oracle_invalid = match
    definition.substitute_oracle_artifact_digest {
    Some(digest) => !digest_is_valid(digest)
    None => false
  }
  if definition.schema_version != 1 ||
    definition.scenario_count <= 0 ||
    definition.negative_controls.length() == 0 ||
    !all_digests_valid([
      definition.source_revision,
      definition.excluded_surfaces_artifact_digest,
      definition.permitted_nondeterminism_artifact_digest,
    ]) ||
    substitute_oracle_invalid {
    return Err(migration_validation_error("judge definition is invalid"))
  }
  match definition.baseline_policy {
    JudgeCleanBaseline => ()
    JudgeExpectedBaselineFailures(expectations) => {
      if expectations.length() == 0 {
        return Err(
          migration_validation_error("baseline expectations are empty"),
        )
      }
      for index, expectation in expectations {
        if expectation.scenario_id.0 == "" ||
          !digest_is_valid(expectation.normalized_outcome_digest) ||
          expectations[index + 1:].any(fn(candidate) {
            candidate.scenario_id == expectation.scenario_id
          }) {
          return Err(
            migration_validation_error("baseline expectation is invalid"),
          )
        }
      }
    }
  }
  for index, control in definition.negative_controls {
    if control.scenario_id.0 == "" ||
      !digest_is_valid(control.expected_failure_digest) ||
      definition.negative_controls[index + 1:].any(fn(candidate) {
        candidate.scenario_id == control.scenario_id
      }) {
      return Err(migration_validation_error("negative control is invalid"))
    }
  }
  Ok(())
}

///|
pub fn validate_judge_qualification_report(
  definition : MigrationJudgeDefinition,
  report : JudgeQualificationReport,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_judge_definition(definition) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if report.judge_definition_digest !=
    migration_judge_definition_digest(definition) ||
    report.source_revision != definition.source_revision ||
    report.baseline_results.length() != definition.scenario_count ||
    report.goal_verification_receipt_ids.length() == 0 ||
    report.goal_audit_receipt_id.0 == "" {
    return Err(migration_validation_error("judge report binding is stale"))
  }
  for index, result in report.baseline_results {
    if result.scenario_id.0 == "" ||
      !digest_is_valid(result.normalized_outcome_digest) ||
      report.baseline_results[index + 1:].any(fn(candidate) {
        candidate.scenario_id == result.scenario_id
      }) {
      return Err(migration_validation_error("baseline result is invalid"))
    }
  }
  for index, receipt_id in report.goal_verification_receipt_ids {
    if receipt_id.0 == "" ||
      report.goal_verification_receipt_ids[index + 1:].contains(receipt_id) {
      return Err(migration_validation_error("judge receipt set is invalid"))
    }
  }
  match definition.baseline_policy {
    JudgeCleanBaseline =>
      if report.baseline_results.any(fn(result) {
          result.classification != JudgeBaselinePassed
        }) {
        return Err(migration_validation_error("source baseline is not clean"))
      }
    JudgeExpectedBaselineFailures(expectations) => {
      if report.baseline_results.length() != expectations.length() {
        return Err(migration_validation_error("source baseline is incomplete"))
      }
      for expectation in expectations {
        if !report.baseline_results.any(fn(result) {
            result.scenario_id == expectation.scenario_id &&
            result.normalized_outcome_digest ==
            expectation.normalized_outcome_digest &&
            result.classification == JudgeInheritedSourceFailure
          }) {
          return Err(migration_validation_error("source baseline drifted"))
        }
      }
    }
  }
  if report.negative_control_results.length() !=
    definition.negative_controls.length() {
    return Err(migration_validation_error("negative controls are incomplete"))
  }
  for index, result in report.negative_control_results {
    if result.scenario_id.0 == "" ||
      !digest_is_valid(result.observed_failure_digest) ||
      report.negative_control_results[index + 1:].any(fn(candidate) {
        candidate.scenario_id == result.scenario_id
      }) {
      return Err(
        migration_validation_error("negative control result is invalid"),
      )
    }
  }
  for control in definition.negative_controls {
    if !report.negative_control_results.any(fn(result) {
        result.scenario_id == control.scenario_id &&
        result.class == control.class &&
        result.observed_failure_digest == control.expected_failure_digest &&
        result.rejected
      }) {
      return Err(migration_validation_error("negative control survived"))
    }
  }
  Ok(())
}

///|
pub fn validate_judge_qualification_evidence_ref(
  reference : JudgeQualificationEvidenceRef,
) -> Result[Unit, @types.ChoirError] {
  let binding = reference.binding
  let terminal_valid = match reference.terminal {
    JudgeQualificationSucceeded(id) => id.0 != ""
    JudgeQualificationEvidenceOnlyCanceled(id) => id.0 != ""
  }
  if binding.qualifying_goal_id.0 == "" ||
    binding.goal_branch_seal_id.0 == "" ||
    !all_digests_valid([
      binding.qualifying_goal_contract_digest,
      binding.goal_branch_seal_digest,
      binding.judge_definition_digest,
      binding.source_revision,
      reference.completion_binding_digest,
      reference.assurance_record_digest,
    ]) ||
    reference.completion_binding_digest !=
    judge_qualification_binding_digest(binding) ||
    !terminal_valid {
    Err(migration_validation_error("judge qualification reference is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn validate_rehearsal_evidence_ref(
  reference : RehearsalEvidenceRef,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(reference.migration_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let binding : RehearsalBinding = {
    migration_contract_ref: reference.migration_contract_ref,
    sampled_inventory_digest: reference.sampled_inventory_digest,
  }
  if reference.rehearsal_goal_id.0 == "" ||
    reference.cancellation_summary_id.0 == "" ||
    !all_digests_valid([
      reference.sampled_inventory_digest,
      reference.completion_binding_digest,
      reference.assurance_record_digest,
    ]) ||
    reference.completion_binding_digest != rehearsal_binding_digest(binding) {
    Err(migration_validation_error("rehearsal evidence reference is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn validate_migration_production_admission_ref(
  reference : MigrationProductionAdmissionRef,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(reference.migration_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let digests = [
    reference.contract_acceptance_digest,
    reference.judge_definition_digest,
    reference.judge_qualification_report_digest,
    reference.judge_qualification_evidence_ref_digest,
  ]
  let rehearsal_invalid = match reference.rehearsal_evidence_ref_digest {
    Some(digest) => !digest_is_valid(digest)
    None => false
  }
  if !all_digests_valid(digests) || rehearsal_invalid {
    Err(migration_validation_error("production admission reference is invalid"))
  } else {
    Ok(())
  }
}

///|
fn migration_bead_kind_for_unit(
  unit : MigrationInventoryUnit,
) -> MigrationBeadKind? {
  match unit.disposition {
    AgentAssisted(reason) => Some(MigrationImplementationBead(reason))
    Unresolved(class) => Some(MigrationGapBead(class))
    Irrelevant(_) | Mechanical(_) => None
  }
}

///|
pub fn validate_migration_bead_proposal(
  proposal : MigrationBeadProposal,
  is_nfc : (String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(proposal.migration_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if proposal.stable_key.0 == "" ||
    proposal.title != "Migrate " + proposal.stable_key.0 ||
    proposal.ownership_claim.0 == "" ||
    proposal.source_paths.length() == 0 ||
    proposal.id !=
    migration_bead_id(
      proposal.migration_contract_ref,
      proposal.stable_key,
      proposal.kind,
    ) ||
    proposal.idempotency_key !=
    migration_bead_idempotency_key(
      proposal.migration_contract_ref,
      proposal.stable_key,
      proposal.kind,
    ) ||
    proposal.blocking_dependency_ids.contains(proposal.id) ||
    proposal.verification_specs.length() == 0 ||
    proposal.verification_specs.any(fn(spec) {
      !inventory_verification_spec_is_valid(spec)
    }) {
    return Err(migration_validation_error("migration Bead proposal is invalid"))
  }
  for index, dependency in proposal.blocking_dependency_ids {
    if dependency.0 == "" ||
      proposal.blocking_dependency_ids[index + 1:].contains(dependency) {
      return Err(
        migration_validation_error("migration Bead dependency is invalid"),
      )
    }
  }
  for path in proposal.source_paths {
    if @control.validate_repo_path(path, is_nfc) is Err(_) {
      return Err(migration_validation_error("migration Bead path is invalid"))
    }
  }
  Ok(())
}

///|
pub fn project_migration_bead_proposals(
  inventory : MigrationInventory,
  contract_ref : @control.MigrationContractRef,
  is_nfc : (String) -> Bool,
) -> Result[Array[MigrationBeadProposal], @types.ChoirError] {
  match validate_migration_inventory(inventory, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_migration_contract_ref(contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let proposals : Array[MigrationBeadProposal] = []
  for unit in inventory.units {
    match migration_bead_kind_for_unit(unit) {
      None => ()
      Some(kind) => {
        let idempotency_key = migration_bead_idempotency_key(
          contract_ref,
          unit.stable_key,
          kind,
        )
        proposals.push({
          id: migration_bead_id(contract_ref, unit.stable_key, kind),
          idempotency_key,
          stable_key: unit.stable_key,
          migration_contract_ref: contract_ref,
          kind,
          title: "Migrate " + unit.stable_key.0,
          ownership_claim: unit.ownership_claim,
          source_paths: unit.source_paths,
          blocking_dependency_ids: [],
          verification_specs: unit.proposed_verification_specs,
        })
      }
    }
  }
  for index = 0; index < proposals.length(); index = index + 1 {
    let unit = inventory.units.filter(fn(candidate) {
        candidate.stable_key == proposals[index].stable_key
      })[0]
    let dependencies : Array[MigrationBeadId] = []
    for dependency in unit.dependency_keys {
      match dependency {
        InventoryUnitDependency(key) =>
          for candidate in proposals {
            if candidate.stable_key == key {
              dependencies.push(candidate.id)
            }
          }
        InventoryExternalDependency(_) => ()
      }
    }
    dependencies.sort()
    proposals[index] = {
      ..proposals[index],
      blocking_dependency_ids: dependencies,
    }
  }
  proposals.sort_by(fn(left, right) { left.id.compare(right.id) })
  for proposal in proposals {
    match validate_migration_bead_proposal(proposal, is_nfc) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(proposals)
}

///|
fn migration_change_is_general(kind : MigrationChangedArtifactKind) -> Bool {
  match kind {
    ChangedJudgeDefinition
    | ChangedValidationPlan
    | ChangedSourceRevision
    | ChangedInventoryGenerator
    | ChangedDependencyMap => true
    _ => false
  }
}

///|
fn migration_change_requires_new_selection(
  kind : MigrationChangedArtifactKind,
) -> Bool {
  match kind {
    ChangedSourceRevision | ChangedInventoryGenerator | ChangedDependencyMap =>
      true
    _ => false
  }
}

///|
pub fn compute_migration_contract_revision_impact_set(
  previous_contract_ref : @control.MigrationContractRef,
  next_contract_ref : @control.MigrationContractRef,
  changes : Array[MigrationContractArtifactChange],
  parts : Array[MigrationPartRevisionDependency],
) -> Result[MigrationContractRevisionImpactSet, @types.ChoirError] {
  match validate_migration_contract_ref(previous_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_migration_contract_ref(next_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if previous_contract_ref.migration_lineage_id !=
    next_contract_ref.migration_lineage_id ||
    next_contract_ref.revision <= previous_contract_ref.revision ||
    changes.length() == 0 {
    return Err(
      migration_validation_error("contract revision lineage is invalid"),
    )
  }
  for index, change in changes {
    if !digest_is_valid(change.previous_digest) ||
      !digest_is_valid(change.next_digest) ||
      change.previous_digest == change.next_digest ||
      changes[index + 1:].any(fn(candidate) { candidate.kind == change.kind }) {
      return Err(
        migration_validation_error("contract artifact change is invalid"),
      )
    }
  }
  for index, part in parts {
    if part.part_id.0 == "" ||
      part.effective_task_contract_revision_id.0 == "" ||
      part.dependency_artifact_digests.any(fn(digest) {
        !digest_is_valid(digest)
      }) ||
      parts[index + 1:].any(fn(candidate) { candidate.part_id == part.part_id }) {
      return Err(
        migration_validation_error("Part revision dependency is invalid"),
      )
    }
  }
  let impacts : Array[MigrationPartImpact] = []
  let carried : Array[@control.RevisionId] = []
  let mut selection_changed = false
  for change in changes {
    if migration_change_requires_new_selection(change.kind) {
      selection_changed = true
    }
  }
  for part in parts {
    let reasons : Array[MigrationImpactReason] = []
    if !part.dependency_complete {
      reasons.push(MigrationUncertainDependencyImpact)
    }
    for change in changes {
      if migration_change_is_general(change.kind) {
        reasons.push(MigrationGeneralValidationImpact(change.kind))
      } else if part.dependency_artifact_digests.contains(
          change.previous_digest,
        ) {
        reasons.push(MigrationDirectArtifactImpact(change.kind))
      }
    }
    if reasons.length() > 0 {
      impacts.push({
        part_id: part.part_id,
        reasons,
        was_integrated: part.integrated,
      })
    } else {
      carried.push(part.effective_task_contract_revision_id)
    }
  }
  impacts.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
  carried.sort_by(fn(left, right) { left.compare(right) })
  let application = if selection_changed ||
    impacts.any(fn(impact) { impact.was_integrated }) {
    MigrationRevisionRequiresGoalSupersession
  } else {
    MigrationRevisionAppliesInPlace
  }
  Ok({
    previous_contract_ref,
    next_contract_ref,
    changes,
    impacted_parts: impacts,
    carried_forward_task_contract_revision_ids: carried,
    application,
  })
}

///|
pub fn migration_part_evidence_is_current(
  impact_set : MigrationContractRevisionImpactSet,
  part_id : @control.PartId,
) -> Bool {
  !impact_set.impacted_parts.any(fn(impact) { impact.part_id == part_id })
}

///|
pub fn validate_migration_supersession(
  supersession : MigrationSupersession,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(supersession.previous_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_migration_contract_ref(supersession.next_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if supersession.prior_goal_id.0 == "" ||
    supersession.previous_contract_ref.migration_lineage_id !=
    supersession.next_contract_ref.migration_lineage_id ||
    supersession.next_contract_ref.revision <=
    supersession.previous_contract_ref.revision ||
    supersession.impacted_integrated_part_ids.length() == 0 ||
    supersession.observed_goal_head.0 == "" ||
    supersession.cutoff_sequence.0 <= 0L {
    return Err(migration_validation_error("migration supersession is invalid"))
  }
  for index, part_id in supersession.impacted_integrated_part_ids {
    if part_id.0 == "" ||
      supersession.impacted_integrated_part_ids[index + 1:].contains(part_id) {
      return Err(migration_validation_error("supersession Part is invalid"))
    }
  }
  Ok(())
}

///|
pub fn validate_migration_continuation_ref(
  continuation : MigrationContinuationRef,
) -> Result[Unit, @types.ChoirError] {
  match validate_migration_contract_ref(continuation.next_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if continuation.prior_goal_id.0 == "" ||
    !digest_is_valid(continuation.supersession_artifact_digest) ||
    continuation.cancellation_summary_id.0 == "" ||
    continuation.terminal_preserved_head.0 == "" {
    Err(migration_validation_error("migration continuation is invalid"))
  } else {
    Ok(())
  }
}

///|
pub fn project_migration_status(
  inventory : MigrationInventory,
  unit_statuses : Array[MigrationUnitExecutionStatus],
  current_contract_ref : @control.MigrationContractRef,
  required_continuation_ref_digest : @control.Digest?,
  affected_part_ids : Array[@control.PartId],
  operational_counts : MigrationOperationalCounts,
  is_nfc : (String) -> Bool,
) -> Result[MigrationStatusProjection, @types.ChoirError] {
  match validate_migration_inventory(inventory, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_migration_contract_ref(current_contract_ref) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if required_continuation_ref_digest is Some(digest) &&
    !digest_is_valid(digest) {
    return Err(migration_validation_error("status continuation is invalid"))
  }
  let counts = [
    operational_counts.queued_parts,
    operational_counts.active_takes,
    operational_counts.waiting_verification_slots,
    operational_counts.running_verification_slots,
    operational_counts.invalidated_verification_slots,
  ]
  if counts.any(fn(value) { value < 0 }) {
    return Err(migration_validation_error("operational count is invalid"))
  }
  for index, part_id in affected_part_ids {
    if part_id.0 == "" || affected_part_ids[index + 1:].contains(part_id) {
      return Err(migration_validation_error("affected Part set is invalid"))
    }
  }
  for index, status in unit_statuses {
    if status.stable_key.0 == "" ||
      status.task_contract_revision_id.0 == "" ||
      unit_statuses[index + 1:].any(fn(candidate) {
        candidate.stable_key == status.stable_key
      }) ||
      validate_migration_contract_ref(status.effective_contract_ref) is Err(_) ||
      (
        status.continuation_ref_digest is Some(digest) &&
        !digest_is_valid(digest)
      ) {
      return Err(migration_validation_error("unit status is invalid"))
    }
  }
  let mut irrelevant_units = 0
  let mut mechanical_units = 0
  let mut agent_assisted_units = 0
  let mut unresolved_units = 0
  let mut integrated_units = 0
  let effective_contract_counts : Array[MigrationEffectiveContractCount] = []
  let mut missing_or_unintegrated = false
  let mut continuation_stale = false
  for unit in inventory.units {
    match unit.disposition {
      Irrelevant(_) => irrelevant_units = irrelevant_units + 1
      Mechanical(_) => mechanical_units = mechanical_units + 1
      Unresolved(_) => unresolved_units = unresolved_units + 1
      AgentAssisted(_) => {
        agent_assisted_units = agent_assisted_units + 1
        let matching = unit_statuses.filter(fn(status) {
          status.stable_key == unit.stable_key
        })
        if matching.length() != 1 || !matching[0].integrated {
          missing_or_unintegrated = true
        } else {
          let status = matching[0]
          integrated_units = integrated_units + 1
          match required_continuation_ref_digest {
            Some(digest) =>
              if status.effective_contract_ref != current_contract_ref ||
                status.continuation_ref_digest != Some(digest) {
                continuation_stale = true
              }
            None =>
              if status.continuation_ref_digest is Some(_) {
                continuation_stale = true
              }
          }
          let mut existing : Int? = None
          for index, count in effective_contract_counts {
            if count.contract_ref == status.effective_contract_ref {
              existing = Some(index)
            }
          }
          match existing {
            Some(index) =>
              effective_contract_counts[index] = {
                ..effective_contract_counts[index],
                unit_count: effective_contract_counts[index].unit_count + 1,
              }
            None =>
              effective_contract_counts.push({
                contract_ref: status.effective_contract_ref,
                unit_count: 1,
              })
          }
        }
      }
    }
  }
  effective_contract_counts.sort_by(fn(left, right) {
    let by_lineage = left.contract_ref.migration_lineage_id.compare(
      right.contract_ref.migration_lineage_id,
    )
    if by_lineage == 0 {
      left.contract_ref.revision.compare(right.contract_ref.revision)
    } else {
      by_lineage
    }
  })
  let completion = if unresolved_units > 0 {
    MigrationCompletionBlockedByUnresolvedUnits
  } else if mechanical_units > 0 {
    MigrationCompletionBlockedByUnsupportedMechanicalUnits
  } else if missing_or_unintegrated {
    MigrationCompletionBlockedByUnintegratedUnits
  } else if continuation_stale {
    MigrationCompletionBlockedByContinuation
  } else {
    MigrationCompletionReady
  }
  let next_route = match completion {
    MigrationCompletionReady => MigrationNoFurtherRoute
    MigrationCompletionBlockedByUnresolvedUnits => MigrationUserInputRoute
    MigrationCompletionBlockedByUnsupportedMechanicalUnits =>
      MigrationContractRevisionRoute
    MigrationCompletionBlockedByUnintegratedUnits => MigrationRepairRoute
    MigrationCompletionBlockedByContinuation => MigrationContinuationRoute
  }
  Ok({
    denominator: inventory.units.length(),
    irrelevant_units,
    mechanical_units,
    agent_assisted_units,
    unresolved_units,
    integrated_units,
    effective_contract_counts,
    affected_part_ids,
    operational_counts,
    next_route,
    completion,
  })
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
