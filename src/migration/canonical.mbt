///|
fn canonical_write_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(@utf8.encode(value).length().to_string())
  buffer.write_char('#')
  buffer.write_string(value)
}

///|
fn canonical_fields(domain : String, fields : Array[String]) -> Bytes {
  let buffer = StringBuilder::new()
  canonical_write_field(buffer, domain)
  canonical_write_field(buffer, fields.length().to_string())
  for field in fields {
    canonical_write_field(buffer, field)
  }
  @utf8.encode(buffer.to_string())
}

///|
fn digest_text(digest : @control.Digest) -> String {
  digest.0
}

///|
fn canonical_digest(content : Bytes) -> @control.Digest {
  @control.Digest(@crypto.bytes_to_hex_string(@crypto.sha256(content)))
}

///|
fn digest_is_valid(digest : @control.Digest) -> Bool {
  let value = digest.0
  if value.length() != 64 {
    return false
  }
  for character in value {
    if !((character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')) {
      return false
    }
  }
  true
}

///|
fn workflow_shape_tag(shape : MigrationWorkflowShape) -> String {
  match shape {
    MechanicalEvolution => "mechanical-evolution"
    StructurePreservingPort => "structure-preserving-port"
    ArchitectureRedesign => "architecture-redesign"
  }
}

///|
fn unit_granularity_tag(granularity : MigrationUnitGranularity) -> String {
  match granularity {
    FileUnit => "file"
    PackageUnit => "package"
    SubsystemUnit => "subsystem"
    SymbolUnit => "symbol"
  }
}

///|
fn feasibility_outcome_tag(outcome : MigrationFeasibilityOutcome) -> String {
  match outcome {
    MigrationProceed => "proceed"
    MigrationDecline => "decline"
  }
}

///|
fn capacity_fields(estimate : MigrationCapacityEstimate) -> Array[String] {
  match estimate {
    CapacityUnknown => ["unknown"]
    CapacityEvidenceRange(minimum, maximum, basis_digest) =>
      [
        "evidence-range",
        minimum.to_string(),
        maximum.to_string(),
        digest_text(basis_digest),
      ]
  }
}

///|
fn option_digest_fields(digest : @control.Digest?) -> Array[String] {
  match digest {
    None => ["none"]
    Some(value) => ["some", digest_text(value)]
  }
}

///|
fn sorted_digests(digests : Array[@control.Digest]) -> Array[@control.Digest] {
  let sorted = digests.copy()
  sorted.sort_by(fn(left, right) { left.compare(right) })
  sorted
}

///|
fn append_digest_array_fields(
  fields : Array[String],
  digests : Array[@control.Digest],
) -> Unit {
  let ordered = sorted_digests(digests)
  fields.push(ordered.length().to_string())
  for digest in ordered {
    fields.push(digest_text(digest))
  }
}

///|
fn append_fields(fields : Array[String], additions : Array[String]) -> Unit {
  for field in additions {
    fields.push(field)
  }
}

///|
pub fn canonical_migration_contract_ref_bytes(
  reference : @control.MigrationContractRef,
) -> Bytes {
  canonical_fields("choir.migration-contract-ref.v1", [
    reference.contract_id.0,
    reference.migration_lineage_id.0,
    reference.revision.to_string(),
    digest_text(reference.contract_artifact_digest),
  ])
}

///|
pub fn canonical_feasibility_report_bytes(
  report : MigrationFeasibilityReport,
) -> Bytes {
  let fields = [
    report.schema_version.to_string(),
    digest_text(report.source_revision),
    digest_text(report.reason_artifact_digest),
    workflow_shape_tag(report.workflow_shape),
    unit_granularity_tag(report.unit_granularity),
    report.estimated_minimum_units.to_string(),
    report.estimated_maximum_units.to_string(),
    digest_text(report.deterministic_scope_artifact_digest),
    digest_text(report.judgment_scope_artifact_digest),
    digest_text(report.judge_assessment_artifact_digest),
    digest_text(report.evidence_gap_artifact_digest),
    digest_text(report.expensive_check_topology_artifact_digest),
  ]
  append_fields(fields, capacity_fields(report.capacity_estimate))
  canonical_fields("choir.migration-feasibility-report.v1", fields)
}

///|
pub fn canonical_feasibility_proposal_bytes(
  proposal : MigrationFeasibilityProposal,
) -> Bytes {
  let fields = [
    digest_text(proposal.report_artifact_digest),
    feasibility_outcome_tag(proposal.outcome),
  ]
  append_fields(
    fields,
    option_digest_fields(proposal.proposed_contract_artifact_digest),
  )
  canonical_fields("choir.migration-feasibility-proposal.v1", fields)
}

///|
fn rehearsal_policy_fields(policy : RehearsalPolicy) -> Array[String] {
  match policy {
    RehearsalNotRequired => ["not-required"]
    RehearsalRequired(sample_digest) => ["required", digest_text(sample_digest)]
  }
}

///|
pub fn canonical_migration_contract_bytes(
  contract : MigrationContract,
) -> Bytes {
  let fields = [
    contract.id.0,
    contract.migration_lineage_id.0,
    contract.revision.to_string(),
    digest_text(contract.source_revision),
    workflow_shape_tag(contract.workflow_shape),
    digest_text(contract.feasibility_report_artifact_digest),
    digest_text(contract.target_architecture_artifact_digest),
    digest_text(contract.rulebook_artifact_digest),
    digest_text(contract.dependency_map_artifact_digest),
    digest_text(contract.gap_inventory_artifact_digest),
    digest_text(contract.inventory_generator_artifact_digest),
    digest_text(contract.qualified_inventory_artifact_digest),
    digest_text(contract.transformation_plan_artifact_digest),
    digest_text(contract.context_assembly_policy_digest),
    digest_text(contract.judge_definition_digest),
    digest_text(contract.judge_qualification_assurance_record_digest),
  ]
  append_fields(fields, option_digest_fields(contract.parity_definition_digest))
  fields.push(digest_text(contract.validation_plan_digest))
  append_fields(fields, rehearsal_policy_fields(contract.rehearsal_policy))
  canonical_fields("choir.migration-contract.v1", fields)
}

///|
fn contract_authorization_fields(
  authorization : MigrationContractAuthorization,
) -> Array[String] {
  match authorization {
    MigrationContractExplicitUserInput(digest) =>
      ["explicit-user-input", digest_text(digest)]
    MigrationContractPreacceptedGoalPolicy(digest) =>
      ["preaccepted-goal-policy", digest_text(digest)]
  }
}

///|
pub fn canonical_contract_acceptance_bytes(
  acceptance : MigrationContractAcceptance,
) -> Bytes {
  let fields = [
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(acceptance.contract_ref),
    ),
  ]
  append_fields(fields, contract_authorization_fields(acceptance.authorization))
  fields.push(acceptance.accepted_event_sequence.0.to_string())
  fields.push(acceptance.accepted_at.to_string())
  canonical_fields("choir.migration-contract-acceptance.v1", fields)
}

///|
pub fn migration_contract_acceptance_digest(
  acceptance : MigrationContractAcceptance,
) -> @control.Digest {
  canonical_digest(canonical_contract_acceptance_bytes(acceptance))
}

///|
pub fn canonical_part_context_manifest_bytes(
  manifest : PartContextManifest,
) -> Bytes {
  let fields = [
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(manifest.migration_contract_ref),
    ),
    manifest.part_task_contract_revision_id.0,
    digest_text(manifest.part_task_contract_digest),
    digest_text(manifest.context_assembly_policy_digest),
  ]
  append_digest_array_fields(fields, manifest.rulebook_section_digests)
  fields.push(digest_text(manifest.dependency_neighborhood_digest))
  append_digest_array_fields(fields, manifest.applicable_gap_entry_digests)
  fields.push(digest_text(manifest.source_path_manifest_digest))
  append_fields(
    fields,
    option_digest_fields(manifest.prior_take_context_digest),
  )
  canonical_fields("choir.part-context-manifest.v1", fields)
}

///|
fn finding_class_tag(class : MigrationFindingClass) -> String {
  match class {
    RuleViolation => "rule-violation"
    RuleGap => "rule-gap"
    JudgeFalsePositive => "judge-false-positive"
    JudgeFalseNegative => "judge-false-negative"
    InventoryOmission => "inventory-omission"
    DependencyMismatch => "dependency-mismatch"
    OwnershipMismatch => "ownership-mismatch"
    ApplicabilityMismatch => "applicability-mismatch"
    BehavioralMismatch => "behavioral-mismatch"
    UnsupportedCase => "unsupported-case"
  }
}

///|
fn finding_severity_tag(severity : MigrationFindingSeverity) -> String {
  match severity {
    Advisory => "advisory"
    Blocking => "blocking"
  }
}

///|
fn finding_disposition_tag(disposition : MigrationFindingDisposition) -> String {
  match disposition {
    RepairPart => "repair-part"
    ReviseContract => "revise-contract"
    ReviseJudge => "revise-judge"
    FollowUpGoalRequired => "follow-up-goal-required"
    AwaitUserDecision => "await-user-decision"
  }
}

///|
fn finding_anchor_fields(anchor : MigrationFindingAnchor) -> Array[String] {
  match anchor {
    Rule(rule_id) => ["rule", rule_id.0]
    JudgeScenario(scenario_id) => ["judge-scenario", scenario_id.0]
    InventoryUnit(stable_key) => ["inventory-unit", stable_key.0]
    DependencyEdge(source, target) => ["dependency-edge", source.0, target.0]
    OwnershipClaim(stable_key) => ["ownership-claim", stable_key.0]
    ParityScenario(scenario_id) => ["parity-scenario", scenario_id.0]
    Contract(reference) =>
      [
        "contract",
        @utf8.decode_lossy(canonical_migration_contract_ref_bytes(reference)),
      ]
  }
}

///|
pub fn canonical_finding_pattern_bytes(
  schema_version : Int,
  class : MigrationFindingClass,
  anchor : MigrationFindingAnchor,
) -> Bytes {
  let fields = [schema_version.to_string(), finding_class_tag(class)]
  append_fields(fields, finding_anchor_fields(anchor))
  canonical_fields("choir.migration-finding-pattern.v1", fields)
}

///|
pub fn migration_finding_pattern_key(
  schema_version : Int,
  class : MigrationFindingClass,
  anchor : MigrationFindingAnchor,
) -> @control.Digest {
  canonical_digest(
    canonical_finding_pattern_bytes(schema_version, class, anchor),
  )
}

///|
pub fn canonical_migration_finding_bytes(finding : MigrationFinding) -> Bytes {
  let fields = [
    finding.schema_version.to_string(),
    finding.id.0,
    digest_text(finding.pattern_key),
    finding_class_tag(finding.class),
    finding_severity_tag(finding.severity),
  ]
  append_fields(fields, finding_anchor_fields(finding.anchor))
  fields.push(finding.audit_take_id.0)
  fields.push(digest_text(finding.audit_subject_digest))
  fields.push(digest_text(finding.evidence_digest))
  fields.push(finding_disposition_tag(finding.disposition))
  canonical_fields("choir.migration-finding.v1", fields)
}

///|
pub fn canonical_migration_findings_artifact_bytes(
  artifact : MigrationFindingsArtifact,
) -> Bytes {
  let fields = [artifact.schema_version.to_string()]
  fields.push(artifact.findings.length().to_string())
  for finding in artifact.findings {
    fields.push(@utf8.decode_lossy(canonical_migration_finding_bytes(finding)))
  }
  canonical_fields("choir.migration-findings-artifact.v1", fields)
}

///|
fn agent_assisted_reason_tag(reason : AgentAssistedReason) -> String {
  match reason {
    SemanticJudgment => "semantic-judgment"
    CrossUnitContext => "cross-unit-context"
    ArchitecturalChoice => "architectural-choice"
    UnsupportedMechanicalTool => "unsupported-mechanical-tool"
    MechanicalQualificationFailed => "mechanical-qualification-failed"
  }
}

///|
fn unresolved_gap_class_tag(class : UnresolvedGapClass) -> String {
  match class {
    MissingRule => "missing-rule"
    AmbiguousApplicability => "ambiguous-applicability"
    MissingDependency => "missing-dependency"
    OwnershipConflict => "ownership-conflict"
    UnsupportedLanguage => "unsupported-language"
    MissingJudge => "missing-judge"
    ContextLimit => "context-limit"
  }
}

///|
fn inventory_disposition_fields(disposition : UnitDisposition) -> Array[String] {
  match disposition {
    Irrelevant(rule) => ["irrelevant", rule.0]
    Mechanical(rule) => ["mechanical", rule.0]
    AgentAssisted(reason) =>
      ["agent-assisted", agent_assisted_reason_tag(reason)]
    Unresolved(class) => ["unresolved", unresolved_gap_class_tag(class)]
  }
}

///|
fn inventory_dependency_fields(
  dependency : MigrationInventoryDependency,
) -> Array[String] {
  match dependency {
    InventoryUnitDependency(key) => ["unit", key.0]
    InventoryExternalDependency(key) => ["external", key.0]
  }
}

///|
fn canonical_inventory_dependency_text(
  dependency : MigrationInventoryDependency,
) -> String {
  @utf8.decode_lossy(
    canonical_fields(
      "choir.migration-inventory-dependency.v1",
      inventory_dependency_fields(dependency),
    ),
  )
}

///|
fn canonical_verification_spec_text(spec : @control.VerificationSpec) -> String {
  @utf8.decode_lossy(
    canonical_fields("choir.verification-spec.v1", [
      spec.id.0,
      spec.version.to_string(),
      spec.digest.0,
      spec.process_spec_digest.0,
    ]),
  )
}

///|
pub fn canonical_migration_inventory_unit_bytes(
  unit : MigrationInventoryUnit,
) -> Bytes {
  let paths = unit.source_paths.map(@control.repo_path_text)
  paths.sort()
  let dependencies = unit.dependency_keys.map(
    canonical_inventory_dependency_text,
  )
  dependencies.sort()
  let gaps = unit.gap_classes.map(unresolved_gap_class_tag)
  gaps.sort()
  let rules = unit.transformation_rule_ids.map(fn(rule) { rule.0 })
  rules.sort()
  let verification = unit.proposed_verification_specs.map(
    canonical_verification_spec_text,
  )
  verification.sort()
  let fields = [unit.stable_key.0]
  fields.push(paths.length().to_string())
  append_fields(fields, paths)
  fields.push(dependencies.length().to_string())
  append_fields(fields, dependencies)
  fields.push(unit.ownership_claim.0)
  fields.push(gaps.length().to_string())
  append_fields(fields, gaps)
  append_fields(fields, inventory_disposition_fields(unit.disposition))
  fields.push(rules.length().to_string())
  append_fields(fields, rules)
  fields.push(verification.length().to_string())
  append_fields(fields, verification)
  canonical_fields("choir.migration-inventory-unit.v1", fields)
}

///|
pub fn canonical_migration_inventory_bytes(
  inventory : MigrationInventory,
) -> Bytes {
  let units = inventory.units.map(fn(unit) {
    @utf8.decode_lossy(canonical_migration_inventory_unit_bytes(unit))
  })
  units.sort()
  let fields = [
    inventory.schema_version.to_string(),
    inventory.source_revision.0,
    inventory.generator_digest.0,
    units.length().to_string(),
  ]
  append_fields(fields, units)
  canonical_fields("choir.migration-inventory.v1", fields)
}

///|
pub fn migration_inventory_digest(
  inventory : MigrationInventory,
) -> @control.Digest {
  canonical_digest(canonical_migration_inventory_bytes(inventory))
}

///|
fn judge_negative_control_class_name(
  class : JudgeNegativeControlClass,
) -> String {
  match class {
    JudgeRuleViolationControl => "rule-violation"
    JudgeBehavioralMismatchControl => "behavioral-mismatch"
    JudgeDependencyFaultControl => "dependency-fault"
    JudgeTypeFaultControl => "type-fault"
  }
}

///|
fn judge_baseline_expectation_fields(
  expectation : JudgeBaselineExpectation,
) -> String {
  @utf8.decode_lossy(
    canonical_fields("choir.judge-baseline-expectation.v1", [
      expectation.scenario_id.0,
      expectation.normalized_outcome_digest.0,
    ]),
  )
}

///|
fn judge_baseline_policy_fields(policy : JudgeBaselinePolicy) -> Array[String] {
  match policy {
    JudgeCleanBaseline => ["clean"]
    JudgeExpectedBaselineFailures(expectations) => {
      let fields = expectations.map(judge_baseline_expectation_fields)
      fields.sort()
      ["expected-failures", fields.length().to_string()] + fields
    }
  }
}

///|
fn judge_negative_control_fields(control : JudgeNegativeControl) -> String {
  @utf8.decode_lossy(
    canonical_fields("choir.judge-negative-control.v1", [
      control.scenario_id.0,
      judge_negative_control_class_name(control.class),
      control.expected_failure_digest.0,
    ]),
  )
}

///|
pub fn canonical_migration_judge_definition_bytes(
  definition : MigrationJudgeDefinition,
) -> Bytes {
  let controls = definition.negative_controls.map(judge_negative_control_fields)
  controls.sort()
  let fields = [
      definition.schema_version.to_string(),
      definition.source_revision.0,
      definition.scenario_count.to_string(),
    ] +
    judge_baseline_policy_fields(definition.baseline_policy) +
    [controls.length().to_string()]
  append_fields(fields, controls)
  fields.push(definition.excluded_surfaces_artifact_digest.0)
  fields.push(definition.permitted_nondeterminism_artifact_digest.0)
  fields.push(
    match definition.substitute_oracle_artifact_digest {
      Some(digest) => digest.0
      None => "none"
    },
  )
  canonical_fields("choir.migration-judge-definition.v1", fields)
}

///|
pub fn migration_judge_definition_digest(
  definition : MigrationJudgeDefinition,
) -> @control.Digest {
  canonical_digest(canonical_migration_judge_definition_bytes(definition))
}

///|
fn judge_baseline_result_bytes(result : JudgeBaselineResult) -> Bytes {
  canonical_fields("choir.judge-baseline-result.v1", [
    result.scenario_id.0,
    result.normalized_outcome_digest.0,
    match result.classification {
      JudgeBaselinePassed => "passed"
      JudgeInheritedSourceFailure => "inherited-source-failure"
      JudgeEnvironmentMismatch => "environment-mismatch"
      JudgeDefect => "judge-defect"
    },
  ])
}

///|
fn judge_negative_control_result_bytes(
  result : JudgeNegativeControlResult,
) -> Bytes {
  canonical_fields("choir.judge-negative-control-result.v1", [
    result.scenario_id.0,
    judge_negative_control_class_name(result.class),
    result.observed_failure_digest.0,
    if result.rejected { "rejected" } else { "survived" },
  ])
}

///|
pub fn canonical_judge_qualification_report_bytes(
  report : JudgeQualificationReport,
) -> Bytes {
  let baseline_rows = report.baseline_results.map(fn(result) {
    @utf8.decode_lossy(judge_baseline_result_bytes(result))
  })
  let control_rows = report.negative_control_results.map(fn(result) {
    @utf8.decode_lossy(judge_negative_control_result_bytes(result))
  })
  let verification_receipts = report.goal_verification_receipt_ids.map(
    fn(receipt_id) { receipt_id.0 },
  )
  canonical_fields("choir.judge-qualification-report.v1", [
    report.judge_definition_digest.0,
    report.source_revision.0,
    @utf8.decode_lossy(
      canonical_fields("choir.judge-baseline-results.v1", baseline_rows),
    ),
    @utf8.decode_lossy(
      canonical_fields("choir.judge-negative-control-results.v1", control_rows),
    ),
    @utf8.decode_lossy(
      canonical_fields(
        "choir.judge-verification-receipt-ids.v1", verification_receipts,
      ),
    ),
    report.goal_audit_receipt_id.0,
  ])
}

///|
pub fn judge_qualification_report_digest(
  report : JudgeQualificationReport,
) -> @control.Digest {
  canonical_digest(canonical_judge_qualification_report_bytes(report))
}

///|
pub fn canonical_qualified_inventory_ref_bytes(
  reference : QualifiedMigrationInventoryRef,
) -> Bytes {
  canonical_fields("choir.qualified-migration-inventory-ref.v1", [
    reference.source_revision.0,
    reference.generator_digest.0,
    reference.inventory_artifact_digest.0,
    reference.canonical_inventory_digest.0,
    reference.execution_evidence_digest.0,
    reference.verification_receipt_id.0,
  ])
}

///|
pub fn canonical_migration_inventory_execution_evidence_bytes(
  evidence : MigrationInventoryExecutionEvidence,
) -> Bytes {
  canonical_fields("choir.migration-inventory-execution-evidence.v1", [
    evidence.validated_process_spec_digest.0,
    evidence.input_artifact_set_digest.0,
    evidence.first_execution_id.0,
    evidence.second_execution_id.0,
    evidence.first_inventory_artifact_digest.0,
    evidence.second_inventory_artifact_digest.0,
    evidence.canonical_inventory_digest.0,
  ])
}

///|
pub fn migration_inventory_execution_evidence_digest(
  evidence : MigrationInventoryExecutionEvidence,
) -> @control.Digest {
  canonical_digest(
    canonical_migration_inventory_execution_evidence_bytes(evidence),
  )
}

///|
pub fn canonical_judge_qualification_binding_bytes(
  binding : JudgeQualificationBinding,
) -> Bytes {
  canonical_fields("choir.judge-qualification-binding.v1", [
    binding.qualifying_goal_id.0,
    binding.qualifying_goal_contract_digest.0,
    binding.goal_branch_seal_id.0,
    binding.goal_branch_seal_digest.0,
    binding.judge_definition_digest.0,
    binding.source_revision.0,
  ])
}

///|
pub fn judge_qualification_binding_digest(
  binding : JudgeQualificationBinding,
) -> @control.Digest {
  canonical_digest(canonical_judge_qualification_binding_bytes(binding))
}

///|
fn judge_qualification_terminal_fields(
  terminal : JudgeQualificationTerminal,
) -> Array[String] {
  match terminal {
    JudgeQualificationSucceeded(id) => ["succeeded", id.0]
    JudgeQualificationEvidenceOnlyCanceled(id) =>
      ["evidence-only-canceled", id.0]
  }
}

///|
pub fn canonical_judge_qualification_evidence_ref_bytes(
  reference : JudgeQualificationEvidenceRef,
) -> Bytes {
  let fields = [
    @utf8.decode_lossy(
      canonical_judge_qualification_binding_bytes(reference.binding),
    ),
    reference.completion_binding_digest.0,
    reference.assurance_record_digest.0,
  ]
  append_fields(fields, judge_qualification_terminal_fields(reference.terminal))
  canonical_fields("choir.judge-qualification-evidence-ref.v1", fields)
}

///|
pub fn judge_qualification_evidence_ref_digest(
  reference : JudgeQualificationEvidenceRef,
) -> @control.Digest {
  canonical_digest(canonical_judge_qualification_evidence_ref_bytes(reference))
}

///|
pub fn canonical_rehearsal_binding_bytes(binding : RehearsalBinding) -> Bytes {
  canonical_fields("choir.rehearsal-binding.v1", [
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(binding.migration_contract_ref),
    ),
    binding.sampled_inventory_digest.0,
  ])
}

///|
pub fn rehearsal_binding_digest(binding : RehearsalBinding) -> @control.Digest {
  canonical_digest(canonical_rehearsal_binding_bytes(binding))
}

///|
pub fn canonical_rehearsal_evidence_ref_bytes(
  reference : RehearsalEvidenceRef,
) -> Bytes {
  canonical_fields("choir.rehearsal-evidence-ref.v1", [
    reference.rehearsal_goal_id.0,
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(reference.migration_contract_ref),
    ),
    reference.sampled_inventory_digest.0,
    reference.completion_binding_digest.0,
    reference.assurance_record_digest.0,
    reference.cancellation_summary_id.0,
  ])
}

///|
pub fn rehearsal_evidence_ref_digest(
  reference : RehearsalEvidenceRef,
) -> @control.Digest {
  canonical_digest(canonical_rehearsal_evidence_ref_bytes(reference))
}

///|
pub fn canonical_migration_production_admission_ref_bytes(
  reference : MigrationProductionAdmissionRef,
) -> Bytes {
  canonical_fields("choir.migration-production-admission-ref.v1", [
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(reference.migration_contract_ref),
    ),
    reference.contract_acceptance_digest.0,
    reference.judge_definition_digest.0,
    reference.judge_qualification_report_digest.0,
    reference.judge_qualification_evidence_ref_digest.0,
    match reference.rehearsal_evidence_ref_digest {
      Some(digest) => digest.0
      None => "none"
    },
  ])
}

///|
pub fn migration_production_admission_ref_digest(
  reference : MigrationProductionAdmissionRef,
) -> @control.Digest {
  canonical_digest(canonical_migration_production_admission_ref_bytes(reference))
}

///|
fn migration_bead_kind_fields(kind : MigrationBeadKind) -> Array[String] {
  match kind {
    MigrationImplementationBead(reason) =>
      ["implementation", agent_assisted_reason_tag(reason)]
    MigrationGapBead(class) => ["gap", unresolved_gap_class_tag(class)]
  }
}

///|
fn migration_bead_scope_fields(scope : MigrationBeadScope) -> Array[String] {
  match scope {
    MigrationProductionBead => ["production"]
    MigrationRehearsalBead(sample_digest) => ["rehearsal", sample_digest.0]
  }
}

///|
pub fn migration_bead_idempotency_key(
  reference : @control.MigrationContractRef,
  stable_key : InventoryStableKey,
  scope : MigrationBeadScope,
  kind : MigrationBeadKind,
) -> @control.Digest {
  let fields = [
    @utf8.decode_lossy(canonical_migration_contract_ref_bytes(reference)),
    stable_key.0,
  ]
  append_fields(fields, migration_bead_scope_fields(scope))
  append_fields(fields, migration_bead_kind_fields(kind))
  canonical_digest(
    canonical_fields("choir.migration-bead-idempotency.v2", fields),
  )
}

///|
pub fn migration_bead_id(
  reference : @control.MigrationContractRef,
  stable_key : InventoryStableKey,
  scope : MigrationBeadScope,
  kind : MigrationBeadKind,
) -> MigrationBeadId {
  let digest = migration_bead_idempotency_key(
    reference,
    stable_key,
    scope,
    kind,
  )
  MigrationBeadId("choir-mig-" + digest.0[0:24].to_owned())
}

///|
pub fn canonical_migration_bead_proposal_bytes(
  proposal : MigrationBeadProposal,
) -> Bytes {
  let paths = proposal.source_paths.map(@control.repo_path_text)
  paths.sort()
  let dependencies = proposal.blocking_dependency_ids.map(fn(id) { id.0 })
  dependencies.sort()
  let verification = proposal.verification_specs.map(
    canonical_verification_spec_text,
  )
  verification.sort()
  let fields = [
    proposal.id.0,
    proposal.idempotency_key.0,
    proposal.stable_key.0,
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(proposal.migration_contract_ref),
    ),
  ]
  append_fields(fields, migration_bead_scope_fields(proposal.scope))
  append_fields(fields, migration_bead_kind_fields(proposal.kind))
  fields.push(proposal.title)
  fields.push(proposal.ownership_claim.0)
  fields.push(paths.length().to_string())
  append_fields(fields, paths)
  fields.push(dependencies.length().to_string())
  append_fields(fields, dependencies)
  fields.push(verification.length().to_string())
  append_fields(fields, verification)
  canonical_fields("choir.migration-bead-proposal.v2", fields)
}

///|
fn changed_artifact_kind_tag(kind : MigrationChangedArtifactKind) -> String {
  match kind {
    ChangedRulebook => "rulebook"
    ChangedJudgeDefinition => "judge-definition"
    ChangedDependencyMap => "dependency-map"
    ChangedInventoryGenerator => "inventory-generator"
    ChangedSourceRevision => "source-revision"
    ChangedContextAssemblyPolicy => "context-assembly-policy"
    ChangedValidationPlan => "validation-plan"
    ChangedGapInventory => "gap-inventory"
    ChangedTransformationPlan => "transformation-plan"
  }
}

///|
fn impact_reason_fields(reason : MigrationImpactReason) -> Array[String] {
  match reason {
    MigrationDirectArtifactImpact(kind) =>
      ["direct", changed_artifact_kind_tag(kind)]
    MigrationGeneralValidationImpact(kind) =>
      ["general", changed_artifact_kind_tag(kind)]
    MigrationUncertainDependencyImpact => ["uncertain"]
  }
}

///|
fn canonical_artifact_change_text(
  change : MigrationContractArtifactChange,
) -> String {
  @utf8.decode_lossy(
    canonical_fields("choir.migration-artifact-change.v1", [
      changed_artifact_kind_tag(change.kind),
      change.previous_digest.0,
      change.next_digest.0,
    ]),
  )
}

///|
fn canonical_part_impact_text(impact : MigrationPartImpact) -> String {
  let reasons = impact.reasons.map(fn(reason) {
    let fields = impact_reason_fields(reason)
    canonical_fields("choir.migration-impact-reason.v1", fields)
    |> @utf8.decode_lossy
  })
  reasons.sort()
  let fields = [impact.part_id.0, impact.was_integrated.to_string()]
  fields.push(reasons.length().to_string())
  append_fields(fields, reasons)
  @utf8.decode_lossy(canonical_fields("choir.migration-part-impact.v1", fields))
}

///|
pub fn canonical_contract_revision_impact_set_bytes(
  impact_set : MigrationContractRevisionImpactSet,
) -> Bytes {
  let changes = impact_set.changes.map(canonical_artifact_change_text)
  changes.sort()
  let impacts = impact_set.impacted_parts.map(canonical_part_impact_text)
  impacts.sort()
  let carried = impact_set.carried_forward_task_contract_revision_ids.map(fn(
    id,
  ) {
    id.0
  })
  carried.sort()
  let fields = [
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(impact_set.previous_contract_ref),
    ),
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(impact_set.next_contract_ref),
    ),
    changes.length().to_string(),
  ]
  append_fields(fields, changes)
  fields.push(impacts.length().to_string())
  append_fields(fields, impacts)
  fields.push(carried.length().to_string())
  append_fields(fields, carried)
  fields.push(
    match impact_set.application {
      MigrationRevisionAppliesInPlace => "in-place"
      MigrationRevisionRequiresGoalSupersession => "supersession"
    },
  )
  canonical_fields("choir.migration-contract-revision-impact-set.v1", fields)
}

///|
pub fn contract_revision_impact_set_digest(
  impact_set : MigrationContractRevisionImpactSet,
) -> @control.Digest {
  canonical_digest(canonical_contract_revision_impact_set_bytes(impact_set))
}

///|
pub fn canonical_migration_supersession_bytes(
  supersession : MigrationSupersession,
) -> Bytes {
  let parts = supersession.impacted_integrated_part_ids.map(fn(id) { id.0 })
  parts.sort()
  let fields = [
    supersession.prior_goal_id.0,
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(supersession.previous_contract_ref),
    ),
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(supersession.next_contract_ref),
    ),
    parts.length().to_string(),
  ]
  append_fields(fields, parts)
  fields.push(supersession.observed_goal_head.0)
  fields.push(supersession.cutoff_sequence.0.to_string())
  canonical_fields("choir.migration-supersession.v1", fields)
}

///|
pub fn migration_supersession_digest(
  supersession : MigrationSupersession,
) -> @control.Digest {
  canonical_digest(canonical_migration_supersession_bytes(supersession))
}

///|
pub fn canonical_migration_continuation_ref_bytes(
  continuation : MigrationContinuationRef,
) -> Bytes {
  canonical_fields("choir.migration-continuation-ref.v1", [
    continuation.prior_goal_id.0,
    continuation.supersession_artifact_digest.0,
    continuation.cancellation_summary_id.0,
    continuation.terminal_preserved_head.0,
    @utf8.decode_lossy(
      canonical_migration_contract_ref_bytes(continuation.next_contract_ref),
    ),
  ])
}

///|
pub fn migration_continuation_ref_digest(
  continuation : MigrationContinuationRef,
) -> @control.Digest {
  canonical_digest(canonical_migration_continuation_ref_bytes(continuation))
}

///|
pub fn migration_contract_digest(
  contract : MigrationContract,
) -> @control.Digest {
  canonical_digest(canonical_migration_contract_bytes(contract))
}

///|
pub fn part_context_manifest_digest(
  manifest : PartContextManifest,
) -> @control.Digest {
  canonical_digest(canonical_part_context_manifest_bytes(manifest))
}
