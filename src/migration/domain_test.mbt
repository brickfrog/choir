///|
let migration_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let migration_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
let migration_digest_c : @control.Digest = @control.Digest(
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
)

///|
fn migration_contract_ref_fixture() -> @control.MigrationContractRef {
  {
    contract_id: @control.MigrationContractId("contract-1"),
    migration_lineage_id: @control.MigrationLineageId("lineage-1"),
    revision: 2,
    contract_artifact_digest: migration_digest_a,
  }
}

///|
fn migration_report_fixture() -> @migration.MigrationFeasibilityReport {
  {
    schema_version: 1,
    source_revision: migration_digest_a,
    reason_artifact_digest: migration_digest_b,
    workflow_shape: @migration.MigrationWorkflowShape::StructurePreservingPort,
    unit_granularity: @migration.MigrationUnitGranularity::PackageUnit,
    estimated_minimum_units: 4,
    estimated_maximum_units: 9,
    deterministic_scope_artifact_digest: migration_digest_a,
    judgment_scope_artifact_digest: migration_digest_b,
    judge_assessment_artifact_digest: migration_digest_c,
    evidence_gap_artifact_digest: migration_digest_a,
    expensive_check_topology_artifact_digest: migration_digest_b,
    capacity_estimate: @migration.MigrationCapacityEstimate::CapacityEvidenceRange(
      2, 6, migration_digest_c,
    ),
  }
}

///|
fn migration_contract_fixture() -> @migration.MigrationContract {
  {
    id: @control.MigrationContractId("contract-1"),
    migration_lineage_id: @control.MigrationLineageId("lineage-1"),
    revision: 2,
    source_revision: migration_digest_a,
    workflow_shape: @migration.MigrationWorkflowShape::StructurePreservingPort,
    feasibility_report_artifact_digest: migration_digest_b,
    target_architecture_artifact_digest: migration_digest_c,
    rulebook_artifact_digest: migration_digest_a,
    dependency_map_artifact_digest: migration_digest_b,
    gap_inventory_artifact_digest: migration_digest_c,
    inventory_generator_artifact_digest: migration_digest_a,
    qualified_inventory_artifact_digest: migration_digest_b,
    transformation_plan_artifact_digest: migration_digest_c,
    context_assembly_policy_digest: migration_digest_a,
    judge_definition_digest: migration_digest_b,
    judge_qualification_assurance_record_digest: migration_digest_c,
    parity_definition_digest: None,
    validation_plan_digest: migration_digest_a,
    rehearsal_policy: @migration.RehearsalPolicy::RehearsalRequired(
      migration_digest_b,
    ),
  }
}

///|
fn context_manifest_fixture() -> @migration.PartContextManifest {
  {
    migration_contract_ref: migration_contract_ref_fixture(),
    part_task_contract_revision_id: @control.RevisionId("part-revision-7"),
    part_task_contract_digest: migration_digest_b,
    context_assembly_policy_digest: migration_digest_c,
    rulebook_section_digests: [migration_digest_c, migration_digest_a],
    dependency_neighborhood_digest: migration_digest_b,
    applicable_gap_entry_digests: [migration_digest_b],
    source_path_manifest_digest: migration_digest_c,
    prior_take_context_digest: Some(migration_digest_a),
  }
}

///|
fn finding_fixture(
  id : String,
  take_id : String,
  evidence : @control.Digest,
) -> @migration.MigrationFinding {
  let anchor = @migration.MigrationFindingAnchor::Rule(
    @migration.MigrationRuleId("imports-no-host-io"),
  )
  {
    schema_version: 1,
    id: @migration.MigrationFindingId(id),
    pattern_key: @migration.migration_finding_pattern_key(
      1,
      @migration.MigrationFindingClass::RuleViolation,
      anchor,
    ),
    class: @migration.MigrationFindingClass::RuleViolation,
    severity: @migration.MigrationFindingSeverity::Blocking,
    anchor,
    audit_take_id: @control.TakeId(take_id),
    audit_subject_digest: migration_digest_b,
    evidence_digest: evidence,
    disposition: @migration.MigrationFindingDisposition::ReviseContract,
  }
}

///|
fn audit_subject_fixture(
  take_id : String,
  subject_digest : @control.Digest,
) -> @control.PartAuditSubject {
  {
    part_id: @control.PartId("part-1"),
    candidate_take_id: @control.TakeId(take_id),
    candidate_commit_oid: @control.GitOid("commit-1"),
    candidate_tree_oid: @control.GitOid("tree-1"),
    task_contract_revision_id: @control.RevisionId("revision-1"),
    task_contract_digest: migration_digest_a,
    verification_receipt_set_digest: migration_digest_b,
    verification_evidence_manifest_digest: migration_digest_c,
    subject_digest,
  }
}

///|
fn audit_result_fixture(
  id : String,
  take_id : String,
  subject_digest : @control.Digest,
  findings_artifact : @control.ArtifactReference,
  total : Int,
  blocking : Int,
) -> @control.AuditResult {
  {
    id: @control.AuditResultId(id),
    audit_take_id: @control.TakeId(take_id),
    take_fencing_epoch: @control.FencingEpoch(1L),
    audit_harness_session_id: @control.HarnessSessionId("session-" + id),
    subject: audit_subject_fixture(take_id, subject_digest),
    auditor_capability_profile_digest: migration_digest_a,
    effective_surface_manifest_digest: migration_digest_b,
    provider_conformance_report_digest: migration_digest_c,
    audit_policy_digest: migration_digest_a,
    findings_artifact: Some(findings_artifact),
    total_findings_count: total,
    blocking_findings_count: blocking,
    started_at: 1L,
    finished_at: 2L,
    outcome: @control.AuditOutcome::AuditFindings,
    result_digest: migration_digest_b,
  }
}

///|
test "migration domain canonical byte fixtures are explicit and versioned" {
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_migration_contract_ref_bytes(
        migration_contract_ref_fixture(),
      ),
    ),
    content="31#choir.migration-contract-ref.v11#410#contract-19#lineage-11#264#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_feasibility_report_bytes(migration_report_fixture()),
    ),
    content="37#choir.migration-feasibility-report.v12#161#164#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb25#structure-preserving-port7#package1#41#964#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc64#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb14#evidence-range1#21#664#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_feasibility_proposal_bytes({
        report_artifact_digest: migration_digest_a,
        outcome: @migration.MigrationFeasibilityOutcome::MigrationProceed,
        proposed_contract_artifact_digest: Some(migration_digest_b),
      }),
    ),
    content="39#choir.migration-feasibility-proposal.v11#464#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa7#proceed4#some64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_migration_contract_bytes(
        migration_contract_fixture(),
      ),
    ),
    content="27#choir.migration-contract.v12#2010#contract-19#lineage-11#264#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa25#structure-preserving-port64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc64#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc64#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc64#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc4#none64#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8#required64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_contract_acceptance_bytes({
        contract_ref: migration_contract_ref_fixture(),
        authorization: @migration.MigrationContractAuthorization::MigrationContractExplicitUserInput(
          migration_digest_b,
        ),
        accepted_event_sequence: @control.EventSequence(8L),
        accepted_at: 42L,
      }),
    ),
    content="38#choir.migration-contract-acceptance.v11#5131#31#choir.migration-contract-ref.v11#410#contract-19#lineage-11#264#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa19#explicit-user-input64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1#82#42",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_part_context_manifest_bytes(
        context_manifest_fixture(),
      ),
    ),
    content="30#choir.part-context-manifest.v12#13131#31#choir.migration-contract-ref.v11#410#contract-19#lineage-11#264#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa15#part-revision-764#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc1#264#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc64#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1#164#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc4#some64#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_migration_finding_bytes(
        finding_fixture("finding-1", "audit-1", migration_digest_c),
      ),
    ),
    content="26#choir.migration-finding.v12#111#19#finding-164#ab7efb844b76423963ac36b7e2de64fd349eb77c438cda66dccb4d09fc2fd41114#rule-violation8#blocking4#rule18#imports-no-host-io7#audit-164#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc15#revise-contract",
  )
  inspect(
    @utf8.decode_lossy(
      @migration.canonical_migration_findings_artifact_bytes({
        schema_version: 1,
        findings: [finding_fixture("finding-1", "audit-1", migration_digest_c)],
      }),
    ),
    content="36#choir.migration-findings-artifact.v11#31#11#1329#26#choir.migration-finding.v12#111#19#finding-164#ab7efb844b76423963ac36b7e2de64fd349eb77c438cda66dccb4d09fc2fd41114#rule-violation8#blocking4#rule18#imports-no-host-io7#audit-164#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb64#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc15#revise-contract",
  )
}

///|
test "declining feasibility creates no migration contract" {
  let declined : @migration.MigrationFeasibilityProposal = {
    report_artifact_digest: migration_digest_a,
    outcome: @migration.MigrationFeasibilityOutcome::MigrationDecline,
    proposed_contract_artifact_digest: None,
  }
  assert_true(@migration.validate_feasibility_proposal(declined) is Ok(_))
  assert_true(
    @migration.validate_feasibility_proposal({
      ..declined,
      proposed_contract_artifact_digest: Some(migration_digest_b),
    })
    is Err(_),
  )
}

///|
test "migration contract reference binds canonical contract bytes" {
  let contract = migration_contract_fixture()
  let reference = @migration.migration_contract_reference(contract).unwrap()
  assert_eq(reference.contract_id, contract.id)
  assert_eq(reference.migration_lineage_id, contract.migration_lineage_id)
  assert_eq(reference.revision, contract.revision)
  assert_eq(
    reference.contract_artifact_digest,
    @migration.migration_contract_digest(contract),
  )
}

///|
test "finding patterns deduplicate occurrences but preserve anchors" {
  let first = finding_fixture("finding-1", "audit-1", migration_digest_a)
  let second = finding_fixture("finding-2", "audit-2", migration_digest_c)
  let other_anchor = @migration.MigrationFindingAnchor::Rule(
    @migration.MigrationRuleId("different-rule"),
  )
  let third = {
    ..second,
    id: @migration.MigrationFindingId("finding-3"),
    anchor: other_anchor,
    pattern_key: @migration.migration_finding_pattern_key(
      1,
      @migration.MigrationFindingClass::RuleViolation,
      other_anchor,
    ),
  }
  let projected = @migration.project_migration_finding_patterns([
    second, third, first,
  ]).unwrap()
  assert_eq(projected.length(), 2)
  assert_true(
    projected.any(fn(observation) {
      observation.pattern_key == first.pattern_key &&
      observation.occurrence_ids == [first.id, second.id]
    }),
  )
}

///|
test "finding patterns project from persisted audit artifacts across restart" {
  let first = finding_fixture("finding-1", "audit-1", migration_digest_a)
  let second = {
    ..first,
    id: @migration.MigrationFindingId("finding-2"),
    audit_take_id: @control.TakeId("audit-2"),
    evidence_digest: migration_digest_c,
  }
  let first_content = @utf8.encode(
    (
      { schema_version: 1, findings: [first] } :
      @migration.MigrationFindingsArtifact)
    .to_json()
    .stringify(indent=0),
  )
  let second_content = @utf8.encode(
    (
      { schema_version: 1, findings: [second] } :
      @migration.MigrationFindingsArtifact)
    .to_json()
    .stringify(indent=0),
  )
  let first_reference : @control.ArtifactReference = {
    artifact_id: "findings-1",
    digest: digest_generated_text(@utf8.decode_lossy(first_content)),
  }
  let second_reference : @control.ArtifactReference = {
    artifact_id: "findings-2",
    digest: digest_generated_text(@utf8.decode_lossy(second_content)),
  }
  let persisted = [
      audit_result_fixture(
        "result-1", "audit-1", migration_digest_b, first_reference, 1, 1,
      ),
      audit_result_fixture(
        "result-2", "audit-2", migration_digest_b, second_reference, 1, 1,
      ),
    ]
    .to_json()
    .stringify(indent=0)
  let restarted : Array[@control.AuditResult] = @json.from_json(
    @json.parse(persisted),
  )
  let projected = @migration.project_migration_patterns_from_audit_results(
    restarted,
    fn(reference) {
      if reference == first_reference {
        Ok(first_content)
      } else if reference == second_reference {
        Ok(second_content)
      } else {
        Err(@types.ChoirError::validation_error("artifact is missing"))
      }
    },
  ).unwrap()
  assert_eq(projected.length(), 1)
  assert_eq(projected[0].occurrence_ids, [first.id, second.id])
  let stale_result = {
    ..restarted[0],
    findings_artifact: Some({ ..first_reference, digest: migration_digest_c }),
  }
  assert_true(
    @migration.project_migration_patterns_from_audit_results([stale_result], fn(
      _,
    ) {
      Ok(first_content)
    })
    is Err(_),
  )
}

///|
fn digest_generated_text(value : String) -> @control.Digest {
  @control.Digest(
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(value))),
  )
}

///|
test "property: context encoding canonicalizes unordered digest sets" {
  @quickcheck.quick_check_fn(
    fn(values : Array[String]) -> Bool {
      let digests = values.map(digest_generated_text)
      let reversed = digests.rev()
      let left = {
        ..context_manifest_fixture(),
        rulebook_section_digests: digests,
        applicable_gap_entry_digests: reversed,
      }
      let right = {
        ..left,
        rulebook_section_digests: reversed,
        applicable_gap_entry_digests: digests,
      }
      @migration.canonical_part_context_manifest_bytes(left) ==
      @migration.canonical_part_context_manifest_bytes(right)
    },
    max_success=128,
    max_size=32,
  )
}

///|
test "property: finding projection excludes occurrence identity" {
  @quickcheck.quick_check_fn(
    fn(values : (String, String, String)) -> Bool {
      let (left_id, right_id, evidence_seed) = values
      let left = finding_fixture(
        "left-" + left_id,
        "left-take-" + left_id,
        digest_generated_text("left-" + evidence_seed),
      )
      let right = finding_fixture(
        "right-" + right_id,
        "right-take-" + right_id,
        digest_generated_text("right-" + evidence_seed),
      )
      match @migration.project_migration_finding_patterns([right, left]) {
        Ok([observation]) =>
          observation.pattern_key == left.pattern_key &&
          observation.occurrence_ids.length() == 2
        _ => false
      }
    },
    max_success=128,
    max_size=32,
  )
}

///|
test "property: findings canonical bytes ignore diagnostic JSON round trip" {
  @quickcheck.quick_check_fn(
    fn(values : (String, String)) -> Bool {
      let (id_seed, evidence_seed) = values
      let artifact : @migration.MigrationFindingsArtifact = {
        schema_version: 1,
        findings: [
          finding_fixture(
            "finding-" + id_seed,
            "take-" + id_seed,
            digest_generated_text(evidence_seed),
          ),
        ],
      }
      let diagnostic = artifact.to_json().stringify(indent=2)
      let json = @json.parse(diagnostic) catch { _ => return false }
      let decoded : @migration.MigrationFindingsArtifact = @json.from_json(json) catch {
        _ => return false
      }
      @migration.canonical_migration_findings_artifact_bytes(artifact) ==
      @migration.canonical_migration_findings_artifact_bytes(decoded)
    },
    max_success=128,
    max_size=32,
  )
}
