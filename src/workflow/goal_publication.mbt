///|
pub(all) struct BranchPublicationIntentId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct RemoteName(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct RemoteRepositoryId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum BranchPublicationState {
  BranchPublicationPlanned
  BranchPublicationAuthorized
  BranchPublicationReceipted
  BranchPublicationDrift
  BranchPublicationPreflightUncertain
  BranchPublicationMutationUncertain
  BranchPublicationAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum RemoteBranchObservation {
  RemoteBranchAbsent
  RemoteBranchAt(@control.GitOid)
  RemoteBranchObservationUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum BranchPublicationReceiptOrigin {
  BranchPublicationMutationApplied
  BranchPublicationAdopted
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BranchPublicationIntent {
  id : BranchPublicationIntentId
  goal_id : @control.GoalId
  canonical_repository_id : RemoteRepositoryId
  remote_name : RemoteName
  remote_head_ref : GitRefName
  expected_prior_remote_oid : @control.GitOid?
  sealed_head_oid : @control.GitOid
  goal_branch_seal_id : @control.GoalBranchSealId
  goal_branch_seal_digest : @control.Digest
  idempotency_key : String
  state : BranchPublicationState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BranchPublicationReceipt {
  receipt_id : @control.ReceiptId
  intent_id : BranchPublicationIntentId
  idempotency_key : String
  canonical_repository_id : RemoteRepositoryId
  remote_head_ref : GitRefName
  prior_remote_oid : @control.GitOid?
  published_oid : @control.GitOid
  goal_branch_seal_id : @control.GoalBranchSealId
  goal_branch_seal_digest : @control.Digest
  origin : BranchPublicationReceiptOrigin
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPublicationRecord {
  goal_id : @control.GoalId
  repository_id : RepositoryId
  goal_ref : GitRefName
  goal_contract_digest : @control.Digest
  assurance_record_digest : @control.Digest
  goal_branch_seal : @control.GoalBranchSeal
  goal_verification_receipt_set_digest : @control.Digest
  goal_verification_evidence_manifest_digest : @control.Digest
  goal_audit_receipt_id : @control.ReceiptId
  goal_audit_result_digest : @control.Digest
  intent : BranchPublicationIntent
  receipt : BranchPublicationReceipt?
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalPublicationTickOutcome {
  GoalPublicationPending
  GoalPublicationComplete
  GoalPublicationDrifted
  GoalPublicationRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_publication_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal publication: " + detail)
}

///|
fn goal_publication_domain_digest(
  domain : String,
  value : Json,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + value.stringify(indent=0)),
  )
}

///|
fn valid_publication_remote_name(name : RemoteName) -> Bool {
  let value = name.0
  if value == "" || value.has_prefix("-") || value.contains("\u{00}") {
    return false
  }
  for character in value {
    if !((character >= 'a' && character <= 'z') ||
      (character >= 'A' && character <= 'Z') ||
      (character >= '0' && character <= '9') ||
      character == '-' ||
      character == '_' ||
      character == '.') {
      return false
    }
  }
  true
}

///|
fn valid_publication_ref(name : GitRefName) -> Bool {
  let value = name.0
  value.has_prefix("refs/heads/") &&
  value.length() > "refs/heads/".length() &&
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
fn goal_publication_intent_key(
  goal_id : @control.GoalId,
  canonical_repository_id : RemoteRepositoryId,
  remote_name : RemoteName,
  remote_head_ref : GitRefName,
  expected_prior_remote_oid : @control.GitOid?,
  seal : @control.GoalBranchSeal,
) -> @control.Digest {
  goal_publication_domain_digest(
    "choir.branch-publication-intent.v1",
    [
      goal_id.to_json(),
      canonical_repository_id.to_json(),
      remote_name.to_json(),
      remote_head_ref.to_json(),
      expected_prior_remote_oid.to_json(),
      seal.head_oid.to_json(),
      seal.id.to_json(),
      seal.seal_digest.to_json(),
    ].to_json(),
  )
}

///|
fn goal_publication_assurance_is_current(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
) -> Bool {
  guard assurance.seal is Some(seal) &&
    assurance.verification_authorization is Some(verification) &&
    assurance.audit_receipt is Some(audit) &&
    assurance.audit_result is Some(audit_result) else {
    return false
  }
  execution.state == GoalExecutionState::GoalExecutionAssured &&
  execution.goal.lifecycle ==
  @control.GoalLifecycle::GoalActive(@control.GoalActiveCondition::GoalRunning) &&
  assurance.stage == GoalAssuranceStage::GoalAudited &&
  assurance.goal_id == execution.goal.id &&
  assurance.repository_id == execution.repository_id &&
  assurance.goal_ref == execution.goal_ref &&
  assurance.goal_contract_digest == execution.goal.contract_digest &&
  seal.goal_id == execution.goal.id &&
  seal.goal_ref == execution.goal_ref.0 &&
  seal.goal_contract_digest == execution.goal.contract_digest &&
  seal.seal_digest == goal_branch_seal_digest(seal) &&
  verification.receipt_set_digest ==
  audit.subject.goal_verification_receipt_set_digest &&
  verification.evidence_manifest_digest ==
  audit.subject.goal_verification_evidence_manifest_digest &&
  audit.subject.goal_branch_seal_id == seal.id &&
  audit.subject.goal_branch_seal_digest == seal.seal_digest &&
  audit.subject.goal_head_oid == seal.head_oid &&
  audit.subject.goal_tree_oid == seal.tree_oid &&
  audit.subject.goal_contract_digest == seal.goal_contract_digest &&
  audit.subject.assurance_policy_revision == seal.assurance_policy_revision &&
  audit.subject.integration_receipt_set_digest ==
  seal.integration_receipt_set_digest &&
  audit.audit_result_digest == audit_result.result_digest &&
  audit.outcome == @control.AuditOutcome::AuditPassed &&
  audit.blocking_findings_count == 0
}

///|
fn goal_publication_record_shape_is_valid(
  record : GoalPublicationRecord,
) -> Bool {
  let key = goal_publication_intent_key(
    record.goal_id,
    record.intent.canonical_repository_id,
    record.intent.remote_name,
    record.intent.remote_head_ref,
    record.intent.expected_prior_remote_oid,
    record.goal_branch_seal,
  )
  let key_text = @storage.digest_text(key)
  if record.goal_id.0 == "" ||
    record.repository_id.0 == "" ||
    record.goal_ref.0 == "" ||
    record.intent.id !=
    BranchPublicationIntentId("publication-intent-" + key_text) ||
    record.intent.idempotency_key != "publication-" + key_text ||
    record.intent.goal_id != record.goal_id ||
    record.intent.sealed_head_oid != record.goal_branch_seal.head_oid ||
    record.intent.goal_branch_seal_id != record.goal_branch_seal.id ||
    record.intent.goal_branch_seal_digest != record.goal_branch_seal.seal_digest ||
    record.goal_branch_seal.goal_id != record.goal_id ||
    record.goal_branch_seal.goal_ref != record.goal_ref.0 ||
    record.goal_branch_seal.goal_contract_digest != record.goal_contract_digest ||
    record.goal_branch_seal.seal_digest !=
    goal_branch_seal_digest(record.goal_branch_seal) ||
    record.intent.canonical_repository_id.0 == "" ||
    !valid_publication_remote_name(record.intent.remote_name) ||
    !valid_publication_ref(record.intent.remote_head_ref) ||
    record.durable_version <= 0 ||
    record.fencing_epoch.0 <= 0L {
    return false
  }
  match (record.intent.state, record.receipt) {
    (BranchPublicationReceipted, Some(receipt)) =>
      receipt.receipt_id ==
      @control.ReceiptId("publication-receipt-" + key_text) &&
      receipt.intent_id == record.intent.id &&
      receipt.idempotency_key == record.intent.idempotency_key &&
      receipt.canonical_repository_id == record.intent.canonical_repository_id &&
      receipt.remote_head_ref == record.intent.remote_head_ref &&
      receipt.published_oid == record.intent.sealed_head_oid &&
      receipt.goal_branch_seal_id == record.intent.goal_branch_seal_id &&
      receipt.goal_branch_seal_digest == record.intent.goal_branch_seal_digest &&
      receipt.observed_at > 0L
    (BranchPublicationReceipted, None) => false
    (_, Some(_)) => false
    _ => true
  }
}

///|
pub fn goal_publication_record_bytes(record : GoalPublicationRecord) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn goal_publication_record_digest(
  record : GoalPublicationRecord,
) -> @control.Digest {
  @storage.artifact_digest(goal_publication_record_bytes(record))
}

///|
pub fn decode_goal_publication_record(
  content : Bytes,
) -> Result[GoalPublicationRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_publication_error("record is not valid JSON"))
  }
  let record : GoalPublicationRecord = @json.from_json(json) catch {
    _ => return Err(goal_publication_error("record has the wrong schema"))
  }
  if goal_publication_record_shape_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_publication_error("record identity is invalid"))
  }
}

///|
pub fn initialize_goal_publication(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  canonical_repository_id : RemoteRepositoryId,
  remote_name : RemoteName,
  remote_head_ref : GitRefName,
  expected_prior_remote_oid : @control.GitOid?,
) -> Result[GoalPublicationRecord, @types.ChoirError] {
  if !goal_publication_assurance_is_current(execution, assurance) {
    return Err(goal_publication_error("Goal assurance is not authorizing"))
  }
  if canonical_repository_id.0 == "" ||
    !valid_publication_remote_name(remote_name) ||
    !valid_publication_ref(remote_head_ref) {
    return Err(goal_publication_error("remote identity is invalid"))
  }
  guard assurance.seal is Some(seal) &&
    assurance.verification_authorization is Some(verification) &&
    assurance.audit_receipt is Some(audit) else {
    return Err(goal_publication_error("assurance evidence is incomplete"))
  }
  if expected_prior_remote_oid == Some(seal.head_oid) {
    return Err(goal_publication_error("expected prior head is already sealed"))
  }
  let key = goal_publication_intent_key(
    execution.goal.id,
    canonical_repository_id,
    remote_name,
    remote_head_ref,
    expected_prior_remote_oid,
    seal,
  )
  let key_text = @storage.digest_text(key)
  let record : GoalPublicationRecord = {
    goal_id: execution.goal.id,
    repository_id: execution.repository_id,
    goal_ref: execution.goal_ref,
    goal_contract_digest: execution.goal.contract_digest,
    assurance_record_digest: goal_assurance_record_digest(assurance),
    goal_branch_seal: seal,
    goal_verification_receipt_set_digest: verification.receipt_set_digest,
    goal_verification_evidence_manifest_digest: verification.evidence_manifest_digest,
    goal_audit_receipt_id: audit.receipt_id,
    goal_audit_result_digest: audit.audit_result_digest,
    intent: {
      id: BranchPublicationIntentId("publication-intent-" + key_text),
      goal_id: execution.goal.id,
      canonical_repository_id,
      remote_name,
      remote_head_ref,
      expected_prior_remote_oid,
      sealed_head_oid: seal.head_oid,
      goal_branch_seal_id: seal.id,
      goal_branch_seal_digest: seal.seal_digest,
      idempotency_key: "publication-" + key_text,
      state: BranchPublicationState::BranchPublicationPlanned,
    },
    receipt: None,
    durable_version: 1,
    fencing_epoch: execution.fencing_epoch,
  }
  if goal_publication_record_shape_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_publication_error("constructed record is invalid"))
  }
}

///|
fn goal_publication_record_is_current(
  record : GoalPublicationRecord,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
) -> Bool {
  goal_publication_assurance_is_current(execution, assurance) &&
  record.goal_id == execution.goal.id &&
  record.repository_id == execution.repository_id &&
  record.goal_ref == execution.goal_ref &&
  record.goal_contract_digest == execution.goal.contract_digest &&
  record.assurance_record_digest == goal_assurance_record_digest(assurance) &&
  assurance.seal == Some(record.goal_branch_seal) &&
  goal_publication_record_shape_is_valid(record)
}

///|
pub fn authorize_goal_publication(
  record : GoalPublicationRecord,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  observed_local_head_oid : @control.GitOid,
  remote_observation : RemoteBranchObservation,
  expected_prior_is_ancestor : Bool,
) -> Result[GoalPublicationRecord, @types.ChoirError] {
  if !(record.intent.state == BranchPublicationState::BranchPublicationPlanned ||
    record.intent.state ==
    BranchPublicationState::BranchPublicationPreflightUncertain) ||
    !goal_publication_record_is_current(record, execution, assurance) ||
    observed_local_head_oid != record.intent.sealed_head_oid {
    return Err(goal_publication_error("publication is not authorizable"))
  }
  let state = match remote_observation {
    RemoteBranchAt(oid) if oid == record.intent.sealed_head_oid =>
      BranchPublicationState::BranchPublicationAuthorized
    RemoteBranchAbsent if record.intent.expected_prior_remote_oid is None =>
      BranchPublicationState::BranchPublicationAuthorized
    RemoteBranchAt(oid) if record.intent.expected_prior_remote_oid == Some(oid) &&
      expected_prior_is_ancestor =>
      BranchPublicationState::BranchPublicationAuthorized
    RemoteBranchObservationUncertain =>
      BranchPublicationState::BranchPublicationPreflightUncertain
    _ => BranchPublicationState::BranchPublicationDrift
  }
  if state == record.intent.state {
    return Ok(record)
  }
  Ok({
    ..record,
    intent: { ..record.intent, state, },
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn record_goal_publication_observation(
  record : GoalPublicationRecord,
  remote_observation : RemoteBranchObservation,
  origin : BranchPublicationReceiptOrigin,
  prior_remote_oid : @control.GitOid?,
  observed_at : Int64,
) -> Result[GoalPublicationRecord, @types.ChoirError] {
  if !(record.intent.state ==
    BranchPublicationState::BranchPublicationAuthorized ||
    record.intent.state ==
    BranchPublicationState::BranchPublicationMutationUncertain) ||
    record.receipt is Some(_) ||
    observed_at <= 0L ||
    !goal_publication_record_shape_is_valid(record) {
    return Err(goal_publication_error("publication observation is not valid"))
  }
  let next = match remote_observation {
    RemoteBranchAt(oid) if oid == record.intent.sealed_head_oid => {
      let key = match record.intent.id {
        BranchPublicationIntentId(value) =>
          if value.has_prefix("publication-intent-") {
            value["publication-intent-".length():].to_owned()
          } else {
            return Err(goal_publication_error("intent identity is invalid"))
          }
      }
      {
        ..record,
        intent: {
          ..record.intent,
          state: BranchPublicationState::BranchPublicationReceipted,
        },
        receipt: Some({
          receipt_id: @control.ReceiptId("publication-receipt-" + key),
          intent_id: record.intent.id,
          idempotency_key: record.intent.idempotency_key,
          canonical_repository_id: record.intent.canonical_repository_id,
          remote_head_ref: record.intent.remote_head_ref,
          prior_remote_oid,
          published_oid: oid,
          goal_branch_seal_id: record.intent.goal_branch_seal_id,
          goal_branch_seal_digest: record.intent.goal_branch_seal_digest,
          origin,
          observed_at,
        }),
        durable_version: record.durable_version + 1,
      }
    }
    RemoteBranchObservationUncertain =>
      if record.intent.state ==
        BranchPublicationState::BranchPublicationMutationUncertain {
        record
      } else {
        {
          ..record,
          intent: {
            ..record.intent,
            state: BranchPublicationState::BranchPublicationMutationUncertain,
          },
          durable_version: record.durable_version + 1,
        }
      }
    _ =>
      {
        ..record,
        intent: {
          ..record.intent,
          state: BranchPublicationState::BranchPublicationDrift,
        },
        durable_version: record.durable_version + 1,
      }
  }
  if goal_publication_record_shape_is_valid(next) {
    Ok(next)
  } else {
    Err(goal_publication_error("publication result is invalid"))
  }
}

///|
pub fn record_goal_publication_cancellation(
  record : GoalPublicationRecord,
  remote_observation : RemoteBranchObservation,
  observed_at : Int64,
) -> Result[GoalPublicationRecord, @types.ChoirError] {
  if observed_at <= 0L || !goal_publication_record_shape_is_valid(record) {
    return Err(goal_publication_error("cancellation observation is invalid"))
  }
  match record.intent.state {
    BranchPublicationPlanned =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: BranchPublicationState::BranchPublicationAbandonedByCancellation,
        },
        durable_version: record.durable_version + 1,
      })
    BranchPublicationPreflightUncertain =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: BranchPublicationState::BranchPublicationAbandonedByCancellation,
        },
        durable_version: record.durable_version + 1,
      })
    BranchPublicationAuthorized | BranchPublicationMutationUncertain =>
      match remote_observation {
        RemoteBranchAt(oid) if oid == record.intent.sealed_head_oid =>
          record_goal_publication_observation(
            record,
            remote_observation,
            BranchPublicationReceiptOrigin::BranchPublicationAdopted,
            Some(oid),
            observed_at,
          )
        RemoteBranchAbsent =>
          Ok({
            ..record,
            intent: {
              ..record.intent,
              state: BranchPublicationState::BranchPublicationAbandonedByCancellation,
            },
            durable_version: record.durable_version + 1,
          })
        RemoteBranchAt(_) =>
          Ok({
            ..record,
            intent: {
              ..record.intent,
              state: BranchPublicationState::BranchPublicationDrift,
            },
            durable_version: record.durable_version + 1,
          })
        RemoteBranchObservationUncertain =>
          if record.intent.state ==
            BranchPublicationState::BranchPublicationMutationUncertain {
            Ok(record)
          } else {
            Ok({
              ..record,
              intent: {
                ..record.intent,
                state: BranchPublicationState::BranchPublicationMutationUncertain,
              },
              durable_version: record.durable_version + 1,
            })
          }
      }
    BranchPublicationReceipted
    | BranchPublicationDrift
    | BranchPublicationAbandonedByCancellation => Ok(record)
  }
}

///|
pub fn goal_publication_cancellation_disposition_is_known(
  record : GoalPublicationRecord,
) -> Bool {
  match record.intent.state {
    BranchPublicationReceipted
    | BranchPublicationDrift
    | BranchPublicationMutationUncertain
    | BranchPublicationAbandonedByCancellation => true
    BranchPublicationPlanned
    | BranchPublicationPreflightUncertain
    | BranchPublicationAuthorized => false
  }
}
