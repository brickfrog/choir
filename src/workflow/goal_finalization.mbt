///|
pub(all) struct PullRequestReadinessSnapshotId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum PullRequestReadinessDecision {
  PullRequestReady
  PullRequestReadinessNeedsInput(PullRequestReadinessNeedsInputReason)
  PullRequestReadinessDrift(PullRequestReadinessDriftReason)
  PullRequestReadinessAmbiguous
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestReadinessNeedsInputReason {
  PullRequestNotOpen
  PullRequestEvidenceLinksMissing
  PullRequestReadinessObservationUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestReadinessDriftReason {
  PullRequestCanonicalIdentityMissing
  PullRequestCanonicalIdentityChanged
  PullRequestHeadOrBaseChanged
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PullRequestReadinessSnapshot {
  snapshot_id : PullRequestReadinessSnapshotId
  finalization_id : @control.FinalizationId
  pull_request_receipt_id : @control.ReceiptId
  goal_branch_seal_id : @control.GoalBranchSealId
  goal_branch_seal_digest : @control.Digest
  observed_remote_id : RemotePullRequestId?
  observed_remote_state : RemotePullRequestState?
  observed_head_repository_id : RemoteRepositoryId?
  observed_head_ref : GitRefName?
  observed_base_repository_id : RemoteRepositoryId?
  observed_base_ref : GitRefName?
  observed_head_oid : @control.GitOid?
  observed_body_digest : @control.Digest?
  goal_contract_link_present : Bool
  evidence_manifest_link_present : Bool
  remote_version_token : String?
  observation_sequence : Int64
  observation_started_at : Int64
  observed_at : Int64
  decision : PullRequestReadinessDecision
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalFinalizationRecord {
  goal_id : @control.GoalId
  repository_id : RepositoryId
  goal_contract_digest : @control.Digest
  assurance_record_digest : @control.Digest
  publication_record_digest : @control.Digest
  pull_request_record_digest : @control.Digest
  readiness : PullRequestReadinessSnapshot
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalFinalizationTickOutcome {
  GoalFinalizationPending
  GoalFinalizationSucceeded
  GoalFinalizationPublicationRemoteUnavailable
  GoalFinalizationNeedsUserInput
  GoalFinalizationDrifted
  GoalFinalizationAmbiguous
  GoalFinalizationRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalFinalizationFaultPoint {
  PullRequestAfterReadinessObservationBeforeSuccessTransaction
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_finalization_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal finalization: " + detail)
}

///|
fn goal_finalization_id(goal_id : @control.GoalId) -> @control.FinalizationId {
  @control.FinalizationId(
    "finalization-" +
    @storage.digest_text(goal_execution_identity_digest(goal_id)),
  )
}

///|
fn readiness_observed_snapshot(
  lookup : PullRequestLookupObservation,
) -> RemotePullRequestSnapshot? {
  match lookup {
    PullRequestStoredIdMatch(value)
    | PullRequestUniqueMarkerMatch(value)
    | PullRequestPossibleExistingMatch(value) => Some(value)
    _ => None
  }
}

///|
fn readiness_decision(
  intent : PullRequestIntent,
  receipt : PullRequestReceipt,
  lookup : PullRequestLookupObservation,
) -> PullRequestReadinessDecision {
  match lookup {
    PullRequestMultipleMarkerMatches => PullRequestReadinessAmbiguous
    PullRequestLookupUncertain =>
      PullRequestReadinessNeedsInput(
        PullRequestReadinessNeedsInputReason::PullRequestReadinessObservationUncertain,
      )
    PullRequestNoMatch =>
      PullRequestReadinessDrift(
        PullRequestReadinessDriftReason::PullRequestCanonicalIdentityMissing,
      )
    PullRequestPossibleExistingMatch(_) =>
      PullRequestReadinessDrift(
        PullRequestReadinessDriftReason::PullRequestCanonicalIdentityChanged,
      )
    PullRequestStoredIdMatch(snapshot)
    | PullRequestUniqueMarkerMatch(snapshot) => {
      if snapshot.remote_id != receipt.remote_pull_request_id ||
        snapshot.marker_state != PullRequestMarkerState::PullRequestMarkerExact {
        return PullRequestReadinessDrift(
          PullRequestReadinessDriftReason::PullRequestCanonicalIdentityChanged,
        )
      }
      if snapshot.head_repository_id != intent.head_repository_id ||
        snapshot.head_ref != intent.head_ref ||
        snapshot.base_repository_id != intent.base_repository_id ||
        snapshot.base_ref != intent.base_ref ||
        snapshot.observed_head_oid != intent.expected_head_oid {
        return PullRequestReadinessDrift(
          PullRequestReadinessDriftReason::PullRequestHeadOrBaseChanged,
        )
      }
      if snapshot.state != RemotePullRequestState::RemotePullRequestOpen {
        return PullRequestReadinessNeedsInput(
          PullRequestReadinessNeedsInputReason::PullRequestNotOpen,
        )
      }
      if !snapshot.goal_contract_link_present ||
        !snapshot.evidence_manifest_link_present {
        return PullRequestReadinessNeedsInput(
          PullRequestReadinessNeedsInputReason::PullRequestEvidenceLinksMissing,
        )
      }
      PullRequestReady
    }
  }
}

///|
fn goal_finalization_record_shape_is_valid(
  record : GoalFinalizationRecord,
) -> Bool {
  record.goal_id.0 != "" &&
  record.repository_id.0 != "" &&
  record.readiness.finalization_id == goal_finalization_id(record.goal_id) &&
  record.readiness.snapshot_id.0.has_prefix("readiness-") &&
  record.readiness.pull_request_receipt_id.0 != "" &&
  record.readiness.observation_sequence > 0L &&
  record.readiness.observation_started_at > 0L &&
  record.readiness.observed_at >= record.readiness.observation_started_at &&
  record.durable_version > 0 &&
  record.fencing_epoch.0 > 0L &&
  @storage.validate_digest(record.goal_contract_digest) is Ok(_) &&
  @storage.validate_digest(record.assurance_record_digest) is Ok(_) &&
  @storage.validate_digest(record.publication_record_digest) is Ok(_) &&
  @storage.validate_digest(record.pull_request_record_digest) is Ok(_) &&
  @storage.validate_digest(record.readiness.goal_branch_seal_digest) is Ok(_)
}

///|
pub fn goal_finalization_record_bytes(record : GoalFinalizationRecord) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn goal_finalization_record_digest(
  record : GoalFinalizationRecord,
) -> @control.Digest {
  @storage.artifact_digest(goal_finalization_record_bytes(record))
}

///|
pub fn decode_goal_finalization_record(
  content : Bytes,
) -> Result[GoalFinalizationRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(goal_finalization_error("record is not valid JSON"))
  }
  let record : GoalFinalizationRecord = @json.from_json(json) catch {
    _ => return Err(goal_finalization_error("record has the wrong schema"))
  }
  if goal_finalization_record_shape_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_finalization_error("record identity is invalid"))
  }
}

///|
fn goal_finalization_prerequisites_are_current(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
) -> Bool {
  pull_request_prerequisites_are_current(execution, assurance, publication) &&
  goal_pull_request_record_is_current(
    pull_request, execution, assurance, publication,
  ) &&
  pull_request.intent.state == PullRequestIntentState::PullRequestReceipted &&
  pull_request.receipt is Some(_)
}

///|
pub fn observe_goal_pull_request_readiness(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
  lookup : PullRequestLookupObservation,
  remote_version_token : String?,
  observation_sequence : Int64,
  observation_started_at : Int64,
  observed_at : Int64,
) -> Result[GoalFinalizationRecord, @types.ChoirError] {
  if !goal_finalization_prerequisites_are_current(
      execution, assurance, publication, pull_request,
    ) ||
    observation_sequence <= 0L ||
    observation_started_at <= 0L ||
    observed_at < observation_started_at ||
    remote_version_token
    .map(fn(value) { value.contains("\u{00}") })
    .unwrap_or(false) {
    return Err(goal_finalization_error("readiness is not observable"))
  }
  guard pull_request.receipt is Some(receipt) else {
    return Err(goal_finalization_error("pull request receipt is absent"))
  }
  let observed = readiness_observed_snapshot(lookup)
  let finalization_id = goal_finalization_id(execution.goal.id)
  let snapshot_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.pull-request-readiness.v1\u{00}" +
      [
        finalization_id.to_json(),
        receipt.receipt_id.to_json(),
        observation_sequence.to_json(),
        lookup.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  let record : GoalFinalizationRecord = {
    goal_id: execution.goal.id,
    repository_id: execution.repository_id,
    goal_contract_digest: execution.goal.contract_digest,
    assurance_record_digest: goal_assurance_record_digest(assurance),
    publication_record_digest: goal_publication_record_digest(publication),
    pull_request_record_digest: goal_pull_request_record_digest(pull_request),
    readiness: {
      snapshot_id: PullRequestReadinessSnapshotId(
        "readiness-" + @storage.digest_text(snapshot_digest),
      ),
      finalization_id,
      pull_request_receipt_id: receipt.receipt_id,
      goal_branch_seal_id: pull_request.intent.goal_branch_seal_id,
      goal_branch_seal_digest: pull_request.intent.goal_branch_seal_digest,
      observed_remote_id: observed.map(fn(value) { value.remote_id }),
      observed_remote_state: observed.map(fn(value) { value.state }),
      observed_head_repository_id: observed.map(fn(value) {
        value.head_repository_id
      }),
      observed_head_ref: observed.map(fn(value) { value.head_ref }),
      observed_base_repository_id: observed.map(fn(value) {
        value.base_repository_id
      }),
      observed_base_ref: observed.map(fn(value) { value.base_ref }),
      observed_head_oid: observed.map(fn(value) { value.observed_head_oid }),
      observed_body_digest: observed.map(fn(value) { value.body_digest }),
      goal_contract_link_present: observed
      .map(fn(value) { value.goal_contract_link_present })
      .unwrap_or(false),
      evidence_manifest_link_present: observed
      .map(fn(value) { value.evidence_manifest_link_present })
      .unwrap_or(false),
      remote_version_token,
      observation_sequence,
      observation_started_at,
      observed_at,
      decision: readiness_decision(pull_request.intent, receipt, lookup),
    },
    durable_version: 1,
    fencing_epoch: execution.fencing_epoch,
  }
  if goal_finalization_record_shape_is_valid(record) {
    Ok(record)
  } else {
    Err(goal_finalization_error("constructed readiness record is invalid"))
  }
}

///|
pub fn authorize_goal_execution_success(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
  finalization : GoalFinalizationRecord,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  if !goal_finalization_prerequisites_are_current(
      execution, assurance, publication, pull_request,
    ) ||
    finalization.goal_id != execution.goal.id ||
    finalization.repository_id != execution.repository_id ||
    finalization.goal_contract_digest != execution.goal.contract_digest ||
    finalization.assurance_record_digest !=
    goal_assurance_record_digest(assurance) ||
    finalization.publication_record_digest !=
    goal_publication_record_digest(publication) ||
    finalization.pull_request_record_digest !=
    goal_pull_request_record_digest(pull_request) ||
    finalization.readiness.decision !=
    PullRequestReadinessDecision::PullRequestReady ||
    !goal_finalization_record_shape_is_valid(finalization) {
    return Err(goal_finalization_error("success evidence is not current"))
  }
  advance_goal_execution_state(
    execution,
    GoalExecutionState::GoalExecutionSucceeded,
  )
}
