///|
pub(all) enum NativeMigrationFindingClass {
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
pub(all) enum NativeMigrationFindingSeverity {
  Advisory
  Blocking
} derive(Debug, Eq, FromJson)

///|
pub(all) enum NativeMigrationFindingDisposition {
  RepairPart
  ReviseContract
  ReviseJudge
  FollowUpGoalRequired
} derive(Debug, Eq, FromJson)

///|
pub(all) enum NativeMigrationFindingAnchorKind {
  Rule
  JudgeScenario
  InventoryUnit
  DependencyEdge
  OwnershipClaim
  ParityScenario
  Contract
} derive(Debug, Eq, FromJson)

///|
pub(all) struct NativeMigrationFindingOutput {
  class : NativeMigrationFindingClass
  severity : NativeMigrationFindingSeverity
  anchor_kind : NativeMigrationFindingAnchorKind
  anchor_primary : String
  anchor_secondary : String
  evidence : String
  disposition : NativeMigrationFindingDisposition
} derive(Debug, Eq, FromJson)

///|
pub(all) enum NativeRepairFindingSeverity {
  Advisory
  Blocking
} derive(Debug, Eq, FromJson)

///|
pub(all) struct NativeRepairFindingOutput {
  severity : NativeRepairFindingSeverity
  summary : String
  evidence : String
  affected_paths : Array[String]
} derive(Debug, Eq, FromJson)

///|
pub(all) struct NativeAuditStructuredOutput {
  outcome : String
  total_findings : Int
  blocking_findings : Int
  repair_findings : Array[NativeRepairFindingOutput]?
  migration_findings : Array[NativeMigrationFindingOutput]?
} derive(Debug, Eq, FromJson)

///|
fn native_repair_finding_output_schema() -> Json {
  {
    "type": "object".to_json(),
    "properties": {
      "severity": {
        "type": "string".to_json(),
        "enum": ["Advisory", "Blocking"].to_json(),
      }.to_json(),
      "summary": { "type": "string".to_json() }.to_json(),
      "evidence": { "type": "string".to_json() }.to_json(),
      "affected_paths": {
        "type": "array".to_json(),
        "items": { "type": "string".to_json() }.to_json(),
      }.to_json(),
    }.to_json(),
    "required": ["severity", "summary", "evidence", "affected_paths"].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
}

///|
fn native_repair_findings_output_schema() -> Json {
  { "type": "array".to_json(), "items": native_repair_finding_output_schema() }.to_json()
}

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
        ].to_json(),
      }.to_json(),
    }.to_json(),
    "required": [
      "class", "severity", "anchor_kind", "anchor_primary", "anchor_secondary", "evidence",
      "disposition",
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
  " Always return repair_findings with one entry per reported finding. Each entry must use the exact severity enum, contain a concise summary and bounded concrete evidence, and list every repository-relative path that a repair must change. A blocking finding must name at least one affected path, and every named path must be inside the supplied mutation surface. Return an empty repair_findings array only when clean. Always return migration_findings. For a migration Part, include one typed entry per finding; otherwise return an empty array. Use the exact enum labels from the output schema, set anchor_secondary to an empty string unless the anchor is a dependency edge, anchor the concrete rule, scenario, inventory unit, dependency edge, ownership claim, parity scenario, or accepted Contract, and include bounded evidence text. Return an empty migration_findings array when clean."
}

///|
pub fn native_audit_repair_findings_with_nfc(
  terminal_response : String,
  total : Int,
  blocking : Int,
  is_nfc : (String) -> Bool,
) -> Result[Array[NativeRepairFindingOutput], @types.ChoirError] {
  let json = @json.parse(terminal_response) catch {
    _ => return Err(native_provider_output_error("audit output is invalid"))
  }
  let output : NativeAuditStructuredOutput = @json.from_json(json) catch {
    _ => return Err(native_provider_output_error("audit output is invalid"))
  }
  let findings = match output.repair_findings {
    Some(value) => value
    None =>
      return Err(
        native_provider_output_error("audit repair findings are missing"),
      )
  }
  if output.total_findings != total ||
    output.blocking_findings != blocking ||
    findings.length() != total ||
    (if total == 0 {
      output.outcome != "passed"
    } else {
      output.outcome != "findings"
    }) {
    return Err(
      native_provider_output_error("audit repair finding counts disagree"),
    )
  }
  let mut observed_blocking = 0
  for finding in findings {
    let summary_bytes = @utf8.encode(finding.summary)
    let evidence_bytes = @utf8.encode(finding.evidence)
    if summary_bytes.length() == 0 ||
      summary_bytes.length() > 4096 ||
      evidence_bytes.length() == 0 ||
      evidence_bytes.length() > 16384 {
      return Err(
        native_provider_output_error("audit repair finding text is invalid"),
      )
    }
    if finding.severity == NativeRepairFindingSeverity::Blocking {
      observed_blocking = observed_blocking + 1
      if finding.affected_paths.length() == 0 {
        return Err(
          native_provider_output_error(
            "blocking audit repair finding has no affected path",
          ),
        )
      }
    }
    for raw_path in finding.affected_paths {
      let path = @control.RepoPath(raw_path)
      match @control.validate_repo_path(path, is_nfc) {
        Ok(_) => ()
        Err(_) =>
          return Err(
            native_provider_output_error("audit repair finding path is invalid"),
          )
      }
    }
  }
  if observed_blocking != blocking {
    return Err(
      native_provider_output_error("audit repair blocking count disagrees"),
    )
  }
  Ok(findings)
}

///|
pub fn native_audit_repair_findings(
  terminal_response : String,
  total : Int,
  blocking : Int,
) -> Result[Array[NativeRepairFindingOutput], @types.ChoirError] {
  native_audit_repair_findings_with_nfc(
    terminal_response, total, blocking, @process_host.native_path_is_nfc,
  )
}

///|
pub fn native_blocking_audit_repair_paths(
  terminal_response : String,
  total : Int,
  blocking : Int,
) -> Result[Array[@control.RepoPath], @types.ChoirError] {
  let findings = match
    native_audit_repair_findings(terminal_response, total, blocking) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let paths : Array[@control.RepoPath] = []
  for finding in findings {
    if finding.severity == NativeRepairFindingSeverity::Blocking {
      for raw_path in finding.affected_paths {
        let path = @control.RepoPath(raw_path)
        if !paths.contains(path) {
          paths.push(path)
        }
      }
    }
  }
  paths.sort()
  if blocking > 0 && paths.length() == 0 {
    Err(native_provider_output_error("blocking audit has no repair paths"))
  } else {
    Ok(paths)
  }
}

///|
pub fn native_migration_finding_class(
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
pub fn native_migration_finding_severity(
  value : NativeMigrationFindingSeverity,
) -> @migration.MigrationFindingSeverity {
  match value {
    Advisory => @migration.MigrationFindingSeverity::Advisory
    Blocking => @migration.MigrationFindingSeverity::Blocking
  }
}

///|
pub fn native_migration_finding_disposition(
  value : NativeMigrationFindingDisposition,
) -> @migration.MigrationFindingDisposition {
  match value {
    RepairPart => @migration.MigrationFindingDisposition::RepairPart
    ReviseContract => @migration.MigrationFindingDisposition::ReviseContract
    ReviseJudge => @migration.MigrationFindingDisposition::ReviseJudge
    FollowUpGoalRequired =>
      @migration.MigrationFindingDisposition::FollowUpGoalRequired
  }
}

///|
pub fn native_migration_finding_anchor(
  value : NativeMigrationFindingOutput,
  contract_ref : @control.MigrationContractRef,
) -> Result[@migration.MigrationFindingAnchor, @types.ChoirError] {
  if value.anchor_primary == "" || value.anchor_primary.contains("\u{00}") {
    return Err(
      native_provider_output_error("migration finding anchor is invalid"),
    )
  }
  match value.anchor_kind {
    Rule if value.anchor_secondary == "" =>
      Ok(
        @migration.MigrationFindingAnchor::Rule(
          @migration.MigrationRuleId(value.anchor_primary),
        ),
      )
    JudgeScenario if value.anchor_secondary == "" =>
      Ok(
        @migration.MigrationFindingAnchor::JudgeScenario(
          @migration.MigrationScenarioId(value.anchor_primary),
        ),
      )
    InventoryUnit if value.anchor_secondary == "" =>
      Ok(
        @migration.MigrationFindingAnchor::InventoryUnit(
          @migration.InventoryStableKey(value.anchor_primary),
        ),
      )
    DependencyEdge =>
      match value.anchor_secondary {
        secondary if secondary != "" && !secondary.contains("\u{00}") =>
          Ok(
            @migration.MigrationFindingAnchor::DependencyEdge(
              @migration.InventoryStableKey(value.anchor_primary),
              @migration.InventoryStableKey(secondary),
            ),
          )
        _ =>
          Err(native_provider_output_error("dependency anchor is incomplete"))
      }
    OwnershipClaim if value.anchor_secondary == "" =>
      Ok(
        @migration.MigrationFindingAnchor::OwnershipClaim(
          @migration.InventoryStableKey(value.anchor_primary),
        ),
      )
    ParityScenario if value.anchor_secondary == "" =>
      Ok(
        @migration.MigrationFindingAnchor::ParityScenario(
          @migration.MigrationScenarioId(value.anchor_primary),
        ),
      )
    Contract if value.anchor_secondary == "" &&
      value.anchor_primary == contract_ref.contract_id.0 =>
      Ok(@migration.MigrationFindingAnchor::Contract(contract_ref))
    _ =>
      Err(native_provider_output_error("migration finding anchor is invalid"))
  }
}

///|
test "native migration audit output decodes closed finding domains" {
  let json = @json.parse(
    "{\"outcome\":\"findings\",\"total_findings\":1,\"blocking_findings\":1,\"repair_findings\":[{\"severity\":\"Blocking\",\"summary\":\"host I/O remains\",\"evidence\":\"src/example.mbt invokes @sys\",\"affected_paths\":[\"src/example.mbt\"]}],\"migration_findings\":[{\"class\":\"RuleViolation\",\"severity\":\"Blocking\",\"anchor_kind\":\"Rule\",\"anchor_primary\":\"rule-1\",\"anchor_secondary\":\"\",\"evidence\":\"observed host I/O\",\"disposition\":\"ReviseContract\"}]}",
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
  let schema = native_migration_finding_output_schema().stringify(indent=0)
  assert_true(schema.contains("\"anchor_secondary\":{\"type\":\"string\"}"))
  assert_true(
    schema.contains(
      "\"required\":[\"class\",\"severity\",\"anchor_kind\",\"anchor_primary\",\"anchor_secondary\",\"evidence\",\"disposition\"]",
    ),
  )
  match
    native_audit_repair_findings_with_nfc(json.stringify(indent=0), 1, 1, fn(
      _,
    ) {
      true
    }) {
    Ok([{ affected_paths: ["src/example.mbt"], .. }]) => ()
    _ => fail("expected one routable repair finding")
  }
}

///|
pub fn native_work_order_planning_output_schema() -> String {
  let string_array : Json = {
    "type": "array".to_json(),
    "items": { "type": "string".to_json() }.to_json(),
  }.to_json()
  let nullable_string : Json = { "type": ["string", "null"].to_json() }.to_json()
  let mutation : Json = {
    "type": "object".to_json(),
    "properties": {
      "id": { "type": "string".to_json() }.to_json(),
      "intent": {
        "type": "string".to_json(),
        "enum": ["BeadCreateIntent", "BeadUpdateIntent"].to_json(),
      }.to_json(),
      "title": nullable_string,
      "description": nullable_string,
      "acceptance_criteria": nullable_string,
      "notes": nullable_string,
      "priority": { "type": ["string", "null"].to_json() }.to_json(),
      "issue_type": { "type": ["string", "null"].to_json() }.to_json(),
      "labels": {
        "anyOf": [string_array, { "type": "null".to_json() }.to_json()].to_json(),
      }.to_json(),
      "blocked_by": string_array,
      "parent": nullable_string,
      "expected_updated_at": nullable_string,
    }.to_json(),
    "required": [
      "id", "intent", "title", "description", "acceptance_criteria", "notes", "priority",
      "issue_type", "labels", "blocked_by", "parent", "expected_updated_at",
    ].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
  let schema : Json = {
    "$schema": "https://json-schema.org/draft/2020-12/schema".to_json(),
    "type": "object".to_json(),
    "properties": {
      "findings": {
        "type": "array".to_json(),
        "items": {
          "type": "object".to_json(),
          "properties": {
            "summary": { "type": "string".to_json() }.to_json(),
            "evidence": { "type": "string".to_json() }.to_json(),
            "related_bead_ids": string_array,
          }.to_json(),
          "required": ["summary", "evidence", "related_bead_ids"].to_json(),
          "additionalProperties": false.to_json(),
        }.to_json(),
      }.to_json(),
      "eligible_work_observed": { "type": "boolean".to_json() }.to_json(),
      "bead_mutations": {
        "type": "object".to_json(),
        "properties": {
          "mutations": { "type": "array".to_json(), "items": mutation }.to_json(),
        }.to_json(),
        "required": ["mutations"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      "primary_target_ids": string_array,
      "prerequisite_closure_ids": string_array,
      // Transport the nested draft as JSON text. Strict structured-output
      // implementations require closed schemas for nested objects; Choir
      // parses this back before the authoritative workflow decode.
      "finite_goal": { "type": ["string", "null"].to_json() }.to_json(),
    }.to_json(),
    "required": [
      "findings", "eligible_work_observed", "bead_mutations", "primary_target_ids",
      "prerequisite_closure_ids", "finite_goal",
    ].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
  schema.stringify(indent=0) + "\n"
}

///|

///|
fn native_provider_output_error(message : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("native Part effect: " + message)
}
