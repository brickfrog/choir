///|
pub(all) struct GoalBranchSealIntentId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct GoalBranchSealId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum GoalBranchSealFailureReason {
  GoalBranchSealHeadDiverged
  GoalBranchSealTreeDiverged
  GoalBranchSealReceiptSetChanged
  GoalBranchSealPolicyChanged
  GoalBranchSealWitnessConflict
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalBranchSealIntentLifecycle {
  GoalBranchSealPlanned
  GoalBranchSealAuthorized
  GoalBranchSealWitnessed
  GoalBranchSealed
  GoalBranchSealIntegrityBlocked(GoalBranchSealFailureReason)
  GoalBranchSealUncertain(GoalBranchSealFailureReason)
  GoalBranchSealAbandonedByCancellation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalBranchSealIntent {
  id : GoalBranchSealIntentId
  goal_id : GoalId
  expected_head_oid : GitOid
  expected_tree_oid : GitOid
  integration_receipt_set_digest : Digest
  assurance_policy_revision : RevisionId
  assurance_policy_digest : Digest
  seal_witness_ref : String
  idempotency_key : String
  lifecycle : GoalBranchSealIntentLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalBranchSeal {
  id : GoalBranchSealId
  intent_id : GoalBranchSealIntentId
  goal_id : GoalId
  seal_epoch : FencingEpoch
  goal_ref : String
  seal_witness_ref : String
  head_oid : GitOid
  tree_oid : GitOid
  goal_contract_digest : Digest
  assurance_policy_revision : RevisionId
  assurance_policy_digest : Digest
  integration_receipt_set_digest : Digest
  sealed_at : Int64
  seal_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalBranchSealWitnessObservation {
  GoalBranchSealWitnessApplied(GitOid, GitOid, GitOid)
  GoalBranchSealWitnessNotApplied(GitOid, GitOid)
  GoalBranchSealWitnessDiverged
  GoalBranchSealWitnessIntegrityError
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalBranchSealReconciliationOutcome {
  GoalBranchSealWitnessAccepted(GoalBranchSealIntent)
  GoalBranchSealRetryAuthorized
  GoalBranchSealReconciliationDiverged
  GoalBranchSealReconciliationIntegrityError
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalVerificationSubject {
  goal_id : GoalId
  goal_branch_seal_id : GoalBranchSealId
  goal_branch_seal_digest : Digest
  goal_head_oid : GitOid
  goal_tree_oid : GitOid
  goal_contract_digest : Digest
  assurance_policy_revision : RevisionId
  integration_receipt_set_digest : Digest
  subject_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalVerificationReceipt {
  receipt_id : ReceiptId
  verification_take_id : TakeId
  verification_execution_id : VerificationExecutionId
  subject : GoalVerificationSubject
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
pub(all) struct GoalVerificationAuthorizationSlot {
  subject_digest : Digest
  verification_spec : VerificationSpec
  lowest_admitted_execution_ordinal : Int
  authorizing_receipt_id : ReceiptId?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalVerificationAuthorizationSet {
  subject_digest : Digest
  receipt_ids : Array[ReceiptId]
  receipt_set_digest : Digest
  evidence_manifest_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAuditSubject {
  goal_id : GoalId
  goal_branch_seal_id : GoalBranchSealId
  goal_branch_seal_digest : Digest
  goal_head_oid : GitOid
  goal_tree_oid : GitOid
  goal_contract_digest : Digest
  assurance_policy_revision : RevisionId
  integration_receipt_set_digest : Digest
  goal_verification_receipt_set_digest : Digest
  goal_verification_evidence_manifest_digest : Digest
  subject_digest : Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAuditResult {
  id : AuditResultId
  audit_take_id : TakeId
  take_fencing_epoch : FencingEpoch
  audit_harness_session_id : HarnessSessionId
  subject : GoalAuditSubject
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
pub(all) struct GoalAuditReceipt {
  receipt_id : ReceiptId
  audit_result_id : AuditResultId
  audit_result_digest : Digest
  subject : GoalAuditSubject
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
