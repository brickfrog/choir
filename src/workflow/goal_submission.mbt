///|
pub(all) struct GoalProposalId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct SelectionDecisionId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct RepositoryId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct GitRefName(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum GoalSelectionPolicy {
  ExactClosure
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SelectionSourceState {
  SelectionSourceOpen
  SelectionSourceClosed
  SelectionSourceAlreadyOwned
  SelectionSourceAmbiguous
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalSelectionSourcePart {
  part_id : @control.PartId
  source_revision_digest : @control.Digest
  source_content_digest : @control.Digest
  dependency_ids : Array[@control.PartId]
  state : SelectionSourceState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalSelectionSnapshot {
  repository_id : RepositoryId
  base_commit_oid : @control.GitOid
  base_tree_oid : @control.GitOid
  parts : Array[GoalSelectionSourcePart]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConductorPartProposal {
  part_id : @control.PartId
  source_revision_digest : @control.Digest
  source_content_digest : @control.Digest
  dependency_ids : Array[@control.PartId]
  task_contract : @control.TaskContractRevision
  provider_surface : @control.ProviderSurfaceId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalProposal {
  id : GoalProposalId
  goal_id : @control.GoalId
  repository_id : RepositoryId
  base_ref : GitRefName
  expected_base_commit_oid : @control.GitOid
  expected_base_tree_oid : @control.GitOid
  integration_target_ref : GitRefName
  selection_policy : GoalSelectionPolicy
  maximum_parallel_parts : Int
  parts : Array[ConductorPartProposal]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SelectionRejectionReason {
  SelectionNotFound
  SelectionDuplicate
  SelectionNotOpen
  SelectionAlreadyOwned
  SelectionMissingOpenDependency
  SelectionDependencyCycle
  SelectionAmbiguous
  SelectionInvalidTaskContract
  SelectionInvalidMutationDeclaration
  SelectionPolicyExcluded
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartSelectionRejection {
  part_id : @control.PartId
  reasons : Array[SelectionRejectionReason]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AcceptedGoalPart {
  part : @control.GoalPart
  source_revision_digest : @control.Digest
  source_content_digest : @control.Digest
  task_contract : @control.TaskContractRevision
  provider_surface : @control.ProviderSurfaceId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalSelectionOutcome {
  GoalSelectionAccepted
  GoalSelectionRejected
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalSelectionDecision {
  id : SelectionDecisionId
  proposal : GoalProposal
  proposal_digest : @control.Digest
  source_snapshot_digest : @control.Digest
  proposed_part_ids : Array[@control.PartId]
  accepted_parts : Array[AcceptedGoalPart]
  rejections : Array[PartSelectionRejection]
  goal : @control.Goal?
  outcome : GoalSelectionOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_submission_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal submission: " + detail)
}

///|
fn goal_submission_domain_digest(
  domain : String,
  json : Json,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + json.stringify(indent=0)),
  )
}

///|
fn sorted_part_ids(ids : Array[@control.PartId]) -> Array[@control.PartId] {
  let sorted = ids.copy()
  sorted.sort_by(fn(left, right) { left.compare(right) })
  sorted
}

///|
fn unique_sorted_part_ids(
  ids : Array[@control.PartId],
) -> Array[@control.PartId] {
  let unique : Array[@control.PartId] = []
  for id in sorted_part_ids(ids) {
    if !unique.contains(id) {
      unique.push(id)
    }
  }
  unique
}

///|
fn valid_git_ref_name(name : GitRefName) -> Bool {
  let value = name.0
  value.has_prefix("refs/") &&
  !value.has_suffix("/") &&
  !value.contains("\u{00}") &&
  !value.contains("..") &&
  !value.contains("//") &&
  !value.contains("@{") &&
  !value.contains("\\") &&
  !value.contains(" ") &&
  !value.contains("~") &&
  !value.contains("^") &&
  !value.contains(":") &&
  !value.contains("?") &&
  !value.contains("*") &&
  !value.contains("[")
}

///|
fn source_part(
  snapshot : GoalSelectionSnapshot,
  part_id : @control.PartId,
) -> GoalSelectionSourcePart? {
  for part in snapshot.parts {
    if part.part_id == part_id {
      return Some(part)
    }
  }
  None
}

///|
fn proposed_part(
  proposal : GoalProposal,
  part_id : @control.PartId,
) -> ConductorPartProposal? {
  for part in proposal.parts {
    if part.part_id == part_id {
      return Some(part)
    }
  }
  None
}

///|
fn proposal_part_count(
  proposal : GoalProposal,
  part_id : @control.PartId,
) -> Int {
  let mut count = 0
  for part in proposal.parts {
    if part.part_id == part_id {
      count = count + 1
    }
  }
  count
}

///|
fn add_rejection(
  rejections : Array[PartSelectionRejection],
  part_id : @control.PartId,
  reason : SelectionRejectionReason,
) -> Unit {
  for rejection in rejections {
    if rejection.part_id == part_id {
      if !rejection.reasons.contains(reason) {
        rejection.reasons.push(reason)
      }
      return
    }
  }
  rejections.push({ part_id, reasons: [reason] })
}

///|
fn snapshot_part_requires_selection(part : GoalSelectionSourcePart) -> Bool {
  match part.state {
    SelectionSourceOpen
    | SelectionSourceAlreadyOwned
    | SelectionSourceAmbiguous => true
    SelectionSourceClosed => false
  }
}

///|
fn proposal_path_reaches(
  proposal : GoalProposal,
  current : @control.PartId,
  target : @control.PartId,
  visited : Array[@control.PartId],
) -> Bool {
  if current == target {
    return true
  }
  if visited.contains(current) {
    return false
  }
  let next_visited = visited.copy()
  next_visited.push(current)
  match proposed_part(proposal, current) {
    Some(part) =>
      part.dependency_ids.any(fn(dependency_id) {
        proposal_path_reaches(proposal, dependency_id, target, next_visited)
      })
    None => false
  }
}

///|
fn proposal_part_has_cycle(
  proposal : GoalProposal,
  part : ConductorPartProposal,
) -> Bool {
  part.dependency_ids.any(fn(dependency_id) {
    proposal_path_reaches(proposal, dependency_id, part.part_id, [])
  })
}

///|
fn validate_selection_snapshot(
  snapshot : GoalSelectionSnapshot,
) -> Result[Unit, @types.ChoirError] {
  if snapshot.repository_id.0 == "" ||
    snapshot.repository_id.0.contains("\u{00}") {
    return Err(goal_submission_error("repository identity is invalid"))
  }
  for index = 0; index < snapshot.parts.length(); index = index + 1 {
    let part = snapshot.parts[index]
    match @storage.validate_digest(part.source_revision_digest) {
      Ok(_) => ()
      Err(_) => return Err(goal_submission_error("source revision is invalid"))
    }
    match @storage.validate_digest(part.source_content_digest) {
      Ok(_) => ()
      Err(_) => return Err(goal_submission_error("source content is invalid"))
    }
    if part.dependency_ids.contains(part.part_id) {
      return Err(goal_submission_error("source dependency is self-referential"))
    }
    for other = index + 1; other < snapshot.parts.length(); other = other + 1 {
      if part.part_id == snapshot.parts[other].part_id {
        return Err(goal_submission_error("source snapshot has duplicate Parts"))
      }
    }
    for dependency_id in part.dependency_ids {
      if source_part(snapshot, dependency_id) is None {
        return Err(goal_submission_error("source dependency is absent"))
      }
    }
  }
  Ok(())
}

///|
fn canonical_goal_selection_snapshot(
  snapshot : GoalSelectionSnapshot,
) -> GoalSelectionSnapshot {
  let parts = snapshot.parts.map(fn(part) {
    { ..part, dependency_ids: sorted_part_ids(part.dependency_ids) }
  })
  parts.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
  { ..snapshot, parts, }
}

///|
pub fn goal_selection_snapshot_digest(
  snapshot : GoalSelectionSnapshot,
) -> @control.Digest {
  @storage.artifact_digest(goal_selection_snapshot_bytes(snapshot))
}

///|
fn canonical_goal_proposal_json(proposal : GoalProposal) -> Json {
  let parts = proposal.parts.copy()
  parts.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
  let rows : Array[Json] = []
  for part in parts {
    rows.push(
      [
        part.part_id.to_json(),
        part.source_revision_digest.to_json(),
        part.source_content_digest.to_json(),
        sorted_part_ids(part.dependency_ids).to_json(),
        part.task_contract.id.to_json(),
        part.task_contract.digest.to_json(),
        part.provider_surface.to_json(),
      ].to_json(),
    )
  }
  [
    proposal.id.to_json(),
    proposal.goal_id.to_json(),
    proposal.repository_id.to_json(),
    proposal.base_ref.to_json(),
    proposal.expected_base_commit_oid.to_json(),
    proposal.expected_base_tree_oid.to_json(),
    proposal.integration_target_ref.to_json(),
    proposal.selection_policy.to_json(),
    proposal.maximum_parallel_parts.to_json(),
    rows.to_json(),
  ].to_json()
}

///|
pub fn goal_proposal_digest(proposal : GoalProposal) -> @control.Digest {
  goal_submission_domain_digest(
    "choir.goal-proposal.v1",
    canonical_goal_proposal_json(proposal),
  )
}

///|
pub fn evaluate_goal_proposal(
  proposal : GoalProposal,
  snapshot : GoalSelectionSnapshot,
  is_nfc : (String) -> Bool,
) -> Result[GoalSelectionDecision, @types.ChoirError] {
  match validate_selection_snapshot(snapshot) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if proposal.id.0 == "" || proposal.id.0.contains("\u{00}") {
    return Err(goal_submission_error("proposal_id is invalid"))
  }
  if proposal.goal_id.0 == "" || proposal.goal_id.0.contains("\u{00}") {
    return Err(goal_submission_error("goal_id is invalid"))
  }
  if proposal.parts.length() == 0 {
    return Err(goal_submission_error("proposal parts are empty"))
  }
  if proposal.maximum_parallel_parts <= 0 {
    return Err(goal_submission_error("maximum_parallel_parts is invalid"))
  }
  if proposal.repository_id != snapshot.repository_id ||
    proposal.expected_base_commit_oid != snapshot.base_commit_oid ||
    proposal.expected_base_tree_oid != snapshot.base_tree_oid {
    return Err(goal_submission_error("captured repository snapshot mismatch"))
  }
  if !valid_git_ref_name(proposal.base_ref) {
    return Err(
      goal_submission_error(
        "base_ref must be a fully qualified refs/... Git ref",
      ),
    )
  }
  if !valid_git_ref_name(proposal.integration_target_ref) {
    return Err(
      goal_submission_error(
        "integration_target_ref must be a fully qualified refs/... Git ref",
      ),
    )
  }
  let proposed_part_ids = unique_sorted_part_ids(
    proposal.parts.map(fn(part) { part.part_id }),
  )
  let rejections : Array[PartSelectionRejection] = []
  for part_id in proposed_part_ids {
    if proposal_part_count(proposal, part_id) > 1 {
      add_rejection(rejections, part_id, SelectionDuplicate)
      continue
    }
    let part = match proposed_part(proposal, part_id) {
      Some(value) => value
      None => continue
    }
    let source = match source_part(snapshot, part_id) {
      Some(value) => value
      None => {
        add_rejection(rejections, part_id, SelectionNotFound)
        continue
      }
    }
    match source.state {
      SelectionSourceClosed =>
        add_rejection(rejections, part_id, SelectionNotOpen)
      SelectionSourceAlreadyOwned =>
        add_rejection(rejections, part_id, SelectionAlreadyOwned)
      SelectionSourceAmbiguous =>
        add_rejection(rejections, part_id, SelectionAmbiguous)
      SelectionSourceOpen => ()
    }
    if part.source_revision_digest != source.source_revision_digest ||
      part.source_content_digest != source.source_content_digest ||
      sorted_part_ids(part.dependency_ids) !=
      sorted_part_ids(source.dependency_ids) ||
      part.task_contract.goal_id != proposal.goal_id ||
      part.task_contract.part_id != part.part_id ||
      part.task_contract.base_commit_oid != snapshot.base_commit_oid ||
      part.task_contract.base_tree_oid != snapshot.base_tree_oid {
      add_rejection(rejections, part_id, SelectionInvalidTaskContract)
    }
    match part.task_contract.mutation_declaration {
      @control.MutationDeclaration::CompleteMutationDeclaration(_) => ()
      _ =>
        add_rejection(rejections, part_id, SelectionInvalidMutationDeclaration)
    }
    if @control.validate_task_contract_revision(part.task_contract, is_nfc)
      is Err(_) {
      add_rejection(rejections, part_id, SelectionInvalidTaskContract)
    }
    let missing_open_dependency = source.dependency_ids.any(fn(dependency_id) {
      match source_part(snapshot, dependency_id) {
        Some(dependency) =>
          snapshot_part_requires_selection(dependency) &&
          !proposed_part_ids.contains(dependency_id)
        None => true
      }
    })
    if missing_open_dependency {
      add_rejection(rejections, part_id, SelectionMissingOpenDependency)
    }
    if proposal_part_has_cycle(proposal, part) {
      add_rejection(rejections, part_id, SelectionDependencyCycle)
    }
  }
  rejections.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
  let proposal_digest = goal_proposal_digest(proposal)
  let source_snapshot_digest = goal_selection_snapshot_digest(snapshot)
  let accepted_parts : Array[AcceptedGoalPart] = []
  let goal : @control.Goal? = if rejections.length() == 0 {
    for part_id in proposed_part_ids {
      guard proposed_part(proposal, part_id) is Some(part) else { continue }
      accepted_parts.push({
        part: {
          id: part.part_id,
          goal_id: proposal.goal_id,
          dependency_ids: sorted_part_ids(part.dependency_ids),
          task_contract_revision_id: part.task_contract.id,
          lifecycle: @control.PartLifecycle::PartPending,
        },
        source_revision_digest: part.source_revision_digest,
        source_content_digest: part.source_content_digest,
        task_contract: part.task_contract,
        provider_surface: part.provider_surface,
      })
    }
    Some({
      id: proposal.goal_id,
      contract_digest: goal_submission_domain_digest(
        "choir.goal-contract.v1",
        [
          proposal_digest.to_json(),
          source_snapshot_digest.to_json(),
          accepted_parts.map(fn(part) { part.part.id }).to_json(),
        ].to_json(),
      ),
      lifecycle: @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalRunning,
      ),
    })
  } else {
    None
  }
  let outcome = if goal is Some(_) {
    GoalSelectionAccepted
  } else {
    GoalSelectionRejected
  }
  let identity_digest = goal_submission_domain_digest(
    "choir.goal-selection-decision-identity.v1",
    [
      proposal_digest.to_json(),
      source_snapshot_digest.to_json(),
      accepted_parts.to_json(),
      rejections.to_json(),
      outcome.to_json(),
    ].to_json(),
  )
  Ok({
    id: SelectionDecisionId(
      "selection-" + @storage.digest_text(identity_digest),
    ),
    proposal,
    proposal_digest,
    source_snapshot_digest,
    proposed_part_ids,
    accepted_parts,
    rejections,
    goal,
    outcome,
  })
}

///|
pub fn goal_selection_decision_bytes(decision : GoalSelectionDecision) -> Bytes {
  @utf8.encode(decision.to_json().stringify(indent=0))
}

///|
pub fn goal_selection_decision_digest(
  decision : GoalSelectionDecision,
) -> @control.Digest {
  @storage.artifact_digest(goal_selection_decision_bytes(decision))
}

///|
pub fn decode_goal_selection_decision(
  content : Bytes,
) -> Result[GoalSelectionDecision, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ =>
      return Err(goal_submission_error("selection decision is not valid JSON"))
  }
  let decision : GoalSelectionDecision = @json.from_json(json) catch {
    _ =>
      return Err(
        goal_submission_error("selection decision has the wrong schema"),
      )
  }
  if decision.id.0 == "" ||
    decision.proposal_digest != goal_proposal_digest(decision.proposal) ||
    @storage.validate_digest(decision.source_snapshot_digest) is Err(_) ||
    (decision.outcome == GoalSelectionAccepted) != (decision.goal is Some(_)) ||
    (decision.outcome == GoalSelectionAccepted) !=
    (decision.rejections.length() == 0) {
    Err(goal_submission_error("selection decision identity is invalid"))
  } else {
    Ok(decision)
  }
}
