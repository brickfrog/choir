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
  PullRequestMergeObserved
  PullRequestReadinessNeedsInput(PullRequestReadinessNeedsInputReason)
  PullRequestReadinessDrift(PullRequestReadinessDriftReason)
  PullRequestReadinessAmbiguous
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestReadinessNeedsInputReason {
  PullRequestNotOpen
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
  remote_version_token : String?
  observation_sequence : Int64
  observation_started_at : Int64
  observed_at : Int64
  decision : PullRequestReadinessDecision
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Delivery evidence observed after the remote reports the pull request
/// merged. Binds the GitHub merge commit and the observed target head that
/// contains it. The reviewed head SHA is deliberately not required to appear
/// in the target: squash and rebase merges rewrite it, so the merge commit
/// is the only durable link.
pub(all) struct GoalDeliveryObservation {
  merge_commit_oid : @control.GitOid
  observed_target_head_oid : @control.GitOid
  target_contains_merge : Bool
  observed_at : Int64
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
  delivery : GoalDeliveryObservation?
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalFinalizationTickOutcome {
  GoalFinalizationPending
  GoalFinalizationAwaitingMerge
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
      match snapshot.state {
        RemotePullRequestState::RemotePullRequestOpen => PullRequestReady
        // Merged is the desired end state, not drift: the delivery flow
        // verifies the merge commit and target containment before success.
        RemotePullRequestState::RemotePullRequestMerged =>
          PullRequestMergeObserved
        RemotePullRequestState::RemotePullRequestClosed =>
          PullRequestReadinessNeedsInput(
            PullRequestReadinessNeedsInputReason::PullRequestNotOpen,
          )
      }
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
  @storage.validate_digest(record.readiness.goal_branch_seal_digest) is Ok(_) &&
  (match record.delivery {
    None => true
    Some(delivery) =>
      delivery.merge_commit_oid.0 != "" &&
      delivery.observed_target_head_oid.0 != "" &&
      delivery.observed_at > 0L
  })
}

///|
/// Whether an awaiting-merge Goal is due for another passive remote
/// observation. Backoff doubles with each observation up to sixteen minutes,
/// so a Goal waiting on a human merge costs one forge call per interval
/// rather than one per tick.
pub fn goal_merge_observation_due(
  record : GoalFinalizationRecord,
  now : Int64,
) -> Bool {
  let exponent = record.readiness.observation_sequence - 1L
  let capped = if exponent < 0L {
    0L
  } else if exponent > 4L {
    4L
  } else {
    exponent
  }
  let interval = 60L * (1L << capped.to_int())
  now >= record.readiness.observed_at + interval
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
      remote_version_token,
      observation_sequence,
      observation_started_at,
      observed_at,
      decision: readiness_decision(pull_request.intent, receipt, lookup),
    },
    delivery: None,
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
fn goal_finalization_evidence_is_current(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
  finalization : GoalFinalizationRecord,
) -> Bool {
  goal_finalization_prerequisites_are_current(
    execution, assurance, publication, pull_request,
  ) &&
  finalization.goal_id == execution.goal.id &&
  finalization.repository_id == execution.repository_id &&
  finalization.goal_contract_digest == execution.goal.contract_digest &&
  finalization.assurance_record_digest ==
  goal_assurance_record_digest(assurance) &&
  finalization.publication_record_digest ==
  goal_publication_record_digest(publication) &&
  finalization.pull_request_record_digest ==
  goal_pull_request_record_digest(pull_request) &&
  goal_finalization_record_shape_is_valid(finalization)
}

///|
/// A ready pull request advances the Goal to AwaitingMerge: Choir's work is
/// published and review is in a human's hands, so the Goal stops consuming
/// provider capacity and waits passively for the merge.
pub fn authorize_goal_awaiting_merge(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
  finalization : GoalFinalizationRecord,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  let decision_permits_wait = match finalization.readiness.decision {
    // A merge observed while still Assured also enters AwaitingMerge first;
    // the delivery observation then completes it on a later tick.
    PullRequestReadinessDecision::PullRequestReady
    | PullRequestReadinessDecision::PullRequestMergeObserved => true
    _ => false
  }
  if !goal_finalization_evidence_is_current(
      execution, assurance, publication, pull_request, finalization,
    ) ||
    !decision_permits_wait {
    return Err(goal_finalization_error("readiness evidence is not current"))
  }
  advance_goal_execution_state(
    execution,
    GoalExecutionState::GoalExecutionAwaitingMerge,
  )
}

///|
/// Success requires observed delivery: the remote reports the pull request
/// merged and the recorded merge commit is contained in the observed target
/// head. Bead completion follows this authorization, never precedes it.
pub fn authorize_goal_execution_success(
  execution : GoalExecutionRecord,
  assurance : GoalAssuranceRecord,
  publication : GoalPublicationRecord,
  pull_request : GoalPullRequestRecord,
  finalization : GoalFinalizationRecord,
) -> Result[GoalExecutionRecord, @types.ChoirError] {
  if !goal_finalization_evidence_is_current(
      execution, assurance, publication, pull_request, finalization,
    ) ||
    finalization.readiness.decision !=
    PullRequestReadinessDecision::PullRequestMergeObserved {
    return Err(goal_finalization_error("success evidence is not current"))
  }
  guard finalization.delivery is Some(delivery) &&
    delivery.target_contains_merge else {
    return Err(goal_finalization_error("delivery evidence is not current"))
  }
  advance_goal_execution_state(
    execution,
    GoalExecutionState::GoalExecutionSucceeded,
  )
}
