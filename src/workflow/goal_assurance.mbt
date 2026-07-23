///|
pub(all) enum GoalAssuranceStage {
  GoalSealPlanned
  GoalSealAuthorized
  GoalSealWitnessed
  GoalSealed
  GoalVerificationPending
  GoalVerified
  GoalAuditPending
  GoalAudited
  GoalAssuranceBlocked
  GoalAssuranceRecoveryUncertain
  GoalAssuranceCanceled
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAssuranceRecord {
  goal_id : @control.GoalId
  repository_id : RepositoryId
  goal_ref : GitRefName
  goal_contract_digest : @control.Digest
  base_commit_oid : @control.GitOid
  integration_receipts : Array[@control.IntegrationReceipt]
  integration_receipt_set_digest : @control.Digest
  assurance_policy_revision : @control.RevisionId
  assurance_policy_digest : @control.Digest
  verification_specs : Array[@control.VerificationSpec]
  identities : GoalAssuranceIdentityPlan
  verification_take : @control.Take
  audit_take : @control.Take
  seal_intent : @control.GoalBranchSealIntent
  seal_witnessed_at : Int64?
  seal : @control.GoalBranchSeal?
  sandbox_leases : Array[@control.SandboxLease]
  harness_sessions : Array[@control.HarnessSession]
  harness_events : Array[@control.HarnessEventEnvelope]
  verification_subject : @control.GoalVerificationSubject?
  verification_slots : Array[@control.GoalVerificationAuthorizationSlot]
  verification_receipts : Array[@control.GoalVerificationReceipt]
  verification_authorization : @control.GoalVerificationAuthorizationSet?
  audit_subject : @control.GoalAuditSubject?
  audit_result : @control.GoalAuditResult?
  audit_receipt : @control.GoalAuditReceipt?
  pending_effect : GoalAssuranceEffectIntent?
  effect_receipts : Array[GoalAssuranceEffectReceipt]
  stage : GoalAssuranceStage
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_assurance_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal assurance: " + detail)
}

///|
fn goal_assurance_domain_digest(
  domain : String,
  value : Json,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + value.stringify(indent=0)),
  )
}

///|
fn ordered_integration_receipts(
  execution : GoalExecutionRecord,
  snapshots : Array[PartWorkflowSnapshot],
  final_head_oid : @control.GitOid,
) -> Result[Array[@control.IntegrationReceipt], @types.ChoirError] {
  if snapshots.length() != execution.part_workflow_ids.length() ||
    snapshots.length() == 0 {
    return Err(goal_assurance_error("Part cardinality is inconsistent"))
  }
  let remaining : Array[@control.IntegrationReceipt] = []
  for snapshot in snapshots {
    if snapshot.goal.id != execution.goal.id ||
      snapshot.part.goal_id != execution.goal.id ||
      !(snapshot.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)) {
      return Err(goal_assurance_error("Part is not integrated"))
    }
    let receipt = match snapshot.integration_receipt {
      Some(value) => value
      None => return Err(goal_assurance_error("integration receipt is absent"))
    }
    if receipt.goal_id != execution.goal.id ||
      receipt.part_id != snapshot.part.id {
      return Err(goal_assurance_error("integration receipt identity is wrong"))
    }
    remaining.push(receipt)
  }
  let ordered : Array[@control.IntegrationReceipt] = []
  let mut head = execution.base_commit_oid
  while remaining.length() > 0 {
    let mut selected = -1
    for index = 0; index < remaining.length(); index = index + 1 {
      if remaining[index].from_head_oid == head {
        if selected >= 0 {
          return Err(goal_assurance_error("integration chain forks"))
        }
        selected = index
      }
    }
    if selected < 0 {
      return Err(goal_assurance_error("integration chain is discontinuous"))
    }
    let receipt = remaining[selected]
    ordered.push(receipt)
    head = receipt.promotion_commit_oid
    ignore(remaining.remove(selected))
  }
  if head != final_head_oid {
    return Err(goal_assurance_error("integration chain does not reach head"))
  }
  Ok(ordered)
}

///|
fn canonical_goal_verification_specs(
  proposed : Array[@control.VerificationSpec],
) -> Result[Array[@control.VerificationSpec], @types.ChoirError] {
  let specs : Array[@control.VerificationSpec] = []
  for spec in proposed {
    for existing in specs {
      if existing.id == spec.id {
        if existing != spec {
          return Err(
            goal_assurance_error("verification spec identity conflicts"),
          )
        }
        continue
      }
    }
    if !specs.any(fn(existing) { existing.id == spec.id }) {
      specs.push(spec)
    }
  }
  specs.sort_by(fn(left, right) { left.id.compare(right.id) })
  if specs.length() == 0 {
    Err(goal_assurance_error("Goal verification plan is empty"))
  } else {
    Ok(specs)
  }
}

///|
pub fn goal_assurance_record_bytes(record : GoalAssuranceRecord) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn goal_assurance_record_digest(
  record : GoalAssuranceRecord,
) -> @control.Digest {
  @storage.artifact_digest(goal_assurance_record_bytes(record))
}

///|
pub fn goal_branch_seal_digest(
  seal : @control.GoalBranchSeal,
) -> @control.Digest {
  goal_assurance_domain_digest(
    "choir.goal-branch-seal.v1",
    [
      seal.id.to_json(),
      seal.intent_id.to_json(),
      seal.goal_id.to_json(),
      seal.seal_epoch.to_json(),
      seal.goal_ref.to_json(),
      seal.seal_witness_ref.to_json(),
      seal.head_oid.to_json(),
      seal.tree_oid.to_json(),
      seal.goal_contract_digest.to_json(),
      seal.assurance_policy_revision.to_json(),
      seal.assurance_policy_digest.to_json(),
      seal.integration_receipt_set_digest.to_json(),
      seal.sealed_at.to_json(),
    ].to_json(),
  )
}

///|
fn goal_assurance_stage_matches(record : GoalAssuranceRecord) -> Bool {
  match
    (
      record.stage,
      record.seal_intent.lifecycle,
      record.seal_witnessed_at,
      record.seal,
    ) {
    (
      GoalSealPlanned,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealPlanned,
      None,
      None,
    ) => true
    (
      GoalSealAuthorized,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealAuthorized,
      None,
      None,
    ) => true
    (
      GoalSealWitnessed,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealWitnessed,
      Some(observed_at),
      None,
    ) => observed_at > 0L
    (
      GoalSealed
      | GoalVerificationPending
      | GoalVerified
      | GoalAuditPending
      | GoalAudited,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
      Some(observed_at),
      Some(seal),
    ) => observed_at > 0L && seal.seal_digest == goal_branch_seal_digest(seal)
    (GoalAssuranceBlocked | GoalAssuranceRecoveryUncertain, _, _, _) => true
    (
      GoalAssuranceCanceled,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealAbandonedByCancellation,
      None,
      None,
    ) => true
    (
      GoalAssuranceCanceled,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealWitnessed,
      Some(observed_at),
      None,
    ) => observed_at > 0L
    (
      GoalAssuranceCanceled,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
      Some(observed_at),
      Some(seal),
    ) => observed_at > 0L && seal.seal_digest == goal_branch_seal_digest(seal)
    (
      GoalAssuranceCanceled,
      @control.GoalBranchSealIntentLifecycle::GoalBranchSealIntegrityBlocked(_)
      | @control.GoalBranchSealIntentLifecycle::GoalBranchSealUncertain(_),
      _,
      _,
    ) => true
    _ => false
  }
}

///|
fn planned_goal_assurance_take(
  take : @control.Take,
  goal_id : @control.GoalId,
) -> Bool {
  take.goal_id == goal_id &&
  take.ordinal > 0 &&
  take.fencing_epoch is None &&
  take.lifecycle == @control.TakeLifecycle::TakePlanned
}

///|
fn planned_goal_assurance_resource(
  take : @control.Take,
  lease : @control.SandboxLease,
  session : @control.HarnessSession,
) -> Bool {
  lease.take_id == take.id &&
  lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeasePlanned &&
  session.take_id == take.id &&
  session.sandbox_generation_id == lease.generation_id &&
  session.lifecycle == @control.HarnessSessionLifecycle::HarnessSessionPlanned &&
  session.last_choir_sequence == @control.EventSequence(0L) &&
  session.open_tool_execution_ids.length() == 0
}

///|
fn planned_goal_assurance_sandbox(
  take : @control.Take,
  lease : @control.SandboxLease,
) -> Bool {
  lease.take_id == take.id &&
  lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeasePlanned
}

///|
fn goal_assurance_identity_plan_is_valid(record : GoalAssuranceRecord) -> Bool {
  let identities = record.identities
  if identities.verification_take.id == identities.audit_take.id ||
    identities.verification_sandbox.id == identities.audit_sandbox.id ||
    identities.verification_sandbox.generation_id ==
    identities.audit_sandbox.generation_id ||
    !planned_goal_assurance_take(identities.verification_take, record.goal_id) ||
    !planned_goal_assurance_take(identities.audit_take, record.goal_id) ||
    !planned_goal_assurance_sandbox(
      identities.verification_take,
      identities.verification_sandbox,
    ) ||
    !planned_goal_assurance_resource(
      identities.audit_take,
      identities.audit_sandbox,
      identities.audit_session,
    ) {
    return false
  }
  match identities.verification_take.purpose {
    @control.TakePurpose::GoalVerification(goal_id, head_oid, _) =>
      if goal_id != record.goal_id ||
        head_oid != record.seal_intent.expected_head_oid {
        return false
      }
    _ => return false
  }
  match identities.audit_take.purpose {
    @control.TakePurpose::GoalAudit(goal_id, _) => goal_id == record.goal_id
    _ => false
  }
}

///|
fn goal_assurance_contract_is_valid(record : GoalAssuranceRecord) -> Bool {
  if record.goal_ref != goal_execution_ref(record.goal_id) {
    return false
  }
  let mut head = record.base_commit_oid
  for index = 0; index < record.integration_receipts.length(); index = index + 1 {
    let receipt = record.integration_receipts[index]
    if receipt.goal_id != record.goal_id || receipt.from_head_oid != head {
      return false
    }
    for other = index + 1
        other < record.integration_receipts.length()
        other = other + 1 {
      if receipt.id == record.integration_receipts[other].id ||
        receipt.part_id == record.integration_receipts[other].part_id {
        return false
      }
    }
    head = receipt.promotion_commit_oid
  }
  if head != record.seal_intent.expected_head_oid ||
    record.integration_receipts[record.integration_receipts.length() - 1].promotion_tree_oid !=
    record.seal_intent.expected_tree_oid {
    return false
  }
  let receipt_set_digest = goal_assurance_domain_digest(
    "choir.goal-integration-receipt-set.v1",
    record.integration_receipts.to_json(),
  )
  if receipt_set_digest != record.integration_receipt_set_digest {
    return false
  }
  for index = 0; index < record.verification_specs.length(); index = index + 1 {
    if index > 0 &&
      record.verification_specs[index - 1].id.compare(
        record.verification_specs[index].id,
      ) >=
      0 {
      return false
    }
  }
  let policy_digest = goal_assurance_domain_digest(
    "choir.goal-assurance-policy.v1",
    [
      record.goal_contract_digest.to_json(),
      record.verification_specs.to_json(),
      record.identities.to_json(),
    ].to_json(),
  )
  if policy_digest != record.assurance_policy_digest ||
    record.assurance_policy_revision !=
    @control.RevisionId("goal-assurance-" + @storage.digest_text(policy_digest)) ||
    !goal_assurance_identity_plan_is_valid(record) {
    return false
  }
  match record.seal {
    Some(seal) =>
      seal.goal_id == record.goal_id &&
      seal.goal_ref == record.goal_ref.0 &&
      seal.head_oid == record.seal_intent.expected_head_oid &&
      seal.tree_oid == record.seal_intent.expected_tree_oid &&
      seal.goal_contract_digest == record.goal_contract_digest &&
      seal.assurance_policy_revision == record.assurance_policy_revision &&
      seal.assurance_policy_digest == record.assurance_policy_digest &&
      seal.integration_receipt_set_digest ==
      record.integration_receipt_set_digest
    None => true
  }
}

///|
pub fn decode_goal_assurance_record(
  content : Bytes,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_assurance_error("record is not valid JSON"))
  }
  let record : GoalAssuranceRecord = @json.from_json(json) catch {
    _ => return Err(goal_assurance_error("record has the wrong schema"))
  }
  if record.goal_id.0 == "" ||
    record.repository_id.0 == "" ||
    record.goal_ref.0 == "" ||
    record.durable_version <= 0 ||
    record.fencing_epoch.0 <= 0L ||
    record.integration_receipts.length() == 0 ||
    record.verification_specs.length() == 0 ||
    record.seal_intent.goal_id != record.goal_id ||
    record.seal_intent.integration_receipt_set_digest !=
    record.integration_receipt_set_digest ||
    record.seal_intent.assurance_policy_revision !=
    record.assurance_policy_revision ||
    record.seal_intent.assurance_policy_digest != record.assurance_policy_digest ||
    !goal_assurance_contract_is_valid(record) ||
    !goal_assurance_stage_matches(record) {
    Err(goal_assurance_error("record identity is invalid"))
  } else {
    Ok(record)
  }
}

///|
pub fn initialize_goal_assurance(
  execution : GoalExecutionRecord,
  snapshots : Array[PartWorkflowSnapshot],
  observed_head_oid : @control.GitOid,
  observed_tree_oid : @control.GitOid,
  verification_specs : Array[@control.VerificationSpec],
  identities : GoalAssuranceIdentityPlan,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if execution.state != GoalExecutionState::GoalExecutionAssuring ||
    execution.goal.lifecycle !=
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ) {
    return Err(goal_assurance_error("Goal is not authorizing assurance"))
  }
  let receipts = match
    ordered_integration_receipts(execution, snapshots, observed_head_oid) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let specs = match canonical_goal_verification_specs(verification_specs) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt_set_digest = goal_assurance_domain_digest(
    "choir.goal-integration-receipt-set.v1",
    receipts.to_json(),
  )
  let assurance_policy_digest = goal_assurance_domain_digest(
    "choir.goal-assurance-policy.v1",
    [
      execution.goal.contract_digest.to_json(),
      specs.to_json(),
      identities.to_json(),
    ].to_json(),
  )
  let assurance_policy_revision = @control.RevisionId(
    "goal-assurance-" + @storage.digest_text(assurance_policy_digest),
  )
  let intent_key = goal_assurance_domain_digest(
    "choir.goal-branch-seal-intent.v1",
    [
      execution.goal.id.to_json(),
      observed_head_oid.to_json(),
      observed_tree_oid.to_json(),
      receipt_set_digest.to_json(),
      assurance_policy_revision.to_json(),
      assurance_policy_digest.to_json(),
    ].to_json(),
  )
  let key = @storage.digest_text(intent_key)
  Ok({
    goal_id: execution.goal.id,
    repository_id: execution.repository_id,
    goal_ref: execution.goal_ref,
    goal_contract_digest: execution.goal.contract_digest,
    base_commit_oid: execution.base_commit_oid,
    integration_receipts: receipts,
    integration_receipt_set_digest: receipt_set_digest,
    assurance_policy_revision,
    assurance_policy_digest,
    verification_specs: specs,
    identities,
    verification_take: identities.verification_take,
    audit_take: identities.audit_take,
    seal_intent: {
      id: @control.GoalBranchSealIntentId("seal-intent-" + key),
      goal_id: execution.goal.id,
      expected_head_oid: observed_head_oid,
      expected_tree_oid: observed_tree_oid,
      integration_receipt_set_digest: receipt_set_digest,
      assurance_policy_revision,
      assurance_policy_digest,
      seal_witness_ref: "refs/choir/goals/" +
      @storage.digest_text(
        @storage.artifact_digest(@utf8.encode(execution.goal.id.0)),
      ) +
      "/sealed/" +
      key,
      idempotency_key: "seal-" + key,
      lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealPlanned,
    },
    seal_witnessed_at: None,
    seal: None,
    sandbox_leases: [],
    harness_sessions: [],
    harness_events: [],
    verification_subject: None,
    verification_slots: [],
    verification_receipts: [],
    verification_authorization: None,
    audit_subject: None,
    audit_result: None,
    audit_receipt: None,
    pending_effect: None,
    effect_receipts: [],
    stage: GoalAssuranceStage::GoalSealPlanned,
    durable_version: 1,
    fencing_epoch: execution.fencing_epoch,
  })
}

///|
pub fn authorize_goal_assurance_seal(
  record : GoalAssuranceRecord,
  goal : @control.Goal,
  observed_head_oid : @control.GitOid,
  observed_tree_oid : @control.GitOid,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if record.stage != GoalAssuranceStage::GoalSealPlanned {
    return Err(goal_assurance_error("seal is not planned"))
  }
  let intent = match
    @control.authorize_goal_branch_seal(
      goal,
      record.seal_intent,
      observed_head_oid,
      observed_tree_oid,
      record.integration_receipt_set_digest,
      record.assurance_policy_revision,
      record.assurance_policy_digest,
    ) {
    Ok(value) => value
    Err(_) => return Err(goal_assurance_error("seal authorization failed"))
  }
  Ok({
    ..record,
    seal_intent: intent,
    stage: GoalAssuranceStage::GoalSealAuthorized,
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn record_goal_assurance_seal_witness(
  record : GoalAssuranceRecord,
  observation : @control.GoalBranchSealWitnessObservation,
  observed_at : Int64,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if record.stage != GoalAssuranceStage::GoalSealAuthorized || observed_at <= 0L {
    return Err(goal_assurance_error("seal is not authorized"))
  }
  match
    @control.reconcile_goal_branch_seal_witness(record.seal_intent, observation) {
    @control.GoalBranchSealReconciliationOutcome::GoalBranchSealWitnessAccepted(
      intent
    ) =>
      Ok({
        ..record,
        seal_intent: intent,
        seal_witnessed_at: Some(observed_at),
        stage: GoalAssuranceStage::GoalSealWitnessed,
        durable_version: record.durable_version + 1,
      })
    @control.GoalBranchSealReconciliationOutcome::GoalBranchSealRetryAuthorized =>
      Ok(record)
    @control.GoalBranchSealReconciliationOutcome::GoalBranchSealReconciliationDiverged =>
      Err(goal_assurance_error("seal witness diverged"))
    @control.GoalBranchSealReconciliationOutcome::GoalBranchSealReconciliationIntegrityError =>
      Err(goal_assurance_error("seal witness is corrupt"))
  }
}

///|
pub fn commit_goal_assurance_seal(
  record : GoalAssuranceRecord,
  seal_id : @control.GoalBranchSealId,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if record.stage != GoalAssuranceStage::GoalSealWitnessed {
    return Err(goal_assurance_error("seal witness is not ready"))
  }
  let sealed_at = match record.seal_witnessed_at {
    Some(value) if value > 0L => value
    _ => return Err(goal_assurance_error("seal witness time is absent"))
  }
  let unfinished : @control.GoalBranchSeal = {
    id: seal_id,
    intent_id: record.seal_intent.id,
    goal_id: record.goal_id,
    seal_epoch: record.fencing_epoch,
    goal_ref: record.goal_ref.0,
    seal_witness_ref: record.seal_intent.seal_witness_ref,
    head_oid: record.seal_intent.expected_head_oid,
    tree_oid: record.seal_intent.expected_tree_oid,
    goal_contract_digest: record.goal_contract_digest,
    assurance_policy_revision: record.assurance_policy_revision,
    assurance_policy_digest: record.assurance_policy_digest,
    integration_receipt_set_digest: record.integration_receipt_set_digest,
    sealed_at,
    seal_digest: @control.Digest(""),
  }
  let seal = { ..unfinished, seal_digest: goal_branch_seal_digest(unfinished) }
  let intent = match
    @control.commit_goal_branch_seal(record.seal_intent, seal) {
    Ok(value) => value
    Err(_) => return Err(goal_assurance_error("seal commit failed"))
  }
  Ok({
    ..record,
    seal_intent: intent,
    seal: Some(seal),
    stage: GoalAssuranceStage::GoalSealed,
    durable_version: record.durable_version + 1,
  })
}

///|
fn cancel_goal_assurance_take(
  take : @control.Take,
  fence : @control.FencingEpoch,
) -> Result[@control.Take, @types.ChoirError] {
  match take.lifecycle {
    @control.TakeLifecycle::TakeLeased =>
      @control.transition_take(
        take,
        @control.TakeTransition::FinishTake(
          fence,
          @control.TakeTerminalDisposition::TakeCanceled,
        ),
      )
    @control.TakeLifecycle::TakeRunning
    | @control.TakeLifecycle::TakeResultRecorded(_) =>
      @control.transition_take(
        take,
        @control.TakeTransition::FinishTake(
          fence,
          @control.TakeTerminalDisposition::TakeInterrupted,
        ),
      )
    _ => Ok(take)
  }
}

///|
fn goal_assurance_session_disposition_is_known(
  session : @control.HarnessSession,
) -> Bool {
  match session.lifecycle {
    @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(_)
    | @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated
    | @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain => true
    _ => false
  }
}

///|
fn goal_assurance_take_disposition_is_known(take : @control.Take) -> Bool {
  match take.lifecycle {
    @control.TakeLifecycle::TakePlanned
    | @control.TakeLifecycle::TakeTerminal(_) => true
    _ => false
  }
}

///|
pub fn goal_assurance_cancellation_disposition_is_known(
  record : GoalAssuranceRecord,
) -> Bool {
  let effect_known = match record.pending_effect {
    None => true
    Some(intent) =>
      match intent.lifecycle {
        GoalAssuranceEffectReceipted
        | GoalAssuranceEffectUncertain
        | GoalAssuranceEffectAbandonedByCancellation => true
        _ => false
      }
  }
  record.stage == GoalAssuranceCanceled &&
  record.seal_intent.lifecycle !=
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealAuthorized &&
  goal_assurance_take_disposition_is_known(record.verification_take) &&
  goal_assurance_take_disposition_is_known(record.audit_take) &&
  record.sandbox_leases.all(fn(lease) {
    lease.lifecycle != @control.SandboxLeaseLifecycle::SandboxLeaseActive
  }) &&
  record.harness_sessions.all(goal_assurance_session_disposition_is_known) &&
  effect_known
}

///|
pub fn record_goal_assurance_cancellation(
  record : GoalAssuranceRecord,
) -> Result[GoalAssuranceRecord, @types.ChoirError] {
  if goal_assurance_cancellation_disposition_is_known(record) {
    return Ok(record)
  }
  if record.seal_intent.lifecycle ==
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealAuthorized {
    return Ok(record)
  }
  let seal_intent = match record.seal_intent.lifecycle {
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealPlanned =>
      {
        ..record.seal_intent,
        lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealAbandonedByCancellation,
      }
    _ => record.seal_intent
  }
  let verification_take = match
    cancel_goal_assurance_take(record.verification_take, record.fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let audit_take = match
    cancel_goal_assurance_take(record.audit_take, record.fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sandbox_leases = record.sandbox_leases.map(fn(lease) {
    if lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeaseActive {
      {
        ..lease,
        lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseUncertain,
      }
    } else {
      lease
    }
  })
  let harness_sessions = record.harness_sessions.map(fn(session) {
    if goal_assurance_session_disposition_is_known(session) {
      session
    } else {
      {
        ..session,
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
      }
    }
  })
  let pending_effect = match record.pending_effect {
    Some({ lifecycle: GoalAssuranceEffectPlanned, .. } as intent) =>
      Some({ ..intent, lifecycle: GoalAssuranceEffectAbandonedByCancellation })
    Some({ lifecycle: GoalAssuranceEffectMayHaveOccurred, .. } as intent) =>
      Some({ ..intent, lifecycle: GoalAssuranceEffectUncertain })
    other => other
  }
  let next = {
    ..record,
    verification_take,
    audit_take,
    seal_intent,
    sandbox_leases,
    harness_sessions,
    pending_effect,
    stage: GoalAssuranceCanceled,
    durable_version: record.durable_version + 1,
  }
  if goal_assurance_cancellation_disposition_is_known(next) {
    Ok(next)
  } else {
    Err(goal_assurance_error("cancellation disposition remains unresolved"))
  }
}
