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
pub(all) struct Digest(String) derive(Debug, Eq, Compare, Hash, ToJson, FromJson)

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
