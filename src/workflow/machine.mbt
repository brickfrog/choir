///|
fn workflow_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Part workflow: " + detail)
}

///|
fn domain_digest(domain : String, json : Json) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + json.stringify(indent=0)),
  )
}

///|
pub fn part_snapshot_bytes(snapshot : PartWorkflowSnapshot) -> Bytes {
  @utf8.encode(snapshot.to_json().stringify(indent=0))
}

///|
pub fn part_snapshot_digest(snapshot : PartWorkflowSnapshot) -> @control.Digest {
  @storage.artifact_digest(part_snapshot_bytes(snapshot))
}

///|
pub fn decode_part_snapshot(
  content : Bytes,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(workflow_error("durable snapshot is not valid JSON"))
  }
  let snapshot : PartWorkflowSnapshot = @json.from_json(json) catch {
    _ =>
      return Err(workflow_error("durable snapshot does not match the schema"))
  }
  Ok(snapshot)
}

///|
pub fn part_effect_observation_digest(
  observation : PartEffectObservation,
) -> @control.Digest {
  domain_digest("choir.part-effect-observation.v1", observation.to_json())
}

///|
pub fn part_effect_witness_bytes(witness : PartEffectWitness) -> Bytes {
  @utf8.encode(witness.to_json().stringify(indent=0))
}

///|
pub fn decode_part_effect_witness(
  content : Bytes,
) -> Result[PartEffectWitness, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(workflow_error("effect witness is not valid JSON"))
  }
  let witness : PartEffectWitness = @json.from_json(json) catch {
    _ => return Err(workflow_error("effect witness does not match the schema"))
  }
  if witness.effect_id.0 == "" ||
    witness.observed_at <= 0L ||
    witness.observation_digest !=
    part_effect_observation_digest(witness.observation) {
    return Err(workflow_error("effect witness identity is invalid"))
  }
  Ok(witness)
}

///|
fn verification_subject(
  candidate : @control.CandidateCommit,
  contract : @control.TaskContractRevision,
) -> @control.PartVerificationSubject {
  let identity = [
    candidate.part_id.to_json(),
    candidate.take_id.to_json(),
    candidate.commit_oid.to_json(),
    candidate.tree_oid.to_json(),
    contract.id.to_json(),
    contract.digest.to_json(),
  ].to_json()
  {
    part_id: candidate.part_id,
    candidate_take_id: candidate.take_id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    task_contract_revision_id: contract.id,
    task_contract_digest: contract.digest,
    subject_digest: domain_digest(
      "choir.part-verification-subject.v1", identity,
    ),
  }
}

///|
fn audit_subject(
  subject : @control.PartVerificationSubject,
  authorization : @control.VerificationAuthorizationSet,
  audit_context_digest : @control.Digest,
) -> @control.PartAuditSubject {
  let identity = [
    subject.part_id.to_json(),
    subject.candidate_take_id.to_json(),
    subject.candidate_commit_oid.to_json(),
    subject.candidate_tree_oid.to_json(),
    subject.task_contract_revision_id.to_json(),
    subject.task_contract_digest.to_json(),
    authorization.receipt_set_digest.to_json(),
    authorization.evidence_manifest_digest.to_json(),
    audit_context_digest.to_json(),
  ].to_json()
  {
    part_id: subject.part_id,
    candidate_take_id: subject.candidate_take_id,
    candidate_commit_oid: subject.candidate_commit_oid,
    candidate_tree_oid: subject.candidate_tree_oid,
    task_contract_revision_id: subject.task_contract_revision_id,
    task_contract_digest: subject.task_contract_digest,
    verification_receipt_set_digest: authorization.receipt_set_digest,
    verification_evidence_manifest_digest: authorization.evidence_manifest_digest,
    audit_context_digest,
    subject_digest: domain_digest("choir.part-audit-subject.v1", identity),
  }
}

///|
fn validate_planned_sandbox(
  lease : @control.SandboxLease,
  take : @control.Take,
) -> Bool {
  lease.take_id == take.id &&
  lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeasePlanned
}

///|
fn validate_planned_session(
  session : @control.HarnessSession,
  take : @control.Take,
  lease : @control.SandboxLease,
) -> Bool {
  session.take_id == take.id &&
  session.sandbox_generation_id == lease.generation_id &&
  session.lifecycle == @control.HarnessSessionLifecycle::HarnessSessionPlanned &&
  session.last_choir_sequence == @control.EventSequence(0L) &&
  session.open_tool_execution_ids.length() == 0
}

///|
pub fn initialize_part_workflow(
  workflow_id : @control.WorkflowId,
  goal : @control.Goal,
  part : @control.GoalPart,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  fencing_epoch : @control.FencingEpoch,
  is_nfc : (String) -> Bool,
  admitted_provider_surfaces~ : Array[@control.ProviderSurfaceId],
  part_context_manifest? : @migration.PartContextManifest? = None,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if workflow_id.0 == "" || workflow_id.0.contains("\u{00}") {
    return Err(workflow_error("workflow identity is empty or invalid"))
  }
  // Provider authority is captured, not chosen here. A Part may only run on a
  // surface its contract admitted, so an identity plan naming any other
  // surface is refused rather than silently accepted.
  if !admitted_provider_surfaces_are_canonical(admitted_provider_surfaces) ||
    !admitted_provider_surfaces.contains(
      identities.implementation_session.surface,
    ) ||
    !admitted_provider_surfaces.contains(identities.audit_session.surface) {
    return Err(
      workflow_error(
        "provider surface is not admitted by the captured contract",
      ),
    )
  }
  if goal.lifecycle !=
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ) ||
    part.goal_id != goal.id ||
    contract.goal_id != goal.id ||
    contract.part_id != part.id ||
    part.task_contract_revision_id != contract.id ||
    contract.verification_specs.length() != 1 {
    return Err(workflow_error("goal, Part, and contract identities disagree"))
  }
  match @control.validate_task_contract_revision(contract, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match (contract.migration_contract_ref, part_context_manifest) {
    (None, None) => ()
    (Some(reference), Some(manifest)) =>
      if reference != manifest.migration_contract_ref ||
        manifest.part_task_contract_revision_id != contract.id ||
        manifest.part_task_contract_digest != contract.digest ||
        @migration.validate_part_context_manifest(manifest) is Err(_) {
        return Err(workflow_error("migration Part context is stale"))
      }
    _ => return Err(workflow_error("migration Part context is incomplete"))
  }
  if identities.implementation_take.lifecycle !=
    @control.TakeLifecycle::TakePlanned ||
    identities.verification_take.lifecycle !=
    @control.TakeLifecycle::TakePlanned ||
    identities.audit_take.lifecycle != @control.TakeLifecycle::TakePlanned ||
    !validate_planned_sandbox(
      identities.implementation_sandbox,
      identities.implementation_take,
    ) ||
    !validate_planned_sandbox(
      identities.verification_sandbox,
      identities.verification_take,
    ) ||
    !validate_planned_sandbox(identities.audit_sandbox, identities.audit_take) ||
    !validate_planned_session(
      identities.implementation_session,
      identities.implementation_take,
      identities.implementation_sandbox,
    ) ||
    !validate_planned_session(
      identities.audit_session,
      identities.audit_take,
      identities.audit_sandbox,
    ) {
    return Err(workflow_error("Take resource identity plan is inconsistent"))
  }
  match identities.implementation_take.purpose {
    @control.TakePurpose::Implementation(part_id, revision_id) =>
      if part_id != part.id || revision_id != contract.id {
        return Err(workflow_error("implementation Take purpose is invalid"))
      }
    _ => return Err(workflow_error("implementation Take purpose is invalid"))
  }
  match identities.verification_take.purpose {
    @control.TakePurpose::PartVerification(part_id, candidate_take_id, _) =>
      if part_id != part.id ||
        candidate_take_id != identities.implementation_take.id {
        return Err(workflow_error("verification Take purpose is invalid"))
      }
    _ => return Err(workflow_error("verification Take purpose is invalid"))
  }
  match identities.audit_take.purpose {
    @control.TakePurpose::PartAudit(part_id, candidate_take_id, _) =>
      if part_id != part.id ||
        candidate_take_id != identities.implementation_take.id {
        return Err(workflow_error("audit Take purpose is invalid"))
      }
    _ => return Err(workflow_error("audit Take purpose is invalid"))
  }
  let ready = match
    @control.transition_part(part, @control.PartTransition::MarkPartReady) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let executing = match
    @control.transition_part(
      ready,
      @control.PartTransition::StartPartTake(identities.implementation_take.id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let implementation_take = match
    @control.transition_take(
      identities.implementation_take,
      @control.TakeTransition::LeaseTake(fencing_epoch),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    workflow_id,
    durable_version: 0,
    fencing_epoch,
    stage: PartAccepted,
    goal,
    part: executing,
    task_contract: contract,
    task_contract_history: [contract],
    part_context_manifest,
    identities,
    admitted_provider_surfaces,
    provider_failovers: [],
    implementation_take,
    verification_take: identities.verification_take,
    audit_take: identities.audit_take,
    prior_takes: [],
    prior_take_evidence: [],
    sandbox_leases: [],
    harness_sessions: [],
    harness_events: [],
    prepared_commands: [],
    implementation_result: None,
    candidate: None,
    verification_subject: None,
    verification_slots: [],
    verification_receipts: [],
    verification_authorization: None,
    audit_subject: None,
    audit_context: None,
    audit_result: None,
    audit_receipt: None,
    integration_lease: None,
    integration_intent: None,
    promotion_commit: None,
    integration_receipt: None,
    integration_conflicts: [],
    pending_effect: None,
    effect_receipts: [],
    dispatch_diagnostic: None,
  })
}

///|
/// An admitted-surface set names each surface once and names at least one.
/// A duplicate entry would make the selection order ambiguous, and an empty
/// set would mean the Part was admitted under no provider authority at all.
fn admitted_provider_surfaces_are_canonical(
  surfaces : Array[@control.ProviderSurfaceId],
) -> Bool {
  if surfaces.length() == 0 {
    return false
  }
  for index, surface in surfaces {
    for earlier in 0..<index {
      if surfaces[earlier] == surface {
        return false
      }
    }
  }
  true
}

///|
pub fn maximum_part_conflict_repairs() -> Int {
  2
}

///|
pub fn maximum_part_audit_repairs() -> Int {
  2
}

///|
pub fn maximum_part_verification_repairs() -> Int {
  2
}

///|
/// How many times a Part may be re-armed after a provider effect died without
/// leaving an artifact. Unattended work must not need a human to press retry,
/// but an unbounded loop against a surface that keeps dying is not recovery.
pub fn maximum_part_recovery_retries() -> Int {
  2
}

///|
fn repair_mutation_score(
  declaration : @control.MutationDeclaration,
  path : @control.RepoPath,
) -> Int {
  let mut score = 0
  match declaration {
    @control.MutationDeclaration::CompleteMutationDeclaration(claims) =>
      for claim in claims {
        match claim {
          @control.MutationClaim::ExactPath(exact) if exact == path =>
            score = score.max(3000000)
          @control.MutationClaim::PathTree(tree) if @control.mutation_claim_covers(
              claim, path,
            ) =>
            score = score.max(2000000 + @control.repo_path_text(tree).length())
          @control.MutationClaim::RepositoryWide => score = score.max(1000000)
          _ => ()
        }
      }
    _ => ()
  }
  score
}

///|
fn goal_repair_owner(
  snapshots : Array[PartWorkflowSnapshot],
  path : @control.RepoPath,
) -> @control.PartId? {
  let mut selected : @control.PartId? = None
  let mut selected_score = 0
  for snapshot in snapshots {
    let mut score = repair_mutation_score(
      snapshot.task_contract.mutation_declaration,
      path,
    )
    match snapshot.candidate {
      Some(candidate) if candidate.changed_paths.contains(path) =>
        score = score + 4000000
      _ => ()
    }
    if score > selected_score {
      selected = Some(snapshot.part.id)
      selected_score = score
    } else if score == selected_score && score > 0 {
      match selected {
        Some(current) if snapshot.part.id.compare(current) < 0 =>
          selected = Some(snapshot.part.id)
        _ => ()
      }
    }
  }
  selected
}

///|
pub fn plan_goal_repair_routes(
  snapshots : Array[PartWorkflowSnapshot],
  paths : Array[@control.RepoPath],
) -> Result[Array[PartRepairRoute], @types.ChoirError] {
  if snapshots.length() == 0 || paths.length() == 0 {
    return Err(workflow_error("Goal repair has no routable work"))
  }
  let routes : Array[PartRepairRoute] = []
  for path in paths {
    let owner = match goal_repair_owner(snapshots, path) {
      Some(value) => value
      None => return Err(workflow_error("Goal repair path is unowned"))
    }
    let mut route_index = -1
    for index, route in routes {
      if route.part_id == owner {
        route_index = index
      }
    }
    if route_index < 0 {
      routes.push({ part_id: owner, affected_paths: [path] })
    } else {
      routes[route_index] = {
        ..routes[route_index],
        affected_paths: routes[route_index].affected_paths + [path],
      }
    }
  }
  routes.sort_by(fn(left, right) { left.part_id.compare(right.part_id) })
  Ok(routes)
}

///|
fn conflict_repair_take_is_fresh(
  previous : @control.Take,
  repair : @control.Take,
) -> Bool {
  repair.id != previous.id &&
  repair.ordinal == previous.ordinal + 1 &&
  repair.lifecycle == @control.TakeLifecycle::TakePlanned
}

///|
pub fn plan_part_conflict_repair(
  snapshot : PartWorkflowSnapshot,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  is_nfc : (String) -> Bool,
) -> Result[PartConflictRepairDecision, @types.ChoirError] {
  if snapshot.stage != PartBlocked ||
    snapshot.pending_effect is Some(_) ||
    !(snapshot.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict
    )) ||
    snapshot.integration_conflicts.length() == 0 {
    return Err(workflow_error("Part is not eligible for conflict repair"))
  }
  if snapshot.integration_conflicts.length() > maximum_part_conflict_repairs() {
    return Ok(PartConflictRepairLimitReached)
  }
  let conflict = snapshot.integration_conflicts[snapshot.integration_conflicts.length() -
    1]
  if snapshot.task_contract_history.length() == 0 ||
    snapshot.task_contract_history[snapshot.task_contract_history.length() - 1] !=
    snapshot.task_contract ||
    contract.id == snapshot.task_contract.id ||
    contract.digest == snapshot.task_contract.digest ||
    contract.goal_id != snapshot.goal.id ||
    contract.part_id != snapshot.part.id ||
    contract.revision != snapshot.task_contract.revision + 1 ||
    contract.repair_conflict_id != Some(conflict.id) ||
    contract.base_commit_oid != conflict.expected_goal_head_oid ||
    contract.base_tree_oid != conflict.expected_goal_head_tree_oid ||
    !conflict_repair_take_is_fresh(
      snapshot.implementation_take,
      identities.implementation_take,
    ) ||
    !conflict_repair_take_is_fresh(
      snapshot.verification_take,
      identities.verification_take,
    ) ||
    !conflict_repair_take_is_fresh(snapshot.audit_take, identities.audit_take) {
    return Err(workflow_error("conflict repair identity plan is invalid"))
  }
  let used_take_ids = snapshot.prior_takes.map(fn(take) { take.id }) +
    [
      snapshot.implementation_take.id,
      snapshot.verification_take.id,
      snapshot.audit_take.id,
    ]
  if used_take_ids.contains(identities.implementation_take.id) ||
    used_take_ids.contains(identities.verification_take.id) ||
    used_take_ids.contains(identities.audit_take.id) {
    return Err(workflow_error("conflict repair reuses a prior Take identity"))
  }
  let pending_part = {
    ..snapshot.part,
    task_contract_revision_id: contract.id,
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let repair_context_manifest = match snapshot.part_context_manifest {
    Some(manifest) =>
      Some({
        ..manifest,
        migration_contract_ref: match contract.migration_contract_ref {
          Some(reference) => reference
          None =>
            return Err(
              workflow_error("conflict repair drops migration context"),
            )
        },
        part_task_contract_revision_id: contract.id,
        part_task_contract_digest: contract.digest,
      })
    None => None
  }
  let initialized = match
    initialize_part_workflow(
      snapshot.workflow_id,
      snapshot.goal,
      pending_part,
      contract,
      identities,
      snapshot.fencing_epoch,
      is_nfc,
      admitted_provider_surfaces=snapshot.admitted_provider_surfaces,
      part_context_manifest=repair_context_manifest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repaired_part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::StartPartConflictRepair(
        conflict.id,
        identities.implementation_take.id,
      ),
    ) {
    Ok(value) => { ..value, task_contract_revision_id: contract.id }
    Err(error) => return Err(error)
  }
  Ok(
    PartConflictRepairPlanned({
      ..initialized,
      durable_version: snapshot.durable_version + 1,
      part: repaired_part,
      task_contract_history: snapshot.task_contract_history + [contract],
      prior_takes: snapshot.prior_takes +
      [
        snapshot.implementation_take,
        snapshot.verification_take,
        snapshot.audit_take,
      ],
      prior_take_evidence: snapshot.prior_take_evidence +
      [
        {
          task_contract_revision_id: snapshot.task_contract.id,
          implementation_result: snapshot.implementation_result,
          candidate: snapshot.candidate,
          verification_receipts: snapshot.verification_receipts,
          verification_authorization: snapshot.verification_authorization,
          audit_result: snapshot.audit_result,
          audit_receipt: snapshot.audit_receipt,
          integration_intent: snapshot.integration_intent,
          integration_receipt: snapshot.integration_receipt,
        },
      ],
      sandbox_leases: snapshot.sandbox_leases,
      harness_sessions: snapshot.harness_sessions,
      harness_events: snapshot.harness_events,
      integration_conflicts: snapshot.integration_conflicts,
      effect_receipts: snapshot.effect_receipts,
      provider_failovers: snapshot.provider_failovers,
    }),
  )
}

///|
pub fn plan_part_audit_repair(
  snapshot : PartWorkflowSnapshot,
  repair : @control.AuditRepairReference,
  source : PartRepairSource,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  is_nfc : (String) -> Bool,
) -> Result[PartAuditRepairDecision, @types.ChoirError] {
  if snapshot.pending_effect is Some(_) {
    return Err(workflow_error("Part has an unresolved effect"))
  }
  let eligible = match (snapshot.part.lifecycle, repair.scope) {
    (
      @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartAuditFindings
      ),
      @control.AuditRepairScope::PartAuditRepair,
    ) =>
      match snapshot.audit_result {
        Some(result) =>
          result.id == repair.audit_result_id &&
          result.result_digest == repair.audit_result_digest &&
          result.findings_artifact == Some(repair.findings_artifact)
        None => false
      }
    (
      @control.PartLifecycle::PartIntegrated(_),
      @control.AuditRepairScope::GoalAuditRepair,
    ) => true
    _ => false
  }
  if !eligible ||
    (snapshot.stage != PartBlocked && snapshot.stage != PartIntegrated) {
    return Err(workflow_error("Part is not eligible for audit repair"))
  }
  let mut prior_repairs = 0
  for previous in snapshot.task_contract_history {
    if previous.repair_audit is Some(_) {
      prior_repairs = prior_repairs + 1
    }
  }
  if prior_repairs >= maximum_part_audit_repairs() {
    return Ok(PartAuditRepairLimitReached)
  }
  if snapshot.task_contract_history.length() == 0 ||
    snapshot.task_contract_history[snapshot.task_contract_history.length() - 1] !=
    snapshot.task_contract ||
    contract.id == snapshot.task_contract.id ||
    contract.digest == snapshot.task_contract.digest ||
    contract.goal_id != snapshot.goal.id ||
    contract.part_id != snapshot.part.id ||
    contract.revision != snapshot.task_contract.revision + 1 ||
    contract.repair_conflict_id is Some(_) ||
    contract.repair_audit != Some(repair) ||
    contract.base_commit_oid != source.commit_oid ||
    contract.base_tree_oid != source.tree_oid ||
    contract.mutation_declaration != snapshot.task_contract.mutation_declaration ||
    !conflict_repair_take_is_fresh(
      snapshot.implementation_take,
      identities.implementation_take,
    ) ||
    !conflict_repair_take_is_fresh(
      snapshot.verification_take,
      identities.verification_take,
    ) ||
    !conflict_repair_take_is_fresh(snapshot.audit_take, identities.audit_take) {
    return Err(workflow_error("audit repair identity plan is invalid"))
  }
  match @control.validate_task_contract_revision(contract, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let used_take_ids = snapshot.prior_takes.map(fn(take) { take.id }) +
    [
      snapshot.implementation_take.id,
      snapshot.verification_take.id,
      snapshot.audit_take.id,
    ]
  if used_take_ids.contains(identities.implementation_take.id) ||
    used_take_ids.contains(identities.verification_take.id) ||
    used_take_ids.contains(identities.audit_take.id) {
    return Err(workflow_error("audit repair reuses a prior Take identity"))
  }
  let pending_part = {
    ..snapshot.part,
    task_contract_revision_id: contract.id,
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let repair_context_manifest = match snapshot.part_context_manifest {
    Some(manifest) =>
      Some({
        ..manifest,
        migration_contract_ref: match contract.migration_contract_ref {
          Some(reference) => reference
          None =>
            return Err(workflow_error("audit repair drops migration context"))
        },
        part_task_contract_revision_id: contract.id,
        part_task_contract_digest: contract.digest,
      })
    None => None
  }
  let initialized = match
    initialize_part_workflow(
      snapshot.workflow_id,
      snapshot.goal,
      pending_part,
      contract,
      identities,
      snapshot.fencing_epoch,
      is_nfc,
      admitted_provider_surfaces=snapshot.admitted_provider_surfaces,
      part_context_manifest=repair_context_manifest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repaired_part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::StartPartAuditRepair(
        repair.audit_result_id,
        identities.implementation_take.id,
      ),
    ) {
    Ok(value) => { ..value, task_contract_revision_id: contract.id }
    Err(error) => return Err(error)
  }
  Ok(
    PartAuditRepairPlanned({
      ..initialized,
      durable_version: snapshot.durable_version + 1,
      part: repaired_part,
      task_contract_history: snapshot.task_contract_history + [contract],
      prior_takes: snapshot.prior_takes +
      [
        snapshot.implementation_take,
        snapshot.verification_take,
        snapshot.audit_take,
      ],
      prior_take_evidence: snapshot.prior_take_evidence +
      [
        {
          task_contract_revision_id: snapshot.task_contract.id,
          implementation_result: snapshot.implementation_result,
          candidate: snapshot.candidate,
          verification_receipts: snapshot.verification_receipts,
          verification_authorization: snapshot.verification_authorization,
          audit_result: snapshot.audit_result,
          audit_receipt: snapshot.audit_receipt,
          integration_intent: snapshot.integration_intent,
          integration_receipt: snapshot.integration_receipt,
        },
      ],
      sandbox_leases: snapshot.sandbox_leases,
      harness_sessions: snapshot.harness_sessions,
      harness_events: snapshot.harness_events,
      integration_conflicts: snapshot.integration_conflicts,
      effect_receipts: snapshot.effect_receipts,
      provider_failovers: snapshot.provider_failovers,
    }),
  )
}

///|
pub fn plan_part_verification_repair(
  snapshot : PartWorkflowSnapshot,
  repair : @control.VerificationRepairReference,
  source : PartRepairSource,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  is_nfc : (String) -> Bool,
) -> Result[PartVerificationRepairDecision, @types.ChoirError] {
  if snapshot.pending_effect is Some(_) {
    return Err(workflow_error("Part has an unresolved effect"))
  }
  let eligible = match (snapshot.part.lifecycle, repair.scope) {
    (
      @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartVerificationFailed
      ),
      @control.VerificationRepairScope::PartVerificationRepair,
    ) => {
      let mut evidence_matches = false
      for receipt in snapshot.verification_receipts {
        if receipt.receipt_id == repair.receipt_id &&
          receipt.verification_execution_id == repair.verification_execution_id &&
          receipt.subject.subject_digest == repair.subject_digest &&
          receipt.evidence == repair.evidence_artifact &&
          receipt.subject.task_contract_revision_id == snapshot.task_contract.id &&
          receipt.outcome != @control.VerificationOutcome::VerificationPassed {
          evidence_matches = true
        }
      }
      evidence_matches
    }
    // Combined verification failed over the sealed Goal tree. This Part's own
    // receipts passed; the routed paths are what make it the repairer.
    (
      @control.PartLifecycle::PartIntegrated(_),
      @control.VerificationRepairScope::GoalVerificationRepair,
    ) => repair.affected_paths.length() > 0
    _ => false
  }
  if !eligible ||
    (snapshot.stage != PartBlocked && snapshot.stage != PartIntegrated) {
    return Err(workflow_error("Part is not eligible for verification repair"))
  }
  let mut prior_repairs = 0
  for previous in snapshot.task_contract_history {
    if previous.repair_verification is Some(_) {
      prior_repairs = prior_repairs + 1
    }
  }
  if prior_repairs >= maximum_part_verification_repairs() {
    return Ok(PartVerificationRepairLimitReached)
  }
  if snapshot.task_contract_history.length() == 0 ||
    snapshot.task_contract_history[snapshot.task_contract_history.length() - 1] !=
    snapshot.task_contract ||
    contract.id == snapshot.task_contract.id ||
    contract.digest == snapshot.task_contract.digest ||
    contract.goal_id != snapshot.goal.id ||
    contract.part_id != snapshot.part.id ||
    contract.revision != snapshot.task_contract.revision + 1 ||
    contract.repair_conflict_id is Some(_) ||
    contract.repair_audit is Some(_) ||
    contract.repair_verification != Some(repair) ||
    contract.base_commit_oid != source.commit_oid ||
    contract.base_tree_oid != source.tree_oid ||
    contract.mutation_declaration != snapshot.task_contract.mutation_declaration ||
    !conflict_repair_take_is_fresh(
      snapshot.implementation_take,
      identities.implementation_take,
    ) ||
    !conflict_repair_take_is_fresh(
      snapshot.verification_take,
      identities.verification_take,
    ) ||
    !conflict_repair_take_is_fresh(snapshot.audit_take, identities.audit_take) {
    return Err(workflow_error("verification repair identity plan is invalid"))
  }
  match @control.validate_task_contract_revision(contract, is_nfc) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let used_take_ids = snapshot.prior_takes.map(fn(take) { take.id }) +
    [
      snapshot.implementation_take.id,
      snapshot.verification_take.id,
      snapshot.audit_take.id,
    ]
  if used_take_ids.contains(identities.implementation_take.id) ||
    used_take_ids.contains(identities.verification_take.id) ||
    used_take_ids.contains(identities.audit_take.id) {
    return Err(
      workflow_error("verification repair reuses a prior Take identity"),
    )
  }
  let pending_part = {
    ..snapshot.part,
    task_contract_revision_id: contract.id,
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let repair_context_manifest = match snapshot.part_context_manifest {
    Some(manifest) =>
      Some({
        ..manifest,
        migration_contract_ref: match contract.migration_contract_ref {
          Some(reference) => reference
          None =>
            return Err(
              workflow_error("verification repair drops migration context"),
            )
        },
        part_task_contract_revision_id: contract.id,
        part_task_contract_digest: contract.digest,
      })
    None => None
  }
  let initialized = match
    initialize_part_workflow(
      snapshot.workflow_id,
      snapshot.goal,
      pending_part,
      contract,
      identities,
      snapshot.fencing_epoch,
      is_nfc,
      admitted_provider_surfaces=snapshot.admitted_provider_surfaces,
      part_context_manifest=repair_context_manifest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repaired_part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::StartPartVerificationRepair(
        repair.receipt_id,
        identities.implementation_take.id,
      ),
    ) {
    Ok(value) => { ..value, task_contract_revision_id: contract.id }
    Err(error) => return Err(error)
  }
  Ok(
    PartVerificationRepairPlanned({
      ..initialized,
      durable_version: snapshot.durable_version + 1,
      part: repaired_part,
      task_contract_history: snapshot.task_contract_history + [contract],
      prior_takes: snapshot.prior_takes +
      [
        snapshot.implementation_take,
        snapshot.verification_take,
        snapshot.audit_take,
      ],
      prior_take_evidence: snapshot.prior_take_evidence +
      [
        {
          task_contract_revision_id: snapshot.task_contract.id,
          implementation_result: snapshot.implementation_result,
          candidate: snapshot.candidate,
          verification_receipts: snapshot.verification_receipts,
          verification_authorization: snapshot.verification_authorization,
          audit_result: snapshot.audit_result,
          audit_receipt: snapshot.audit_receipt,
          integration_intent: snapshot.integration_intent,
          integration_receipt: snapshot.integration_receipt,
        },
      ],
      sandbox_leases: snapshot.sandbox_leases,
      harness_sessions: snapshot.harness_sessions,
      harness_events: snapshot.harness_events,
      integration_conflicts: snapshot.integration_conflicts,
      effect_receipts: snapshot.effect_receipts,
      provider_failovers: snapshot.provider_failovers,
    }),
  )
}

///|
/// User-requested retry of a blocked Part: same task contract, fresh Take,
/// sandbox, and session identities, prior evidence archived. Integration
/// conflicts are excluded — they retry through conflict repair, which must
/// revise the contract to the conflicting head.
pub fn plan_part_retry(
  snapshot : PartWorkflowSnapshot,
  identities : PartIdentityPlan,
  is_nfc : (String) -> Bool,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  guard snapshot.stage == PartBlocked &&
    snapshot.pending_effect is None &&
    snapshot.part.lifecycle is @control.PartLifecycle::PartBlocked(reason) else {
    return Err(workflow_error("Part is not eligible for retry"))
  }
  if reason == @control.PartBlockReason::PartIntegrationConflict {
    return Err(
      workflow_error("integration conflicts retry through conflict repair"),
    )
  }
  if !conflict_repair_take_is_fresh(
      snapshot.implementation_take,
      identities.implementation_take,
    ) ||
    !conflict_repair_take_is_fresh(
      snapshot.verification_take,
      identities.verification_take,
    ) ||
    !conflict_repair_take_is_fresh(snapshot.audit_take, identities.audit_take) {
    return Err(workflow_error("retry identity plan is invalid"))
  }
  let used_take_ids = snapshot.prior_takes.map(fn(take) { take.id }) +
    [
      snapshot.implementation_take.id,
      snapshot.verification_take.id,
      snapshot.audit_take.id,
    ]
  if used_take_ids.contains(identities.implementation_take.id) ||
    used_take_ids.contains(identities.verification_take.id) ||
    used_take_ids.contains(identities.audit_take.id) {
    return Err(workflow_error("retry reuses a prior Take identity"))
  }
  let pending_part = {
    ..snapshot.part,
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let initialized = match
    initialize_part_workflow(
      snapshot.workflow_id,
      snapshot.goal,
      pending_part,
      snapshot.task_contract,
      identities,
      snapshot.fencing_epoch,
      is_nfc,
      admitted_provider_surfaces=snapshot.admitted_provider_surfaces,
      part_context_manifest=snapshot.part_context_manifest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let retried_part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::RestartBlockedPart(
        identities.implementation_take.id,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..initialized,
    durable_version: snapshot.durable_version + 1,
    part: retried_part,
    task_contract_history: snapshot.task_contract_history,
    prior_takes: snapshot.prior_takes +
    [
      snapshot.implementation_take,
      snapshot.verification_take,
      snapshot.audit_take,
    ],
    prior_take_evidence: snapshot.prior_take_evidence +
    [
      {
        task_contract_revision_id: snapshot.task_contract.id,
        implementation_result: snapshot.implementation_result,
        candidate: snapshot.candidate,
        verification_receipts: snapshot.verification_receipts,
        verification_authorization: snapshot.verification_authorization,
        audit_result: snapshot.audit_result,
        audit_receipt: snapshot.audit_receipt,
        integration_intent: snapshot.integration_intent,
        integration_receipt: snapshot.integration_receipt,
      },
    ],
    sandbox_leases: snapshot.sandbox_leases,
    harness_sessions: snapshot.harness_sessions,
    harness_events: snapshot.harness_events,
    integration_conflicts: snapshot.integration_conflicts,
    effect_receipts: snapshot.effect_receipts,
    provider_failovers: snapshot.provider_failovers,
  })
}

///|
/// Re-arm an ownership-violating implementation under the same mutation
/// declaration and retained diagnostic. This is a bounded repair Take, not a
/// widening of the contract: `plan_part_retry` archives the failed candidate
/// evidence and preserves the exact TaskContractRevision.
pub fn plan_part_ownership_repair(
  snapshot : PartWorkflowSnapshot,
  identities : PartIdentityPlan,
  is_nfc : (String) -> Bool,
) -> Result[PartOwnershipRepairDecision, @types.ChoirError] {
  if snapshot.stage != PartBlocked ||
    !(snapshot.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartOwnershipViolation
    )) ||
    snapshot.pending_effect is Some(_) ||
    snapshot.dispatch_diagnostic is None {
    return Err(workflow_error("Part is not eligible for ownership repair"))
  }
  let diagnostic = snapshot.dispatch_diagnostic.unwrap()
  if diagnostic.take_id != snapshot.implementation_take.id ||
    !diagnostic.detail.has_prefix("candidate failed normalization:") {
    return Err(workflow_error("ownership violation evidence is absent"))
  }
  if snapshot.prior_takes.length() / 3 >= maximum_part_recovery_retries() {
    return Ok(PartOwnershipRepairLimitReached)
  }
  match plan_part_retry(snapshot, identities, is_nfc) {
    Ok(value) => Ok(PartOwnershipRepairPlanned(value))
    Err(error) => Err(error)
  }
}

///|
fn stage_effect_suffix(stage : PartWorkflowStage) -> String {
  match stage {
    PartAccepted => "implementation-sandbox"
    PartImplementationSandboxPrepared => "implementation-command"
    PartImplementationCommandPrepared => "implementation-harness"
    PartImplementationHarnessStarted => "implementation-dispatch"
    PartImplementationCompleted => "candidate-normalization"
    PartCandidateRecorded => "verification-sandbox"
    PartVerificationSandboxPrepared => "verification-dispatch"
    PartVerified => "audit-sandbox"
    PartAuditSandboxPrepared => "audit-command"
    PartAuditCommandPrepared => "audit-harness"
    PartAuditHarnessStarted => "audit-dispatch"
    PartIntegrationPlanned => "promotion-generation"
    PartIntegrationAuthorized => "integration-apply"
    _ => "none"
  }
}

///|
fn command_capability_profile_digest(
  snapshot : PartWorkflowSnapshot,
  role : @command.CommandRole,
) -> @control.Digest {
  match role {
    ImplementationCommand =>
      snapshot.task_contract.implementation_capability_profile_digest
    PartAuditCommand => snapshot.task_contract.audit_capability_profile_digest
  }
}

///|
fn part_command_preparation_plan(
  snapshot : PartWorkflowSnapshot,
  role : @command.CommandRole,
  take : @control.Take,
  session : @control.HarnessSession,
  subject : @command.CommandExecutionSubject,
) -> PartCommandPreparationPlan {
  let policy_digest = match snapshot.part_context_manifest {
    Some(manifest) => manifest.context_assembly_policy_digest
    None => @command.default_part_context_policy_digest()
  }
  let template = @command.default_command_template(role)
  {
    role,
    take,
    session_id: session.id,
    subject,
    goal_contract_digest: snapshot.goal.contract_digest,
    task_contract_revision_id: snapshot.task_contract.id,
    task_contract_digest: snapshot.task_contract.digest,
    instruction_artifact_digest: snapshot.task_contract.instruction_artifact.digest,
    migration_contract_ref: snapshot.task_contract.migration_contract_ref,
    provider_surface: session.surface,
    provider_surface_and_profile_digest: @command.provider_surface_and_profile_digest(
      session.surface,
      session.effective_surface_manifest_digest,
      command_capability_profile_digest(snapshot, role),
    ),
    context_assembly_policy_digest: policy_digest,
    context_manifest: snapshot.part_context_manifest,
    template_digest: template.digest,
    maximum_command_bytes: 1048576,
  }
}

///|
fn prepared_command_for(
  snapshot : PartWorkflowSnapshot,
  role : @command.CommandRole,
  take_id : @control.TakeId,
  session_id : @control.HarnessSessionId,
) -> PartPreparedCommand? {
  for prepared in snapshot.prepared_commands {
    if prepared.plan.role == role &&
      prepared.plan.take.id == take_id &&
      prepared.plan.session_id == session_id {
      return Some(prepared)
    }
  }
  None
}

///|
fn session_start_intent(
  snapshot : PartWorkflowSnapshot,
  session : @control.HarnessSession,
  prepared : PartPreparedCommand,
) -> @control.HarnessSessionStartIntent {
  {
    effect_id: snapshot.workflow_id.effect(session.id.0 + ":start"),
    session_id: session.id,
    take_id: prepared.plan.take.id,
    provider_surface_and_profile_digest: prepared.plan.provider_surface_and_profile_digest,
    declared_surface_digest: session.effective_surface_manifest_digest,
    initial_command_artifact_digest: Some(prepared.command_artifact.digest),
    supervisor_key: "choir-harness-" + session.id.0,
  }
}

///|
fn harness_command_intent(
  snapshot : PartWorkflowSnapshot,
  session : @control.HarnessSession,
  prepared : PartPreparedCommand,
) -> @control.HarnessCommandIntent {
  let effect_id = snapshot.workflow_id.effect(session.id.0 + ":command-1")
  {
    effect_id,
    session_id: session.id,
    command_id: @control.HarnessCommandId(session.id.0 + ":command-1"),
    command_sequence: 1,
    required_provider_cursor: None,
    command_artifact_digest: prepared.command_artifact.digest,
    // The provider dedupes on this token, so it must be the same identity
    // Choir reconciles the effect under, not a parallel spelling of it.
    provider_idempotency_token: Some(effect_id.0),
  }
}

///|
fn prepared_command_is_current(
  snapshot : PartWorkflowSnapshot,
  prepared : PartPreparedCommand,
) -> Bool {
  let (expected, current_take) = match prepared.plan.role {
    ImplementationCommand =>
      (
        Some(
          part_command_preparation_plan(
            snapshot,
            @command.CommandRole::ImplementationCommand,
            snapshot.implementation_take,
            snapshot.identities.implementation_session,
            @command.CommandExecutionSubject::ImplementationCommandSubject(
              snapshot.part.id,
              snapshot.task_contract.id,
              snapshot.task_contract.digest,
            ),
          ),
        ),
        snapshot.implementation_take,
      )
    PartAuditCommand =>
      match
        (
          snapshot.audit_subject,
          snapshot.verification_subject,
          snapshot.verification_authorization,
          snapshot.audit_context,
        ) {
        (Some(subject), Some(verification), Some(authorization), Some(context)) if audit_subject(
            verification,
            authorization,
            context.digest,
          ) ==
          subject =>
          (
            Some(
              part_command_preparation_plan(
                snapshot,
                @command.CommandRole::PartAuditCommand,
                snapshot.audit_take,
                snapshot.identities.audit_session,
                @command.CommandExecutionSubject::PartAuditCommandSubject(
                  subject,
                ),
              ),
            ),
            snapshot.audit_take,
          )
        _ => (None, snapshot.audit_take)
      }
  }
  let immutable_take_matches = prepared.plan.take.id == current_take.id &&
    prepared.plan.take.goal_id == current_take.goal_id &&
    prepared.plan.take.purpose == current_take.purpose &&
    prepared.plan.take.ordinal == current_take.ordinal &&
    prepared.plan.take.fencing_epoch == current_take.fencing_epoch
  let expected_matches = match expected {
    Some(value) => { ..value, take: prepared.plan.take } == prepared.plan
    None => false
  }
  immutable_take_matches &&
  expected_matches &&
  prepared.provenance.command_artifact_digest ==
  prepared.command_artifact.digest
}

///|
fn start_intent_has_preparation(
  snapshot : PartWorkflowSnapshot,
  session : @control.HarnessSession,
  start : @control.HarnessSessionStartIntent,
  role : @command.CommandRole,
  artifact_digest_exists : (@control.Digest) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  match prepared_command_for(snapshot, role, session.take_id, session.id) {
    Some(prepared) => {
      if !prepared_command_is_current(snapshot, prepared) ||
        start != session_start_intent(snapshot, session, prepared) {
        return Err(@types.ChoirError::command_preparation_stale_binding())
      }
      if !artifact_digest_exists(prepared.command_artifact.digest) {
        return Err(
          @types.ChoirError::command_preparation_missing_required_artifact(
            prepared.command_artifact.digest.0,
          ),
        )
      }
      Ok(())
    }
    None =>
      Err(
        @types.ChoirError::command_preparation_missing_required_artifact(
          "prepared-command",
        ),
      )
  }
}

///|
fn command_intent_has_preparation(
  snapshot : PartWorkflowSnapshot,
  take_id : @control.TakeId,
  command : @control.HarnessCommandIntent,
  session : @control.HarnessSession,
  role : @command.CommandRole,
  artifact_digest_exists : (@control.Digest) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  match prepared_command_for(snapshot, role, take_id, session.id) {
    Some(prepared) => {
      if !prepared_command_is_current(snapshot, prepared) ||
        command != harness_command_intent(snapshot, session, prepared) {
        return Err(@types.ChoirError::command_preparation_stale_binding())
      }
      if !artifact_digest_exists(prepared.command_artifact.digest) {
        return Err(
          @types.ChoirError::command_preparation_missing_required_artifact(
            prepared.command_artifact.digest.0,
          ),
        )
      }
      Ok(())
    }
    None =>
      Err(
        @types.ChoirError::command_preparation_missing_required_artifact(
          "prepared-command",
        ),
      )
  }
}

///|
fn next_effect_kind(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartEffectKind?, @types.ChoirError] {
  match snapshot.stage {
    PartAccepted =>
      Ok(
        Some(
          PrepareImplementationSandbox(
            snapshot.identities.implementation_sandbox,
          ),
        ),
      )
    PartImplementationSandboxPrepared =>
      Ok(
        Some(
          PrepareImplementationCommand(
            part_command_preparation_plan(
              snapshot,
              @command.CommandRole::ImplementationCommand,
              snapshot.implementation_take,
              snapshot.identities.implementation_session,
              @command.CommandExecutionSubject::ImplementationCommandSubject(
                snapshot.part.id,
                snapshot.task_contract.id,
                snapshot.task_contract.digest,
              ),
            ),
          ),
        ),
      )
    PartImplementationCommandPrepared =>
      match
        prepared_command_for(
          snapshot,
          @command.CommandRole::ImplementationCommand,
          snapshot.implementation_take.id,
          snapshot.identities.implementation_session.id,
        ) {
        Some(prepared) =>
          Ok(
            Some(
              StartImplementationHarness(
                snapshot.identities.implementation_session,
                session_start_intent(
                  snapshot,
                  snapshot.identities.implementation_session,
                  prepared,
                ),
              ),
            ),
          )
        None => Err(workflow_error("implementation command is missing"))
      }
    PartImplementationHarnessStarted =>
      match
        prepared_command_for(
          snapshot,
          @command.CommandRole::ImplementationCommand,
          snapshot.implementation_take.id,
          snapshot.identities.implementation_session.id,
        ) {
        Some(prepared) =>
          Ok(
            Some(
              DispatchImplementation(
                snapshot.implementation_take.id,
                harness_command_intent(
                  snapshot,
                  snapshot.identities.implementation_session,
                  prepared,
                ),
              ),
            ),
          )
        None => Err(workflow_error("implementation command is missing"))
      }
    PartImplementationCompleted =>
      match snapshot.implementation_result {
        Some(result) =>
          Ok(
            Some(
              NormalizeImplementationCandidate(
                snapshot.implementation_take.id,
                result.result_artifact.digest,
              ),
            ),
          )
        None => Err(workflow_error("implementation result is missing"))
      }
    PartCandidateRecorded =>
      Ok(
        Some(
          PrepareVerificationSandbox(snapshot.identities.verification_sandbox),
        ),
      )
    PartVerificationSandboxPrepared =>
      match snapshot.verification_subject {
        Some(subject) =>
          Ok(Some(DispatchVerification(snapshot.verification_take.id, subject)))
        None => Err(workflow_error("verification subject is missing"))
      }
    PartVerified =>
      match (snapshot.audit_subject, snapshot.audit_context) {
        (Some(subject), Some(context)) if subject.audit_context_digest ==
          context.digest =>
          Ok(Some(PrepareAuditSandbox(snapshot.identities.audit_sandbox)))
        _ => Err(workflow_error("audit context is missing or stale"))
      }
    PartAuditSandboxPrepared =>
      match snapshot.audit_subject {
        Some(subject) =>
          Ok(
            Some(
              PrepareAuditCommand(
                part_command_preparation_plan(
                  snapshot,
                  @command.CommandRole::PartAuditCommand,
                  snapshot.audit_take,
                  snapshot.identities.audit_session,
                  @command.CommandExecutionSubject::PartAuditCommandSubject(
                    subject,
                  ),
                ),
              ),
            ),
          )
        None => Err(workflow_error("audit subject is missing"))
      }
    PartAuditCommandPrepared =>
      match
        prepared_command_for(
          snapshot,
          @command.CommandRole::PartAuditCommand,
          snapshot.audit_take.id,
          snapshot.identities.audit_session.id,
        ) {
        Some(prepared) =>
          Ok(
            Some(
              StartAuditHarness(
                snapshot.identities.audit_session,
                session_start_intent(
                  snapshot,
                  snapshot.identities.audit_session,
                  prepared,
                ),
              ),
            ),
          )
        None => Err(workflow_error("audit command is missing"))
      }
    PartAuditHarnessStarted =>
      match snapshot.audit_subject {
        Some(subject) =>
          match
            prepared_command_for(
              snapshot,
              @command.CommandRole::PartAuditCommand,
              snapshot.audit_take.id,
              snapshot.identities.audit_session.id,
            ) {
            Some(prepared) =>
              Ok(
                Some(
                  DispatchAudit(
                    snapshot.audit_take.id,
                    harness_command_intent(
                      snapshot,
                      snapshot.identities.audit_session,
                      prepared,
                    ),
                    subject,
                  ),
                ),
              )
            None => Err(workflow_error("audit command is missing"))
          }
        None => Err(workflow_error("audit subject is missing"))
      }
    PartIntegrationPlanned =>
      match snapshot.integration_intent {
        Some(intent) => Ok(Some(GeneratePromotion(intent)))
        None => Err(workflow_error("integration intent is missing"))
      }
    PartIntegrationAuthorized =>
      match (snapshot.integration_intent, snapshot.promotion_commit) {
        (Some(intent), Some(promotion)) =>
          Ok(Some(ApplyIntegration(intent.id, promotion)))
        _ => Err(workflow_error("authorized integration is incomplete"))
      }
    _ => Ok(None)
  }
}

///|
pub fn plan_next_part_effect(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartEffectIntent?, @types.ChoirError] {
  match snapshot.pending_effect {
    Some(intent) => Ok(Some(intent))
    None =>
      match next_effect_kind(snapshot) {
        Ok(None) => Ok(None)
        Ok(Some(kind)) => {
          // The attempt discriminator matters. A retried Part re-plans the
          // same stages, so an id built only from the workflow and stage
          // collides with the previous attempt's witnesses: the retry then
          // either errors on every tick or waits forever for a witness that
          // can never match. A retry mints a fresh implementation Take, and
          // that identity is stable for the life of one attempt, so it scopes
          // the effect id to the attempt without disturbing recovery within
          // an attempt across daemon restarts.
          let effect_id = snapshot.workflow_id.effect(
            snapshot.implementation_take.id.0 +
            ":" +
            stage_effect_suffix(snapshot.stage),
          )
          Ok(
            Some({
              effect_id,
              request_digest: domain_digest(
                "choir.part-effect-request.v1",
                kind.to_json(),
              ),
              kind,
              lifecycle: PartEffectPlanned,
            }),
          )
        }
        Err(error) => Err(error)
      }
  }
}

///|
pub fn persist_planned_part_effect(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect is Some(_) {
    return Err(workflow_error("another external effect is unresolved"))
  }
  match plan_next_part_effect(snapshot) {
    Ok(Some(expected)) if expected == intent =>
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        pending_effect: Some(intent),
      })
    Ok(_) => Err(workflow_error("effect is not the deterministic next effect"))
    Err(error) => Err(error)
  }
}

///|
pub fn authorize_pending_part_effect(
  snapshot : PartWorkflowSnapshot,
  artifact_digest_exists : (@control.Digest) -> Bool,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  match snapshot.pending_effect {
    Some({ lifecycle: PartEffectPlanned, .. } as intent) => {
      let preparation_check = match intent.kind {
        PrepareAuditSandbox(_) =>
          match (snapshot.audit_subject, snapshot.audit_context) {
            (Some(subject), Some(context)) if subject.audit_context_digest ==
              context.digest &&
              artifact_digest_exists(context.digest) => Ok(())
            _ => Err(workflow_error("audit context is missing or stale"))
          }
        StartImplementationHarness(session, start) =>
          start_intent_has_preparation(
            snapshot,
            session,
            start,
            @command.CommandRole::ImplementationCommand,
            artifact_digest_exists,
          )
        StartAuditHarness(session, start) =>
          start_intent_has_preparation(
            snapshot,
            session,
            start,
            @command.CommandRole::PartAuditCommand,
            artifact_digest_exists,
          )
        DispatchImplementation(take_id, command) =>
          command_intent_has_preparation(
            snapshot,
            take_id,
            command,
            snapshot.identities.implementation_session,
            @command.CommandRole::ImplementationCommand,
            artifact_digest_exists,
          )
        DispatchAudit(take_id, command, subject) => {
          let prepared = command_intent_has_preparation(
            snapshot,
            take_id,
            command,
            snapshot.identities.audit_session,
            @command.CommandRole::PartAuditCommand,
            artifact_digest_exists,
          )
          match prepared {
            Err(error) => Err(error)
            Ok(_) =>
              match
                (
                  snapshot.verification_subject,
                  snapshot.verification_authorization,
                  snapshot.audit_context,
                ) {
                (Some(verification), Some(authorization), Some(context)) if artifact_digest_exists(
                    context.digest,
                  ) &&
                  audit_subject(verification, authorization, context.digest) ==
                  subject => Ok(())
                _ => Err(workflow_error("audit context is missing or stale"))
              }
          }
        }
        _ => Ok(())
      }
      match preparation_check {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let verification_take = match intent.kind {
        DispatchVerification(take_id, _) =>
          if take_id != snapshot.verification_take.id {
            return Err(workflow_error("verification Take is misbound"))
          } else {
            match
              @control.transition_take(
                snapshot.verification_take,
                @control.TakeTransition::StartTake(snapshot.fencing_epoch),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
          }
        _ => snapshot.verification_take
      }
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        verification_take,
        pending_effect: Some({ ..intent, lifecycle: PartEffectMayHaveOccurred }),
      })
    }
    Some(_) => Err(workflow_error("external effect is not planned"))
    None => Err(workflow_error("no external effect is pending"))
  }
}

///|
fn record_part_provider_dispatch_uncertainty(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  reason : @control.TakeUncertaintyReason,
  session_lifecycle : @control.HarnessSessionLifecycle,
  error_context : String,
  detail : String,
  observed_at~ : Int64,
  availability? : @control.ProviderAvailability = @control.ProviderAvailability::ProviderUnavailable,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect != Some(intent) ||
    intent.lifecycle != PartEffectMayHaveOccurred {
    return Err(workflow_error(error_context + " has no authorized effect"))
  }
  let (take, session_id) = match intent.kind {
    DispatchImplementation(take_id, command)
    | DispatchAudit(take_id, command, _) => {
      let take = if take_id == snapshot.implementation_take.id {
        snapshot.implementation_take
      } else if take_id == snapshot.audit_take.id {
        snapshot.audit_take
      } else {
        return Err(workflow_error(error_context + " named an unknown Take"))
      }
      (take, Some(command.session_id))
    }
    // Verification runs a sandbox process with no harness session. It still
    // has a Take to fence and a Part to block, and leaving it unrecordable
    // meant a lost verification process retried forever with nothing durable
    // to show for it.
    DispatchVerification(take_id, _) =>
      if take_id == snapshot.verification_take.id {
        (snapshot.verification_take, None)
      } else {
        return Err(workflow_error(error_context + " named an unknown Take"))
      }
    _ =>
      return Err(
        workflow_error(error_context + " did not arise from a dispatch"),
      )
  }
  let terminal_take = match
    @control.transition_take(
      take,
      @control.TakeTransition::FinishTake(
        snapshot.fencing_epoch,
        @control.TakeTerminalDisposition::TakeRecoveryUncertain(reason),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sessions = match session_id {
    None => snapshot.harness_sessions
    Some(identity) => {
      let mut found_session = false
      let updated = snapshot.harness_sessions.map(fn(session) {
        if session.id == identity && session.take_id == take.id {
          found_session = true
          { ..session, lifecycle: session_lifecycle }
        } else {
          session
        }
      })
      if !found_session {
        return Err(workflow_error(error_context + " session is missing"))
      }
      updated
    }
  }
  let part = match
    @control.transition_part(
      snapshot.part,
      @control.PartTransition::BlockPart(
        @control.PartBlockReason::PartRecoveryUncertain,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..snapshot,
    durable_version: snapshot.durable_version + 1,
    stage: PartRecoveryUncertain,
    part,
    implementation_take: if take.id == snapshot.implementation_take.id {
      terminal_take
    } else {
      snapshot.implementation_take
    },
    verification_take: if take.id == snapshot.verification_take.id {
      terminal_take
    } else {
      snapshot.verification_take
    },
    audit_take: if take.id == snapshot.audit_take.id {
      terminal_take
    } else {
      snapshot.audit_take
    },
    harness_sessions: sessions,
    pending_effect: Some({ ..intent, lifecycle: PartEffectUncertain }),
    // A cause recorded when the dispatch actually failed outranks anything a
    // later reconciliation can say. Reconciliation observes that recovery is
    // impossible, which is a verdict, not evidence of what went wrong.
    // What the surface reported is re-read here, so its date moves with it:
    // an availability carrying a stale instant would be aged out against a
    // clock reading that has nothing to do with when it was observed.
    dispatch_diagnostic: Some(
      match snapshot.dispatch_diagnostic {
        Some(observed) if observed.take_id == take.id =>
          {
            ..observed,
            reason: Some(reason),
            recovery: Some(detail),
            availability,
            observed_at,
          }
        _ =>
          {
            take_id: take.id,
            session_id,
            reason: Some(reason),
            detail,
            recovery: None,
            availability,
            observed_at,
          }
      },
    ),
  })
}

///|
/// Record what an effect dispatch observed at the moment it failed, without
/// resolving the Take.
///
/// The failure that ends a Take is frequently not the one a later tick can
/// classify: a result archive that fails to transfer kills the tick, and the
/// next tick sees only an unresolvable pending effect. Keeping the first
/// observation is what makes the eventual block report a cause instead of a
/// guess.
/// Whether an effect runs a provider session, and so can be classified by the
/// provider-uncertainty recorders.
///
/// Verification runs a sandbox process with no harness session. Routing its
/// failure to the provider recorders rejected it as "not a provider dispatch"
/// on every tick, turning one lost verification process into a permanent
/// stall.
pub fn part_effect_is_provider_dispatch(intent : PartEffectIntent) -> Bool {
  match intent.kind {
    DispatchImplementation(_, _) | DispatchAudit(_, _, _) => true
    _ => false
  }
}

///|
/// Whether an effect dispatches work whose loss can be fenced onto a Take.
/// Verification belongs here even though it has no harness session.
pub fn part_effect_is_dispatch(intent : PartEffectIntent) -> Bool {
  match intent.kind {
    DispatchImplementation(_, _)
    | DispatchAudit(_, _, _)
    | DispatchVerification(_, _) => true
    _ => false
  }
}

///|
test "a sandbox-only effect is not a provider dispatch" {
  let intent : PartEffectIntent = {
    effect_id: @control.EffectId("e"),
    kind: PartEffectKind::NormalizeImplementationCandidate(
      @control.TakeId("take-1"),
      @control.Digest("d"),
    ),
    request_digest: @control.Digest("r"),
    lifecycle: PartEffectMayHaveOccurred,
  }
  assert_false(part_effect_is_provider_dispatch(intent))
}

///|
pub fn record_part_dispatch_failure(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  detail : String,
  observed_at~ : Int64,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect != Some(intent) ||
    intent.lifecycle != PartEffectMayHaveOccurred {
    return Err(workflow_error("dispatch failure has no authorized effect"))
  }
  let (take_id, session_id) = match intent.kind {
    DispatchImplementation(take_id, command)
    | DispatchAudit(take_id, command, _) => (take_id, Some(command.session_id))
    DispatchVerification(take_id, _) => (take_id, None)
    _ => return Err(workflow_error("dispatch failure is not a dispatch effect"))
  }
  match snapshot.dispatch_diagnostic {
    Some(observed) if observed.take_id == take_id => Ok(snapshot)
    _ =>
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
        dispatch_diagnostic: Some({
          take_id,
          session_id,
          reason: None,
          detail,
          recovery: None,
          availability: @control.ProviderAvailability::ProviderUnavailable,
          observed_at,
        }),
      })
  }
}

///|
pub fn record_part_provider_protocol_violation(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  detail : String,
  observed_at~ : Int64,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  record_part_provider_dispatch_uncertainty(
    snapshot,
    intent,
    @control.TakeUncertaintyReason::TakeProtocolViolation,
    @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated,
    "protocol violation",
    detail,
    observed_at~,
  )
}

///|
pub fn record_part_event_ingestion_overflow(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  detail : String,
  observed_at~ : Int64,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  record_part_provider_dispatch_uncertainty(
    snapshot,
    intent,
    @control.TakeUncertaintyReason::TakeCursorGap,
    @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
    "event ingestion overflow",
    detail,
    observed_at~,
  )
}

///|
/// Durable artifact an effect leaves behind when it reaches the Part, used to
/// decide whether an uncertain effect actually occurred.
///
/// Effects that mutate the shared integration branch have no such local
/// artifact, so they are never discharged from evidence held by the Part alone.
priv enum PartEffectEvidence {
  PartEffectEvidenceAbsent
  PartEffectEvidencePresent
  PartEffectEvidenceUnavailable
}

///|
fn part_effect_evidence(
  snapshot : PartWorkflowSnapshot,
  kind : PartEffectKind,
) -> PartEffectEvidence {
  let present = fn(landed : Bool) {
    if landed {
      PartEffectEvidencePresent
    } else {
      PartEffectEvidenceAbsent
    }
  }
  match kind {
    PrepareImplementationSandbox(_)
    | PrepareImplementationCommand(_)
    | StartImplementationHarness(_, _)
    | DispatchImplementation(_, _)
    | NormalizeImplementationCandidate(_, _) =>
      present(snapshot.candidate is Some(_))
    PrepareVerificationSandbox(_) | DispatchVerification(_, _) =>
      present(snapshot.verification_receipts.length() > 0)
    PrepareAuditSandbox(_)
    | PrepareAuditCommand(_)
    | StartAuditHarness(_, _)
    | DispatchAudit(_, _, _) => present(snapshot.audit_receipt is Some(_))
    GeneratePromotion(_) | ApplyIntegration(_, _) =>
      PartEffectEvidenceUnavailable
  }
}

///|
pub(all) enum PartUncertaintyReconciliation {
  PartUncertaintyDischarged(PartWorkflowSnapshot)
  PartUncertaintyRetained
} derive(Debug, Eq)

///|
/// Resolve a Part parked on provider-dispatch uncertainty using the evidence
/// the Part already holds.
///
/// A Take that died without leaving its artifact — no candidate, no
/// verification receipt, no audit receipt — did not occur, so the uncertainty
/// is discharged and the Part becomes retryable through the ordinary blocked
/// path. Uncertainty is retained whenever the effect did leave an artifact, or
/// where the Part cannot see the outcome at all (integration and promotion),
/// because a wrong guess there would duplicate a durable side effect.
pub fn reconcile_part_recovery_uncertainty(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartUncertaintyReconciliation, @types.ChoirError] {
  guard snapshot.stage == PartRecoveryUncertain &&
    snapshot.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain
    ) else {
    return Err(workflow_error("Part is not parked on recovery uncertainty"))
  }
  let intent = match snapshot.pending_effect {
    Some(value) if value.lifecycle == PartEffectUncertain => value
    _ => return Err(workflow_error("Part has no uncertain effect"))
  }
  match part_effect_evidence(snapshot, intent.kind) {
    PartEffectEvidenceAbsent =>
      Ok(
        PartUncertaintyDischarged({
          ..snapshot,
          durable_version: snapshot.durable_version + 1,
          stage: PartBlocked,
          pending_effect: None,
        }),
      )
    PartEffectEvidencePresent | PartEffectEvidenceUnavailable =>
      Ok(PartUncertaintyRetained)
  }
}

///|
pub(all) enum PartRecoveryRetryDecision {
  PartRecoveryRetryPlanned(PartWorkflowSnapshot)
  PartRecoveryRetryRetained
  PartRecoveryRetryLimitReached
  /// The surface itself said it cannot serve yet, and no other surface the
  /// contract admits can take the work. This is a wait, not a failure, and it
  /// never changes which provider the contract authorized.
  PartRecoveryRetryDeferred(@control.ProviderAvailability)
  /// The surface cannot serve and the captured contract admits another one,
  /// so the next bounded recovery Take is armed there. The Take that already
  /// died is never retargeted; only the fresh one moves.
  PartRecoveryRetryFailedOver(PartWorkflowSnapshot, PartProviderFailover)
} derive(Debug, Eq)

///|
/// What each surface this Part has already left last told it.
///
/// Only a surface the Part is not currently on can be a failover target, so
/// the live diagnostic — which speaks for the current surface — is never an
/// observation this decision can consult. The recorded failovers are: each one
/// names the surface it left and why, and that memory is what keeps a Part
/// from being handed back to a surface it already found spent.
fn part_surface_observations(
  failovers : Array[PartProviderFailover],
) -> Array[@control.ProviderSurfaceObservation] {
  let observations : Array[@control.ProviderSurfaceObservation] = []
  for failover in failovers {
    observations.push({
      surface: failover.from_surface,
      availability: failover.cause,
      // The move was decided on the observation that caused it, so the
      // decision instant dates the observation. It is never earlier than the
      // dispatch that failed, so an undated allowance is re-checked no sooner
      // than the schedule says.
      observed_at: failover.decided_at,
    })
  }
  observations
}

///|
/// How many times this Part has already been deferred by one surface.
///
/// Each recorded failover is one such deferral: the Part left that surface
/// because it said it could not serve. The count is what makes a re-check
/// interval back off, so a surface that keeps refusing is asked less often
/// rather than the same Part hammering it every interval.
fn part_surface_prior_deferrals(
  failovers : Array[PartProviderFailover],
  surface : @control.ProviderSurfaceId,
) -> Int {
  let mut count = 0
  for failover in failovers {
    if failover.from_surface == surface {
      count = count + 1
    }
  }
  count
}

///|
/// When a surface that reported a spent allowance without naming a reset
/// instant is asked again.
///
/// Choir does not know when the allowance returns, so the schedule claims
/// nothing about that. What it does say is that one observation is not
/// permanent: the first re-check is a minute later, each further deferral of
/// the same surface waits twice as long, and no wait exceeds half an hour. A
/// Part therefore always has an instant at which it becomes eligible again,
/// and the bounded recovery budget still decides how many attempts it gets.
fn part_provider_recheck_policy() -> Result[
  @control.ProviderRecheckPolicy,
  @types.ChoirError,
] {
  @control.provider_recheck_policy(
    base_seconds=60L,
    growth=2L,
    ceiling_seconds=1_800L,
    reset_horizon_seconds=691_200L,
  )
}

///|
/// Autonomous counterpart to the operator retry path: discharge a provider
/// effect that demonstrably left no artifact and re-arm the Part with fresh
/// identities, without a user message.
///
/// An effect that may have occurred is deliberately retained — guessing there
/// would duplicate a durable side effect — and a Part that has already burned
/// its recovery budget stops, so a surface that keeps dying surfaces as a
/// bounded blocker rather than an infinite loop.
///
/// `identities` is asked for a plan on a named surface rather than handed one,
/// because the surface is this decision's to make: the captured contract says
/// which surfaces are admitted, and only the host can mint identities and the
/// surface manifest digest for the one that is chosen.
pub fn plan_part_recovery_retry(
  snapshot : PartWorkflowSnapshot,
  identities : (@control.ProviderSurfaceId) -> PartIdentityPlan,
  is_nfc : (String) -> Bool,
  now? : Int64 = 0L,
) -> Result[PartRecoveryRetryDecision, @types.ChoirError] {
  let current = snapshot.identities.implementation_session.surface
  let policy = match part_provider_recheck_policy() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // A surface that reported a spent allowance or a retry-after must not be hit
  // again until its own evidence says it is ready, or — where it named no
  // instant — until the re-check schedule says the observation has aged out.
  // Re-arming sooner would burn the recovery budget against a surface that
  // cannot serve, so the work either moves to another admitted surface or
  // waits for a stated instant.
  let failover : PartProviderFailover? = match snapshot.dispatch_diagnostic {
    Some(diagnostic) =>
      if @control.provider_availability_admits_dispatch(
          diagnostic.availability,
          observed_at=diagnostic.observed_at,
          prior_deferrals=part_surface_prior_deferrals(
            snapshot.provider_failovers,
            current,
          ),
          policy~,
          now~,
        ) {
        None
      } else {
        match
          @control.select_admitted_provider_surface(
            current,
            snapshot.admitted_provider_surfaces,
            part_surface_observations(snapshot.provider_failovers),
            policy,
            now,
          ) {
          Some(target) =>
            Some({
              from_surface: current,
              to_surface: target,
              cause: diagnostic.availability,
              retry_ordinal: snapshot.prior_takes.length() / 3 + 1,
              decided_at: now,
            })
          None => return Ok(PartRecoveryRetryDeferred(diagnostic.availability))
        }
      }
    None => None
  }
  let discharged = match reconcile_part_recovery_uncertainty(snapshot) {
    Ok(PartUncertaintyDischarged(value)) => value
    Ok(PartUncertaintyRetained) => return Ok(PartRecoveryRetryRetained)
    Err(error) => return Err(error)
  }
  if snapshot.prior_takes.length() / 3 >= maximum_part_recovery_retries() {
    return Ok(PartRecoveryRetryLimitReached)
  }
  let target = match failover {
    Some(record) => record.to_surface
    None => current
  }
  let plan = identities(target)
  // The host mints identities; it does not get to decide the surface. A plan
  // that came back on a different surface than the one selected would move
  // provider authority without a recorded decision.
  if plan.implementation_session.surface != target ||
    plan.audit_session.surface != target {
    return Err(
      workflow_error(
        "recovery identity plan uses an unselected provider surface",
      ),
    )
  }
  match plan_part_retry(discharged, plan, is_nfc) {
    Ok(value) =>
      match failover {
        Some(record) =>
          Ok(
            PartRecoveryRetryFailedOver(
              {
                ..value,
                provider_failovers: value.provider_failovers + [record],
              },
              record,
            ),
          )
        None => Ok(PartRecoveryRetryPlanned(value))
      }
    Err(error) => Err(error)
  }
}

///|
pub fn record_part_provider_process_loss(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
  detail : String,
  observed_at~ : Int64,
  availability? : @control.ProviderAvailability = @control.ProviderAvailability::ProviderUnavailable,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  record_part_provider_dispatch_uncertainty(
    snapshot,
    intent,
    @control.TakeUncertaintyReason::TakeEffectUncertain,
    @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
    "provider process loss",
    detail,
    observed_at~,
    availability~,
  )
}
