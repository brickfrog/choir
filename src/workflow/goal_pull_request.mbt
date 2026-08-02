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
  draft : Bool
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
pub(all) enum PullRequestMergeState {
  PullRequestMergeNotRequested
  PullRequestMergePlanned
  PullRequestMergeAuthorized
  PullRequestMergeMayHaveBeenIssued
  PullRequestMergeEnabled
  PullRequestMergeRejected(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Cancellation of a Goal whose exact pull request already exists is itself a
/// remote effect: GitHub keeps authority to merge that pull request until
/// automatic merge is disabled and the pull request is closed. This state
/// machine is what makes that neutralization durable, idempotent, and
/// exact-identity bound, so source Beads are never released while the forge
/// can still merge on the Goal's behalf.
pub(all) enum PullRequestCancellationState {
  PullRequestCancellationNotRequested
  PullRequestCancellationPlanned
  PullRequestNeutralizeAuthorized
  PullRequestNeutralizeMayHaveBeenIssued
  PullRequestNeutralized
  PullRequestSupersededByMerge
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestMergeDispatchObservation {
  PullRequestMergeDispatchAccepted
  PullRequestMergeDispatchRejected(@control.Digest)
  PullRequestMergeDispatchUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestNeedsInputReason {
  PullRequestPossibleExisting
  PullRequestAmbiguousIdentity
  PullRequestRemoteClosed
  PullRequestRemoteDrift
  PullRequestIdentityMarkerMissing
  PullRequestDraftUnderAutoMerge
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
  /// Presentation state, never a delivery-policy override: a draft pull
  /// request is not offered for review and cannot be merged.
  draft : Bool
  auto_merge_enabled : Bool
  marker_state : PullRequestMarkerState
  title_digest : @control.Digest
  body_digest : @control.Digest
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
  document : PullRequestDocument
  identity_marker : PullRequestIdentityMarker
  idempotency_key : String
  canonical_remote_pull_request_id : RemotePullRequestId?
  state : PullRequestIntentState
  delivery_policy : @types.PullRequestDeliveryPolicy
  merge_state : PullRequestMergeState
  cancellation_state : PullRequestCancellationState
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
  GoalPullRequestDeliveryFailed(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalPullRequestFaultPoint {
  PullRequestAfterIntentBeforeLookup
  PullRequestAfterEmptyLookupBeforeAuthorized
  PullRequestAfterAuthorizedBeforeCreateMayHaveBeenIssued
  PullRequestAfterCreateMayHaveBeenIssuedBeforeDispatch
  PullRequestAfterRemoteCreateBeforeResponse
  PullRequestAfterResponseBeforeReceipt
  PullRequestDuringReceiptTransaction
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
fn pull_request_merge_failure_digest(
  domain : String,
  value : Json,
) -> @control.Digest {
  goal_pull_request_digest("choir.pull-request-merge." + domain + ".v1", value)
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
pub fn pull_request_document_is_valid(document : PullRequestDocument) -> Bool {
  let title = document.title.trim().to_owned()
  title != "" &&
  @control.validate_semantic_commit_title(@control.SemanticCommitTitle(title))
  is Ok(_) &&
  !title.contains("\u{00}") &&
  !title.contains("\n") &&
  !title.contains("\r") &&
  document.body.trim() != "" &&
  document.body.length() <= 1024 * 1024 &&
  !document.body.contains("\u{00}")
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
  snapshot.marker_state == PullRequestMarkerState::PullRequestMarkerExact &&
  snapshot.title_digest ==
  @storage.artifact_digest(@utf8.encode(intent.document.title)) &&
  snapshot.body_digest ==
  @storage.artifact_digest(@utf8.encode(intent.document.body))
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
  let merge_shape_valid = match
    (record.intent.delivery_policy.mode, record.intent.merge_state) {
    (
      @types.PullRequestDeliveryMode::PullRequestReviewOnly,
      PullRequestMergeState::PullRequestMergeNotRequested,
    ) => true
    (
      @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      PullRequestMergeState::PullRequestMergePlanned
      | PullRequestMergeState::PullRequestMergeAuthorized
      | PullRequestMergeState::PullRequestMergeMayHaveBeenIssued
      | PullRequestMergeState::PullRequestMergeEnabled,
    ) => true
    (
      @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      PullRequestMergeState::PullRequestMergeRejected(digest),
    ) => @storage.validate_digest(digest) is Ok(_)
    _ => false
  }
  // Neutralization only ever targets the exact receipted pull request, so any
  // cancellation state past "not requested" must carry that receipt.
  let cancellation_shape_valid = match record.intent.cancellation_state {
    PullRequestCancellationState::PullRequestCancellationNotRequested => true
    _ => record.receipt is Some(_)
  }
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
    !pull_request_document_is_valid(record.intent.document) ||
    !record.intent.document.body.contains(marker) ||
    !merge_shape_valid ||
    !cancellation_shape_valid ||
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
      receipt.observed_title_digest ==
      @storage.artifact_digest(@utf8.encode(record.intent.document.title)) &&
      receipt.observed_body_digest ==
      @storage.artifact_digest(@utf8.encode(record.intent.document.body)) &&
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
  delivery_policy? : @types.PullRequestDeliveryPolicy = {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  },
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if execution.completion_mode != GoalCompletionMode::GoalPublishable ||
    !pull_request_prerequisites_are_current(execution, assurance, publication) ||
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
  let draft_rejects_automatic_merge = document.draft &&
    delivery_policy.mode == @types.PullRequestDeliveryMode::PullRequestAutoMerge
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
      document,
      identity_marker: marker,
      idempotency_key: "pr-" + key_text,
      canonical_remote_pull_request_id: None,
      // A draft cannot merge, so an automatic-merge Goal that asked for one is
      // rejected here with retained evidence rather than silently downgraded
      // to review-only, which would have closed source Beads on an open draft.
      state: if draft_rejects_automatic_merge {
        PullRequestIntentState::PullRequestNeedsInput(
          PullRequestNeedsInputReason::PullRequestDraftUnderAutoMerge,
        )
      } else {
        PullRequestIntentState::PullRequestPlanned
      },
      delivery_policy,
      merge_state: match delivery_policy.mode {
        @types.PullRequestDeliveryMode::PullRequestReviewOnly =>
          PullRequestMergeState::PullRequestMergeNotRequested
        @types.PullRequestDeliveryMode::PullRequestAutoMerge =>
          if draft_rejects_automatic_merge {
            PullRequestMergeState::PullRequestMergeRejected(
              pull_request_merge_failure_digest(
                "draft-under-auto-merge",
                document.to_json(),
              ),
            )
          } else {
            PullRequestMergeState::PullRequestMergePlanned
          }
      },
      cancellation_state: PullRequestCancellationState::PullRequestCancellationNotRequested,
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
fn record_pull_request_needs_input_or_delivery_failure(
  record : GoalPullRequestRecord,
  reason : PullRequestNeedsInputReason,
  evidence : Json,
) -> GoalPullRequestRecord {
  {
    ..record,
    intent: {
      ..record.intent,
      state: PullRequestIntentState::PullRequestNeedsInput(reason),
      merge_state: if record.intent.delivery_policy.mode ==
        @types.PullRequestDeliveryMode::PullRequestAutoMerge {
        PullRequestMergeState::PullRequestMergeRejected(
          pull_request_merge_failure_digest("reconciliation", evidence),
        )
      } else {
        record.intent.merge_state
      },
    },
    durable_version: record.durable_version + 1,
  }
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
    return Ok(
      record_pull_request_needs_input_or_delivery_failure(
        record,
        PullRequestNeedsInputReason::PullRequestIdentityMarkerMissing,
        snapshot.to_json(),
      ),
    )
  }
  if !pull_request_receipt_matches_snapshot(record.intent, snapshot) {
    return Ok(
      record_pull_request_needs_input_or_delivery_failure(
        record,
        PullRequestNeedsInputReason::PullRequestRemoteDrift,
        snapshot.to_json(),
      ),
    )
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
  let merge_state = if snapshot.state ==
    RemotePullRequestState::RemotePullRequestClosed &&
    record.intent.delivery_policy.mode ==
    @types.PullRequestDeliveryMode::PullRequestAutoMerge {
    PullRequestMergeState::PullRequestMergeRejected(
      pull_request_merge_failure_digest("remote-closed", snapshot.to_json()),
    )
  } else {
    record.intent.merge_state
  }
  let next = {
    ..record,
    intent: {
      ..record.intent,
      canonical_remote_pull_request_id: Some(snapshot.remote_id),
      state,
      merge_state,
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
      Ok(
        record_pull_request_needs_input_or_delivery_failure(
          record,
          PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
          lookup.to_json(),
        ),
      )
    PullRequestLookupObservation::PullRequestPossibleExistingMatch(_) =>
      Ok(
        record_pull_request_needs_input_or_delivery_failure(
          record,
          PullRequestNeedsInputReason::PullRequestPossibleExisting,
          lookup.to_json(),
        ),
      )
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
      Ok(
        record_pull_request_needs_input_or_delivery_failure(
          record,
          PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
          lookup.to_json(),
        ),
      )
    PullRequestLookupObservation::PullRequestPossibleExistingMatch(_) =>
      Ok(
        record_pull_request_needs_input_or_delivery_failure(
          record,
          PullRequestNeedsInputReason::PullRequestPossibleExisting,
          lookup.to_json(),
        ),
      )
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
fn exact_pull_request_snapshot(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
) -> RemotePullRequestSnapshot? {
  let snapshot = match lookup {
    PullRequestStoredIdMatch(value) | PullRequestUniqueMarkerMatch(value) =>
      value
    _ => return None
  }
  guard record.receipt is Some(receipt) &&
    snapshot.remote_id == receipt.remote_pull_request_id &&
    pull_request_receipt_matches_snapshot(record.intent, snapshot) else {
    return None
  }
  Some(snapshot)
}

///|
pub fn authorize_goal_pull_request_merge(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.state != PullRequestIntentState::PullRequestReceipted ||
    record.intent.delivery_policy.mode !=
    @types.PullRequestDeliveryMode::PullRequestAutoMerge ||
    record.intent.merge_state != PullRequestMergeState::PullRequestMergePlanned ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("automatic merge is not authorizable"))
  }
  let next_state = match exact_pull_request_snapshot(record, lookup) {
    Some(snapshot) =>
      match snapshot.state {
        RemotePullRequestState::RemotePullRequestMerged =>
          PullRequestMergeState::PullRequestMergeEnabled
        RemotePullRequestState::RemotePullRequestOpen =>
          if snapshot.auto_merge_enabled {
            PullRequestMergeState::PullRequestMergeEnabled
          } else {
            PullRequestMergeState::PullRequestMergeAuthorized
          }
        RemotePullRequestState::RemotePullRequestClosed =>
          PullRequestMergeState::PullRequestMergeRejected(
            pull_request_merge_failure_digest(
              "remote-closed",
              snapshot.to_json(),
            ),
          )
      }
    None =>
      match lookup {
        PullRequestLookupUncertain => return Ok(record)
        _ =>
          PullRequestMergeState::PullRequestMergeRejected(
            pull_request_merge_failure_digest("identity", lookup.to_json()),
          )
      }
  }
  Ok({
    ..record,
    intent: { ..record.intent, merge_state: next_state },
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn mark_goal_pull_request_merge_may_have_been_issued(
  record : GoalPullRequestRecord,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.state != PullRequestIntentState::PullRequestReceipted ||
    record.intent.merge_state !=
    PullRequestMergeState::PullRequestMergeAuthorized ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("merge dispatch is not authorized"))
  }
  Ok({
    ..record,
    intent: {
      ..record.intent,
      merge_state: PullRequestMergeState::PullRequestMergeMayHaveBeenIssued,
    },
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn record_goal_pull_request_merge_dispatch(
  record : GoalPullRequestRecord,
  observation : PullRequestMergeDispatchObservation,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.merge_state !=
    PullRequestMergeState::PullRequestMergeMayHaveBeenIssued ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("merge dispatch observation is stale"))
  }
  match observation {
    PullRequestMergeDispatchAccepted | PullRequestMergeDispatchUncertain =>
      Ok(record)
    PullRequestMergeDispatchRejected(digest) => {
      if @storage.validate_digest(digest) is Err(_) {
        return Err(goal_pull_request_error("merge rejection is invalid"))
      }
      Ok({
        ..record,
        intent: {
          ..record.intent,
          merge_state: PullRequestMergeState::PullRequestMergeRejected(digest),
        },
        durable_version: record.durable_version + 1,
      })
    }
  }
}

///|
pub fn reconcile_goal_pull_request_merge(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.merge_state !=
    PullRequestMergeState::PullRequestMergeMayHaveBeenIssued ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("merge reconciliation is invalid"))
  }
  match exact_pull_request_snapshot(record, lookup) {
    Some(snapshot) =>
      match snapshot.state {
        RemotePullRequestState::RemotePullRequestMerged =>
          Ok({
            ..record,
            intent: {
              ..record.intent,
              merge_state: PullRequestMergeState::PullRequestMergeEnabled,
            },
            durable_version: record.durable_version + 1,
          })
        RemotePullRequestState::RemotePullRequestOpen =>
          if snapshot.auto_merge_enabled {
            Ok({
              ..record,
              intent: {
                ..record.intent,
                merge_state: PullRequestMergeState::PullRequestMergeEnabled,
              },
              durable_version: record.durable_version + 1,
            })
          } else {
            Ok({
              ..record,
              intent: {
                ..record.intent,
                merge_state: PullRequestMergeState::PullRequestMergeAuthorized,
              },
              durable_version: record.durable_version + 1,
            })
          }
        RemotePullRequestState::RemotePullRequestClosed =>
          Ok({
            ..record,
            intent: {
              ..record.intent,
              merge_state: PullRequestMergeState::PullRequestMergeRejected(
                pull_request_merge_failure_digest(
                  "remote-closed",
                  snapshot.to_json(),
                ),
              ),
            },
            durable_version: record.durable_version + 1,
          })
      }
    None =>
      match lookup {
        PullRequestLookupUncertain => Ok(record)
        _ =>
          Ok({
            ..record,
            intent: {
              ..record.intent,
              merge_state: PullRequestMergeState::PullRequestMergeRejected(
                pull_request_merge_failure_digest("identity", lookup.to_json()),
              ),
            },
            durable_version: record.durable_version + 1,
          })
      }
  }
}

///|
/// The exact remote pull request has no merge authority left: it is closed and
/// carries no automatic merge. Nothing observed by identity alone is enough —
/// the snapshot must be the exact authorized pull request.
fn pull_request_neutralization_from_snapshot(
  snapshot : RemotePullRequestSnapshot,
) -> PullRequestCancellationState? {
  match snapshot.state {
    RemotePullRequestState::RemotePullRequestMerged =>
      Some(PullRequestCancellationState::PullRequestSupersededByMerge)
    RemotePullRequestState::RemotePullRequestClosed =>
      if snapshot.auto_merge_enabled {
        None
      } else {
        Some(PullRequestCancellationState::PullRequestNeutralized)
      }
    RemotePullRequestState::RemotePullRequestOpen => None
  }
}

///|
/// Cancellation transitions that also settle the automatic merge intent: a
/// neutralized pull request can never merge, and a superseded one already did.
fn apply_pull_request_cancellation_state(
  record : GoalPullRequestRecord,
  cancellation_state : PullRequestCancellationState,
) -> GoalPullRequestRecord {
  let merge_state = match
    (record.intent.delivery_policy.mode, cancellation_state) {
    (
      @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      PullRequestCancellationState::PullRequestNeutralized,
    ) =>
      PullRequestMergeState::PullRequestMergeRejected(
        pull_request_merge_failure_digest(
          "canceled",
          record.intent.id.to_json(),
        ),
      )
    (
      @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      PullRequestCancellationState::PullRequestSupersededByMerge,
    ) => PullRequestMergeState::PullRequestMergeEnabled
    _ => record.intent.merge_state
  }
  {
    ..record,
    intent: { ..record.intent, cancellation_state, merge_state },
    durable_version: record.durable_version + 1,
  }
}

///|
/// Record the cancellation cutoff against the pull request intent. A pull
/// request that was never dispatched is abandoned outright; one that may exist
/// remotely is reconciled first, and an exact receipted pull request enters the
/// neutralization state machine instead of being treated as already settled.
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
      // Once create may have been issued, one empty lookup cannot distinguish
      // a request that never reached the forge from a created pull request
      // whose query visibility lagged. Keep claims held until exact remote
      // identity can be reconciled or a separate recovery path proves absence.
      match
        reconcile_goal_pull_request_after_create(record, lookup, observed_at) {
        Ok(reconciled) => Ok(plan_goal_pull_request_cancellation(reconciled))
        Err(error) => Err(error)
      }
    PullRequestReceipted
    | PullRequestNeedsInput(_)
    | PullRequestAbandonedByCancellation =>
      Ok(plan_goal_pull_request_cancellation(record))
  }
}

///|
fn plan_goal_pull_request_cancellation(
  record : GoalPullRequestRecord,
) -> GoalPullRequestRecord {
  if record.receipt is None ||
    record.intent.cancellation_state !=
    PullRequestCancellationState::PullRequestCancellationNotRequested {
    return record
  }
  {
    ..record,
    intent: {
      ..record.intent,
      cancellation_state: PullRequestCancellationState::PullRequestCancellationPlanned,
    },
    durable_version: record.durable_version + 1,
  }
}

///|
/// Decide whether the exact pull request still needs a neutralizing effect.
/// An unchanged record means the remote disposition is not yet known and the
/// Goal must keep its claims.
pub fn authorize_goal_pull_request_neutralization(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.cancellation_state !=
    PullRequestCancellationState::PullRequestCancellationPlanned ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("neutralization is not authorizable"))
  }
  match exact_pull_request_snapshot(record, lookup) {
    Some(snapshot) =>
      match pull_request_neutralization_from_snapshot(snapshot) {
        Some(settled) =>
          Ok(apply_pull_request_cancellation_state(record, settled))
        None =>
          Ok(
            apply_pull_request_cancellation_state(
              record,
              PullRequestCancellationState::PullRequestNeutralizeAuthorized,
            ),
          )
      }
    None => Ok(record)
  }
}

///|
pub fn mark_goal_pull_request_neutralize_may_have_been_issued(
  record : GoalPullRequestRecord,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.cancellation_state !=
    PullRequestCancellationState::PullRequestNeutralizeAuthorized ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("neutralize dispatch is not authorized"))
  }
  Ok(
    apply_pull_request_cancellation_state(
      record,
      PullRequestCancellationState::PullRequestNeutralizeMayHaveBeenIssued,
    ),
  )
}

///|
/// Reconcile the remote result of a neutralize dispatch. Dispatch output is
/// never trusted: only a fresh exact-identity observation settles the state,
/// and an open pull request re-authorizes another idempotent attempt.
pub fn reconcile_goal_pull_request_neutralization(
  record : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
) -> Result[GoalPullRequestRecord, @types.ChoirError] {
  if record.intent.cancellation_state !=
    PullRequestCancellationState::PullRequestNeutralizeMayHaveBeenIssued ||
    !goal_pull_request_record_shape_is_valid(record) {
    return Err(goal_pull_request_error("neutralization is not reconcilable"))
  }
  match exact_pull_request_snapshot(record, lookup) {
    Some(snapshot) =>
      match pull_request_neutralization_from_snapshot(snapshot) {
        Some(settled) =>
          Ok(apply_pull_request_cancellation_state(record, settled))
        None =>
          Ok(
            apply_pull_request_cancellation_state(
              record,
              PullRequestCancellationState::PullRequestNeutralizeAuthorized,
            ),
          )
      }
    None => Ok(record)
  }
}

///|
/// The exact pull request merged before cancellation could neutralize it.
/// Delivery wins: the Goal succeeds and its source Beads close at the delivery
/// boundary rather than being released.
pub fn goal_pull_request_delivery_superseded_cancellation(
  record : GoalPullRequestRecord,
) -> Bool {
  record.intent.cancellation_state ==
  PullRequestCancellationState::PullRequestSupersededByMerge &&
  record.receipt is Some(_)
}

///|
/// Cancellation may only commit once no remote pull request retains authority
/// to merge this Goal's exact head. Uncertain remotes are deliberately not
/// "known": they keep the Goal canceling and its source claims held.
pub fn goal_pull_request_cancellation_disposition_is_known(
  record : GoalPullRequestRecord,
) -> Bool {
  match record.intent.state {
    PullRequestAbandonedByCancellation => true
    PullRequestReceipted | PullRequestNeedsInput(_) =>
      match record.intent.cancellation_state {
        PullRequestCancellationState::PullRequestNeutralized
        | PullRequestCancellationState::PullRequestSupersededByMerge => true
        // No exact receipt exists to neutralize: identity was never
        // established, so this Goal never enabled a remote merge.
        PullRequestCancellationState::PullRequestCancellationNotRequested =>
          record.receipt is None
        _ => false
      }
    PullRequestPlanned
    | PullRequestAuthorized
    | PullRequestCreateMayHaveBeenIssued
    | PullRequestRemoteCreateUncertain => false
  }
}
