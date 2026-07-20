///|
pub(all) struct PullRequestIntentId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct RemotePullRequestId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct PullRequestNumber(Int) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct PullRequestUrl(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct PullRequestIdentityMarker(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct PullRequestDocument {
  title : String
  body : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestProvider {
  GitHubPullRequestProvider
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestIntentState {
  PullRequestPlanned
  PullRequestAuthorized
  PullRequestCreateMayHaveBeenIssued
  PullRequestReceipted
  PullRequestNeedsInput(PullRequestNeedsInputReason)
  PullRequestRemoteCreateUncertain
  PullRequestAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestNeedsInputReason {
  PullRequestPossibleExisting
  PullRequestAmbiguousIdentity
  PullRequestRemoteClosed
  PullRequestRemoteDrift
  PullRequestIdentityMarkerMissing
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum RemotePullRequestState {
  RemotePullRequestOpen
  RemotePullRequestClosed
  RemotePullRequestMerged
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestMarkerState {
  PullRequestMarkerExact
  PullRequestMarkerMissing
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestReceiptOrigin {
  PullRequestCreated
  PullRequestAdopted
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RemotePullRequestSnapshot {
  remote_id : RemotePullRequestId
  number : PullRequestNumber
  url : PullRequestUrl
  provider_repository_id : RemoteRepositoryId
  head_repository_id : RemoteRepositoryId
  head_ref : GitRefName
  base_repository_id : RemoteRepositoryId
  base_ref : GitRefName
  observed_head_oid : @control.GitOid
  state : RemotePullRequestState
  marker_state : PullRequestMarkerState
  title_digest : @control.Digest
  body_digest : @control.Digest
  goal_contract_link_present : Bool
  evidence_manifest_link_present : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestLookupObservation {
  PullRequestNoMatch
  PullRequestStoredIdMatch(RemotePullRequestSnapshot)
  PullRequestUniqueMarkerMatch(RemotePullRequestSnapshot)
  PullRequestMultipleMarkerMatches
  PullRequestPossibleExistingMatch(RemotePullRequestSnapshot)
  PullRequestLookupUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PullRequestIntent {
  id : PullRequestIntentId
  goal_id : @control.GoalId
  provider : PullRequestProvider
  canonical_repository_id : RemoteRepositoryId
  head_repository_id : RemoteRepositoryId
  head_ref : GitRefName
  base_repository_id : RemoteRepositoryId
  base_ref : GitRefName
  expected_head_oid : @control.GitOid
  goal_contract_digest : @control.Digest
  goal_branch_seal_id : @control.GoalBranchSealId
  goal_branch_seal_digest : @control.Digest
  combined_audit_receipt_id : @control.ReceiptId
  evidence_manifest_digest : @control.Digest
  title_and_body_artifact_digest : @control.Digest
  identity_marker : PullRequestIdentityMarker
  idempotency_key : String
  canonical_remote_pull_request_id : RemotePullRequestId?
  state : PullRequestIntentState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PullRequestReceipt {
  receipt_id : @control.ReceiptId
  intent_id : PullRequestIntentId
  idempotency_key : String
  provider_repository_id : RemoteRepositoryId
  remote_pull_request_id : RemotePullRequestId
  number : PullRequestNumber
  url : PullRequestUrl
  head_repository_id : RemoteRepositoryId
  head_ref : GitRefName
  base_repository_id : RemoteRepositoryId
  base_ref : GitRefName
  expected_head_oid : @control.GitOid
  observed_head_oid : @control.GitOid
  goal_branch_seal_id : @control.GoalBranchSealId
  goal_branch_seal_digest : @control.Digest
  origin : PullRequestReceiptOrigin
  observed_remote_state : RemotePullRequestState
  observed_marker_state : PullRequestMarkerState
  observed_title_digest : @control.Digest
  observed_body_digest : @control.Digest
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPullRequestRecord {
  goal_id : @control.GoalId
  repository_id : RepositoryId
  goal_contract_digest : @control.Digest
  assurance_record_digest : @control.Digest
  publication_record_digest : @control.Digest
  intent : PullRequestIntent
  receipt : PullRequestReceipt?
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalPullRequestTickOutcome {
  GoalPullRequestPending
  GoalPullRequestComplete
  GoalPullRequestNeedsUserInput
  GoalPullRequestRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_pull_request_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal pull request: " + detail)
}

///|
fn goal_pull_request_digest(domain : String, value : Json) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + value.stringify(indent=0)),
  )
}

///|
fn pull_request_ref_is_valid(name : GitRefName) -> Bool {
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
fn pull_request_intent_key(
  goal_id : @control.GoalId,
  canonical_repository_id : RemoteRepositoryId,
  head_repository_id : RemoteRepositoryId,
  head_ref : GitRefName,
  base_repository_id : RemoteRepositoryId,
  base_ref : GitRefName,
  expected_head_oid : @control.GitOid,
) -> @control.Digest {
  goal_pull_request_digest(
    "choir.final-pull-request-intent.v1",
    [
      goal_id.to_json(),
      canonical_repository_id.to_json(),
      head_repository_id.to_json(),
      head_ref.to_json(),
      base_repository_id.to_json(),
      base_ref.to_json(),
      expected_head_oid.to_json(),
    ].to_json(),
  )
}

///|
fn pull_request_document_is_valid(document : PullRequestDocument) -> Bool {
  let title = document.title.trim().to_owned()
  title != "" &&
  title.length() <= 256 &&
  !title.contains("\u{00}") &&
  !title.contains("\n") &&
  !title.contains("\r") &&
  document.body != "" &&
  document.body.length() <= 1024 * 1024 &&
  !document.body.contains("\u{00}")
}

///|
pub fn pull_request_document_bytes(document : PullRequestDocument) -> Bytes {
  @utf8.encode(document.to_json().stringify(indent=0))
}

///|
pub fn pull_request_document_digest(
  document : PullRequestDocument,
) -> @control.Digest {
  @storage.artifact_digest(pull_request_document_bytes(document))
}

///|
pub fn decode_pull_request_document(
  content : Bytes,
) -> Result[PullRequestDocument, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_pull_request_error("document is not valid JSON"))
  }
  let document : PullRequestDocument = @json.from_json(json) catch {
    _ => return Err(goal_pull_request_error("document has the wrong schema"))
  }
  if pull_request_document_is_valid(document) {
    Ok(document)
  } else {
    Err(goal_pull_request_error("document is invalid"))
  }
}

///|
pub fn goal_pull_request_identity_marker(
  execution : GoalExecutionRecord,
  publication : GoalPublicationRecord,
  base_repository_id : RemoteRepositoryId,
) -> Result[PullRequestIdentityMarker, @types.ChoirError] {
  guard publication.receipt is Some(receipt) else {
    return Err(goal_pull_request_error("publication receipt is absent"))
  }
  if execution.goal.id != publication.goal_id ||
    execution.repository_id != publication.repository_id ||
    execution.integration_target_ref.0 == "" ||
    base_repository_id.0 == "" ||
    receipt.published_oid != publication.intent.sealed_head_oid {
    return Err(goal_pull_request_error("marker prerequisites are inconsistent"))
  }
  let key = pull_request_intent_key(
    execution.goal.id,
    publication.intent.canonical_repository_id,
    publication.intent.canonical_repository_id,
    publication.intent.remote_head_ref,
    base_repository_id,
    execution.integration_target_ref,
    publication.intent.sealed_head_oid,
  )
  Ok(
    PullRequestIdentityMarker(
      "<!-- choir-final-pr:" + @storage.digest_text(key) + " -->",
    ),
  )
}

///|
fn pull_request_snapshot_shape_is_valid(
  snapshot : RemotePullRequestSnapshot,
) -> Bool {
  snapshot.remote_id.0 != "" &&
  snapshot.number.0 > 0 &&
  snapshot.url.0 != "" &&
  !snapshot.url.0.contains("\u{00}") &&
  snapshot.provider_repository_id.0 != "" &&
  snapshot.head_repository_id.0 != "" &&
  snapshot.base_repository_id.0 != "" &&
  pull_request_ref_is_valid(snapshot.head_ref) &&
  pull_request_ref_is_valid(snapshot.base_ref) &&
  snapshot.observed_head_oid.0 != "" &&
  @storage.validate_digest(snapshot.title_digest) is Ok(_) &&
  @storage.validate_digest(snapshot.body_digest) is Ok(_)
}

///|
fn pull_request_receipt_matches_snapshot(
  intent : PullRequestIntent,
  snapshot : RemotePullRequestSnapshot,
) -> Bool {
  pull_request_snapshot_shape_is_valid(snapshot) &&
  snapshot.provider_repository_id == intent.canonical_repository_id &&
  snapshot.head_repository_id == intent.head_repository_id &&
  snapshot.head_ref == intent.head_ref &&
  snapshot.base_repository_id == intent.base_repository_id &&
  snapshot.base_ref == intent.base_ref &&
  snapshot.observed_head_oid == intent.expected_head_oid &&
  snapshot.marker_state == PullRequestMarkerState::PullRequestMarkerExact
}

///|
fn goal_pull_request_record_shape_is_valid(
  record : GoalPullRequestRecord,
) -> Bool {
  let key = pull_request_intent_key(
    record.goal_id,
    record.intent.canonical_repository_id,
    record.intent.head_repository_id,
    record.intent.head_ref,
    record.intent.base_repository_id,
    record.intent.base_ref,
    record.intent.expected_head_oid,
  )
  let key_text = @storage.digest_text(key)
  let marker = "<!-- choir-final-pr:" + key_text + " -->"
  if record.goal_id.0 == "" ||
    record.repository_id.0 == "" ||
    record.intent.id != PullRequestIntentId("pr-intent-" + key_text) ||
    record.intent.goal_id != record.goal_id ||
    record.intent.idempotency_key != "pr-" + key_text ||
    record.intent.identity_marker != PullRequestIdentityMarker(marker) ||
    record.intent.canonical_repository_id.0 == "" ||
    record.intent.head_repository_id.0 == "" ||
    record.intent.base_repository_id.0 == "" ||
    !pull_request_ref_is_valid(record.intent.head_ref) ||
    !pull_request_ref_is_valid(record.intent.base_ref) ||
    record.intent.expected_head_oid.0 == "" ||
    record.intent.goal_contract_digest != record.goal_contract_digest ||
    @storage.validate_digest(record.intent.goal_branch_seal_digest) is Err(_) ||
    @storage.validate_digest(record.intent.evidence_manifest_digest) is Err(_) ||
    @storage.validate_digest(record.intent.title_and_body_artifact_digest)
    is Err(_) ||
    record.durable_version <= 0 ||
    record.fencing_epoch.0 <= 0L {
    return false
  }
  match (record.intent.state, record.receipt) {
    (
      PullRequestIntentState::PullRequestReceipted
      | PullRequestIntentState::PullRequestNeedsInput(
        PullRequestNeedsInputReason::PullRequestRemoteClosed
      ),
      Some(receipt),
    ) =>
      receipt.receipt_id == @control.ReceiptId("pr-receipt-" + key_text) &&
      receipt.intent_id == record.intent.id &&
      receipt.idempotency_key == record.intent.idempotency_key &&
      receipt.provider_repository_id == record.intent.canonical_repository_id &&
      receipt.remote_pull_request_id.0 != "" &&
      receipt.number.0 > 0 &&
      receipt.url.0 != "" &&
      receipt.head_repository_id == record.intent.head_repository_id &&
      receipt.head_ref == record.intent.head_ref &&
      receipt.base_repository_id == record.intent.base_repository_id &&
      receipt.base_ref == record.intent.base_ref &&
      receipt.expected_head_oid == record.intent.expected_head_oid &&
      receipt.observed_head_oid == record.intent.expected_head_oid &&
      receipt.goal_branch_seal_id == record.intent.goal_branch_seal_id &&
      receipt.goal_branch_seal_digest == record.intent.goal_branch_seal_digest &&
      receipt.observed_marker_state ==
      PullRequestMarkerState::PullRequestMarkerExact &&
      receipt.observed_at > 0L &&
      record.intent.canonical_remote_pull_request_id ==
      Some(receipt.remote_pull_request_id)
    (PullRequestIntentState::PullRequestReceipted, None) => false
    (_, Some(_)) => false
    _ => true
  }
}

///|
pub fn goal_pull_request_record_bytes(record : GoalPullRequestRecord) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn goal_pull_request_record_digest(
  record : GoalPullRequestRecord,
) -> @control.Digest {
  @storage.artifact_digest(goal_pull_request_record_bytes(record))
}

///|
pub fn decode_goal_pull_request_record(
  content : Bytes,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_pull_request_error("record is not valid JSON"))
  }
  let record : GoalPullRequestRecord = @json.from_json(json) catch {
    _ => return Err(goal_pull_request_error("record has the wrong schema"))
  }
  if goal_pull_request_record_shape_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_pull_request_error("record identity is invalid"))
  }
}

///|
fn pull_request_prerequisites_are_current(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
) -> Bool {
  guard assurance.seal is Some(seal) &&
    assurance.verification_authorization is Some(verification) &&
    assurance.audit_receipt is Some(audit) &&
    publication.receipt is Some(publication_receipt) else {
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
  publication.goal_id == execution.goal.id &&
  publication.repository_id == execution.repository_id &&
  publication.goal_ref == execution.goal_ref &&
  publication.goal_contract_digest == execution.goal.contract_digest &&
  publication.assurance_record_digest == goal_assurance_record_digest(assurance) &&
  publication.goal_branch_seal == seal &&
  publication.goal_verification_receipt_set_digest ==
  verification.receipt_set_digest &&
  publication.goal_verification_evidence_manifest_digest ==
  verification.evidence_manifest_digest &&
  publication.goal_audit_receipt_id == audit.receipt_id &&
  publication.goal_audit_result_digest == audit.audit_result_digest &&
  publication.intent.state == BranchPublicationState::BranchPublicationReceipted &&
  publication_receipt.published_oid == seal.head_oid &&
  publication_receipt.goal_branch_seal_id == seal.id &&
  publication_receipt.goal_branch_seal_digest == seal.seal_digest
}

///|
pub fn initialize_goal_pull_request(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  provider : PullRequestProvider,
  base_repository_id : RemoteRepositoryId,
  document : PullRequestDocument,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if !pull_request_prerequisites_are_current(execution, assurance, publication) ||
    base_repository_id.0 == "" ||
    !pull_request_document_is_valid(document) {
    return Err(
      goal_pull_request_error("final PR prerequisites are not current"),
    )
  }
  guard assurance.seal is Some(seal) &&
    assurance.audit_receipt is Some(audit) &&
    assurance.verification_authorization is Some(verification) else {
    return Err(goal_pull_request_error("assurance evidence is incomplete"))
  }
  let key = pull_request_intent_key(
    execution.goal.id,
    publication.intent.canonical_repository_id,
    publication.intent.canonical_repository_id,
    publication.intent.remote_head_ref,
    base_repository_id,
    execution.integration_target_ref,
    seal.head_oid,
  )
  let key_text = @storage.digest_text(key)
  let marker = PullRequestIdentityMarker(
    "<!-- choir-final-pr:" + key_text + " -->",
  )
  if !document.body.contains(marker.0) {
    return Err(goal_pull_request_error("document lacks its identity marker"))
  }
  let title_and_body_artifact_digest = pull_request_document_digest(document)
  let record : GoalPullRequestRecord = {
    goal_id: execution.goal.id,
    repository_id: execution.repository_id,
    goal_contract_digest: execution.goal.contract_digest,
    assurance_record_digest: goal_assurance_record_digest(assurance),
    publication_record_digest: goal_publication_record_digest(publication),
    intent: {
      id: PullRequestIntentId("pr-intent-" + key_text),
      goal_id: execution.goal.id,
      provider,
      canonical_repository_id: publication.intent.canonical_repository_id,
      head_repository_id: publication.intent.canonical_repository_id,
      head_ref: publication.intent.remote_head_ref,
      base_repository_id,
      base_ref: execution.integration_target_ref,
      expected_head_oid: seal.head_oid,
      goal_contract_digest: execution.goal.contract_digest,
      goal_branch_seal_id: seal.id,
      goal_branch_seal_digest: seal.seal_digest,
      combined_audit_receipt_id: audit.receipt_id,
      evidence_manifest_digest: verification.evidence_manifest_digest,
      title_and_body_artifact_digest,
      identity_marker: marker,
      idempotency_key: "pr-" + key_text,
      canonical_remote_pull_request_id: None,
      state: PullRequestIntentState::PullRequestPlanned,
    },
    receipt: None,
    durable_version: 1,
    fencing_epoch: execution.fencing_epoch,
  }
  if goal_pull_request_record_shape_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_pull_request_error("constructed record is invalid"))
  }
}

///|
fn goal_pull_request_record_is_current(
  record : GoalPullRequestRecord,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
) -> Bool {
  pull_request_prerequisites_are_current(execution, assurance, publication) &&
  record.goal_id == execution.goal.id &&
  record.repository_id == execution.repository_id &&
  record.goal_contract_digest == execution.goal.contract_digest &&
  record.assurance_record_digest == goal_assurance_record_digest(assurance) &&
  record.publication_record_digest ==
  goal_publication_record_digest(publication) &&
  goal_pull_request_record_shape_is_valid(record)
}

///|
fn receipt_goal_pull_request(
  record : GoalPullRequestRecord,
  snapshot : RemotePullRequestSnapshot,
  origin : PullRequestReceiptOrigin,
  observed_at : Int64,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if !pull_request_snapshot_shape_is_valid(snapshot) || observed_at <= 0L {
    return Err(goal_pull_request_error("remote PR observation is invalid"))
  }
  if snapshot.marker_state != PullRequestMarkerState::PullRequestMarkerExact {
    return Ok({
      ..record,
      intent: {
        ..record.intent,
        canonical_remote_pull_request_id: Some(snapshot.remote_id),
        state: PullRequestIntentState::PullRequestNeedsInput(
          PullRequestNeedsInputReason::PullRequestIdentityMarkerMissing,
        ),
      },
      durable_version: record.durable_version + 1,
    })
  }
  if !pull_request_receipt_matches_snapshot(record.intent, snapshot) {
    return Ok({
      ..record,
      intent: {
        ..record.intent,
        canonical_remote_pull_request_id: Some(snapshot.remote_id),
        state: PullRequestIntentState::PullRequestNeedsInput(
          PullRequestNeedsInputReason::PullRequestRemoteDrift,
        ),
      },
      durable_version: record.durable_version + 1,
    })
  }
  let key = match record.intent.id {
    PullRequestIntentId(value) =>
      if value.has_prefix("pr-intent-") {
        value["pr-intent-".length():].to_owned()
      } else {
        return Err(goal_pull_request_error("intent identity is invalid"))
      }
  }
  let receipt : PullRequestReceipt = {
    receipt_id: @control.ReceiptId("pr-receipt-" + key),
    intent_id: record.intent.id,
    idempotency_key: record.intent.idempotency_key,
    provider_repository_id: snapshot.provider_repository_id,
    remote_pull_request_id: snapshot.remote_id,
    number: snapshot.number,
    url: snapshot.url,
    head_repository_id: snapshot.head_repository_id,
    head_ref: snapshot.head_ref,
    base_repository_id: snapshot.base_repository_id,
    base_ref: snapshot.base_ref,
    expected_head_oid: record.intent.expected_head_oid,
    observed_head_oid: snapshot.observed_head_oid,
    goal_branch_seal_id: record.intent.goal_branch_seal_id,
    goal_branch_seal_digest: record.intent.goal_branch_seal_digest,
    origin,
    observed_remote_state: snapshot.state,
    observed_marker_state: snapshot.marker_state,
    observed_title_digest: snapshot.title_digest,
    observed_body_digest: snapshot.body_digest,
    observed_at,
  }
  let state = match snapshot.state {
    RemotePullRequestState::RemotePullRequestClosed =>
      PullRequestIntentState::PullRequestNeedsInput(
        PullRequestNeedsInputReason::PullRequestRemoteClosed,
      )
    _ => PullRequestIntentState::PullRequestReceipted
  }
  let next = {
    ..record,
    intent: {
      ..record.intent,
      canonical_remote_pull_request_id: Some(snapshot.remote_id),
      state,
    },
    receipt: Some(receipt),
    durable_version: record.durable_version + 1,
  }
  if goal_pull_request_record_shape_is_valid(next) {
    Ok(next)
  } else {
    Err(goal_pull_request_error("receipt result is invalid"))
  }
}

///|
pub fn authorize_goal_pull_request(
  record : GoalPullRequestRecord,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  observed_remote_head_oid : @control.GitOid,
  lookup : PullRequestLookupObservation,
  observed_at : Int64,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.state != PullRequestIntentState::PullRequestPlanned ||
    !goal_pull_request_record_is_current(
      record, execution, assurance, publication,
    ) ||
    observed_remote_head_oid != record.intent.expected_head_oid ||
    observed_at <= 0L {
    return Err(goal_pull_request_error("final PR is not authorizable"))
  }
  match lookup {
    PullRequestLookupObservation::PullRequestNoMatch =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestAuthorized,
        },
        durable_version: record.durable_version + 1,
      })
    PullRequestLookupObservation::PullRequestStoredIdMatch(snapshot)
    | PullRequestLookupObservation::PullRequestUniqueMarkerMatch(snapshot) =>
      receipt_goal_pull_request(
        record,
        snapshot,
        PullRequestReceiptOrigin::PullRequestAdopted,
        observed_at,
      )
    PullRequestLookupObservation::PullRequestMultipleMarkerMatches =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestNeedsInput(
            PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
          ),
        },
        durable_version: record.durable_version + 1,
      })
    PullRequestLookupObservation::PullRequestPossibleExistingMatch(_) =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestNeedsInput(
            PullRequestNeedsInputReason::PullRequestPossibleExisting,
          ),
        },
        durable_version: record.durable_version + 1,
      })
    PullRequestLookupObservation::PullRequestLookupUncertain =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestRemoteCreateUncertain,
        },
        durable_version: record.durable_version + 1,
      })
  }
}

///|
pub fn mark_goal_pull_request_create_may_have_been_issued(
  record : GoalPullRequestRecord,
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.state != PullRequestIntentState::PullRequestAuthorized ||
    !goal_pull_request_record_is_current(
      record, execution, assurance, publication,
    ) {
    return Err(goal_pull_request_error("create dispatch is not authorized"))
  }
  Ok({
    ..record,
    intent: {
      ..record.intent,
      state: PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
    },
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn reconcile_goal_pull_request_after_create(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
  observed_at : Int64,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if !(record.intent.state ==
    PullRequestIntentState::PullRequestCreateMayHaveBeenIssued ||
    record.intent.state ==
    PullRequestIntentState::PullRequestRemoteCreateUncertain) ||
    record.receipt is Some(_) ||
    observed_at <= 0L ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("create reconciliation is invalid"))
  }
  match lookup {
    PullRequestLookupObservation::PullRequestStoredIdMatch(snapshot)
    | PullRequestLookupObservation::PullRequestUniqueMarkerMatch(snapshot) =>
      receipt_goal_pull_request(
        record,
        snapshot,
        PullRequestReceiptOrigin::PullRequestCreated,
        observed_at,
      )
    PullRequestLookupObservation::PullRequestMultipleMarkerMatches =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestNeedsInput(
            PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
          ),
        },
        durable_version: record.durable_version + 1,
      })
    PullRequestLookupObservation::PullRequestPossibleExistingMatch(_) =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestNeedsInput(
            PullRequestNeedsInputReason::PullRequestPossibleExisting,
          ),
        },
        durable_version: record.durable_version + 1,
      })
    PullRequestLookupObservation::PullRequestNoMatch
    | PullRequestLookupObservation::PullRequestLookupUncertain =>
      if record.intent.state ==
        PullRequestIntentState::PullRequestRemoteCreateUncertain {
        Ok(record)
      } else {
        Ok({
          ..record,
          intent: {
            ..record.intent,
            state: PullRequestIntentState::PullRequestRemoteCreateUncertain,
          },
          durable_version: record.durable_version + 1,
        })
      }
  }
}

///|
pub fn record_goal_pull_request_cancellation(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
  observed_at : Int64,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if observed_at <= 0L || !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("cancellation observation is invalid"))
  }
  match record.intent.state {
    PullRequestPlanned | PullRequestAuthorized =>
      Ok({
        ..record,
        intent: {
          ..record.intent,
          state: PullRequestIntentState::PullRequestAbandonedByCancellation,
        },
        durable_version: record.durable_version + 1,
      })
    PullRequestCreateMayHaveBeenIssued | PullRequestRemoteCreateUncertain =>
      reconcile_goal_pull_request_after_create(record, lookup, observed_at)
    PullRequestReceipted
    | PullRequestNeedsInput(_)
    | PullRequestAbandonedByCancellation => Ok(record)
  }
}

///|
pub fn goal_pull_request_cancellation_disposition_is_known(
  record : GoalPullRequestRecord,
) -> Bool {
  match record.intent.state {
    PullRequestReceipted
    | PullRequestNeedsInput(_)
    | PullRequestRemoteCreateUncertain
    | PullRequestAbandonedByCancellation => true
    PullRequestPlanned
    | PullRequestAuthorized
    | PullRequestCreateMayHaveBeenIssued => false
  }
}
