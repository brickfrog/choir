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
  let output : @provider_host.NativeAuditStructuredOutput = @json.from_json(
    json,
  ) catch {
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
    if finding.severity ==
      @provider_host.NativeMigrationFindingSeverity::Blocking {
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
    let anchor = match
      @provider_host.native_migration_finding_anchor(draft, contract_ref) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let class = @provider_host.native_migration_finding_class(draft.class)
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
      severity: @provider_host.native_migration_finding_severity(draft.severity),
      anchor,
      audit_take_id: take_id,
      audit_subject_digest: subject.subject_digest,
      evidence_digest: evidence.digest,
      disposition: @provider_host.native_migration_finding_disposition(
        draft.disposition,
      ),
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
  guard json is Object(output_fields) else {
    return Err(native_part_effect_error("migration audit output is invalid"))
  }
  guard artifact.to_json() is Object(migration_fields) else {
    return Err(
      native_part_effect_error("migration findings artifact is invalid"),
    )
  }
  for key, value in migration_fields {
    output_fields[key] = value
  }
  match
    adopt_native_effect_artifact(
      runtime,
      snapshot.goal.id,
      @utf8.encode(output_fields.to_json().stringify(indent=0)),
      @storage.ArtifactProvenance::ArtifactAuditFindings(take_id),
    ) {
    Ok(value) => Ok(Some(value))
    Err(error) => Err(error)
  }
}

///|
