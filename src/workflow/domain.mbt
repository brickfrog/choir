///|
pub(all) enum PartWorkflowStage {
  PartAccepted
  PartImplementationSandboxPrepared
  PartImplementationCommandPrepared
  PartImplementationHarnessStarted
  PartImplementationCompleted
  PartCandidateRecorded
  PartVerificationSandboxPrepared
  PartVerified
  PartAuditSandboxPrepared
  PartAuditCommandPrepared
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
  integration_receipt : @control.IntegrationReceipt?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartRepairSource {
  commit_oid : @control.GitOid
  tree_oid : @control.GitOid
} derive(Debug, Eq)

///|
pub(all) struct PartCommandPreparationPlan {
  role : @command.CommandRole
  take : @control.Take
  session_id : @control.HarnessSessionId
  subject : @command.CommandExecutionSubject
  goal_contract_digest : @control.Digest
  task_contract_revision_id : @control.RevisionId
  task_contract_digest : @control.Digest
  instruction_artifact_digest : @control.Digest
  migration_contract_ref : @control.MigrationContractRef?
  provider_surface : @control.ProviderSurfaceId
  provider_surface_and_profile_digest : @control.Digest
  context_assembly_policy_digest : @control.Digest
  context_manifest : @migration.PartContextManifest?
  template_digest : @control.Digest
  maximum_command_bytes : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartPreparedCommand {
  plan : PartCommandPreparationPlan
  command_artifact : @control.ArtifactReference
  provenance : @command.CommandPreparationProvenance
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartEffectKind {
  PrepareImplementationSandbox(@control.SandboxLease)
  PrepareImplementationCommand(PartCommandPreparationPlan)
  StartImplementationHarness(
    @control.HarnessSession,
    @control.HarnessSessionStartIntent
  )
  DispatchImplementation(@control.TakeId, @control.HarnessCommandIntent)
  NormalizeImplementationCandidate(@control.TakeId, @control.Digest)
  PrepareVerificationSandbox(@control.SandboxLease)
  DispatchVerification(@control.TakeId, @control.PartVerificationSubject)
  PrepareAuditSandbox(@control.SandboxLease)
  PrepareAuditCommand(PartCommandPreparationPlan)
  StartAuditHarness(@control.HarnessSession, @control.HarnessSessionStartIntent)
  DispatchAudit(
    @control.TakeId,
    @control.HarnessCommandIntent,
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
  effect_id : @control.EffectId
  kind : PartEffectKind
  request_digest : @control.Digest
  lifecycle : PartEffectLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartEffectReceipt {
  effect_id : @control.EffectId
  request_digest : @control.Digest
  observation_digest : @control.Digest
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartEffectWitness {
  effect_id : @control.EffectId
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
  ImplementationCommandPrepared(PartPreparedCommand)
  ImplementationHarnessStarted(@control.HarnessSession)
  ImplementationCompleted(
    ImplementationExecutionResult,
    @control.HarnessSession,
    Array[@control.HarnessEventEnvelope]
  )
  CandidateNormalized(@control.CandidateCommit, @control.CandidatePathEvidence)
  VerificationSandboxPrepared(@control.SandboxLease)
  VerificationCompleted(VerificationExecutionResult)
  AuditSandboxPrepared(@control.SandboxLease)
  AuditCommandPrepared(PartPreparedCommand)
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
/// What Choir observed when a provider dispatch ended recovery-uncertain.
///
/// Without this the Part records only that "a Take was uncertain", and a
/// provider outage, a harness bug, and a lost process are indistinguishable to
/// anyone reading the Goal. `detail` is Choir's own diagnostic for the failure
/// it classified; provider output is never copied into durable state.
pub(all) struct PartDispatchDiagnostic {
  take_id : @control.TakeId
  /// The harness session, when the effect had one. Verification runs a
  /// sandbox process with no session.
  session_id : @control.HarnessSessionId?
  /// The terminal classification, once the Take has one. A dispatch that
  /// failed while the Take is still unresolved has no classification yet, and
  /// claiming one would misreport the failure.
  reason : @control.TakeUncertaintyReason?
  /// What Choir observed at the moment the dispatch failed.
  detail : String
  /// Why the failure could not be recovered, when a later reconciliation
  /// decided that. This is a verdict about recovery, never the cause, and it
  /// never replaces `detail`.
  recovery : String?
  /// What the provider surface itself reported. An exhausted subscription
  /// allowance and a crashed provider are both "the Take did not run", but
  /// only one of them clears at a known instant.
  availability : @control.ProviderAvailability
  /// When `availability` was observed. An observation the surface dated
  /// itself — a reported reset or retry-after — carries its own instant, but
  /// one that dated nothing has to be aged out against the clock instead, and
  /// an undated observation can only be treated as permanent.
  observed_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One recorded surface change, and the observation that caused it.
///
/// A Part that quietly started spending a different subscription would be
/// indistinguishable from one that was always authorized to, so each move is
/// recorded rather than inferred from the current identity plan.
pub(all) struct PartProviderFailover {
  from_surface : @control.ProviderSurfaceId
  to_surface : @control.ProviderSurfaceId
  /// What the surface being left reported. This is the whole reason the Part
  /// moved, and it is the observation that also keeps the Part from being
  /// sent back while it still holds.
  cause : @control.ProviderAvailability
  /// Which bounded recovery attempt this move armed.
  retry_ordinal : Int
  decided_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartWorkflowSnapshot {
  workflow_id : @control.WorkflowId
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
  stage : PartWorkflowStage
  goal : @control.Goal
  part : @control.GoalPart
  task_contract : @control.TaskContractRevision
  task_contract_history : Array[@control.TaskContractRevision]
  part_context_manifest : @migration.PartContextManifest?
  identities : PartIdentityPlan
  /// Every provider surface this Part's captured contract admits, in the order
  /// the contract named them. The identity plan runs on one of these and
  /// recovery may move the next Take to another one; a Part admitted under a
  /// single surface therefore waits rather than changing provider authority.
  admitted_provider_surfaces : Array[@control.ProviderSurfaceId]
  /// Each surface change this Part made, oldest first.
  provider_failovers : Array[PartProviderFailover]
  implementation_take : @control.Take
  verification_take : @control.Take
  audit_take : @control.Take
  prior_takes : Array[@control.Take]
  prior_take_evidence : Array[PriorPartTakeEvidence]
  sandbox_leases : Array[@control.SandboxLease]
  harness_sessions : Array[@control.HarnessSession]
  harness_events : Array[@control.HarnessEventEnvelope]
  prepared_commands : Array[PartPreparedCommand]
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
  dispatch_diagnostic : PartDispatchDiagnostic?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PartConflictRepairDecision {
  PartConflictRepairPlanned(PartWorkflowSnapshot)
  PartConflictRepairLimitReached
} derive(Debug, Eq)

///|
pub(all) enum PartAuditRepairDecision {
  PartAuditRepairPlanned(PartWorkflowSnapshot)
  PartAuditRepairLimitReached
} derive(Debug, Eq)

///|
pub(all) enum PartVerificationRepairDecision {
  PartVerificationRepairPlanned(PartWorkflowSnapshot)
  PartVerificationRepairLimitReached
} derive(Debug, Eq)

///|
pub(all) enum PartOwnershipRepairDecision {
  PartOwnershipRepairPlanned(PartWorkflowSnapshot)
  PartOwnershipRepairLimitReached
} derive(Debug, Eq)

///|
pub(all) struct PartRepairRoute {
  part_id : @control.PartId
  affected_paths : Array[@control.RepoPath]
} derive(Debug, Eq)
