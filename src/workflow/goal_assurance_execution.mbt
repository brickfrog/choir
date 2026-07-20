///|
pub(all) struct GoalAssuranceIdentityPlan {
  verification_take : @control.Take
  verification_sandbox : @control.SandboxLease
  verification_session : @control.HarnessSession
  audit_take : @control.Take
  audit_sandbox : @control.SandboxLease
  audit_session : @control.HarnessSession
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalAssuranceEffectKind {
  PrepareGoalVerificationSandbox(@control.SandboxLease)
  StartGoalVerificationHarness(@control.HarnessSession)
  DispatchGoalVerification(
    @control.TakeId,
    @control.HarnessSessionId,
    @control.GoalVerificationSubject
  )
  PrepareGoalAuditSandbox(@control.SandboxLease)
  StartGoalAuditHarness(@control.HarnessSession)
  DispatchGoalAudit(
    @control.TakeId,
    @control.HarnessSessionId,
    @control.GoalAuditSubject
  )
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalAssuranceEffectLifecycle {
  GoalAssuranceEffectPlanned
  GoalAssuranceEffectMayHaveOccurred
  GoalAssuranceEffectReceipted
  GoalAssuranceEffectUncertain
  GoalAssuranceEffectAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAssuranceEffectIntent {
  effect_id : String
  kind : GoalAssuranceEffectKind
  request_digest : @control.Digest
  lifecycle : GoalAssuranceEffectLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAssuranceEffectReceipt {
  effect_id : String
  request_digest : @control.Digest
  observation_digest : @control.Digest
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAssuranceEffectWitness {
  effect_id : String
  request_digest : @control.Digest
  observation : GoalAssuranceEffectObservation
  observation_digest : @control.Digest
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalVerificationSpecExecution {
  verification_execution_id : @control.VerificationExecutionId
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
pub(all) struct GoalVerificationExecutionResult {
  take_id : @control.TakeId
  session_id : @control.HarnessSessionId
  subject : @control.GoalVerificationSubject
  executions : Array[GoalVerificationSpecExecution]
  evidence_manifest : @control.ArtifactReference
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAuditSubmission {
  audit_take_id : @control.TakeId
  take_fencing_epoch : @control.FencingEpoch
  audit_harness_session_id : @control.HarnessSessionId
  subject : @control.GoalAuditSubject
  provider_conformance_report_digest : @control.Digest
  findings_artifact : @control.ArtifactReference?
  total_findings_count : Int
  blocking_findings_count : Int
  started_at : Int64
  finished_at : Int64
  outcome : @control.AuditOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAuditReceiptMetadata {
  receipt_id : @control.ReceiptId
  provider_surface_id : @control.ProviderSurfaceId
  provider_identity : String
  model_identity : @control.ModelIdentity
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalAssuranceEffectObservation {
  GoalVerificationSandboxPrepared(@control.SandboxLease)
  GoalVerificationHarnessStarted(@control.HarnessSession)
  GoalVerificationCompleted(
    GoalVerificationExecutionResult,
    @control.HarnessSession,
    Array[@control.HarnessEventEnvelope]
  )
  GoalAuditSandboxPrepared(@control.SandboxLease)
  GoalAuditHarnessStarted(@control.HarnessSession)
  GoalAuditCompleted(
    GoalAuditSubmission,
    @control.HarnessSession,
    Array[@control.HarnessEventEnvelope]
  )
} derive(Debug, Eq, ToJson, FromJson)
