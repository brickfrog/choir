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
pub fn canonical_qualified_inventory_ref_bytes(
  reference : QualifiedMigrationInventoryRef,
) -> Bytes {
  canonical_fields("choir.qualified-migration-inventory-ref.v1", [
    reference.source_revision.0,
    reference.generator_digest.0,
    reference.inventory_artifact_digest.0,
    reference.canonical_inventory_digest.0,
    reference.verification_receipt_id.0,
  ])
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
