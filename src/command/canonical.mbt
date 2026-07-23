///|
fn write_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(@utf8.encode(value).length().to_string())
  buffer.write_char('#')
  buffer.write_string(value)
}

///|
fn canonical_fields(domain : String, fields : Array[String]) -> Bytes {
  let buffer = StringBuilder::new()
  write_field(buffer, domain)
  write_field(buffer, fields.length().to_string())
  for field in fields {
    write_field(buffer, field)
  }
  @utf8.encode(buffer.to_string())
}

///|
fn digest_bytes(content : Bytes) -> @control.Digest {
  @control.Digest(@crypto.bytes_to_hex_string(@crypto.sha256(content)))
}

///|
fn role_tag(role : CommandRole) -> String {
  match role {
    ImplementationCommand => "implementation"
    PartAuditCommand => "part-audit"
  }
}

///|
fn provider_surface_tag(surface : @control.ProviderSurfaceId) -> String {
  match surface {
    ClaudeSubscriptionCli => "claude-subscription-cli"
    CodexSubscriptionCli => "codex-subscription-cli"
  }
}

///|
pub fn canonical_command_subject_bytes(
  subject : CommandExecutionSubject,
) -> Bytes {
  let fields = match subject {
    ImplementationCommandSubject(part_id, revision_id, contract_digest) =>
      ["implementation", part_id.0, revision_id.0, contract_digest.0]
    PartAuditCommandSubject(value) =>
      [
        "part-audit",
        value.part_id.0,
        value.candidate_take_id.0,
        value.candidate_commit_oid.0,
        value.candidate_tree_oid.0,
        value.task_contract_revision_id.0,
        value.task_contract_digest.0,
        value.verification_receipt_set_digest.0,
        value.verification_evidence_manifest_digest.0,
        value.subject_digest.0,
      ]
  }
  canonical_fields("choir.command-subject.v1", fields)
}

///|
pub fn command_subject_digest(
  subject : CommandExecutionSubject,
) -> @control.Digest {
  digest_bytes(canonical_command_subject_bytes(subject))
}

///|
pub fn canonical_take_purpose_bytes(purpose : @control.TakePurpose) -> Bytes {
  let fields = match purpose {
    Implementation(part_id, revision_id) =>
      ["implementation", part_id.0, revision_id.0]
    PartVerification(part_id, take_id, subject_digest) =>
      ["part-verification", part_id.0, take_id.0, subject_digest.0]
    PartAudit(part_id, take_id, subject_digest) =>
      ["part-audit", part_id.0, take_id.0, subject_digest.0]
    GoalVerification(goal_id, tree_oid, subject_digest) =>
      ["goal-verification", goal_id.0, tree_oid.0, subject_digest.0]
    GoalAudit(goal_id, subject_digest) =>
      ["goal-audit", goal_id.0, subject_digest.0]
  }
  canonical_fields("choir.take-purpose.v1", fields)
}

///|
pub fn take_purpose_digest(purpose : @control.TakePurpose) -> @control.Digest {
  digest_bytes(canonical_take_purpose_bytes(purpose))
}

///|
fn optional_digest_fields(value : @control.Digest?) -> Array[String] {
  match value {
    None => ["none"]
    Some(digest) => ["some", digest.0]
  }
}

///|
fn optional_contract_fields(
  value : @control.MigrationContractRef?,
) -> Array[String] {
  match value {
    None => ["none"]
    Some(reference) =>
      [
        "some",
        @utf8.decode_lossy(
          @migration.canonical_migration_contract_ref_bytes(reference),
        ),
      ]
  }
}

///|
pub fn canonical_command_provenance_bytes(
  provenance : CommandPreparationProvenance,
) -> Bytes {
  let fields = [
    provenance.schema_version.to_string(),
    provenance.take_id.0,
    provenance.take_purpose_digest.0,
    provenance.subject_digest.0,
    provenance.goal_contract_digest.0,
    provenance.task_contract_revision_id.0,
    provenance.task_contract_digest.0,
  ]
  for field in optional_contract_fields(provenance.migration_contract_ref) {
    fields.push(field)
  }
  fields.push(provenance.template_digest.0)
  fields.push(provider_surface_tag(provenance.provider_surface))
  fields.push(provenance.provider_surface_and_profile_digest.0)
  fields.push(provenance.context_assembly_policy_digest.0)
  for field in optional_digest_fields(provenance.context_manifest_digest) {
    fields.push(field)
  }
  fields.push(provenance.context_projection_digest.0)
  fields.push(provenance.maximum_command_bytes.to_string())
  fields.push(provenance.command_artifact_digest.0)
  fields.push(provenance.command_byte_length.to_string())
  canonical_fields("choir.command-preparation-provenance.v1", fields)
}

///|
pub fn command_provenance_digest(
  provenance : CommandPreparationProvenance,
) -> @control.Digest {
  digest_bytes(canonical_command_provenance_bytes(provenance))
}

///|
fn canonical_context_projection_bytes(
  ordered_digests : Array[@control.Digest],
) -> Bytes {
  let fields = [ordered_digests.length().to_string()]
  for digest in ordered_digests {
    fields.push(digest.0)
  }
  canonical_fields("choir.command-context-projection.v1", fields)
}
