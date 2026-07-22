///|
fn digest_valid(digest : @control.Digest) -> Bool {
  if digest.0.length() != 64 {
    return false
  }
  for character in digest.0 {
    if !((character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')) {
      return false
    }
  }
  true
}

///|
fn sorted_unique_digests(
  values : Array[@control.Digest],
) -> Array[@control.Digest] {
  let ordered = values.copy()
  ordered.sort_by(fn(left, right) { left.compare(right) })
  let unique : Array[@control.Digest] = []
  for value in ordered {
    if unique.length() == 0 || unique[unique.length() - 1] != value {
      unique.push(value)
    }
  }
  unique
}

///|
fn expected_context_digests(
  instruction_digest : @control.Digest,
  manifest : @migration.PartContextManifest?,
) -> Array[@control.Digest] {
  let values = [instruction_digest]
  match manifest {
    None => ()
    Some(value) => {
      values.push(value.migration_contract_ref.contract_artifact_digest)
      for digest in value.rulebook_section_digests {
        values.push(digest)
      }
      values.push(value.dependency_neighborhood_digest)
      for digest in value.applicable_gap_entry_digests {
        values.push(digest)
      }
      values.push(value.source_path_manifest_digest)
      match value.prior_take_context_digest {
        Some(digest) => values.push(digest)
        None => ()
      }
    }
  }
  sorted_unique_digests(values)
}

///|
fn subject_matches_request(request : CommandPreparationRequest) -> Bool {
  match (request.take.purpose, request.subject, request.template.role) {
    (
      Implementation(part_id, revision_id),
      ImplementationCommandSubject(subject_part_id, subject_revision_id, digest),
      ImplementationCommand,
    ) =>
      part_id == subject_part_id &&
      revision_id == subject_revision_id &&
      revision_id == request.task_contract_revision_id &&
      digest == request.task_contract_digest
    (
      PartVerification(part_id, candidate_take_id, subject_digest),
      PartVerificationCommandSubject(subject),
      PartVerificationCommand,
    ) =>
      part_id == subject.part_id &&
      candidate_take_id == subject.candidate_take_id &&
      subject_digest == subject.subject_digest &&
      subject.task_contract_revision_id == request.task_contract_revision_id &&
      subject.task_contract_digest == request.task_contract_digest
    (
      PartAudit(part_id, candidate_take_id, subject_digest),
      PartAuditCommandSubject(subject),
      PartAuditCommand,
    ) =>
      part_id == subject.part_id &&
      candidate_take_id == subject.candidate_take_id &&
      subject_digest == subject.subject_digest &&
      subject.task_contract_revision_id == request.task_contract_revision_id &&
      subject.task_contract_digest == request.task_contract_digest
    _ => false
  }
}

///|
fn migration_context_matches(request : CommandPreparationRequest) -> Bool {
  match (request.migration_contract_ref, request.context_manifest) {
    (None, None) => true
    (Some(reference), Some(manifest)) =>
      reference == manifest.migration_contract_ref &&
      manifest.part_task_contract_revision_id ==
      request.task_contract_revision_id &&
      manifest.part_task_contract_digest == request.task_contract_digest &&
      manifest.context_assembly_policy_digest ==
      request.context_assembly_policy_digest &&
      @migration.validate_part_context_manifest(manifest) is Ok(_)
    _ => false
  }
}

///|
fn context_artifact_index(
  artifacts : Array[CommandContextArtifact],
  digest : @control.Digest,
) -> Int? {
  for index, artifact in artifacts {
    if artifact.digest == digest {
      return Some(index)
    }
  }
  None
}

///|
fn ordered_context_artifacts(
  request : CommandPreparationRequest,
) -> Result[Array[CommandContextArtifact], @types.ChoirError] {
  let expected = expected_context_digests(
    request.instruction_artifact_digest,
    request.context_manifest,
  )
  let actual_digests = request.context_artifacts.map(fn(value) { value.digest })
  let actual = sorted_unique_digests(actual_digests)
  if actual.length() != request.context_artifacts.length() ||
    actual.length() > expected.length() {
    return Err(@types.ChoirError::command_preparation_stale_binding())
  }
  for digest in expected {
    match context_artifact_index(request.context_artifacts, digest) {
      None =>
        return Err(
          @types.ChoirError::command_preparation_missing_required_artifact(
            digest.0,
          ),
        )
      Some(index) => {
        let artifact = request.context_artifacts[index]
        if digest_bytes(artifact.content) != artifact.digest {
          return Err(@types.ChoirError::command_preparation_digest_mismatch())
        }
        let _ = @utf8.decode(artifact.content) catch {
          _ =>
            return Err(@types.ChoirError::command_preparation_stale_binding())
        }
      }
    }
  }
  if actual != expected {
    return Err(@types.ChoirError::command_preparation_stale_binding())
  }
  Ok(
    expected.map(fn(digest) {
      request.context_artifacts[context_artifact_index(
        request.context_artifacts,
        digest,
      ).unwrap()]
    }),
  )
}

///|
fn append_framed_text(
  buffer : StringBuilder,
  label : String,
  content : String,
) -> Unit {
  buffer.write_string(label)
  buffer.write_char(' ')
  buffer.write_string(@utf8.encode(content).length().to_string())
  buffer.write_char('\n')
  buffer.write_string(content)
  buffer.write_char('\n')
}

///|
fn build_exact_command_bytes(
  request : CommandPreparationRequest,
  ordered_context : Array[CommandContextArtifact],
) -> Result[Bytes, @types.ChoirError] {
  let template = @utf8.decode(request.template.content) catch {
    _ =>
      return Err(@types.ChoirError::command_preparation_unsupported_template())
  }
  let buffer = StringBuilder::new()
  buffer.write_string("CHOIR_COMMAND_V1\n")
  buffer.write_string("ROLE " + role_tag(request.template.role) + "\n")
  buffer.write_string("TAKE " + request.take.id.0 + "\n")
  append_framed_text(
    buffer,
    "SUBJECT",
    @utf8.decode_lossy(canonical_command_subject_bytes(request.subject)),
  )
  append_framed_text(buffer, "TEMPLATE", template)
  match request.context_manifest {
    Some(manifest) =>
      append_framed_text(
        buffer,
        "PART_CONTEXT_MANIFEST",
        @utf8.decode_lossy(
          @migration.canonical_part_context_manifest_bytes(manifest),
        ),
      )
    None => ()
  }
  for artifact in ordered_context {
    let content = @utf8.decode(artifact.content) catch {
      _ => return Err(@types.ChoirError::command_preparation_stale_binding())
    }
    append_framed_text(buffer, "CONTEXT " + artifact.digest.0, content)
  }
  Ok(@utf8.encode(buffer.to_string()))
}

///|
pub fn prepare_command(
  request : CommandPreparationRequest,
) -> Result[PreparedCommand, @types.ChoirError] {
  if request.schema_version != 1 ||
    request.maximum_command_bytes <= 0 ||
    request.take.id.0 == "" ||
    request.task_contract_revision_id.0 == "" ||
    ![
      request.goal_contract_digest,
      request.task_contract_digest,
      request.instruction_artifact_digest,
      request.provider_surface_and_profile_digest,
      request.context_assembly_policy_digest,
      request.template.digest,
    ].all(fn(digest) { digest_valid(digest) }) ||
    !subject_matches_request(request) ||
    !migration_context_matches(request) {
    return Err(@types.ChoirError::command_preparation_stale_binding())
  }
  if request.template.schema_version != 1 ||
    request.template.content.length() == 0 {
    return Err(@types.ChoirError::command_preparation_unsupported_template())
  }
  if digest_bytes(request.template.content) != request.template.digest {
    return Err(@types.ChoirError::command_preparation_digest_mismatch())
  }
  let ordered_context = match ordered_context_artifacts(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let command_bytes = match
    build_exact_command_bytes(request, ordered_context) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if command_bytes.length() > request.maximum_command_bytes {
    return Err(
      @types.ChoirError::command_preparation_size_limit_exceeded(
        command_bytes.length(),
        request.maximum_command_bytes,
      ),
    )
  }
  let ordered_digests = ordered_context.map(fn(value) { value.digest })
  let manifest_digest = match request.context_manifest {
    None => None
    Some(manifest) =>
      Some(
        digest_bytes(@migration.canonical_part_context_manifest_bytes(manifest)),
      )
  }
  let command_artifact_digest = digest_bytes(command_bytes)
  Ok({
    command_bytes,
    provenance: {
      schema_version: 1,
      take_id: request.take.id,
      take_purpose_digest: take_purpose_digest(request.take.purpose),
      subject_digest: command_subject_digest(request.subject),
      goal_contract_digest: request.goal_contract_digest,
      task_contract_revision_id: request.task_contract_revision_id,
      task_contract_digest: request.task_contract_digest,
      migration_contract_ref: request.migration_contract_ref,
      template_digest: request.template.digest,
      provider_surface: request.provider_surface,
      provider_surface_and_profile_digest: request.provider_surface_and_profile_digest,
      context_assembly_policy_digest: request.context_assembly_policy_digest,
      context_manifest_digest: manifest_digest,
      context_projection_digest: digest_bytes(
        canonical_context_projection_bytes(ordered_digests),
      ),
      maximum_command_bytes: request.maximum_command_bytes,
      command_artifact_digest,
      command_byte_length: command_bytes.length(),
    },
  })
}
