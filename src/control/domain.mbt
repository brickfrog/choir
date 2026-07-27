///|
/// Stable durable identities. The wrappers prevent accidentally crossing
/// Goal, Part, Take, receipt, and digest domains at orchestration boundaries.
pub(all) struct GoalId(String) derive(Debug, Eq, Compare, Hash, ToJson, FromJson)

///|
pub(all) struct PartId(String) derive(Debug, Eq, Compare, Hash, ToJson, FromJson)

///|
pub(all) struct TakeId(String) derive(Debug, Eq, Compare, Hash, ToJson, FromJson)

///|
pub(all) struct CandidateId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct ReceiptId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct RevisionId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct FinalizationId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct CancellationSummaryId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
/// The durable key of one Part's workflow record.
pub(all) struct WorkflowId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
/// The durable key of one authorized host effect.
///
/// Every effect id belongs to exactly one workflow, so it is always derived
/// from that workflow rather than composed by the caller. `WorkflowId::effect`
/// is the only place that knows the separator; a hand-built key that spells it
/// differently loads nothing and the effect waits forever on a witness that
/// cannot arrive.
pub(all) struct EffectId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
/// Mint an effect id inside this workflow's namespace.
pub fn WorkflowId::effect(self : WorkflowId, suffix : String) -> EffectId {
  EffectId(self.0 + ":" + suffix)
}

///|
/// Mint an effect id inside this Goal's namespace, for the Goal-level
/// assurance effects that no Part workflow owns.
pub fn GoalId::effect(self : GoalId, suffix : String) -> EffectId {
  EffectId(self.0 + ":" + suffix)
}

///|
pub(all) struct Digest(String) derive(Debug, Eq, Compare, Hash, ToJson, FromJson)

///|
/// Whether this is a well-formed SHA-256 digest: 64 lowercase hex characters.
///
/// One implementation because this decides what evidence gates accept. It was
/// hand-rolled identically in four packages — storage, sandbox, control, and
/// migration — and a single copy drifting to accept uppercase or a different
/// length would quietly change which receipts and artifacts are admitted, in
/// one subsystem and not the others.
pub fn Digest::is_valid(self : Digest) -> Bool {
  if self.0.length() != 64 {
    return false
  }
  for character in self.0 {
    if !((character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')) {
      return false
    }
  }
  true
}

///|
pub(all) struct GitOid(String) derive(Debug, Eq, Compare, Hash, ToJson, FromJson)

///|
pub(all) struct EventSequence(Int64) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct FencingEpoch(Int64) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
/// The only nonterminal Goal condition that authorizes new work or effects is
/// `GoalRunning`. All other active conditions are observation/reconciliation
/// states.
pub(all) enum GoalActiveCondition {
  GoalRunning
  GoalNeedsInput
  GoalDrift
  GoalAmbiguous
  GoalIntegrityBlocked
  GoalRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalLifecycle {
  GoalActive(GoalActiveCondition)
  GoalCanceling(EventSequence)
  GoalSucceeded(FinalizationId)
  GoalCanceled(CancellationSummaryId)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalTransition {
  ObserveGoalCondition(GoalActiveCondition)
  RequestGoalCancellation(EventSequence)
  CommitGoalSuccess(FinalizationId)
  CommitGoalCancellation(CancellationSummaryId)
  /// Delivery beat cancellation: the exact authorized pull request was already
  /// merged when the cancellation race resolved. Only an observed remote merge
  /// authorizes this trigger.
  CommitGoalDeliveredDuringCancellation(FinalizationId)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartBlockReason {
  PartDependencyBlocked
  PartVerificationFailed
  PartAuditFindings
  PartAuditUnavailable
  PartIntegrationConflict
  PartOwnershipViolation
  PartIntegrityBlocked
  PartRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A Part is the durable unit of intended work. Verification and audit Takes
/// advance this state but are not additional Parts.
pub(all) enum PartLifecycle {
  PartPending
  PartReady
  PartExecuting(TakeId)
  PartCandidate(CandidateId)
  PartVerified(CandidateId, Digest)
  PartAudited(CandidateId, Digest, ReceiptId)
  PartPromoting(CandidateId, Digest, ReceiptId)
  PartIntegrated(ReceiptId)
  PartBlocked(PartBlockReason)
  PartCanceledNotRun
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartTransition {
  MarkPartReady
  StartPartTake(TakeId)
  RetryPartTake(TakeId)
  RecordPartCandidate(TakeId, CandidateId)
  RecordPartVerification(CandidateId, Digest)
  RecordPartAudit(CandidateId, ReceiptId)
  BeginPartPromotion(CandidateId)
  RecordPartIntegration(CandidateId, ReceiptId)
  StartPartConflictRepair(IntegrationConflictId, TakeId)
  StartPartAuditRepair(AuditResultId, TakeId)
  StartPartVerificationRepair(ReceiptId, TakeId)
  RestartBlockedPart(TakeId)
  BlockPart(PartBlockReason)
  CancelPartNotRun
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Every Take has one immutable purpose. Auxiliary verification and audit
/// Takes consume resources but never enter a Goal's selected Part set.
pub(all) enum TakePurpose {
  Implementation(PartId, RevisionId)
  PartVerification(PartId, TakeId, Digest)
  PartAudit(PartId, TakeId, Digest)
  GoalVerification(GoalId, GitOid, Digest)
  GoalAudit(GoalId, Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TakeFailureReason {
  TakeProviderFailed
  TakeVerificationFailed
  TakeAuditFindings
  TakePolicyRejected
  TakeResourceLimit
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TakeUncertaintyReason {
  TakeLeaseLost
  TakeCursorGap
  TakeEventConflict
  TakeEffectUncertain
  TakeProtocolViolation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TakeTerminalDisposition {
  TakeSucceeded
  TakeFailed(TakeFailureReason)
  TakeInterrupted
  TakeRecoveryUncertain(TakeUncertaintyReason)
  TakeCanceled
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TakeLifecycle {
  TakePlanned
  TakeLeased
  TakeRunning
  TakeResultRecorded(Digest)
  TakeTerminal(TakeTerminalDisposition)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TakeTransition {
  LeaseTake(FencingEpoch)
  StartTake(FencingEpoch)
  RecordTakeResult(FencingEpoch, Digest)
  FinishTake(FencingEpoch, TakeTerminalDisposition)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Goal {
  id : GoalId
  contract_digest : Digest
  lifecycle : GoalLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPart {
  id : PartId
  goal_id : GoalId
  dependency_ids : Array[PartId]
  task_contract_revision_id : RevisionId
  lifecycle : PartLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Take {
  id : TakeId
  goal_id : GoalId
  purpose : TakePurpose
  ordinal : Int
  fencing_epoch : FencingEpoch?
  lifecycle : TakeLifecycle
} derive(Debug, Eq, ToJson, FromJson)
