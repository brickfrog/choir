///|
enum NativeMigrationFindingClass {
  RuleViolation
  RuleGap
  JudgeFalsePositive
  JudgeFalseNegative
  InventoryOmission
  DependencyMismatch
  OwnershipMismatch
  ApplicabilityMismatch
  BehavioralMismatch
  UnsupportedCase
} derive(Debug, Eq, FromJson)

///|
enum NativeMigrationFindingSeverity {
  Advisory
  Blocking
} derive(Debug, Eq, FromJson)

///|
enum NativeMigrationFindingDisposition {
  RepairPart
  ReviseContract
  ReviseJudge
  FollowUpGoalRequired
  AwaitUserDecision
} derive(Debug, Eq, FromJson)

///|
enum NativeMigrationFindingAnchorKind {
  Rule
  JudgeScenario
  InventoryUnit
  DependencyEdge
  OwnershipClaim
  ParityScenario
  Contract
} derive(Debug, Eq, FromJson)

///|
struct NativeMigrationFindingOutput {
  class : NativeMigrationFindingClass
  severity : NativeMigrationFindingSeverity
  anchor_kind : NativeMigrationFindingAnchorKind
  anchor_primary : String
  anchor_secondary : String?
  evidence : String
  disposition : NativeMigrationFindingDisposition
} derive(Debug, Eq, FromJson)

///|
struct NativeAuditStructuredOutput {
  outcome : String
  total_findings : Int
  blocking_findings : Int
  migration_findings : Array[NativeMigrationFindingOutput]?
} derive(Debug, Eq, FromJson)

///|
fn native_migration_finding_output_schema() -> Json {
  {
    "type": "object".to_json(),
    "properties": {
      "class": {
        "type": "string".to_json(),
        "enum": [
          "RuleViolation", "RuleGap", "JudgeFalsePositive", "JudgeFalseNegative",
          "InventoryOmission", "DependencyMismatch", "OwnershipMismatch", "ApplicabilityMismatch",
          "BehavioralMismatch", "UnsupportedCase",
        ].to_json(),
      }.to_json(),
      "severity": {
        "type": "string".to_json(),
        "enum": ["Advisory", "Blocking"].to_json(),
      }.to_json(),
      "anchor_kind": {
        "type": "string".to_json(),
        "enum": [
          "Rule", "JudgeScenario", "InventoryUnit", "DependencyEdge", "OwnershipClaim",
          "ParityScenario", "Contract",
        ].to_json(),
      }.to_json(),
      "anchor_primary": { "type": "string".to_json() }.to_json(),
      "anchor_secondary": { "type": "string".to_json() }.to_json(),
      "evidence": { "type": "string".to_json() }.to_json(),
      "disposition": {
        "type": "string".to_json(),
        "enum": [
          "RepairPart", "ReviseContract", "ReviseJudge", "FollowUpGoalRequired",
          "AwaitUserDecision",
        ].to_json(),
      }.to_json(),
    }.to_json(),
    "required": [
      "class", "severity", "anchor_kind", "anchor_primary", "evidence", "disposition",
    ].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
}

///|
fn native_migration_findings_output_schema() -> Json {
  {
    "type": "array".to_json(),
    "items": native_migration_finding_output_schema(),
  }.to_json()
}

///|
fn native_migration_audit_output_instruction() -> String {
  " For a migration Part, also return migration_findings with one typed entry per finding. Use the exact enum labels from the output schema, anchor the concrete rule, scenario, inventory unit, dependency edge, ownership claim, parity scenario, or accepted Contract, and include bounded evidence text. Return an empty migration_findings array when clean."
}

///|
fn native_migration_finding_class(
  value : NativeMigrationFindingClass,
) -> @migration.MigrationFindingClass {
  match value {
    RuleViolation => @migration.MigrationFindingClass::RuleViolation
    RuleGap => @migration.MigrationFindingClass::RuleGap
    JudgeFalsePositive => @migration.MigrationFindingClass::JudgeFalsePositive
    JudgeFalseNegative => @migration.MigrationFindingClass::JudgeFalseNegative
    InventoryOmission => @migration.MigrationFindingClass::InventoryOmission
    DependencyMismatch => @migration.MigrationFindingClass::DependencyMismatch
    OwnershipMismatch => @migration.MigrationFindingClass::OwnershipMismatch
    ApplicabilityMismatch =>
      @migration.MigrationFindingClass::ApplicabilityMismatch
    BehavioralMismatch => @migration.MigrationFindingClass::BehavioralMismatch
    UnsupportedCase => @migration.MigrationFindingClass::UnsupportedCase
  }
}

///|
fn native_migration_finding_severity(
  value : NativeMigrationFindingSeverity,
) -> @migration.MigrationFindingSeverity {
  match value {
    Advisory => @migration.MigrationFindingSeverity::Advisory
    Blocking => @migration.MigrationFindingSeverity::Blocking
  }
}

///|
fn native_migration_finding_disposition(
  value : NativeMigrationFindingDisposition,
) -> @migration.MigrationFindingDisposition {
  match value {
    RepairPart => @migration.MigrationFindingDisposition::RepairPart
    ReviseContract => @migration.MigrationFindingDisposition::ReviseContract
    ReviseJudge => @migration.MigrationFindingDisposition::ReviseJudge
    FollowUpGoalRequired =>
      @migration.MigrationFindingDisposition::FollowUpGoalRequired
    AwaitUserDecision =>
      @migration.MigrationFindingDisposition::AwaitUserDecision
  }
}

///|
fn native_migration_finding_anchor(
  value : NativeMigrationFindingOutput,
  contract_ref : @control.MigrationContractRef,
) -> Result[@migration.MigrationFindingAnchor, @types.ChoirError] {
  if value.anchor_primary == "" || value.anchor_primary.contains("\u{00}") {
    return Err(native_part_effect_error("migration finding anchor is invalid"))
  }
  match value.anchor_kind {
    Rule if value.anchor_secondary is None =>
      Ok(
        @migration.MigrationFindingAnchor::Rule(
          @migration.MigrationRuleId(value.anchor_primary),
        ),
      )
    JudgeScenario if value.anchor_secondary is None =>
      Ok(
        @migration.MigrationFindingAnchor::JudgeScenario(
          @migration.MigrationScenarioId(value.anchor_primary),
        ),
      )
    InventoryUnit if value.anchor_secondary is None =>
      Ok(
        @migration.MigrationFindingAnchor::InventoryUnit(
          @migration.InventoryStableKey(value.anchor_primary),
        ),
      )
    DependencyEdge =>
      match value.anchor_secondary {
        Some(secondary) if secondary != "" && !secondary.contains("\u{00}") =>
          Ok(
            @migration.MigrationFindingAnchor::DependencyEdge(
              @migration.InventoryStableKey(value.anchor_primary),
              @migration.InventoryStableKey(secondary),
            ),
          )
        _ => Err(native_part_effect_error("dependency anchor is incomplete"))
      }
    OwnershipClaim if value.anchor_secondary is None =>
      Ok(
        @migration.MigrationFindingAnchor::OwnershipClaim(
          @migration.InventoryStableKey(value.anchor_primary),
        ),
      )
    ParityScenario if value.anchor_secondary is None =>
      Ok(
        @migration.MigrationFindingAnchor::ParityScenario(
          @migration.MigrationScenarioId(value.anchor_primary),
        ),
      )
    Contract if value.anchor_secondary is None &&
      value.anchor_primary == contract_ref.contract_id.0 =>
      Ok(@migration.MigrationFindingAnchor::Contract(contract_ref))
    _ => Err(native_part_effect_error("migration finding anchor is invalid"))
  }
}

///|
fn native_migration_findings_artifact(
  runtime : NativePartEffectRuntime,
  snapshot : @workflow.PartWorkflowSnapshot,
  take_id : @control.TakeId,
  subject : @control.PartAuditSubject,
  terminal_response : String,
  total : Int,
  blocking : Int,
) -> Result[@control.ArtifactReference?, @types.ChoirError] {
  let contract_ref = match snapshot.task_contract.migration_contract_ref {
    Some(value) => value
    None =>
      return Err(native_part_effect_error("migration contract is missing"))
  }
  let json = @json.parse(terminal_response) catch {
    _ =>
      return Err(native_part_effect_error("migration audit output is invalid"))
  }
  let output : NativeAuditStructuredOutput = @json.from_json(json) catch {
    _ =>
      return Err(native_part_effect_error("migration audit output is invalid"))
  }
  let drafts = match output.migration_findings {
    Some(value) => value
    None =>
      return Err(
        native_part_effect_error("migration audit findings are missing"),
      )
  }
  if output.total_findings != total ||
    output.blocking_findings != blocking ||
    drafts.length() != total ||
    (if total == 0 {
      output.outcome != "passed"
    } else {
      output.outcome != "findings"
    }) {
    return Err(native_part_effect_error("migration audit counts disagree"))
  }
  let mut observed_blocking = 0
  for finding in drafts {
    if finding.severity == NativeMigrationFindingSeverity::Blocking {
      observed_blocking = observed_blocking + 1
    }
  }
  if observed_blocking != blocking {
    return Err(native_part_effect_error("migration blocking count disagrees"))
  }
  if total == 0 {
    return Ok(None)
  }
  let findings : Array[@migration.MigrationFinding] = []
  for index, draft in drafts {
    let evidence_bytes = @utf8.encode(draft.evidence)
    if evidence_bytes.length() == 0 || evidence_bytes.length() > 16384 {
      return Err(
        native_part_effect_error("migration finding evidence is invalid"),
      )
    }
    let evidence = match
      adopt_native_effect_artifact(
        runtime,
        snapshot.goal.id,
        evidence_bytes,
        @storage.ArtifactProvenance::ArtifactAuditFindings(take_id),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let anchor = match native_migration_finding_anchor(draft, contract_ref) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let class = native_migration_finding_class(draft.class)
    let pattern_key = @migration.migration_finding_pattern_key(1, class, anchor)
    let identity = @storage.artifact_digest(
      @utf8.encode(
        "choir.migration-finding-id.v1\u{00}" +
        take_id.0 +
        "\u{00}" +
        subject.subject_digest.0 +
        "\u{00}" +
        index.to_string() +
        "\u{00}" +
        pattern_key.0 +
        "\u{00}" +
        evidence.digest.0,
      ),
    )
    findings.push({
      schema_version: 1,
      id: @migration.MigrationFindingId("finding-" + identity.0),
      pattern_key,
      class,
      severity: native_migration_finding_severity(draft.severity),
      anchor,
      audit_take_id: take_id,
      audit_subject_digest: subject.subject_digest,
      evidence_digest: evidence.digest,
      disposition: native_migration_finding_disposition(draft.disposition),
    })
  }
  let artifact : @migration.MigrationFindingsArtifact = {
    schema_version: 1,
    findings,
  }
  match @migration.validate_migration_findings_artifact(artifact) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    adopt_native_effect_artifact(
      runtime,
      snapshot.goal.id,
      @utf8.encode(artifact.to_json().stringify(indent=0)),
      @storage.ArtifactProvenance::ArtifactAuditFindings(take_id),
    ) {
    Ok(value) => Ok(Some(value))
    Err(error) => Err(error)
  }
}

///|
test "native migration audit output decodes closed finding domains" {
  let json = @json.parse(
    "{\"outcome\":\"findings\",\"total_findings\":1,\"blocking_findings\":1,\"migration_findings\":[{\"class\":\"RuleViolation\",\"severity\":\"Blocking\",\"anchor_kind\":\"Rule\",\"anchor_primary\":\"rule-1\",\"evidence\":\"observed host I/O\",\"disposition\":\"ReviseContract\"}]}",
  )
  let output : NativeAuditStructuredOutput = @json.from_json(json)
  guard output.migration_findings is Some([finding]) else {
    fail("expected one typed migration finding")
  }
  assert_eq(finding.class, NativeMigrationFindingClass::RuleViolation)
  assert_eq(finding.severity, NativeMigrationFindingSeverity::Blocking)
  assert_eq(
    finding.disposition,
    NativeMigrationFindingDisposition::ReviseContract,
  )
}
