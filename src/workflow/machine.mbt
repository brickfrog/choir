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
  if witness.effect_id == "" ||
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
  workflow_id : String,
  goal : @control.Goal,
  part : @control.GoalPart,
  contract : @control.TaskContractRevision,
  identities : PartIdentityPlan,
  fencing_epoch : @control.FencingEpoch,
  is_nfc : (String) -> Bool,
  part_context_manifest? : @migration.PartContextManifest? = None,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if workflow_id == "" || workflow_id.contains("\u{00}") {
    return Err(workflow_error("workflow identity is empty or invalid"))
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
      identities.verification_session,
      identities.verification_take,
      identities.verification_sandbox,
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
    audit_result: None,
    audit_receipt: None,
    integration_lease: None,
    integration_intent: None,
    promotion_commit: None,
    integration_receipt: None,
    integration_conflicts: [],
    pending_effect: None,
    effect_receipts: [],
  })
}

///|
pub fn maximum_part_conflict_repairs() -> Int {
  2
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
        },
      ],
      sandbox_leases: snapshot.sandbox_leases,
      harness_sessions: snapshot.harness_sessions,
      harness_events: snapshot.harness_events,
      integration_conflicts: snapshot.integration_conflicts,
      effect_receipts: snapshot.effect_receipts,
    }),
  )
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
    PartVerificationSandboxPrepared => "verification-command"
    PartVerificationCommandPrepared => "verification-harness"
    PartVerificationHarnessStarted => "verification-dispatch"
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
    PartVerificationCommand =>
      snapshot.task_contract.verification_capability_profile_digest
    PartAuditCommand => snapshot.task_contract.audit_capability_profile_digest
    GoalVerificationCommand | GoalAuditCommand =>
      snapshot.task_contract.audit_capability_profile_digest
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
    effect_id: snapshot.workflow_id + ":" + session.id.0 + ":start",
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
  {
    effect_id: snapshot.workflow_id + ":" + session.id.0 + ":command-1",
    session_id: session.id,
    command_id: @control.HarnessCommandId(session.id.0 + ":command-1"),
    command_sequence: 1,
    required_provider_cursor: None,
    command_artifact_digest: prepared.command_artifact.digest,
    provider_idempotency_token: Some(
      snapshot.workflow_id + ":" + session.id.0 + ":command-1",
    ),
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
    PartVerificationCommand =>
      match snapshot.verification_subject {
        Some(subject) =>
          (
            Some(
              part_command_preparation_plan(
                snapshot,
                @command.CommandRole::PartVerificationCommand,
                snapshot.verification_take,
                snapshot.identities.verification_session,
                @command.CommandExecutionSubject::PartVerificationCommandSubject(
                  subject,
                ),
              ),
            ),
            snapshot.verification_take,
          )
        None => (None, snapshot.verification_take)
      }
    PartAuditCommand =>
      match snapshot.audit_subject {
        Some(subject) =>
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
        None => (None, snapshot.audit_take)
      }
    GoalVerificationCommand | GoalAuditCommand => (None, prepared.plan.take)
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
          Ok(
            Some(
              PrepareVerificationCommand(
                part_command_preparation_plan(
                  snapshot,
                  @command.CommandRole::PartVerificationCommand,
                  snapshot.verification_take,
                  snapshot.identities.verification_session,
                  @command.CommandExecutionSubject::PartVerificationCommandSubject(
                    subject,
                  ),
                ),
              ),
            ),
          )
        None => Err(workflow_error("verification subject is missing"))
      }
    PartVerificationCommandPrepared =>
      match
        prepared_command_for(
          snapshot,
          @command.CommandRole::PartVerificationCommand,
          snapshot.verification_take.id,
          snapshot.identities.verification_session.id,
        ) {
        Some(prepared) =>
          Ok(
            Some(
              StartVerificationHarness(
                snapshot.identities.verification_session,
                session_start_intent(
                  snapshot,
                  snapshot.identities.verification_session,
                  prepared,
                ),
              ),
            ),
          )
        None => Err(workflow_error("verification command is missing"))
      }
    PartVerificationHarnessStarted =>
      match snapshot.verification_subject {
        Some(subject) =>
          match
            prepared_command_for(
              snapshot,
              @command.CommandRole::PartVerificationCommand,
              snapshot.verification_take.id,
              snapshot.identities.verification_session.id,
            ) {
            Some(prepared) =>
              Ok(
                Some(
                  DispatchVerification(
                    snapshot.verification_take.id,
                    harness_command_intent(
                      snapshot,
                      snapshot.identities.verification_session,
                      prepared,
                    ),
                    subject,
                  ),
                ),
              )
            None => Err(workflow_error("verification command is missing"))
          }
        None => Err(workflow_error("verification subject is missing"))
      }
    PartVerified =>
      Ok(Some(PrepareAuditSandbox(snapshot.identities.audit_sandbox)))
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
          let effect_id = snapshot.workflow_id +
            ":" +
            stage_effect_suffix(snapshot.stage)
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
        StartImplementationHarness(session, start) =>
          start_intent_has_preparation(
            snapshot,
            session,
            start,
            @command.CommandRole::ImplementationCommand,
            artifact_digest_exists,
          )
        StartVerificationHarness(session, start) =>
          start_intent_has_preparation(
            snapshot,
            session,
            start,
            @command.CommandRole::PartVerificationCommand,
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
        DispatchVerification(take_id, command, _) =>
          command_intent_has_preparation(
            snapshot,
            take_id,
            command,
            snapshot.identities.verification_session,
            @command.CommandRole::PartVerificationCommand,
            artifact_digest_exists,
          )
        DispatchAudit(take_id, command, _) =>
          command_intent_has_preparation(
            snapshot,
            take_id,
            command,
            snapshot.identities.audit_session,
            @command.CommandRole::PartAuditCommand,
            artifact_digest_exists,
          )
        _ => Ok(())
      }
      match preparation_check {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      Ok({
        ..snapshot,
        durable_version: snapshot.durable_version + 1,
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
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if snapshot.pending_effect != Some(intent) ||
    intent.lifecycle != PartEffectMayHaveOccurred {
    return Err(workflow_error(error_context + " has no authorized effect"))
  }
  let (take, session_id) = match intent.kind {
    DispatchImplementation(take_id, command)
    | DispatchVerification(take_id, command, _)
    | DispatchAudit(take_id, command, _) => {
      let take = if take_id == snapshot.implementation_take.id {
        snapshot.implementation_take
      } else if take_id == snapshot.verification_take.id {
        snapshot.verification_take
      } else if take_id == snapshot.audit_take.id {
        snapshot.audit_take
      } else {
        return Err(workflow_error(error_context + " named an unknown Take"))
      }
      (take, command.session_id)
    }
    _ =>
      return Err(
        workflow_error(
          error_context + " did not arise from a provider dispatch",
        ),
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
  let mut found_session = false
  let sessions = snapshot.harness_sessions.map(fn(session) {
    if session.id == session_id && session.take_id == take.id {
      found_session = true
      { ..session, lifecycle: session_lifecycle }
    } else {
      session
    }
  })
  if !found_session {
    return Err(workflow_error(error_context + " session is missing"))
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
  })
}

///|
pub fn record_part_provider_protocol_violation(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  record_part_provider_dispatch_uncertainty(
    snapshot,
    intent,
    @control.TakeUncertaintyReason::TakeProtocolViolation,
    @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated,
    "protocol violation",
  )
}

///|
pub fn record_part_event_ingestion_overflow(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  record_part_provider_dispatch_uncertainty(
    snapshot,
    intent,
    @control.TakeUncertaintyReason::TakeCursorGap,
    @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
    "event ingestion overflow",
  )
}

///|
pub fn record_part_provider_process_loss(
  snapshot : PartWorkflowSnapshot,
  intent : PartEffectIntent,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  record_part_provider_dispatch_uncertainty(
    snapshot,
    intent,
    @control.TakeUncertaintyReason::TakeEffectUncertain,
    @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
    "provider process loss",
  )
}
