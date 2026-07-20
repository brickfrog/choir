///|
pub(all) struct SandboxLeaseId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct SandboxGenerationId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct HarnessSessionId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct HarnessEventId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct VerificationExecutionId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct VerificationSpecId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct AuditResultId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct IntegrationLeaseId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct IntegrationIntentId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct IntegrationReceiptId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct ArtifactReference {
  artifact_id : String
  digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RepoPath(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum RepositoryPathMode {
  CaseSensitiveNfc
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum UnknownMutationReason {
  SemanticScopeUnknown
  GeneratedOutputsUnknown
  RepositoryWideToolingUnknown
  ConductorCouldNotDetermine
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MutationClaim {
  ExactPath(RepoPath)
  PathTree(RepoPath)
  RepositoryWide
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MutationDeclaration {
  CompleteMutationDeclaration(Array[MutationClaim])
  UnknownMutationDeclaration(UnknownMutationReason)
  MissingMutationDeclaration
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerificationSpec {
  id : VerificationSpecId
  version : Int
  digest : Digest
  process_spec_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskContractRevision {
  id : RevisionId
  goal_id : GoalId
  part_id : PartId
  revision : Int
  digest : Digest
  instruction_artifact : ArtifactReference
  base_commit_oid : GitOid
  base_tree_oid : GitOid
  path_mode : RepositoryPathMode
  mutation_declaration : MutationDeclaration
  verification_specs : Array[VerificationSpec]
  audit_policy_digest : Digest
  implementation_capability_profile_digest : Digest
  verification_capability_profile_digest : Digest
  audit_capability_profile_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CandidateCommit {
  id : CandidateId
  goal_id : GoalId
  part_id : PartId
  take_id : TakeId
  base_commit_oid : GitOid
  commit_oid : GitOid
  tree_oid : GitOid
  canonical_change_digest : Digest
  changed_paths : Array[RepoPath]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum CandidateValidationFailure {
  CandidateWrongGoal
  CandidateWrongPart
  CandidateWrongTake
  CandidateWrongBase
  CandidateInvalidPath(RepoPath)
  CandidateOwnershipViolation(Array[RepoPath])
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CandidatePathEvidence {
  candidate_tree_paths : Array[RepoPath]
  symlink_prefix_paths : Array[RepoPath]
  normalization_collision_paths : Array[RepoPath]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxLeaseLifecycle {
  SandboxLeasePlanned
  SandboxLeaseActive
  SandboxLeaseReleased
  SandboxLeaseUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxLease {
  id : SandboxLeaseId
  take_id : TakeId
  generation_id : SandboxGenerationId
  capability_profile_digest : Digest
  runtime_policy_digest : Digest
  lifecycle : SandboxLeaseLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ProviderSurfaceId {
  ClaudeSubscriptionCli
  CodexSubscriptionCli
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessCursorClass {
  HarnessCursorNotResumable
  HarnessCursorProviderEventId
  HarnessCursorTransition
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessTerminalObservation {
  HarnessCompleted
  HarnessFailed
  HarnessInterrupted
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessSessionLifecycle {
  HarnessSessionPlanned
  HarnessSessionAwaitingEvents
  HarnessSessionRunning
  HarnessSessionTerminalObserved(HarnessTerminalObservation)
  HarnessSessionIngestionClosedCleanly(HarnessTerminalObservation)
  HarnessSessionProtocolViolated
  HarnessSessionRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HarnessSession {
  id : HarnessSessionId
  take_id : TakeId
  sandbox_generation_id : SandboxGenerationId
  surface : ProviderSurfaceId
  effective_surface_manifest_digest : Digest
  cursor_class : HarnessCursorClass
  provider_cursor : String?
  last_choir_sequence : EventSequence
  open_tool_execution_ids : Array[String]
  lifecycle : HarnessSessionLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum EventSourcePosition {
  EventProviderId(String)
  EventProviderCursorTransition(String, String)
  EventNonResumableOrdinal(String, Int)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum EventRedactionState {
  EventNotSensitive
  EventRedacted
  EventWithheld
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessEventKind {
  HarnessStarted
  HarnessToolStarted(String)
  HarnessToolFinished(String)
  HarnessTerminal(HarnessTerminalObservation)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HarnessEventEnvelope {
  id : HarnessEventId
  take_id : TakeId
  session_id : HarnessSessionId
  source_position : EventSourcePosition
  choir_sequence : EventSequence
  observed_at : Int64
  kind : HarnessEventKind
  sanitized_payload_digest : Digest
  redaction_state : EventRedactionState
  late : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum HarnessIngestionDisposition {
  HarnessEventAppended
  HarnessEventDuplicate
  HarnessEventLate
  HarnessEventConflict
  HarnessEventCursorGap
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HarnessIngestionResult {
  session : HarnessSession
  event : HarnessEventEnvelope?
  disposition : HarnessIngestionDisposition
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerificationOutcome {
  VerificationPassed
  VerificationFailed
  VerificationErrored
  VerificationInterrupted
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartVerificationSubject {
  part_id : PartId
  candidate_take_id : TakeId
  candidate_commit_oid : GitOid
  candidate_tree_oid : GitOid
  task_contract_revision_id : RevisionId
  task_contract_digest : Digest
  subject_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerificationReceipt {
  receipt_id : ReceiptId
  verification_take_id : TakeId
  verification_execution_id : VerificationExecutionId
  subject : PartVerificationSubject
  verification_spec : VerificationSpec
  prepared_environment_and_image_digest : Digest
  sandbox_runtime_and_policy_digest : Digest
  subject_pre_tree_oid : GitOid
  subject_post_tree_oid : GitOid
  evidence : ArtifactReference
  started_at : Int64
  finished_at : Int64
  outcome : VerificationOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerificationAuthorizationSlot {
  subject_digest : Digest
  verification_spec : VerificationSpec
  lowest_admitted_execution_ordinal : Int
  authorizing_receipt_id : ReceiptId?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerificationAuthorizationSet {
  subject_digest : Digest
  receipt_ids : Array[ReceiptId]
  receipt_set_digest : Digest
  evidence_manifest_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerificationGateStaleReason {
  VerificationStaleSubject
  VerificationStaleSpec
  VerificationStaleEnvironment
  VerificationStaleRuntime
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerificationGateRejectionReason {
  VerificationMissingSlot
  VerificationMissingReceipt
  VerificationOutcomeNotPassing
  VerificationTreeChanged
  VerificationSessionNotCleanlyClosed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerificationGateCorruptionReason {
  VerificationDuplicateSlot
  VerificationDuplicateReceipt
  VerificationEvidenceMissing
  VerificationReceiptProtocolViolation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerificationGateObservation {
  VerificationGateValid(Array[ReceiptId])
  VerificationGateStale(VerificationGateStaleReason)
  VerificationGateRejected(VerificationGateRejectionReason)
  VerificationGateCorrupt(VerificationGateCorruptionReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartAuditSubject {
  part_id : PartId
  candidate_take_id : TakeId
  candidate_commit_oid : GitOid
  candidate_tree_oid : GitOid
  task_contract_revision_id : RevisionId
  task_contract_digest : Digest
  verification_receipt_set_digest : Digest
  verification_evidence_manifest_digest : Digest
  subject_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditOutcome {
  AuditPassed
  AuditFindings
  AuditFailed
  AuditInterrupted
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ModelIdentity {
  ReportedModelIdentity(String)
  UnreportedModelIdentity
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AuditResult {
  id : AuditResultId
  audit_take_id : TakeId
  take_fencing_epoch : FencingEpoch
  audit_harness_session_id : HarnessSessionId
  subject : PartAuditSubject
  auditor_capability_profile_digest : Digest
  effective_surface_manifest_digest : Digest
  provider_conformance_report_digest : Digest
  audit_policy_digest : Digest
  findings_artifact : ArtifactReference?
  total_findings_count : Int
  blocking_findings_count : Int
  started_at : Int64
  finished_at : Int64
  outcome : AuditOutcome
  result_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AuditReceipt {
  receipt_id : ReceiptId
  audit_result_id : AuditResultId
  audit_result_digest : Digest
  subject : PartAuditSubject
  audit_take_id : TakeId
  audit_harness_session_id : HarnessSessionId
  audit_sandbox_generation_id : SandboxGenerationId
  auditor_capability_profile_digest : Digest
  provider_surface_id : ProviderSurfaceId
  provider_identity : String
  model_identity : ModelIdentity
  provider_conformance_report_digest : Digest
  audit_policy_digest : Digest
  findings_artifact : ArtifactReference?
  total_findings_count : Int
  blocking_findings_count : Int
  started_at : Int64
  finished_at : Int64
  outcome : AuditOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditGateStaleReason {
  AuditStaleSubject
  AuditStalePolicy
  AuditStaleCapabilityProfile
  AuditStaleProviderConformance
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditGateRejectionReason {
  AuditOutcomeNotPassing
  AuditHasBlockingFindings
  AuditNotIndependent
  AuditSessionNotCleanlyClosed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditGateCorruptionReason {
  AuditResultMismatch
  AuditArtifactMissing
  AuditReceiptProtocolViolation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditGateObservation {
  AuditGateMissing
  AuditGateValid(ReceiptId)
  AuditGateStale(AuditGateStaleReason)
  AuditGateRejected(AuditGateRejectionReason)
  AuditGateCorrupt(AuditGateCorruptionReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PromotionStrategy {
  NoFastForwardThreeWayV1
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalIntegrationLease {
  id : IntegrationLeaseId
  goal_id : GoalId
  fencing_epoch : FencingEpoch
  holder : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum IntegrationIntentLifecycle {
  IntegrationPlanned
  IntegrationPrepared
  IntegrationAuthorized
  IntegrationReceipted
  IntegrationConflict
  IntegrationIntegrityBlocked
  IntegrationUncertain
  IntegrationAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntegrationIntent {
  id : IntegrationIntentId
  goal_id : GoalId
  part_id : PartId
  candidate_id : CandidateId
  candidate_commit_oid : GitOid
  candidate_tree_oid : GitOid
  expected_goal_head_oid : GitOid
  strategy : PromotionStrategy
  promotion_metadata_digest : Digest
  integration_lease_epoch : FencingEpoch
  lifecycle : IntegrationIntentLifecycle
  promotion_commit_oid : GitOid?
  promotion_tree_oid : GitOid?
  git_witness_ref : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PromotionCommit {
  intent_id : IntegrationIntentId
  commit_oid : GitOid
  tree_oid : GitOid
  first_parent_oid : GitOid
  second_parent_oid : GitOid
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum IntegrationWitnessObservation {
  IntegrationWitnessApplied(GitOid, GitOid)
  IntegrationWitnessNotApplied(GitOid)
  IntegrationWitnessDiverged
  IntegrationWitnessIntegrityError
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum IntegrationAuthorizationFailure {
  IntegrationPartNotAudited
  IntegrationCandidateMismatch
  IntegrationVerificationInvalid
  IntegrationAuditInvalid
  IntegrationLeaseMismatch
  IntegrationIntentNotPrepared
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum IntegrationReconciliationOutcome {
  IntegrationRetryAuthorized
  IntegrationApplied(IntegrationReceipt)
  IntegrationReconciliationDiverged
  IntegrationReconciliationIntegrityError
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntegrationReceipt {
  id : IntegrationReceiptId
  intent_id : IntegrationIntentId
  goal_id : GoalId
  part_id : PartId
  candidate_id : CandidateId
  candidate_commit_oid : GitOid
  candidate_tree_oid : GitOid
  from_head_oid : GitOid
  promotion_commit_oid : GitOid
  promotion_tree_oid : GitOid
  witness_ref : String
  integrated_at : Int64
} derive(Debug, Eq, ToJson, FromJson)
