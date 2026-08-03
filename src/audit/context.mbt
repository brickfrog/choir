///|
/// Canonical audit-context bounds. The extra byte is captured only to prove
/// that the complete diff is over limit; no prefix enters the artifact.
pub let audit_context_byte_limit : Int = 1048576

///|
pub let audit_context_diff_sentinel_bytes : Int = 1048577

///|
pub(all) enum AuditContextLineCount {
  AuditContextKnownLineCount(Int64)
  AuditContextUnknownLineCount
} derive(Debug, Eq)

///|
pub(all) struct AuditContextFileStat {
  path : @control.RepoPath
  additions : AuditContextLineCount
  deletions : AuditContextLineCount
} derive(Debug, Eq)

///|
pub(all) struct GoalAuditContextPart {
  part_id : @control.PartId
  task_contract_revision_id : @control.RevisionId
  task_contract_digest : @control.Digest
  mutation_declaration : @control.MutationDeclaration
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditContextKind {
  PartAuditContext(
    @control.GoalId,
    @control.PartId,
    @control.CandidateId,
    @control.TakeId,
    @control.GitOid,
    @control.RevisionId,
    @control.Digest,
    @control.MutationDeclaration
  )
  GoalAuditContext(
    @control.GoalId,
    @control.GoalBranchSealId,
    @control.Digest,
    @control.GitOid,
    @control.Digest,
    Array[GoalAuditContextPart]
  )
} derive(Debug, Eq)

///|
pub(all) enum AuditContextUnifiedDiff {
  CompleteUnifiedDiff(Bytes)
  UnifiedDiffOmittedOverLimit
} derive(Debug, Eq)

///|
pub(all) struct AuditContext {
  schema_version : Int
  kind : AuditContextKind
  base_tree_oid : @control.GitOid
  subject_tree_oid : @control.GitOid
  changed_paths : Array[@control.RepoPath]
  file_stats : Array[AuditContextFileStat]
  unified_diff : AuditContextUnifiedDiff
} derive(Debug, Eq)

///|
pub(all) struct CanonicalAuditContextArtifact {
  context : AuditContext
  content : Bytes
  reference : @control.ArtifactReference
} derive(Debug, Eq)

///|
pub(all) struct AuditContextGitCapture {
  changed_paths_z : Bytes
  numstat_z : Bytes
  unified_diff : Bytes
  unified_diff_exceeded_sentinel : Bool
} derive(Debug, Eq)

///|
fn audit_context_error() -> @types.ChoirError {
  // Deliberately generic: hostile paths must never be reflected by validation.
  @types.ChoirError::validation_error("audit context is invalid")
}

///|
fn write_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(@utf8.encode(value).length().to_string())
  buffer.write_char('#')
  buffer.write_string(value)
}

///|
fn valid_oid(value : String) -> Bool {
  (value.length() == 40 || value.length() == 64) &&
  value.all(fn(char) {
    (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')
  })
}

///|
fn valid_path(path : @control.RepoPath) -> Bool {
  let value = path.0
  value != "" &&
  !value.has_prefix("/") &&
  !value.contains("\u{0000}") &&
  !value.has_suffix("/") &&
  value.split("/").all(fn(part) { part != "" && part != "." && part != ".." })
}

///|
fn mutation_fields(value : @control.MutationDeclaration) -> Array[String] {
  match value {
    @control.MutationDeclaration::CompleteMutationDeclaration(claims) => {
      let encoded : Array[Array[String]] = []
      for claim in claims {
        match claim {
          @control.MutationClaim::ExactPath(path) =>
            encoded.push(["exact", path.0])
          @control.MutationClaim::PathTree(path) =>
            encoded.push(["tree", path.0])
          @control.MutationClaim::RepositoryWide =>
            encoded.push(["repository-wide"])
        }
      }
      encoded.sort_by(fn(left, right) {
        left.join("\u{0000}").compare(right.join("\u{0000}"))
      })
      let fields = ["complete", encoded.length().to_string()]
      for claim in encoded {
        for field in claim {
          fields.push(field)
        }
      }
      fields
    }
    @control.MutationDeclaration::UnknownMutationDeclaration(reason) =>
      [
        "unknown",
        match reason {
          @control.UnknownMutationReason::SemanticScopeUnknown =>
            "semantic-scope"
          @control.UnknownMutationReason::GeneratedOutputsUnknown =>
            "generated-outputs"
          @control.UnknownMutationReason::RepositoryWideToolingUnknown =>
            "repository-tooling"
          @control.UnknownMutationReason::ConductorCouldNotDetermine =>
            "conductor"
        },
      ]
    @control.MutationDeclaration::MissingMutationDeclaration => ["missing"]
  }
}

///|
fn valid_mutation(value : @control.MutationDeclaration) -> Bool {
  match value {
    @control.MutationDeclaration::CompleteMutationDeclaration(claims) => {
      let keys : Array[String] = []
      for claim in claims {
        match claim {
          @control.MutationClaim::ExactPath(path) => {
            let key = "exact\u{0000}" + path.0
            if !valid_path(path) || keys.contains(key) {
              return false
            }
            keys.push(key)
          }
          @control.MutationClaim::PathTree(path) => {
            let key = "tree\u{0000}" + path.0
            if !valid_path(path) || keys.contains(key) {
              return false
            }
            keys.push(key)
          }
          @control.MutationClaim::RepositoryWide => {
            if keys.contains("repository-wide") {
              return false
            }
            keys.push("repository-wide")
          }
        }
      }
      true
    }
    _ => true
  }
}

///|
fn line_count_fields(value : AuditContextLineCount) -> Array[String] {
  match value {
    AuditContextKnownLineCount(count) => ["known", count.to_string()]
    AuditContextUnknownLineCount => ["unknown"]
  }
}

///|
fn canonical_metadata(
  context : AuditContext,
) -> Result[Bytes, @types.ChoirError] {
  let fields : Array[String] = [context.schema_version.to_string()]
  match context.kind {
    PartAuditContext(
      goal,
      part,
      candidate,
      take,
      commit,
      revision,
      contract,
      mutation
    ) => {
      fields.push("part")
      fields.push(goal.0)
      fields.push(part.0)
      fields.push(candidate.0)
      fields.push(take.0)
      fields.push(commit.0)
      fields.push(revision.0)
      fields.push(contract.0)
      for field in mutation_fields(mutation) {
        fields.push(field)
      }
    }
    GoalAuditContext(goal, seal, seal_digest, head, contract, parts) => {
      fields.push("goal")
      fields.push(goal.0)
      fields.push(seal.0)
      fields.push(seal_digest.0)
      fields.push(head.0)
      fields.push(contract.0)
      fields.push(parts.length().to_string())
      for part in parts {
        fields.push(part.part_id.0)
        fields.push(part.task_contract_revision_id.0)
        fields.push(part.task_contract_digest.0)
        for field in mutation_fields(part.mutation_declaration) {
          fields.push(field)
        }
      }
    }
  }
  fields.push(context.base_tree_oid.0)
  fields.push(context.subject_tree_oid.0)
  fields.push(context.changed_paths.length().to_string())
  for path in context.changed_paths {
    fields.push(path.0)
  }
  fields.push(context.file_stats.length().to_string())
  for stat in context.file_stats {
    fields.push(stat.path.0)
    for field in line_count_fields(stat.additions) {
      fields.push(field)
    }
    for field in line_count_fields(stat.deletions) {
      fields.push(field)
    }
  }
  match context.unified_diff {
    CompleteUnifiedDiff(diff) => {
      fields.push("complete")
      fields.push(diff.length().to_string())
    }
    UnifiedDiffOmittedOverLimit => fields.push("omitted-over-limit")
  }
  let buffer = StringBuilder::new()
  write_field(buffer, "choir.audit-context.v1")
  write_field(buffer, fields.length().to_string())
  for field in fields {
    write_field(buffer, field)
  }
  let bytes = @utf8.encode(buffer.to_string())
  if bytes.length() > audit_context_byte_limit {
    Err(audit_context_error())
  } else {
    Ok(bytes)
  }
}

///|
fn join_metadata_and_diff(metadata : Bytes, diff : Bytes) -> Bytes {
  let joined = FixedArray::make(metadata.length() + diff.length(), (0 : Byte))
  for index, byte in metadata {
    joined[index] = byte
  }
  for index, byte in diff {
    joined[metadata.length() + index] = byte
  }
  joined.unsafe_reinterpret_as_bytes()
}

///|
/// Construct and validate the immutable artifact from bounded Git responses.
/// `captured_diff` must be the complete output or the 1,048,577-byte sentinel.
pub fn build_audit_context(
  kind : AuditContextKind,
  base_tree_oid : @control.GitOid,
  subject_tree_oid : @control.GitOid,
  changed_paths : Array[@control.RepoPath],
  file_stats : Array[AuditContextFileStat],
  captured_diff : Bytes,
) -> Result[CanonicalAuditContextArtifact, @types.ChoirError] {
  if !valid_oid(base_tree_oid.0) ||
    !valid_oid(subject_tree_oid.0) ||
    captured_diff.length() > audit_context_diff_sentinel_bytes {
    return Err(audit_context_error())
  }
  match kind {
    PartAuditContext(_, _, _, _, commit, _, digest, mutation) =>
      if !valid_oid(commit.0) || !digest.is_valid() || !valid_mutation(mutation) {
        return Err(audit_context_error())
      }
    GoalAuditContext(_, _, seal_digest, head, digest, parts) =>
      if !seal_digest.is_valid() ||
        !valid_oid(head.0) ||
        !digest.is_valid() ||
        parts.any(fn(part) {
          !part.task_contract_digest.is_valid() ||
          !valid_mutation(part.mutation_declaration)
        }) {
        return Err(audit_context_error())
      }
  }
  let paths = changed_paths.copy()
  paths.sort()
  if paths.any(fn(path) { !valid_path(path) }) {
    return Err(audit_context_error())
  }
  for index = 1; index < paths.length(); index = index + 1 {
    if paths[index - 1] == paths[index] {
      return Err(audit_context_error())
    }
  }
  let stats = file_stats.copy()
  stats.sort_by(fn(left, right) { left.path.compare(right.path) })
  if stats.length() != paths.length() {
    return Err(audit_context_error())
  }
  for index, stat in stats {
    if stat.path != paths[index] || !valid_path(stat.path) {
      return Err(audit_context_error())
    }
    match (stat.additions, stat.deletions) {
      (AuditContextKnownLineCount(add), AuditContextKnownLineCount(del)) =>
        if add < 0L || del < 0L {
          return Err(audit_context_error())
        }
      (AuditContextKnownLineCount(add), _) if add < 0L =>
        return Err(audit_context_error())
      (_, AuditContextKnownLineCount(del)) if del < 0L =>
        return Err(audit_context_error())
      _ => ()
    }
  }
  let canonical_kind = match kind {
    GoalAuditContext(goal, seal, seal_digest, head, contract, parts) => {
      let ordered = parts.copy()
      ordered.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
      for index = 1; index < ordered.length(); index = index + 1 {
        if ordered[index - 1].part_id == ordered[index].part_id {
          return Err(audit_context_error())
        }
      }
      GoalAuditContext(goal, seal, seal_digest, head, contract, ordered)
    }
    value => value
  }
  let unified_diff = if captured_diff.length() <= audit_context_byte_limit {
    CompleteUnifiedDiff(captured_diff)
  } else {
    UnifiedDiffOmittedOverLimit
  }
  let context = {
    schema_version: 1,
    kind: canonical_kind,
    base_tree_oid,
    subject_tree_oid,
    changed_paths: paths,
    file_stats: stats,
    unified_diff,
  }
  let metadata = match canonical_metadata(context) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let content = match unified_diff {
    CompleteUnifiedDiff(diff) => join_metadata_and_diff(metadata, diff)
    UnifiedDiffOmittedOverLimit => metadata
  }
  let digest = @storage.artifact_digest(content)
  Ok({
    context,
    content,
    reference: { artifact_id: "sha256:" + digest.0, digest },
  })
}

///|
/// Parse one `--numstat -z` record after host capture has split NUL records.
pub fn parse_numstat_record(
  record : String,
) -> Result[AuditContextFileStat, @types.ChoirError] {
  let fields = record.split("\t").collect()
  if fields.length() != 3 ||
    !valid_path(@control.RepoPath(fields[2].to_owned())) {
    return Err(audit_context_error())
  }
  fn parse_count(
    value : String,
  ) -> Result[AuditContextLineCount, @types.ChoirError] {
    if value == "-" {
      return Ok(AuditContextUnknownLineCount)
    }
    if value == "" || value.any(fn(char) { char < '0' || char > '9' }) {
      return Err(audit_context_error())
    }
    let parsed = @string.parse_int64(value) catch {
      _ => return Err(audit_context_error())
    }
    if parsed < 0L {
      Err(audit_context_error())
    } else {
      Ok(AuditContextKnownLineCount(parsed))
    }
  }
  let additions = match parse_count(fields[0].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let deletions = match parse_count(fields[1].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ path: @control.RepoPath(fields[2].to_owned()), additions, deletions })
}

///|
/// Validate and combine the three deterministic injected Git responses.
pub fn build_audit_context_from_git_capture(
  kind : AuditContextKind,
  base_tree_oid : @control.GitOid,
  subject_tree_oid : @control.GitOid,
  expected_paths : Array[@control.RepoPath],
  capture : AuditContextGitCapture,
) -> Result[CanonicalAuditContextArtifact, @types.ChoirError] {
  let paths_text = @utf8.decode(capture.changed_paths_z) catch {
    _ => return Err(audit_context_error())
  }
  let paths : Array[@control.RepoPath] = []
  if paths_text != "" {
    if !paths_text.has_suffix("\u{0000}") {
      return Err(audit_context_error())
    }
    for raw in paths_text.split("\u{0000}") {
      if raw != "" {
        paths.push(@control.RepoPath(raw.to_owned()))
      }
    }
  }
  let stats_text = @utf8.decode(capture.numstat_z) catch {
    _ => return Err(audit_context_error())
  }
  let stats : Array[AuditContextFileStat] = []
  if stats_text != "" {
    if !stats_text.has_suffix("\u{0000}") {
      return Err(audit_context_error())
    }
    for raw in stats_text.split("\u{0000}") {
      if raw != "" {
        match parse_numstat_record(raw.to_owned()) {
          Ok(value) => stats.push(value)
          Err(error) => return Err(error)
        }
      }
    }
  }
  let canonical_expected = expected_paths.copy()
  canonical_expected.sort()
  let canonical_observed = paths.copy()
  canonical_observed.sort()
  if canonical_expected != canonical_observed {
    return Err(audit_context_error())
  }
  let diff = if capture.unified_diff_exceeded_sentinel {
    Bytes::make(audit_context_diff_sentinel_bytes, (0 : Byte))
  } else {
    capture.unified_diff
  }
  build_audit_context(kind, base_tree_oid, subject_tree_oid, paths, stats, diff)
}
