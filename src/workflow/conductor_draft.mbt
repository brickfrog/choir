///|
pub(all) struct ConductorVerificationDraft {
  arguments : Array[String]
  timeout_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConductorPartDraft {
  part_id : @control.PartId
  instruction : String
  exact_paths : Array[@control.RepoPath]
  path_trees : Array[@control.RepoPath]
  repository_wide : Bool
  verification : ConductorVerificationDraft
  provider_surface : @control.ProviderSurfaceId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConductorGoalDraft {
  proposal_id : GoalProposalId
  goal_id : @control.GoalId
  base_ref : GitRefName
  integration_target_ref : GitRefName
  maximum_parallel_parts : Int
  parts : Array[ConductorPartDraft]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn conductor_draft_string(
  fields : Map[String, Json],
  field : String,
) -> String? {
  match fields.get(field) {
    Some(String(value)) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    _ => None
  }
}

///|
fn conductor_draft_strings(
  fields : Map[String, Json],
  field : String,
) -> Array[String]? {
  match fields.get(field) {
    Some(Array(values)) => {
      let strings : Array[String] = []
      for value in values {
        match value {
          String(raw) => {
            let trimmed = raw.trim().to_owned()
            if trimmed == "" {
              return None
            }
            strings.push(trimmed)
          }
          _ => return None
        }
      }
      Some(strings)
    }
    _ => None
  }
}

///|
fn conductor_draft_bool(
  fields : Map[String, Json],
  field : String,
  default : Bool,
) -> Bool? {
  match fields.get(field) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    None => Some(default)
    _ => None
  }
}

///|
fn conductor_draft_int(fields : Map[String, Json], field : String) -> Int? {
  match fields.get(field) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn conductor_draft_int64_or(
  fields : Map[String, Json],
  field : String,
  default : Int64,
) -> Int64? {
  match fields.get(field) {
    Some(Number(value, ..)) => Some(value.to_int64())
    None => Some(default)
    _ => None
  }
}

///|
fn conductor_draft_has_only(
  fields : Map[String, Json],
  allowed : Array[String],
) -> Bool {
  let valid = @ref.new(true)
  fields.each(fn(key, _) { if !allowed.contains(key) { valid.val = false } })
  valid.val
}

///|
fn conductor_provider_surface(value : String) -> @control.ProviderSurfaceId? {
  match value.trim().to_lower() {
    "claude" | "claude-subscription" | "claude-cli" =>
      Some(@control.ProviderSurfaceId::ClaudeSubscriptionCli)
    "codex" | "codex-subscription" | "codex-cli" =>
      Some(@control.ProviderSurfaceId::CodexSubscriptionCli)
    _ => None
  }
}

///|
fn decode_conductor_part_draft(
  json : Json,
) -> Result[ConductorPartDraft, @types.ChoirError] {
  guard json is Object(fields) else {
    return Err(goal_submission_error("Conductor Part draft must be an object"))
  }
  if !conductor_draft_has_only(fields, [
      "part_id", "instruction", "provider", "exact_paths", "path_trees", "repository_wide",
      "verify_args", "verify_timeout_ms",
    ]) {
    return Err(goal_submission_error("Conductor Part draft has unknown fields"))
  }
  let part_id = match conductor_draft_string(fields, "part_id") {
    Some(value) => @control.PartId(value)
    None => return Err(goal_submission_error("Conductor Part ID is missing"))
  }
  let instruction = match conductor_draft_string(fields, "instruction") {
    Some(value) => value
    None =>
      return Err(goal_submission_error("Conductor instruction is missing"))
  }
  let provider_surface = match conductor_draft_string(fields, "provider") {
    Some(value) =>
      match conductor_provider_surface(value) {
        Some(surface) => surface
        None =>
          return Err(goal_submission_error("Conductor provider is unsupported"))
      }
    None => return Err(goal_submission_error("Conductor provider is missing"))
  }
  let exact_paths = match fields.get("exact_paths") {
    None => []
    Some(_) =>
      match conductor_draft_strings(fields, "exact_paths") {
        Some(values) => values.map(fn(path) { @control.RepoPath(path) })
        None => return Err(goal_submission_error("exact_paths is invalid"))
      }
  }
  let path_trees = match fields.get("path_trees") {
    None => []
    Some(_) =>
      match conductor_draft_strings(fields, "path_trees") {
        Some(values) => values.map(fn(path) { @control.RepoPath(path) })
        None => return Err(goal_submission_error("path_trees is invalid"))
      }
  }
  let repository_wide = match
    conductor_draft_bool(fields, "repository_wide", false) {
    Some(value) => value
    None => return Err(goal_submission_error("repository_wide is invalid"))
  }
  if repository_wide && (exact_paths.length() > 0 || path_trees.length() > 0) {
    return Err(
      goal_submission_error(
        "repository_wide cannot be combined with path declarations",
      ),
    )
  }
  if !repository_wide && exact_paths.length() == 0 && path_trees.length() == 0 {
    return Err(goal_submission_error("mutation declaration is empty"))
  }
  let arguments = match conductor_draft_strings(fields, "verify_args") {
    Some(values) if values.length() > 0 => values
    _ => return Err(goal_submission_error("verify_args is missing or invalid"))
  }
  let timeout_ms = match
    conductor_draft_int64_or(fields, "verify_timeout_ms", 120000L) {
    Some(value) if value > 0L && value <= 600000L => value
    _ => return Err(goal_submission_error("verify_timeout_ms is invalid"))
  }
  Ok({
    part_id,
    instruction,
    exact_paths,
    path_trees,
    repository_wide,
    verification: { arguments, timeout_ms },
    provider_surface,
  })
}

///|
pub fn decode_conductor_goal_draft(
  content : String,
) -> Result[ConductorGoalDraft, @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ =>
      return Err(
        goal_submission_error("Conductor Goal draft is not valid JSON"),
      )
  }
  guard json is Object(fields) else {
    return Err(goal_submission_error("Conductor Goal draft must be an object"))
  }
  if !conductor_draft_has_only(fields, [
      "proposal_id", "goal_id", "base_ref", "integration_target_ref", "maximum_parallel_parts",
      "parts",
    ]) {
    return Err(goal_submission_error("Conductor Goal draft has unknown fields"))
  }
  let proposal_id = match conductor_draft_string(fields, "proposal_id") {
    Some(value) => GoalProposalId(value)
    None => return Err(goal_submission_error("proposal_id is missing"))
  }
  let goal_id = match conductor_draft_string(fields, "goal_id") {
    Some(value) => @control.GoalId(value)
    None => return Err(goal_submission_error("goal_id is missing"))
  }
  let base_ref = match conductor_draft_string(fields, "base_ref") {
    Some(value) => GitRefName(value)
    None => return Err(goal_submission_error("base_ref is missing"))
  }
  let integration_target_ref = match
    conductor_draft_string(fields, "integration_target_ref") {
    Some(value) => GitRefName(value)
    None =>
      return Err(goal_submission_error("integration_target_ref is missing"))
  }
  let maximum_parallel_parts = match
    conductor_draft_int(fields, "maximum_parallel_parts") {
    Some(value) if value > 0 => value
    _ => return Err(goal_submission_error("maximum_parallel_parts is invalid"))
  }
  let parts = match fields.get("parts") {
    Some(Array(values)) if values.length() > 0 => {
      let decoded : Array[ConductorPartDraft] = []
      for value in values {
        match decode_conductor_part_draft(value) {
          Ok(part) => decoded.push(part)
          Err(error) => return Err(error)
        }
      }
      decoded
    }
    _ => return Err(goal_submission_error("parts is missing or invalid"))
  }
  Ok({
    proposal_id,
    goal_id,
    base_ref,
    integration_target_ref,
    maximum_parallel_parts,
    parts,
  })
}

///|
fn bead_string(fields : Map[String, Json], field : String) -> String {
  match fields.get(field) {
    Some(String(value)) => value
    Some(Number(value, ..)) => value.to_string()
    _ => ""
  }
}

///|
fn validate_bead_issue_fields(
  fields : Map[String, Json],
  nested_dependency : Bool,
) -> Result[Int, @types.ChoirError] {
  for field in ["id", "title", "status", "issue_type", "updated_at"] {
    if bead_string(fields, field).trim() == "" {
      return Err(goal_submission_error("Beads issue requires " + field))
    }
  }
  match fields.get("priority") {
    Some(Number(value, ..)) if value.to_int() >= 0 && value.to_int() <= 4 => ()
    _ => return Err(goal_submission_error("Beads issue priority is invalid"))
  }
  if nested_dependency {
    if bead_string(fields, "dependency_type").trim() == "" {
      return Err(
        goal_submission_error("Beads dependency requires dependency_type"),
      )
    }
    return Ok(0)
  }
  match fields.get("dependency_count") {
    Some(Number(value, ..)) if value.to_int() >= 0 => Ok(value.to_int())
    _ => Err(goal_submission_error("Beads issue dependency_count is invalid"))
  }
}

///|
fn validate_bead_dependency_contract(
  fields : Map[String, Json],
) -> Result[Unit, @types.ChoirError] {
  let expected = match validate_bead_issue_fields(fields, false) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match fields.get("dependencies") {
    None if expected == 0 => Ok(())
    Some(Array(values)) if values.length() == expected => {
      for value in values {
        guard value is Object(dependency) else {
          return Err(goal_submission_error("Beads dependency is not an issue"))
        }
        match validate_bead_issue_fields(dependency, true) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      Ok(())
    }
    _ =>
      Err(
        goal_submission_error(
          "Beads dependency_count does not match dependency details",
        ),
      )
  }
}

///|
fn bead_dependency_ids(fields : Map[String, Json]) -> Array[@control.PartId] {
  let ids : Array[@control.PartId] = []
  match fields.get("dependencies") {
    Some(Array(values)) =>
      for value in values {
        match value {
          Object(dependency) => {
            let kind = bead_string(dependency, "dependency_type")
            let id = bead_string(dependency, "id").trim().to_owned()
            if id != "" && (kind == "" || kind == "blocks") {
              ids.push(@control.PartId(id))
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  unique_sorted_part_ids(ids)
}

///|
fn bead_source_state(fields : Map[String, Json]) -> SelectionSourceState {
  let status = bead_string(fields, "status").trim().to_lower()
  let assignee = bead_string(fields, "assignee").trim()
  match status {
    "closed" => SelectionSourceClosed
    "in_progress" => SelectionSourceAlreadyOwned
    "open" | "blocked" | "deferred" =>
      if assignee == "" {
        SelectionSourceOpen
      } else {
        SelectionSourceAlreadyOwned
      }
    _ => SelectionSourceAmbiguous
  }
}

///|
fn bead_source_revision_digest(fields : Map[String, Json]) -> @control.Digest {
  let dependencies = bead_dependency_ids(fields)
  goal_submission_domain_digest(
    "choir.bead-source-revision.v1",
    [
      bead_string(fields, "id").to_json(),
      bead_string(fields, "title").to_json(),
      bead_string(fields, "description").to_json(),
      bead_string(fields, "acceptance_criteria").to_json(),
      bead_string(fields, "notes").to_json(),
      bead_string(fields, "status").to_json(),
      bead_string(fields, "priority").to_json(),
      bead_string(fields, "issue_type").to_json(),
      bead_string(fields, "assignee").to_json(),
      bead_string(fields, "updated_at").to_json(),
      dependencies.to_json(),
    ].to_json(),
  )
}

///|
fn source_part_from_bead_fields(
  fields : Map[String, Json],
) -> GoalSelectionSourcePart? {
  let id = bead_string(fields, "id").trim().to_owned()
  if id == "" {
    return None
  }
  Some({
    part_id: @control.PartId(id),
    source_revision_digest: bead_source_revision_digest(fields),
    dependency_ids: bead_dependency_ids(fields),
    state: bead_source_state(fields),
  })
}

///|
fn add_captured_source_part(
  parts : Array[GoalSelectionSourcePart],
  candidate : GoalSelectionSourcePart,
) -> Result[Unit, @types.ChoirError] {
  for existing in parts {
    if existing.part_id == candidate.part_id {
      return if existing == candidate {
        Ok(())
      } else {
        Err(
          goal_submission_error("Beads returned conflicting source revisions"),
        )
      }
    }
  }
  parts.push(candidate)
  Ok(())
}

///|
fn capture_nested_bead_dependencies(
  parts : Array[GoalSelectionSourcePart],
  fields : Map[String, Json],
) -> Result[Unit, @types.ChoirError] {
  match fields.get("dependencies") {
    Some(Array(values)) =>
      for value in values {
        match value {
          Object(dependency) => {
            let kind = bead_string(dependency, "dependency_type")
            if kind == "" || kind == "blocks" {
              match source_part_from_bead_fields(dependency) {
                Some(part) =>
                  match add_captured_source_part(parts, part) {
                    Ok(_) => ()
                    Err(error) => return Err(error)
                  }
                None => ()
              }
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  Ok(())
}

///|
pub fn goal_selection_snapshot_from_beads_json(
  repository_id : RepositoryId,
  base_commit_oid : @control.GitOid,
  base_tree_oid : @control.GitOid,
  content : String,
) -> Result[GoalSelectionSnapshot, @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ => return Err(goal_submission_error("Beads capture is not valid JSON"))
  }
  let values = match json {
    Array(items) => items
    Object(_) => [json]
    _ => return Err(goal_submission_error("Beads capture has the wrong shape"))
  }
  let parts : Array[GoalSelectionSourcePart] = []
  for value in values {
    match value {
      Object(fields) => {
        match validate_bead_dependency_contract(fields) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        match source_part_from_bead_fields(fields) {
          Some(part) =>
            match add_captured_source_part(parts, part) {
              Ok(_) => ()
              Err(error) => return Err(error)
            }
          None => return Err(goal_submission_error("Beads issue has no ID"))
        }
        match capture_nested_bead_dependencies(parts, fields) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      _ =>
        return Err(goal_submission_error("Beads capture contains a non-issue"))
    }
  }
  parts.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
  Ok({ repository_id, base_commit_oid, base_tree_oid, parts })
}

///|
pub fn goal_selection_snapshot_bytes(snapshot : GoalSelectionSnapshot) -> Bytes {
  @utf8.encode(
    "choir.goal-selection-snapshot.v1\u{00}" +
    canonical_goal_selection_snapshot(snapshot).to_json().stringify(indent=0),
  )
}

///|
pub fn decode_goal_selection_snapshot(
  content : Bytes,
) -> Result[GoalSelectionSnapshot, @types.ChoirError] {
  let encoded = @utf8.decode_lossy(content)
  let prefix = "choir.goal-selection-snapshot.v1\u{00}"
  if !encoded.has_prefix(prefix) {
    return Err(goal_submission_error("selection snapshot domain is invalid"))
  }
  let json = @json.parse(encoded[prefix.length():].to_owned()) catch {
    _ =>
      return Err(goal_submission_error("selection snapshot is not valid JSON"))
  }
  let snapshot : GoalSelectionSnapshot = @json.from_json(json) catch {
    _ =>
      return Err(
        goal_submission_error("selection snapshot has the wrong schema"),
      )
  }
  match validate_selection_snapshot(snapshot) {
    Ok(_) => Ok(snapshot)
    Err(error) => Err(error)
  }
}
