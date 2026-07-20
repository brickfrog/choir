///|
pub(all) enum PartWorkflowStage {
  PartAccepted
  PartImplementationSandboxPrepared
  PartImplementationHarnessStarted
  PartImplementationCompleted
  PartCandidateRecorded
  PartVerificationSandboxPrepared
  PartVerificationHarnessStarted
  PartVerified
  PartAuditSandboxPrepared
  PartAuditHarnessStarted
  PartAuditResultRecorded
  PartAudited
  PartIntegrationPlanned
  PartPromotionPrepared
  PartIntegrationAuthorized
  PartIntegrated
  PartCanceled
  PartBlocked
  PartRecoveryUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartIdentityPlan {
  implementation_take : @control.Take
  implementation_sandbox : @control.SandboxLease
  implementation_session : @control.HarnessSession
  verification_take : @control.Take
  verification_sandbox : @control.SandboxLease
  verification_session : @control.HarnessSession
  audit_take : @control.Take
  audit_sandbox : @control.SandboxLease
  audit_session : @control.HarnessSession
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PriorPartTakeEvidence {
  task_contract_revision_id : @control.RevisionId
  implementation_result : ImplementationExecutionResult?
  candidate : @control.CandidateCommit?
  verification_receipts : Array[@control.VerificationReceipt]
  verification_authorization : @control.VerificationAuthorizationSet?
  audit_result : @control.AuditResult?
  audit_receipt : @control.AuditReceipt?
  integration_intent : @control.IntegrationIntent?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartEffectKind {
  PrepareImplementationSandbox(@control.SandboxLease)
  StartImplementationHarness(@control.HarnessSession)
  DispatchImplementation(@control.TakeId, @control.HarnessSessionId)
  NormalizeImplementationCandidate(@control.TakeId, @control.Digest)
  PrepareVerificationSandbox(@control.SandboxLease)
  StartVerificationHarness(@control.HarnessSession)
  DispatchVerification(
    @control.TakeId,
    @control.HarnessSessionId,
    @control.PartVerificationSubject
  )
  PrepareAuditSandbox(@control.SandboxLease)
  StartAuditHarness(@control.HarnessSession)
  DispatchAudit(
    @control.TakeId,
    @control.HarnessSessionId,
    @control.PartAuditSubject
  )
  GeneratePromotion(@control.IntegrationIntent)
  ApplyIntegration(@control.IntegrationIntentId, @control.PromotionCommit)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartEffectLifecycle {
  PartEffectPlanned
  PartEffectMayHaveOccurred
  PartEffectReceipted
  PartEffectUncertain
  PartEffectAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartEffectIntent {
  effect_id : String
  kind : PartEffectKind
  request_digest : @control.Digest
  lifecycle : PartEffectLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartEffectReceipt {
  effect_id : String
  request_digest : @control.Digest
  observation_digest : @control.Digest
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartEffectWitness {
  effect_id : String
  request_digest : @control.Digest
  observation : PartEffectObservation
  observation_digest : @control.Digest
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ImplementationExecutionResult {
  take_id : @control.TakeId
  session_id : @control.HarnessSessionId
  result_artifact : @control.ArtifactReference
  finished_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerificationExecutionResult {
  take_id : @control.TakeId
  session_id : @control.HarnessSessionId
  verification_execution_id : @control.VerificationExecutionId
  subject : @control.PartVerificationSubject
  verification_spec : @control.VerificationSpec
  environment_and_image_digest : @control.Digest
  runtime_and_policy_digest : @control.Digest
  subject_pre_tree_oid : @control.GitOid
  subject_post_tree_oid : @control.GitOid
  evidence : @control.ArtifactReference
  started_at : Int64
  finished_at : Int64
  outcome : @control.VerificationOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AuditSubmission {
  audit_take_id : @control.TakeId
  take_fencing_epoch : @control.FencingEpoch
  audit_harness_session_id : @control.HarnessSessionId
  subject : @control.PartAuditSubject
  provider_conformance_report_digest : @control.Digest
  findings_artifact : @control.ArtifactReference?
  total_findings_count : Int
  blocking_findings_count : Int
  started_at : Int64
  finished_at : Int64
  outcome : @control.AuditOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AuditReceiptMetadata {
  receipt_id : @control.ReceiptId
  provider_surface_id : @control.ProviderSurfaceId
  provider_identity : String
  model_identity : @control.ModelIdentity
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntegrationPlanInput {
  lease : @control.GoalIntegrationLease
  intent_id : @control.IntegrationIntentId
  expected_goal_head_oid : @control.GitOid
  promotion_metadata_digest : @control.Digest
  git_witness_ref : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartEffectObservation {
  ImplementationSandboxPrepared(@control.SandboxLease)
  ImplementationHarnessStarted(@control.HarnessSession)
  ImplementationCompleted(
    ImplementationExecutionResult,
    @control.HarnessSession,
    Array[@control.HarnessEventEnvelope]
  )
  CandidateNormalized(@control.CandidateCommit, @control.CandidatePathEvidence)
  VerificationSandboxPrepared(@control.SandboxLease)
  VerificationHarnessStarted(@control.HarnessSession)
  VerificationCompleted(
    VerificationExecutionResult,
    @control.HarnessSession,
    Array[@control.HarnessEventEnvelope]
  )
  AuditSandboxPrepared(@control.SandboxLease)
  AuditHarnessStarted(@control.HarnessSession)
  AuditCompleted(
    AuditSubmission,
    @control.HarnessSession,
    Array[@control.HarnessEventEnvelope]
  )
  PromotionGenerated(@control.PromotionCommit)
  PromotionConflictObserved(@control.IntegrationConflict)
  IntegrationWitnessObserved(@control.IntegrationWitnessObservation)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartWorkflowSnapshot {
  workflow_id : String
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
  stage : PartWorkflowStage
  goal : @control.Goal
  part : @control.GoalPart
  task_contract : @control.TaskContractRevision
  task_contract_history : Array[@control.TaskContractRevision]
  identities : PartIdentityPlan
  implementation_take : @control.Take
  verification_take : @control.Take
  audit_take : @control.Take
  prior_takes : Array[@control.Take]
  prior_take_evidence : Array[PriorPartTakeEvidence]
  sandbox_leases : Array[@control.SandboxLease]
  harness_sessions : Array[@control.HarnessSession]
  harness_events : Array[@control.HarnessEventEnvelope]
  implementation_result : ImplementationExecutionResult?
  candidate : @control.CandidateCommit?
  verification_subject : @control.PartVerificationSubject?
  verification_slots : Array[@control.VerificationAuthorizationSlot]
  verification_receipts : Array[@control.VerificationReceipt]
  verification_authorization : @control.VerificationAuthorizationSet?
  audit_subject : @control.PartAuditSubject?
  audit_result : @control.AuditResult?
  audit_receipt : @control.AuditReceipt?
  integration_lease : @control.GoalIntegrationLease?
  integration_intent : @control.IntegrationIntent?
  promotion_commit : @control.PromotionCommit?
  integration_receipt : @control.IntegrationReceipt?
  integration_conflicts : Array[@control.IntegrationConflict]
  pending_effect : PartEffectIntent?
  effect_receipts : Array[PartEffectReceipt]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartConflictRepairDecision {
  PartConflictRepairPlanned(PartWorkflowSnapshot)
  PartConflictRepairLimitReached
} derive(Debug, Eq)
