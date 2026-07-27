///| The identity of the durable value shapes this build can decode.
///
/// `@storage.decide_control_state` compares the generation recorded inside the
/// control store against the one this build reports. If they disagree the store
/// is destroyed, so the generation has to move exactly when the durable shapes
/// move — no sooner, and never later.
///
/// It used to be a hand-edited `choir-control-state-v8` string in the host
/// package. Deriving it from the SQL schema would have been worse than that:
/// the DDL is generic over record key, version, and value digest, so it does
/// not change when the value shapes do, and a generation that cannot change
/// never detects an incompatible store at all.
///
/// So the generation is derived from the shapes themselves. Every type that
/// reaches a durable record is instantiated once below and its serialized key
/// structure is digested. Adding a field to a stored record is a compile error
/// until the instance here is updated, and the digest then moves on its own.
///
/// What this covers, and how strongly:
///
/// * Struct fields. Record literals in MoonBit are exhaustive, so a new field
///   does not compile until it is given a value here, and the new JSON key
///   moves the digest. A removed or renamed field does the same. This one the
///   compiler proves.
/// * Enum variants. Each variant is named once in an array and once in an
///   exhaustive match, so a new variant does not compile until the match names
///   it. The array beside it is what the digest reads. They sit adjacent
///   because only the match is checked: the compiler stops the build, and the
///   edit it demands is right next to the list that has to grow with it.
/// * Whole record types. A new kind of record stored under its own
///   `@storage.StateRecordKey` has to be added to `durable_shape_table`.
///   Nothing forces that, which is why the test names every stored record.
///
/// What it does not cover: a change in the *meaning* of a field whose shape is
/// unchanged. No mechanical scheme can see that.
///
/// Placeholder values are fixed and empty on purpose. Only structure should be
/// able to move the digest, and an empty string cannot drift.

///|
let durable_shape_digest : @control.Digest = @control.Digest("")

///|
let durable_shape_goal_id : @control.GoalId = @control.GoalId("")

///|
let durable_shape_part_id : @control.PartId = @control.PartId("")

///|
let durable_shape_candidate_id : @control.CandidateId = @control.CandidateId("")

///|
let durable_shapes_part_block_reason : Array[@control.PartBlockReason] = [
  @control.PartBlockReason::PartDependencyBlocked,
  @control.PartBlockReason::PartVerificationFailed,
  @control.PartBlockReason::PartAuditFindings,
  @control.PartBlockReason::PartAuditUnavailable,
  @control.PartBlockReason::PartIntegrationConflict,
  @control.PartBlockReason::PartOwnershipViolation,
  @control.PartBlockReason::PartIntegrityBlocked,
  @control.PartBlockReason::PartRecoveryUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_part_block_reason(value : @control.PartBlockReason) -> Json {
  match value {
    PartDependencyBlocked
    | PartVerificationFailed
    | PartAuditFindings
    | PartAuditUnavailable
    | PartIntegrationConflict
    | PartOwnershipViolation
    | PartIntegrityBlocked
    | PartRecoveryUncertain => value.to_json()
  }
}

///|
let durable_shape_receipt_id : @control.ReceiptId = @control.ReceiptId("")

///|
let durable_shape_take_id : @control.TakeId = @control.TakeId("")

///|
let durable_shapes_part_lifecycle : Array[@control.PartLifecycle] = [
  @control.PartLifecycle::PartPending,
  @control.PartLifecycle::PartReady,
  @control.PartLifecycle::PartExecuting(durable_shape_take_id),
  @control.PartLifecycle::PartCandidate(durable_shape_candidate_id),
  @control.PartLifecycle::PartVerified(
    durable_shape_candidate_id, durable_shape_digest,
  ),
  @control.PartLifecycle::PartAudited(
    durable_shape_candidate_id, durable_shape_digest, durable_shape_receipt_id,
  ),
  @control.PartLifecycle::PartPromoting(
    durable_shape_candidate_id, durable_shape_digest, durable_shape_receipt_id,
  ),
  @control.PartLifecycle::PartIntegrated(durable_shape_receipt_id),
  @control.PartLifecycle::PartBlocked(durable_shapes_part_block_reason[0]),
  @control.PartLifecycle::PartCanceledNotRun,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_part_lifecycle(value : @control.PartLifecycle) -> Json {
  match value {
    PartPending
    | PartReady
    | PartExecuting(_)
    | PartCandidate(_)
    | PartVerified(_, _)
    | PartAudited(_, _, _)
    | PartPromoting(_, _, _)
    | PartIntegrated(_)
    | PartBlocked(_)
    | PartCanceledNotRun => value.to_json()
  }
}

///|
let durable_shape_revision_id : @control.RevisionId = @control.RevisionId("")

///|
let durable_shape_goal_part : @control.GoalPart = {
  id: durable_shape_part_id,
  goal_id: durable_shape_goal_id,
  dependency_ids: [durable_shape_part_id],
  task_contract_revision_id: durable_shape_revision_id,
  lifecycle: durable_shapes_part_lifecycle[0],
}

///|
let durable_shape_migration_contract_id : @control.MigrationContractId = @control.MigrationContractId(
  "",
)

///|
let durable_shape_migration_lineage_id : @control.MigrationLineageId = @control.MigrationLineageId(
  "",
)

///|
let durable_shape_migration_contract_ref : @control.MigrationContractRef = {
  contract_id: durable_shape_migration_contract_id,
  migration_lineage_id: durable_shape_migration_lineage_id,
  revision: 0,
  contract_artifact_digest: durable_shape_digest,
}

///|
let durable_shape_part_context_manifest : @migration.PartContextManifest = {
  migration_contract_ref: durable_shape_migration_contract_ref,
  part_task_contract_revision_id: durable_shape_revision_id,
  part_task_contract_digest: durable_shape_digest,
  context_assembly_policy_digest: durable_shape_digest,
  rulebook_section_digests: [durable_shape_digest],
  dependency_neighborhood_digest: durable_shape_digest,
  applicable_gap_entry_digests: [durable_shape_digest],
  source_path_manifest_digest: durable_shape_digest,
  prior_take_context_digest: Some(durable_shape_digest),
}

///|
let durable_shapes_provider_surface_id : Array[@control.ProviderSurfaceId] = [
  @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  @control.ProviderSurfaceId::CodexSubscriptionCli,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_provider_surface_id(
  value : @control.ProviderSurfaceId,
) -> Json {
  match value {
    ClaudeSubscriptionCli | CodexSubscriptionCli => value.to_json()
  }
}

///|
let durable_shape_artifact_reference : @control.ArtifactReference = {
  artifact_id: "",
  digest: durable_shape_digest,
}

///|
let durable_shapes_audit_repair_scope : Array[@control.AuditRepairScope] = [
  @control.AuditRepairScope::PartAuditRepair,
  @control.AuditRepairScope::GoalAuditRepair,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_audit_repair_scope(value : @control.AuditRepairScope) -> Json {
  match value {
    PartAuditRepair | GoalAuditRepair => value.to_json()
  }
}

///|
let durable_shape_audit_result_id : @control.AuditResultId = @control.AuditResultId(
  "",
)

///|
let durable_shape_repo_path : @control.RepoPath = @control.RepoPath("")

///|
let durable_shape_audit_repair_reference : @control.AuditRepairReference = {
  scope: durable_shapes_audit_repair_scope[0],
  audit_result_id: durable_shape_audit_result_id,
  audit_result_digest: durable_shape_digest,
  findings_artifact: durable_shape_artifact_reference,
  affected_paths: [durable_shape_repo_path],
}

///|
let durable_shape_git_oid : @control.GitOid = @control.GitOid("")

///|
let durable_shape_integration_conflict_id : @control.IntegrationConflictId = @control.IntegrationConflictId(
  "",
)

///|
let durable_shapes_mutation_claim : Array[@control.MutationClaim] = [
  @control.MutationClaim::ExactPath(durable_shape_repo_path),
  @control.MutationClaim::PathTree(durable_shape_repo_path),
  @control.MutationClaim::RepositoryWide,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_mutation_claim(value : @control.MutationClaim) -> Json {
  match value {
    ExactPath(_) | PathTree(_) | RepositoryWide => value.to_json()
  }
}

///|
let durable_shapes_unknown_mutation_reason : Array[
  @control.UnknownMutationReason,
] = [
  @control.UnknownMutationReason::SemanticScopeUnknown,
  @control.UnknownMutationReason::GeneratedOutputsUnknown,
  @control.UnknownMutationReason::RepositoryWideToolingUnknown,
  @control.UnknownMutationReason::ConductorCouldNotDetermine,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_unknown_mutation_reason(
  value : @control.UnknownMutationReason,
) -> Json {
  match value {
    SemanticScopeUnknown
    | GeneratedOutputsUnknown
    | RepositoryWideToolingUnknown
    | ConductorCouldNotDetermine => value.to_json()
  }
}

///|
let durable_shapes_mutation_declaration : Array[@control.MutationDeclaration] = [
  @control.MutationDeclaration::CompleteMutationDeclaration([
    durable_shapes_mutation_claim[0],
  ]),
  @control.MutationDeclaration::UnknownMutationDeclaration(
    durable_shapes_unknown_mutation_reason[0],
  ),
  @control.MutationDeclaration::MissingMutationDeclaration,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_mutation_declaration(
  value : @control.MutationDeclaration,
) -> Json {
  match value {
    CompleteMutationDeclaration(_)
    | UnknownMutationDeclaration(_)
    | MissingMutationDeclaration => value.to_json()
  }
}

///|
let durable_shapes_repository_path_mode : Array[@control.RepositoryPathMode] = [
  @control.RepositoryPathMode::CaseSensitiveNfc,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_repository_path_mode(
  value : @control.RepositoryPathMode,
) -> Json {
  match value {
    CaseSensitiveNfc => value.to_json()
  }
}

///|
let durable_shape_semantic_commit_title : @control.SemanticCommitTitle = @control.SemanticCommitTitle(
  "",
)

///|
let durable_shape_verification_execution_id : @control.VerificationExecutionId = @control.VerificationExecutionId(
  "",
)

///|
let durable_shapes_verification_repair_scope : Array[
  @control.VerificationRepairScope,
] = [
  @control.VerificationRepairScope::PartVerificationRepair,
  @control.VerificationRepairScope::GoalVerificationRepair,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_verification_repair_scope(
  value : @control.VerificationRepairScope,
) -> Json {
  match value {
    PartVerificationRepair | GoalVerificationRepair => value.to_json()
  }
}

///|
let durable_shape_verification_spec_id : @control.VerificationSpecId = @control.VerificationSpecId(
  "",
)

///|
let durable_shape_verification_spec : @control.VerificationSpec = {
  id: durable_shape_verification_spec_id,
  version: 0,
  digest: durable_shape_digest,
  process_spec_digest: durable_shape_digest,
}

///|
let durable_shape_verification_repair_reference : @control.VerificationRepairReference = {
  scope: durable_shapes_verification_repair_scope[0],
  receipt_id: durable_shape_receipt_id,
  verification_execution_id: durable_shape_verification_execution_id,
  subject_digest: durable_shape_digest,
  verification_spec: durable_shape_verification_spec,
  evidence_artifact: durable_shape_artifact_reference,
  affected_paths: [durable_shape_repo_path],
}

///|
let durable_shape_task_contract_revision : @control.TaskContractRevision = {
  id: durable_shape_revision_id,
  goal_id: durable_shape_goal_id,
  part_id: durable_shape_part_id,
  revision: 0,
  digest: durable_shape_digest,
  commit_title: durable_shape_semantic_commit_title,
  repair_conflict_id: Some(durable_shape_integration_conflict_id),
  repair_audit: Some(durable_shape_audit_repair_reference),
  repair_verification: Some(durable_shape_verification_repair_reference),
  instruction_artifact: durable_shape_artifact_reference,
  base_commit_oid: durable_shape_git_oid,
  base_tree_oid: durable_shape_git_oid,
  path_mode: durable_shapes_repository_path_mode[0],
  mutation_declaration: durable_shapes_mutation_declaration[0],
  verification_specs: [durable_shape_verification_spec],
  audit_policy_digest: durable_shape_digest,
  migration_contract_ref: Some(durable_shape_migration_contract_ref),
  migration_continuation_ref_digest: Some(durable_shape_digest),
  implementation_capability_profile_digest: durable_shape_digest,
  verification_capability_profile_digest: durable_shape_digest,
  audit_capability_profile_digest: durable_shape_digest,
}

///|
let durable_shape_accepted_goal_part : AcceptedGoalPart = {
  part: durable_shape_goal_part,
  source_revision_digest: durable_shape_digest,
  source_content_digest: durable_shape_digest,
  task_contract: durable_shape_task_contract_revision,
  provider_surface: durable_shapes_provider_surface_id[0],
  part_context_manifest: Some(durable_shape_part_context_manifest),
}

///|
let durable_shapes_audit_gate_corruption_reason : Array[
  @control.AuditGateCorruptionReason,
] = [
  @control.AuditGateCorruptionReason::AuditResultMismatch,
  @control.AuditGateCorruptionReason::AuditArtifactMissing,
  @control.AuditGateCorruptionReason::AuditReceiptProtocolViolation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_audit_gate_corruption_reason(
  value : @control.AuditGateCorruptionReason,
) -> Json {
  match value {
    AuditResultMismatch
    | AuditArtifactMissing
    | AuditReceiptProtocolViolation => value.to_json()
  }
}

///|
let durable_shapes_audit_gate_rejection_reason : Array[
  @control.AuditGateRejectionReason,
] = [
  @control.AuditGateRejectionReason::AuditOutcomeNotPassing,
  @control.AuditGateRejectionReason::AuditHasBlockingFindings,
  @control.AuditGateRejectionReason::AuditNotIndependent,
  @control.AuditGateRejectionReason::AuditSessionNotCleanlyClosed,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_audit_gate_rejection_reason(
  value : @control.AuditGateRejectionReason,
) -> Json {
  match value {
    AuditOutcomeNotPassing
    | AuditHasBlockingFindings
    | AuditNotIndependent
    | AuditSessionNotCleanlyClosed => value.to_json()
  }
}

///|
let durable_shapes_audit_gate_stale_reason : Array[
  @control.AuditGateStaleReason,
] = [
  @control.AuditGateStaleReason::AuditStaleSubject,
  @control.AuditGateStaleReason::AuditStalePolicy,
  @control.AuditGateStaleReason::AuditStaleCapabilityProfile,
  @control.AuditGateStaleReason::AuditStaleProviderConformance,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_audit_gate_stale_reason(
  value : @control.AuditGateStaleReason,
) -> Json {
  match value {
    AuditStaleSubject
    | AuditStalePolicy
    | AuditStaleCapabilityProfile
    | AuditStaleProviderConformance => value.to_json()
  }
}

///|
let durable_shapes_audit_gate_observation : Array[@control.AuditGateObservation] = [
  @control.AuditGateObservation::AuditGateMissing,
  @control.AuditGateObservation::AuditGateValid(durable_shape_receipt_id),
  @control.AuditGateObservation::AuditGateStale(
    durable_shapes_audit_gate_stale_reason[0],
  ),
  @control.AuditGateObservation::AuditGateRejected(
    durable_shapes_audit_gate_rejection_reason[0],
  ),
  @control.AuditGateObservation::AuditGateCorrupt(
    durable_shapes_audit_gate_corruption_reason[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_audit_gate_observation(
  value : @control.AuditGateObservation,
) -> Json {
  match value {
    AuditGateMissing
    | AuditGateValid(_)
    | AuditGateStale(_)
    | AuditGateRejected(_)
    | AuditGateCorrupt(_) => value.to_json()
  }
}

///|
let durable_shapes_audit_outcome : Array[@control.AuditOutcome] = [
  @control.AuditOutcome::AuditPassed,
  @control.AuditOutcome::AuditFindings,
  @control.AuditOutcome::AuditFailed,
  @control.AuditOutcome::AuditInterrupted,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_audit_outcome(value : @control.AuditOutcome) -> Json {
  match value {
    AuditPassed | AuditFindings | AuditFailed | AuditInterrupted =>
      value.to_json()
  }
}

///|
let durable_shape_harness_session_id : @control.HarnessSessionId = @control.HarnessSessionId(
  "",
)

///|
let durable_shapes_model_identity : Array[@control.ModelIdentity] = [
  @control.ModelIdentity::ReportedModelIdentity(""),
  @control.ModelIdentity::UnreportedModelIdentity,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_model_identity(value : @control.ModelIdentity) -> Json {
  match value {
    ReportedModelIdentity(_) | UnreportedModelIdentity => value.to_json()
  }
}

///|
let durable_shape_part_audit_subject : @control.PartAuditSubject = {
  part_id: durable_shape_part_id,
  candidate_take_id: durable_shape_take_id,
  candidate_commit_oid: durable_shape_git_oid,
  candidate_tree_oid: durable_shape_git_oid,
  task_contract_revision_id: durable_shape_revision_id,
  task_contract_digest: durable_shape_digest,
  verification_receipt_set_digest: durable_shape_digest,
  verification_evidence_manifest_digest: durable_shape_digest,
  subject_digest: durable_shape_digest,
}

///|
let durable_shape_sandbox_generation_id : @control.SandboxGenerationId = @control.SandboxGenerationId(
  "",
)

///|
let durable_shape_audit_receipt : @control.AuditReceipt = {
  receipt_id: durable_shape_receipt_id,
  audit_result_id: durable_shape_audit_result_id,
  audit_result_digest: durable_shape_digest,
  subject: durable_shape_part_audit_subject,
  audit_take_id: durable_shape_take_id,
  audit_harness_session_id: durable_shape_harness_session_id,
  audit_sandbox_generation_id: durable_shape_sandbox_generation_id,
  auditor_capability_profile_digest: durable_shape_digest,
  provider_surface_id: durable_shapes_provider_surface_id[0],
  provider_identity: "",
  model_identity: durable_shapes_model_identity[0],
  provider_conformance_report_digest: durable_shape_digest,
  audit_policy_digest: durable_shape_digest,
  findings_artifact: Some(durable_shape_artifact_reference),
  total_findings_count: 0,
  blocking_findings_count: 0,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_audit_outcome[0],
}

///|
let durable_shape_fencing_epoch : @control.FencingEpoch = @control.FencingEpoch(
  0L,
)

///|
let durable_shape_audit_result : @control.AuditResult = {
  id: durable_shape_audit_result_id,
  audit_take_id: durable_shape_take_id,
  take_fencing_epoch: durable_shape_fencing_epoch,
  audit_harness_session_id: durable_shape_harness_session_id,
  subject: durable_shape_part_audit_subject,
  auditor_capability_profile_digest: durable_shape_digest,
  effective_surface_manifest_digest: durable_shape_digest,
  provider_conformance_report_digest: durable_shape_digest,
  audit_policy_digest: durable_shape_digest,
  findings_artifact: Some(durable_shape_artifact_reference),
  total_findings_count: 0,
  blocking_findings_count: 0,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_audit_outcome[0],
  result_digest: durable_shape_digest,
}

///|
let durable_shape_audit_submission : AuditSubmission = {
  audit_take_id: durable_shape_take_id,
  take_fencing_epoch: durable_shape_fencing_epoch,
  audit_harness_session_id: durable_shape_harness_session_id,
  subject: durable_shape_part_audit_subject,
  provider_conformance_report_digest: durable_shape_digest,
  findings_artifact: Some(durable_shape_artifact_reference),
  total_findings_count: 0,
  blocking_findings_count: 0,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_audit_outcome[0],
}

///|
let durable_shape_branch_publication_intent_id : BranchPublicationIntentId = BranchPublicationIntentId(
  "",
)

///|
let durable_shapes_branch_publication_state : Array[BranchPublicationState] = [
  BranchPublicationState::BranchPublicationPlanned,
  BranchPublicationState::BranchPublicationAuthorized,
  BranchPublicationState::BranchPublicationReceipted,
  BranchPublicationState::BranchPublicationDrift,
  BranchPublicationState::BranchPublicationPreflightUncertain,
  BranchPublicationState::BranchPublicationMutationUncertain,
  BranchPublicationState::BranchPublicationAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_branch_publication_state(
  value : BranchPublicationState,
) -> Json {
  match value {
    BranchPublicationPlanned
    | BranchPublicationAuthorized
    | BranchPublicationReceipted
    | BranchPublicationDrift
    | BranchPublicationPreflightUncertain
    | BranchPublicationMutationUncertain
    | BranchPublicationAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shape_git_ref_name : GitRefName = GitRefName("")

///|
let durable_shape_goal_branch_seal_id : @control.GoalBranchSealId = @control.GoalBranchSealId(
  "",
)

///|
let durable_shape_remote_name : RemoteName = RemoteName("")

///|
let durable_shape_remote_repository_id : RemoteRepositoryId = RemoteRepositoryId(
  "",
)

///|
let durable_shape_branch_publication_intent : BranchPublicationIntent = {
  id: durable_shape_branch_publication_intent_id,
  goal_id: durable_shape_goal_id,
  canonical_repository_id: durable_shape_remote_repository_id,
  remote_name: durable_shape_remote_name,
  remote_head_ref: durable_shape_git_ref_name,
  expected_prior_remote_oid: Some(durable_shape_git_oid),
  sealed_head_oid: durable_shape_git_oid,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  idempotency_key: "",
  state: durable_shapes_branch_publication_state[0],
}

///|
let durable_shapes_branch_publication_receipt_origin : Array[
  BranchPublicationReceiptOrigin,
] = [
  BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
  BranchPublicationReceiptOrigin::BranchPublicationAdopted,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_branch_publication_receipt_origin(
  value : BranchPublicationReceiptOrigin,
) -> Json {
  match value {
    BranchPublicationMutationApplied | BranchPublicationAdopted =>
      value.to_json()
  }
}

///|
let durable_shape_branch_publication_receipt : BranchPublicationReceipt = {
  receipt_id: durable_shape_receipt_id,
  intent_id: durable_shape_branch_publication_intent_id,
  idempotency_key: "",
  canonical_repository_id: durable_shape_remote_repository_id,
  remote_head_ref: durable_shape_git_ref_name,
  prior_remote_oid: Some(durable_shape_git_oid),
  published_oid: durable_shape_git_oid,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  origin: durable_shapes_branch_publication_receipt_origin[0],
  observed_at: 0L,
}

///|
let durable_shape_cancellation_summary_id : @control.CancellationSummaryId = @control.CancellationSummaryId(
  "",
)

///|
let durable_shape_candidate_commit : @control.CandidateCommit = {
  id: durable_shape_candidate_id,
  goal_id: durable_shape_goal_id,
  part_id: durable_shape_part_id,
  take_id: durable_shape_take_id,
  base_commit_oid: durable_shape_git_oid,
  commit_oid: durable_shape_git_oid,
  tree_oid: durable_shape_git_oid,
  canonical_change_digest: durable_shape_digest,
  changed_paths: [durable_shape_repo_path],
}

///|
let durable_shape_candidate_path_evidence : @control.CandidatePathEvidence = {
  candidate_tree_paths: [durable_shape_repo_path],
  symlink_prefix_paths: [durable_shape_repo_path],
  normalization_collision_paths: [durable_shape_repo_path],
}

///|
let durable_shapes_command_execution_subject : Array[
  @command.CommandExecutionSubject,
] = [
  @command.CommandExecutionSubject::ImplementationCommandSubject(
    durable_shape_part_id, durable_shape_revision_id, durable_shape_digest,
  ),
  @command.CommandExecutionSubject::PartAuditCommandSubject(
    durable_shape_part_audit_subject,
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_command_execution_subject(
  value : @command.CommandExecutionSubject,
) -> Json {
  match value {
    ImplementationCommandSubject(_, _, _) | PartAuditCommandSubject(_) =>
      value.to_json()
  }
}

///|
let durable_shape_command_preparation_provenance : @command.CommandPreparationProvenance = {
  schema_version: 0,
  take_id: durable_shape_take_id,
  take_purpose_digest: durable_shape_digest,
  subject_digest: durable_shape_digest,
  goal_contract_digest: durable_shape_digest,
  task_contract_revision_id: durable_shape_revision_id,
  task_contract_digest: durable_shape_digest,
  migration_contract_ref: Some(durable_shape_migration_contract_ref),
  template_digest: durable_shape_digest,
  provider_surface: durable_shapes_provider_surface_id[0],
  provider_surface_and_profile_digest: durable_shape_digest,
  context_assembly_policy_digest: durable_shape_digest,
  context_manifest_digest: Some(durable_shape_digest),
  context_projection_digest: durable_shape_digest,
  maximum_command_bytes: 0,
  command_artifact_digest: durable_shape_digest,
  command_byte_length: 0,
}

///|
let durable_shapes_command_role : Array[@command.CommandRole] = [
  @command.CommandRole::ImplementationCommand,
  @command.CommandRole::PartAuditCommand,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_command_role(value : @command.CommandRole) -> Json {
  match value {
    ImplementationCommand | PartAuditCommand => value.to_json()
  }
}

///|
let durable_shape_conductor_part_proposal : ConductorPartProposal = {
  part_id: durable_shape_part_id,
  source_revision_digest: durable_shape_digest,
  source_content_digest: durable_shape_digest,
  dependency_ids: [durable_shape_part_id],
  task_contract: durable_shape_task_contract_revision,
  provider_surface: durable_shapes_provider_surface_id[0],
  part_context_manifest: Some(durable_shape_part_context_manifest),
}

///|
let durable_shape_effect_id : @control.EffectId = @control.EffectId("")

///|
let durable_shapes_event_redaction_state : Array[@control.EventRedactionState] = [
  @control.EventRedactionState::EventNotSensitive,
  @control.EventRedactionState::EventRedacted,
  @control.EventRedactionState::EventWithheld,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_event_redaction_state(
  value : @control.EventRedactionState,
) -> Json {
  match value {
    EventNotSensitive | EventRedacted | EventWithheld => value.to_json()
  }
}

///|
let durable_shape_event_sequence : @control.EventSequence = @control.EventSequence(
  0L,
)

///|
let durable_shapes_event_source_position : Array[@control.EventSourcePosition] = [
  @control.EventSourcePosition::EventProviderId(""),
  @control.EventSourcePosition::EventProviderCursorTransition("", ""),
  @control.EventSourcePosition::EventNonResumableOrdinal("", 0),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_event_source_position(
  value : @control.EventSourcePosition,
) -> Json {
  match value {
    EventProviderId(_)
    | EventProviderCursorTransition(_, _)
    | EventNonResumableOrdinal(_, _) => value.to_json()
  }
}

///|
let durable_shape_finalization_id : @control.FinalizationId = @control.FinalizationId(
  "",
)

///|
let durable_shapes_goal_active_condition : Array[@control.GoalActiveCondition] = [
  @control.GoalActiveCondition::GoalRunning,
  @control.GoalActiveCondition::GoalNeedsInput,
  @control.GoalActiveCondition::GoalDrift,
  @control.GoalActiveCondition::GoalAmbiguous,
  @control.GoalActiveCondition::GoalIntegrityBlocked,
  @control.GoalActiveCondition::GoalRecoveryUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_active_condition(
  value : @control.GoalActiveCondition,
) -> Json {
  match value {
    GoalRunning
    | GoalNeedsInput
    | GoalDrift
    | GoalAmbiguous
    | GoalIntegrityBlocked
    | GoalRecoveryUncertain => value.to_json()
  }
}

///|
let durable_shapes_goal_lifecycle : Array[@control.GoalLifecycle] = [
  @control.GoalLifecycle::GoalActive(durable_shapes_goal_active_condition[0]),
  @control.GoalLifecycle::GoalCanceling(durable_shape_event_sequence),
  @control.GoalLifecycle::GoalSucceeded(durable_shape_finalization_id),
  @control.GoalLifecycle::GoalCanceled(durable_shape_cancellation_summary_id),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_lifecycle(value : @control.GoalLifecycle) -> Json {
  match value {
    GoalActive(_) | GoalCanceling(_) | GoalSucceeded(_) | GoalCanceled(_) =>
      value.to_json()
  }
}

///|
let durable_shape_goal : @control.Goal = {
  id: durable_shape_goal_id,
  contract_digest: durable_shape_digest,
  lifecycle: durable_shapes_goal_lifecycle[0],
}

///|
let durable_shapes_verification_gate_corruption_reason : Array[
  @control.VerificationGateCorruptionReason,
] = [
  @control.VerificationGateCorruptionReason::VerificationDuplicateSlot,
  @control.VerificationGateCorruptionReason::VerificationDuplicateReceipt,
  @control.VerificationGateCorruptionReason::VerificationEvidenceMissing,
  @control.VerificationGateCorruptionReason::VerificationReceiptProtocolViolation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_verification_gate_corruption_reason(
  value : @control.VerificationGateCorruptionReason,
) -> Json {
  match value {
    VerificationDuplicateSlot
    | VerificationDuplicateReceipt
    | VerificationEvidenceMissing
    | VerificationReceiptProtocolViolation => value.to_json()
  }
}

///|
let durable_shapes_verification_gate_rejection_reason : Array[
  @control.VerificationGateRejectionReason,
] = [
  @control.VerificationGateRejectionReason::VerificationMissingSlot,
  @control.VerificationGateRejectionReason::VerificationMissingReceipt,
  @control.VerificationGateRejectionReason::VerificationOutcomeNotPassing,
  @control.VerificationGateRejectionReason::VerificationTreeChanged,
  @control.VerificationGateRejectionReason::VerificationSessionNotCleanlyClosed,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_verification_gate_rejection_reason(
  value : @control.VerificationGateRejectionReason,
) -> Json {
  match value {
    VerificationMissingSlot
    | VerificationMissingReceipt
    | VerificationOutcomeNotPassing
    | VerificationTreeChanged
    | VerificationSessionNotCleanlyClosed => value.to_json()
  }
}

///|
let durable_shapes_verification_gate_stale_reason : Array[
  @control.VerificationGateStaleReason,
] = [
  @control.VerificationGateStaleReason::VerificationStaleSubject,
  @control.VerificationGateStaleReason::VerificationStaleSpec,
  @control.VerificationGateStaleReason::VerificationStaleEnvironment,
  @control.VerificationGateStaleReason::VerificationStaleRuntime,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_verification_gate_stale_reason(
  value : @control.VerificationGateStaleReason,
) -> Json {
  match value {
    VerificationStaleSubject
    | VerificationStaleSpec
    | VerificationStaleEnvironment
    | VerificationStaleRuntime => value.to_json()
  }
}

///|
let durable_shapes_verification_gate_observation : Array[
  @control.VerificationGateObservation,
] = [
  @control.VerificationGateObservation::VerificationGateValid([
    durable_shape_receipt_id,
  ]),
  @control.VerificationGateObservation::VerificationGateStale(
    durable_shapes_verification_gate_stale_reason[0],
  ),
  @control.VerificationGateObservation::VerificationGateRejected(
    durable_shapes_verification_gate_rejection_reason[0],
  ),
  @control.VerificationGateObservation::VerificationGateCorrupt(
    durable_shapes_verification_gate_corruption_reason[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_verification_gate_observation(
  value : @control.VerificationGateObservation,
) -> Json {
  match value {
    VerificationGateValid(_)
    | VerificationGateStale(_)
    | VerificationGateRejected(_)
    | VerificationGateCorrupt(_) => value.to_json()
  }
}

///|
let durable_shapes_goal_assurance_block_reason : Array[GoalAssuranceBlockReason] = [
  GoalAssuranceBlockReason::GoalAssuranceVerificationBlocked(
    durable_shapes_verification_gate_observation[0],
  ),
  GoalAssuranceBlockReason::GoalAssuranceAuditBlocked(
    durable_shapes_audit_gate_observation[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_assurance_block_reason(
  value : GoalAssuranceBlockReason,
) -> Json {
  match value {
    GoalAssuranceVerificationBlocked(_) | GoalAssuranceAuditBlocked(_) =>
      value.to_json()
  }
}

///|
let durable_shape_goal_audit_subject : @control.GoalAuditSubject = {
  goal_id: durable_shape_goal_id,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  goal_head_oid: durable_shape_git_oid,
  goal_tree_oid: durable_shape_git_oid,
  goal_contract_digest: durable_shape_digest,
  assurance_policy_revision: durable_shape_revision_id,
  integration_receipt_set_digest: durable_shape_digest,
  goal_verification_receipt_set_digest: durable_shape_digest,
  goal_verification_evidence_manifest_digest: durable_shape_digest,
  subject_digest: durable_shape_digest,
}

///|
let durable_shape_goal_verification_subject : @control.GoalVerificationSubject = {
  goal_id: durable_shape_goal_id,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  goal_head_oid: durable_shape_git_oid,
  goal_tree_oid: durable_shape_git_oid,
  goal_contract_digest: durable_shape_digest,
  assurance_policy_revision: durable_shape_revision_id,
  integration_receipt_set_digest: durable_shape_digest,
  subject_digest: durable_shape_digest,
}

///|
let durable_shapes_harness_cursor_class : Array[@control.HarnessCursorClass] = [
  @control.HarnessCursorClass::HarnessCursorNotResumable,
  @control.HarnessCursorClass::HarnessCursorProviderEventId,
  @control.HarnessCursorClass::HarnessCursorTransition,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_harness_cursor_class(
  value : @control.HarnessCursorClass,
) -> Json {
  match value {
    HarnessCursorNotResumable
    | HarnessCursorProviderEventId
    | HarnessCursorTransition => value.to_json()
  }
}

///|
let durable_shapes_harness_terminal_observation : Array[
  @control.HarnessTerminalObservation,
] = [
  @control.HarnessTerminalObservation::HarnessCompleted,
  @control.HarnessTerminalObservation::HarnessFailed,
  @control.HarnessTerminalObservation::HarnessInterrupted,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_harness_terminal_observation(
  value : @control.HarnessTerminalObservation,
) -> Json {
  match value {
    HarnessCompleted | HarnessFailed | HarnessInterrupted => value.to_json()
  }
}

///|
let durable_shapes_harness_session_lifecycle : Array[
  @control.HarnessSessionLifecycle,
] = [
  @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  @control.HarnessSessionLifecycle::HarnessSessionRunning,
  @control.HarnessSessionLifecycle::HarnessSessionTerminalObserved(
    durable_shapes_harness_terminal_observation[0],
  ),
  @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
    durable_shapes_harness_terminal_observation[0],
  ),
  @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated,
  @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_harness_session_lifecycle(
  value : @control.HarnessSessionLifecycle,
) -> Json {
  match value {
    HarnessSessionPlanned
    | HarnessSessionAwaitingEvents
    | HarnessSessionRunning
    | HarnessSessionTerminalObserved(_)
    | HarnessSessionIngestionClosedCleanly(_)
    | HarnessSessionProtocolViolated
    | HarnessSessionRecoveryUncertain => value.to_json()
  }
}

///|
let durable_shape_take_usage : @control.TakeUsage = {
  input_tokens: 0,
  output_tokens: 0,
  cache_read_tokens: 0,
  cache_creation_tokens: 0,
  wall_time_ms: 0,
}

///|
let durable_shape_harness_session : @control.HarnessSession = {
  id: durable_shape_harness_session_id,
  take_id: durable_shape_take_id,
  sandbox_generation_id: durable_shape_sandbox_generation_id,
  surface: durable_shapes_provider_surface_id[0],
  effective_surface_manifest_digest: durable_shape_digest,
  cursor_class: durable_shapes_harness_cursor_class[0],
  provider_cursor: Some(""),
  last_choir_sequence: durable_shape_event_sequence,
  open_tool_execution_ids: [""],
  lifecycle: durable_shapes_harness_session_lifecycle[0],
  usage: Some(durable_shape_take_usage),
}

///|
let durable_shape_sandbox_lease_id : @control.SandboxLeaseId = @control.SandboxLeaseId(
  "",
)

///|
let durable_shapes_sandbox_lease_lifecycle : Array[
  @control.SandboxLeaseLifecycle,
] = [
  @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  @control.SandboxLeaseLifecycle::SandboxLeaseActive,
  @control.SandboxLeaseLifecycle::SandboxLeaseReleased,
  @control.SandboxLeaseLifecycle::SandboxLeaseUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_sandbox_lease_lifecycle(
  value : @control.SandboxLeaseLifecycle,
) -> Json {
  match value {
    SandboxLeasePlanned
    | SandboxLeaseActive
    | SandboxLeaseReleased
    | SandboxLeaseUncertain => value.to_json()
  }
}

///|
let durable_shape_sandbox_lease : @control.SandboxLease = {
  id: durable_shape_sandbox_lease_id,
  take_id: durable_shape_take_id,
  generation_id: durable_shape_sandbox_generation_id,
  capability_profile_digest: durable_shape_digest,
  runtime_policy_digest: durable_shape_digest,
  lifecycle: durable_shapes_sandbox_lease_lifecycle[0],
}

///|
let durable_shapes_goal_assurance_effect_kind : Array[GoalAssuranceEffectKind] = [
  GoalAssuranceEffectKind::PrepareGoalVerificationSandbox(
    durable_shape_sandbox_lease,
  ),
  GoalAssuranceEffectKind::DispatchGoalVerification(
    durable_shape_take_id, durable_shape_goal_verification_subject,
  ),
  GoalAssuranceEffectKind::PrepareGoalAuditSandbox(durable_shape_sandbox_lease),
  GoalAssuranceEffectKind::StartGoalAuditHarness(durable_shape_harness_session),
  GoalAssuranceEffectKind::DispatchGoalAudit(
    durable_shape_take_id, durable_shape_harness_session_id, durable_shape_goal_audit_subject,
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_assurance_effect_kind(
  value : GoalAssuranceEffectKind,
) -> Json {
  match value {
    PrepareGoalVerificationSandbox(_)
    | DispatchGoalVerification(_, _)
    | PrepareGoalAuditSandbox(_)
    | StartGoalAuditHarness(_)
    | DispatchGoalAudit(_, _, _) => value.to_json()
  }
}

///|
let durable_shapes_goal_assurance_effect_lifecycle : Array[
  GoalAssuranceEffectLifecycle,
] = [
  GoalAssuranceEffectLifecycle::GoalAssuranceEffectPlanned,
  GoalAssuranceEffectLifecycle::GoalAssuranceEffectMayHaveOccurred,
  GoalAssuranceEffectLifecycle::GoalAssuranceEffectReceipted,
  GoalAssuranceEffectLifecycle::GoalAssuranceEffectUncertain,
  GoalAssuranceEffectLifecycle::GoalAssuranceEffectAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_assurance_effect_lifecycle(
  value : GoalAssuranceEffectLifecycle,
) -> Json {
  match value {
    GoalAssuranceEffectPlanned
    | GoalAssuranceEffectMayHaveOccurred
    | GoalAssuranceEffectReceipted
    | GoalAssuranceEffectUncertain
    | GoalAssuranceEffectAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shape_goal_assurance_effect_intent : GoalAssuranceEffectIntent = {
  effect_id: durable_shape_effect_id,
  kind: durable_shapes_goal_assurance_effect_kind[0],
  request_digest: durable_shape_digest,
  lifecycle: durable_shapes_goal_assurance_effect_lifecycle[0],
}

///|
let durable_shape_goal_audit_submission : GoalAuditSubmission = {
  audit_take_id: durable_shape_take_id,
  take_fencing_epoch: durable_shape_fencing_epoch,
  audit_harness_session_id: durable_shape_harness_session_id,
  subject: durable_shape_goal_audit_subject,
  provider_conformance_report_digest: durable_shape_digest,
  findings_artifact: Some(durable_shape_artifact_reference),
  total_findings_count: 0,
  blocking_findings_count: 0,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_audit_outcome[0],
}

///|
let durable_shapes_verification_outcome : Array[@control.VerificationOutcome] = [
  @control.VerificationOutcome::VerificationPassed,
  @control.VerificationOutcome::VerificationFailed,
  @control.VerificationOutcome::VerificationErrored,
  @control.VerificationOutcome::VerificationInterrupted,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_verification_outcome(
  value : @control.VerificationOutcome,
) -> Json {
  match value {
    VerificationPassed
    | VerificationFailed
    | VerificationErrored
    | VerificationInterrupted => value.to_json()
  }
}

///|
let durable_shape_goal_verification_spec_execution : GoalVerificationSpecExecution = {
  verification_execution_id: durable_shape_verification_execution_id,
  verification_spec: durable_shape_verification_spec,
  environment_and_image_digest: durable_shape_digest,
  runtime_and_policy_digest: durable_shape_digest,
  subject_pre_tree_oid: durable_shape_git_oid,
  subject_post_tree_oid: durable_shape_git_oid,
  evidence: durable_shape_artifact_reference,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_verification_outcome[0],
}

///|
let durable_shape_goal_verification_execution_result : GoalVerificationExecutionResult = {
  take_id: durable_shape_take_id,
  subject: durable_shape_goal_verification_subject,
  executions: [durable_shape_goal_verification_spec_execution],
  evidence_manifest: durable_shape_artifact_reference,
}

///|
let durable_shape_harness_event_id : @control.HarnessEventId = @control.HarnessEventId(
  "",
)

///|
let durable_shapes_harness_tool_disposition : Array[
  @control.HarnessToolDisposition,
] = [
  @control.HarnessToolDisposition::HarnessToolSucceeded,
  @control.HarnessToolDisposition::HarnessToolFailed,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_harness_tool_disposition(
  value : @control.HarnessToolDisposition,
) -> Json {
  match value {
    HarnessToolSucceeded | HarnessToolFailed => value.to_json()
  }
}

///|
let durable_shapes_harness_event_kind : Array[@control.HarnessEventKind] = [
  @control.HarnessEventKind::HarnessStarted,
  @control.HarnessEventKind::HarnessToolStarted(""),
  @control.HarnessEventKind::HarnessToolFinished(
    "",
    durable_shapes_harness_tool_disposition[0],
  ),
  @control.HarnessEventKind::HarnessTerminal(
    durable_shapes_harness_terminal_observation[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_harness_event_kind(value : @control.HarnessEventKind) -> Json {
  match value {
    HarnessStarted
    | HarnessToolStarted(_)
    | HarnessToolFinished(_, _)
    | HarnessTerminal(_) => value.to_json()
  }
}

///|
let durable_shape_harness_event_envelope : @control.HarnessEventEnvelope = {
  id: durable_shape_harness_event_id,
  take_id: durable_shape_take_id,
  session_id: durable_shape_harness_session_id,
  source_position: durable_shapes_event_source_position[0],
  choir_sequence: durable_shape_event_sequence,
  observed_at: 0L,
  kind: durable_shapes_harness_event_kind[0],
  sanitized_payload_digest: durable_shape_digest,
  redaction_state: durable_shapes_event_redaction_state[0],
  late: false,
}

///|
let durable_shapes_goal_assurance_effect_observation : Array[
  GoalAssuranceEffectObservation,
] = [
  GoalAssuranceEffectObservation::GoalVerificationSandboxPrepared(
    durable_shape_sandbox_lease,
  ),
  GoalAssuranceEffectObservation::GoalVerificationCompleted(
    durable_shape_goal_verification_execution_result,
  ),
  GoalAssuranceEffectObservation::GoalAuditSandboxPrepared(
    durable_shape_sandbox_lease,
  ),
  GoalAssuranceEffectObservation::GoalAuditHarnessStarted(
    durable_shape_harness_session,
  ),
  GoalAssuranceEffectObservation::GoalAuditCompleted(
    durable_shape_goal_audit_submission,
    durable_shape_harness_session,
    [durable_shape_harness_event_envelope],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_assurance_effect_observation(
  value : GoalAssuranceEffectObservation,
) -> Json {
  match value {
    GoalVerificationSandboxPrepared(_)
    | GoalVerificationCompleted(_)
    | GoalAuditSandboxPrepared(_)
    | GoalAuditHarnessStarted(_)
    | GoalAuditCompleted(_, _, _) => value.to_json()
  }
}

///|
let durable_shape_goal_assurance_effect_receipt : GoalAssuranceEffectReceipt = {
  effect_id: durable_shape_effect_id,
  request_digest: durable_shape_digest,
  observation_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shape_goal_assurance_effect_witness : GoalAssuranceEffectWitness = {
  effect_id: durable_shape_effect_id,
  request_digest: durable_shape_digest,
  observation: durable_shapes_goal_assurance_effect_observation[0],
  observation_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shapes_take_failure_reason : Array[@control.TakeFailureReason] = [
  @control.TakeFailureReason::TakeProviderFailed,
  @control.TakeFailureReason::TakeVerificationFailed,
  @control.TakeFailureReason::TakeAuditFindings,
  @control.TakeFailureReason::TakePolicyRejected,
  @control.TakeFailureReason::TakeResourceLimit,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_take_failure_reason(
  value : @control.TakeFailureReason,
) -> Json {
  match value {
    TakeProviderFailed
    | TakeVerificationFailed
    | TakeAuditFindings
    | TakePolicyRejected
    | TakeResourceLimit => value.to_json()
  }
}

///|
let durable_shapes_take_uncertainty_reason : Array[
  @control.TakeUncertaintyReason,
] = [
  @control.TakeUncertaintyReason::TakeLeaseLost,
  @control.TakeUncertaintyReason::TakeCursorGap,
  @control.TakeUncertaintyReason::TakeEventConflict,
  @control.TakeUncertaintyReason::TakeEffectUncertain,
  @control.TakeUncertaintyReason::TakeProtocolViolation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_take_uncertainty_reason(
  value : @control.TakeUncertaintyReason,
) -> Json {
  match value {
    TakeLeaseLost
    | TakeCursorGap
    | TakeEventConflict
    | TakeEffectUncertain
    | TakeProtocolViolation => value.to_json()
  }
}

///|
let durable_shapes_take_terminal_disposition : Array[
  @control.TakeTerminalDisposition,
] = [
  @control.TakeTerminalDisposition::TakeSucceeded,
  @control.TakeTerminalDisposition::TakeFailed(
    durable_shapes_take_failure_reason[0],
  ),
  @control.TakeTerminalDisposition::TakeInterrupted,
  @control.TakeTerminalDisposition::TakeRecoveryUncertain(
    durable_shapes_take_uncertainty_reason[0],
  ),
  @control.TakeTerminalDisposition::TakeCanceled,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_take_terminal_disposition(
  value : @control.TakeTerminalDisposition,
) -> Json {
  match value {
    TakeSucceeded
    | TakeFailed(_)
    | TakeInterrupted
    | TakeRecoveryUncertain(_)
    | TakeCanceled => value.to_json()
  }
}

///|
let durable_shapes_take_lifecycle : Array[@control.TakeLifecycle] = [
  @control.TakeLifecycle::TakePlanned,
  @control.TakeLifecycle::TakeLeased,
  @control.TakeLifecycle::TakeRunning,
  @control.TakeLifecycle::TakeResultRecorded(durable_shape_digest),
  @control.TakeLifecycle::TakeTerminal(
    durable_shapes_take_terminal_disposition[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_take_lifecycle(value : @control.TakeLifecycle) -> Json {
  match value {
    TakePlanned
    | TakeLeased
    | TakeRunning
    | TakeResultRecorded(_)
    | TakeTerminal(_) => value.to_json()
  }
}

///|
let durable_shapes_take_purpose : Array[@control.TakePurpose] = [
  @control.TakePurpose::Implementation(
    durable_shape_part_id, durable_shape_revision_id,
  ),
  @control.TakePurpose::PartVerification(
    durable_shape_part_id, durable_shape_take_id, durable_shape_digest,
  ),
  @control.TakePurpose::PartAudit(
    durable_shape_part_id, durable_shape_take_id, durable_shape_digest,
  ),
  @control.TakePurpose::GoalVerification(
    durable_shape_goal_id, durable_shape_git_oid, durable_shape_digest,
  ),
  @control.TakePurpose::GoalAudit(durable_shape_goal_id, durable_shape_digest),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_take_purpose(value : @control.TakePurpose) -> Json {
  match value {
    Implementation(_, _)
    | PartVerification(_, _, _)
    | PartAudit(_, _, _)
    | GoalVerification(_, _, _)
    | GoalAudit(_, _) => value.to_json()
  }
}

///|
let durable_shape_take : @control.Take = {
  id: durable_shape_take_id,
  goal_id: durable_shape_goal_id,
  purpose: durable_shapes_take_purpose[0],
  ordinal: 0,
  fencing_epoch: Some(durable_shape_fencing_epoch),
  lifecycle: durable_shapes_take_lifecycle[0],
}

///|
let durable_shape_goal_assurance_identity_plan : GoalAssuranceIdentityPlan = {
  verification_take: durable_shape_take,
  verification_sandbox: durable_shape_sandbox_lease,
  audit_take: durable_shape_take,
  audit_sandbox: durable_shape_sandbox_lease,
  audit_session: durable_shape_harness_session,
}

///|
let durable_shapes_goal_assurance_stage : Array[GoalAssuranceStage] = [
  GoalAssuranceStage::GoalSealPlanned,
  GoalAssuranceStage::GoalSealAuthorized,
  GoalAssuranceStage::GoalSealWitnessed,
  GoalAssuranceStage::GoalSealed,
  GoalAssuranceStage::GoalVerificationPending,
  GoalAssuranceStage::GoalVerified,
  GoalAssuranceStage::GoalAuditPending,
  GoalAssuranceStage::GoalAudited,
  GoalAssuranceStage::GoalAssuranceBlocked,
  GoalAssuranceStage::GoalAssuranceRecoveryUncertain,
  GoalAssuranceStage::GoalAssuranceCanceled,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_assurance_stage(value : GoalAssuranceStage) -> Json {
  match value {
    GoalSealPlanned
    | GoalSealAuthorized
    | GoalSealWitnessed
    | GoalSealed
    | GoalVerificationPending
    | GoalVerified
    | GoalAuditPending
    | GoalAudited
    | GoalAssuranceBlocked
    | GoalAssuranceRecoveryUncertain
    | GoalAssuranceCanceled => value.to_json()
  }
}

///|
let durable_shape_goal_audit_receipt : @control.GoalAuditReceipt = {
  receipt_id: durable_shape_receipt_id,
  audit_result_id: durable_shape_audit_result_id,
  audit_result_digest: durable_shape_digest,
  subject: durable_shape_goal_audit_subject,
  audit_take_id: durable_shape_take_id,
  audit_harness_session_id: durable_shape_harness_session_id,
  audit_sandbox_generation_id: durable_shape_sandbox_generation_id,
  auditor_capability_profile_digest: durable_shape_digest,
  provider_surface_id: durable_shapes_provider_surface_id[0],
  provider_identity: "",
  model_identity: durable_shapes_model_identity[0],
  provider_conformance_report_digest: durable_shape_digest,
  audit_policy_digest: durable_shape_digest,
  findings_artifact: Some(durable_shape_artifact_reference),
  total_findings_count: 0,
  blocking_findings_count: 0,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_audit_outcome[0],
}

///|
let durable_shape_goal_audit_result : @control.GoalAuditResult = {
  id: durable_shape_audit_result_id,
  audit_take_id: durable_shape_take_id,
  take_fencing_epoch: durable_shape_fencing_epoch,
  audit_harness_session_id: durable_shape_harness_session_id,
  subject: durable_shape_goal_audit_subject,
  auditor_capability_profile_digest: durable_shape_digest,
  effective_surface_manifest_digest: durable_shape_digest,
  provider_conformance_report_digest: durable_shape_digest,
  audit_policy_digest: durable_shape_digest,
  findings_artifact: Some(durable_shape_artifact_reference),
  total_findings_count: 0,
  blocking_findings_count: 0,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_audit_outcome[0],
  result_digest: durable_shape_digest,
}

///|
let durable_shape_goal_branch_seal_intent_id : @control.GoalBranchSealIntentId = @control.GoalBranchSealIntentId(
  "",
)

///|
let durable_shape_goal_branch_seal : @control.GoalBranchSeal = {
  id: durable_shape_goal_branch_seal_id,
  intent_id: durable_shape_goal_branch_seal_intent_id,
  goal_id: durable_shape_goal_id,
  seal_epoch: durable_shape_fencing_epoch,
  goal_ref: "",
  seal_witness_ref: "",
  head_oid: durable_shape_git_oid,
  tree_oid: durable_shape_git_oid,
  goal_contract_digest: durable_shape_digest,
  assurance_policy_revision: durable_shape_revision_id,
  assurance_policy_digest: durable_shape_digest,
  integration_receipt_set_digest: durable_shape_digest,
  sealed_at: 0L,
  seal_digest: durable_shape_digest,
}

///|
let durable_shapes_goal_branch_seal_failure_reason : Array[
  @control.GoalBranchSealFailureReason,
] = [
  @control.GoalBranchSealFailureReason::GoalBranchSealHeadDiverged,
  @control.GoalBranchSealFailureReason::GoalBranchSealTreeDiverged,
  @control.GoalBranchSealFailureReason::GoalBranchSealReceiptSetChanged,
  @control.GoalBranchSealFailureReason::GoalBranchSealPolicyChanged,
  @control.GoalBranchSealFailureReason::GoalBranchSealWitnessConflict,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_branch_seal_failure_reason(
  value : @control.GoalBranchSealFailureReason,
) -> Json {
  match value {
    GoalBranchSealHeadDiverged
    | GoalBranchSealTreeDiverged
    | GoalBranchSealReceiptSetChanged
    | GoalBranchSealPolicyChanged
    | GoalBranchSealWitnessConflict => value.to_json()
  }
}

///|
let durable_shapes_goal_branch_seal_intent_lifecycle : Array[
  @control.GoalBranchSealIntentLifecycle,
] = [
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealPlanned,
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealAuthorized,
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealWitnessed,
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealIntegrityBlocked(
    durable_shapes_goal_branch_seal_failure_reason[0],
  ),
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealUncertain(
    durable_shapes_goal_branch_seal_failure_reason[0],
  ),
  @control.GoalBranchSealIntentLifecycle::GoalBranchSealAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_branch_seal_intent_lifecycle(
  value : @control.GoalBranchSealIntentLifecycle,
) -> Json {
  match value {
    GoalBranchSealPlanned
    | GoalBranchSealAuthorized
    | GoalBranchSealWitnessed
    | GoalBranchSealed
    | GoalBranchSealIntegrityBlocked(_)
    | GoalBranchSealUncertain(_)
    | GoalBranchSealAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shape_goal_branch_seal_intent : @control.GoalBranchSealIntent = {
  id: durable_shape_goal_branch_seal_intent_id,
  goal_id: durable_shape_goal_id,
  expected_head_oid: durable_shape_git_oid,
  expected_tree_oid: durable_shape_git_oid,
  integration_receipt_set_digest: durable_shape_digest,
  assurance_policy_revision: durable_shape_revision_id,
  assurance_policy_digest: durable_shape_digest,
  seal_witness_ref: "",
  idempotency_key: "",
  lifecycle: durable_shapes_goal_branch_seal_intent_lifecycle[0],
}

///|
let durable_shape_goal_verification_authorization_set : @control.GoalVerificationAuthorizationSet = {
  subject_digest: durable_shape_digest,
  receipt_ids: [durable_shape_receipt_id],
  receipt_set_digest: durable_shape_digest,
  evidence_manifest_digest: durable_shape_digest,
}

///|
let durable_shape_goal_verification_authorization_slot : @control.GoalVerificationAuthorizationSlot = {
  subject_digest: durable_shape_digest,
  verification_spec: durable_shape_verification_spec,
  lowest_admitted_execution_ordinal: 0,
  authorizing_receipt_id: Some(durable_shape_receipt_id),
}

///|
let durable_shape_goal_verification_receipt : @control.GoalVerificationReceipt = {
  receipt_id: durable_shape_receipt_id,
  verification_take_id: durable_shape_take_id,
  verification_execution_id: durable_shape_verification_execution_id,
  subject: durable_shape_goal_verification_subject,
  verification_spec: durable_shape_verification_spec,
  prepared_environment_and_image_digest: durable_shape_digest,
  sandbox_runtime_and_policy_digest: durable_shape_digest,
  subject_pre_tree_oid: durable_shape_git_oid,
  subject_post_tree_oid: durable_shape_git_oid,
  evidence: durable_shape_artifact_reference,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_verification_outcome[0],
}

///|
let durable_shape_integration_intent_id : @control.IntegrationIntentId = @control.IntegrationIntentId(
  "",
)

///|
let durable_shape_integration_receipt_id : @control.IntegrationReceiptId = @control.IntegrationReceiptId(
  "",
)

///|
let durable_shape_integration_receipt : @control.IntegrationReceipt = {
  id: durable_shape_integration_receipt_id,
  intent_id: durable_shape_integration_intent_id,
  goal_id: durable_shape_goal_id,
  part_id: durable_shape_part_id,
  candidate_id: durable_shape_candidate_id,
  candidate_commit_oid: durable_shape_git_oid,
  candidate_tree_oid: durable_shape_git_oid,
  from_head_oid: durable_shape_git_oid,
  promotion_commit_oid: durable_shape_git_oid,
  promotion_tree_oid: durable_shape_git_oid,
  witness_ref: "",
  integrated_at: 0L,
}

///|
let durable_shape_repository_id : RepositoryId = RepositoryId("")

///|
let durable_shape_goal_assurance_record : GoalAssuranceRecord = {
  goal_id: durable_shape_goal_id,
  repository_id: durable_shape_repository_id,
  goal_ref: durable_shape_git_ref_name,
  goal_contract_digest: durable_shape_digest,
  base_commit_oid: durable_shape_git_oid,
  integration_receipts: [durable_shape_integration_receipt],
  integration_receipt_set_digest: durable_shape_digest,
  assurance_policy_revision: durable_shape_revision_id,
  assurance_policy_digest: durable_shape_digest,
  verification_specs: [durable_shape_verification_spec],
  identities: durable_shape_goal_assurance_identity_plan,
  verification_take: durable_shape_take,
  audit_take: durable_shape_take,
  seal_intent: durable_shape_goal_branch_seal_intent,
  seal_witnessed_at: Some(0L),
  seal: Some(durable_shape_goal_branch_seal),
  sandbox_leases: [durable_shape_sandbox_lease],
  harness_sessions: [durable_shape_harness_session],
  harness_events: [durable_shape_harness_event_envelope],
  verification_subject: Some(durable_shape_goal_verification_subject),
  verification_slots: [durable_shape_goal_verification_authorization_slot],
  verification_receipts: [durable_shape_goal_verification_receipt],
  verification_authorization: Some(
    durable_shape_goal_verification_authorization_set,
  ),
  audit_subject: Some(durable_shape_goal_audit_subject),
  audit_result: Some(durable_shape_goal_audit_result),
  audit_receipt: Some(durable_shape_goal_audit_receipt),
  pending_effect: Some(durable_shape_goal_assurance_effect_intent),
  effect_receipts: [durable_shape_goal_assurance_effect_receipt],
  stage: durable_shapes_goal_assurance_stage[0],
  blocked_reason: Some(durable_shapes_goal_assurance_block_reason[0]),
  durable_version: 0,
  fencing_epoch: durable_shape_fencing_epoch,
}

///|
let durable_shape_goal_branch_init_intent_id : GoalBranchInitIntentId = GoalBranchInitIntentId(
  "",
)

///|
let durable_shapes_goal_branch_init_lifecycle : Array[GoalBranchInitLifecycle] = [
  GoalBranchInitLifecycle::GoalBranchInitPlanned,
  GoalBranchInitLifecycle::GoalBranchInitAuthorized,
  GoalBranchInitLifecycle::GoalBranchInitReceipted,
  GoalBranchInitLifecycle::GoalBranchInitIntegrityBlocked,
  GoalBranchInitLifecycle::GoalBranchInitUncertain,
  GoalBranchInitLifecycle::GoalBranchInitAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_branch_init_lifecycle(
  value : GoalBranchInitLifecycle,
) -> Json {
  match value {
    GoalBranchInitPlanned
    | GoalBranchInitAuthorized
    | GoalBranchInitReceipted
    | GoalBranchInitIntegrityBlocked
    | GoalBranchInitUncertain
    | GoalBranchInitAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shape_goal_branch_init_receipt : GoalBranchInitReceipt = {
  intent_id: durable_shape_goal_branch_init_intent_id,
  idempotency_key: durable_shape_digest,
  repository_id: durable_shape_repository_id,
  goal_ref: durable_shape_git_ref_name,
  initialized_oid: durable_shape_git_oid,
  initialization_witness_ref: durable_shape_git_ref_name,
  observed_at: 0L,
}

///|
let durable_shape_goal_branch_initialization : GoalBranchInitialization = {
  intent_id: durable_shape_goal_branch_init_intent_id,
  goal_id: durable_shape_goal_id,
  repository_id: durable_shape_repository_id,
  goal_ref: durable_shape_git_ref_name,
  captured_base_oid: durable_shape_git_oid,
  initialization_witness_ref: durable_shape_git_ref_name,
  idempotency_key: durable_shape_digest,
  lifecycle: durable_shapes_goal_branch_init_lifecycle[0],
  receipt: Some(durable_shape_goal_branch_init_receipt),
}

///|
let durable_shapes_goal_cancellation_cause : Array[GoalCancellationCause] = [
  GoalCancellationCause::GoalCancellationUserRequested,
  GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
    durable_shape_digest, durable_shape_digest,
  ),
  GoalCancellationCause::GoalCancellationSupersededByContractRevision(
    durable_shape_digest,
  ),
  GoalCancellationCause::GoalCancellationAuditRepairFailed(durable_shape_digest),
  GoalCancellationCause::GoalCancellationVerificationRepairFailed(
    durable_shape_digest,
  ),
  GoalCancellationCause::GoalCancellationAutoMergeFailed(durable_shape_digest),
  GoalCancellationCause::GoalCancellationWorkOrderStopped(durable_shape_digest),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_cancellation_cause(value : GoalCancellationCause) -> Json {
  match value {
    GoalCancellationUserRequested
    | GoalCancellationEvidenceOnlyCompleted(_, _)
    | GoalCancellationSupersededByContractRevision(_)
    | GoalCancellationAuditRepairFailed(_)
    | GoalCancellationVerificationRepairFailed(_)
    | GoalCancellationAutoMergeFailed(_)
    | GoalCancellationWorkOrderStopped(_) => value.to_json()
  }
}

///|
let durable_shape_goal_cancellation_request : GoalCancellationRequest = {
  goal_id: durable_shape_goal_id,
  cutoff_sequence: durable_shape_event_sequence,
  cause: durable_shapes_goal_cancellation_cause[0],
  requested_at: 0L,
}

///|
let durable_shapes_goal_completion_mode : Array[GoalCompletionMode] = [
  GoalCompletionMode::GoalPublishable,
  GoalCompletionMode::GoalEvidenceOnly(durable_shape_digest),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_completion_mode(value : GoalCompletionMode) -> Json {
  match value {
    GoalPublishable | GoalEvidenceOnly(_) => value.to_json()
  }
}

///|
let durable_shapes_goal_execution_state : Array[GoalExecutionState] = [
  GoalExecutionState::GoalExecutionQueued,
  GoalExecutionState::GoalExecutionRunning,
  GoalExecutionState::GoalExecutionAssuring,
  GoalExecutionState::GoalExecutionAssured,
  GoalExecutionState::GoalExecutionPaused,
  GoalExecutionState::GoalExecutionBlocked,
  GoalExecutionState::GoalExecutionCanceling,
  GoalExecutionState::GoalExecutionSucceeded,
  GoalExecutionState::GoalExecutionCanceled,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_execution_state(value : GoalExecutionState) -> Json {
  match value {
    GoalExecutionQueued
    | GoalExecutionRunning
    | GoalExecutionAssuring
    | GoalExecutionAssured
    | GoalExecutionPaused
    | GoalExecutionBlocked
    | GoalExecutionCanceling
    | GoalExecutionSucceeded
    | GoalExecutionCanceled => value.to_json()
  }
}

///|
let durable_shape_goal_input_request_id : GoalInputRequestId = GoalInputRequestId(
  "",
)

///|
let durable_shape_goal_input_answer : GoalInputAnswer = {
  request_id: durable_shape_goal_input_request_id,
  answer_artifact: durable_shape_artifact_reference,
  answered_at: 0L,
}

///|
let durable_shapes_goal_input_reason : Array[GoalInputReason] = [
  GoalInputReason::GoalInputPublicationRemoteUnavailable,
  GoalInputReason::GoalInputFinalizationNeedsUserInput,
  GoalInputReason::GoalInputFinalizationDrifted,
  GoalInputReason::GoalInputFinalizationAmbiguous,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_input_reason(value : GoalInputReason) -> Json {
  match value {
    GoalInputPublicationRemoteUnavailable
    | GoalInputFinalizationNeedsUserInput
    | GoalInputFinalizationDrifted
    | GoalInputFinalizationAmbiguous => value.to_json()
  }
}

///|
let durable_shape_goal_input_request : GoalInputRequest = {
  id: durable_shape_goal_input_request_id,
  goal_id: durable_shape_goal_id,
  reason: durable_shapes_goal_input_reason[0],
  created_at_version: 0,
}

///|
let durable_shapes_goal_pause_reason : Array[GoalPauseReason] = [
  GoalPauseReason::GoalPauseRecoveryUncertain,
  GoalPauseReason::GoalPauseRequested,
  GoalPauseReason::GoalPauseAwaitingAnswer(durable_shape_goal_input_request_id),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_pause_reason(value : GoalPauseReason) -> Json {
  match value {
    GoalPauseRecoveryUncertain
    | GoalPauseRequested
    | GoalPauseAwaitingAnswer(_) => value.to_json()
  }
}

///|
let durable_shape_goal_pause : GoalPause = {
  reason: durable_shapes_goal_pause_reason[0],
  resume_state: durable_shapes_goal_execution_state[0],
}

///|
let durable_shapes_goal_policy_change : Array[GoalPolicyChange] = [
  GoalPolicyChange::GoalPolicyInitial,
  GoalPolicyChange::GoalPolicySetMaximumParallelParts(0),
  GoalPolicyChange::GoalPolicyPause,
  GoalPolicyChange::GoalPolicyResume,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_policy_change(value : GoalPolicyChange) -> Json {
  match value {
    GoalPolicyInitial
    | GoalPolicySetMaximumParallelParts(_)
    | GoalPolicyPause
    | GoalPolicyResume => value.to_json()
  }
}

///|
let durable_shape_goal_policy_revision : GoalPolicyRevision = {
  id: durable_shape_revision_id,
  goal_id: durable_shape_goal_id,
  parent_revision_id: Some(durable_shape_revision_id),
  ordinal: 0,
  change: durable_shapes_goal_policy_change[0],
  maximum_parallel_parts: 0,
  digest: durable_shape_digest,
}

///|
let durable_shape_goal_source_claim_intent_id : GoalSourceClaimIntentId = GoalSourceClaimIntentId(
  "",
)

///|
let durable_shapes_goal_source_claim_conflict_reason : Array[
  GoalSourceClaimConflictReason,
] = [
  GoalSourceClaimConflictReason::GoalSourceClaimContentDrift,
  GoalSourceClaimConflictReason::GoalSourceClaimOwnedByAnotherActor,
  GoalSourceClaimConflictReason::GoalSourceClaimClosedBeforeExecution,
  GoalSourceClaimConflictReason::GoalSourceClaimAmbiguous,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_source_claim_conflict_reason(
  value : GoalSourceClaimConflictReason,
) -> Json {
  match value {
    GoalSourceClaimContentDrift
    | GoalSourceClaimOwnedByAnotherActor
    | GoalSourceClaimClosedBeforeExecution
    | GoalSourceClaimAmbiguous => value.to_json()
  }
}

///|
let durable_shapes_goal_source_claim_lifecycle : Array[GoalSourceClaimLifecycle] = [
  GoalSourceClaimLifecycle::GoalSourceClaimPlanned,
  GoalSourceClaimLifecycle::GoalSourceClaimAuthorized,
  GoalSourceClaimLifecycle::GoalSourceClaimReceipted,
  GoalSourceClaimLifecycle::GoalSourceClaimConflict(
    durable_shapes_goal_source_claim_conflict_reason[0],
  ),
  GoalSourceClaimLifecycle::GoalSourceReleaseAuthorized,
  GoalSourceClaimLifecycle::GoalSourceReleased,
  GoalSourceClaimLifecycle::GoalSourceReleaseConflict(
    durable_shapes_goal_source_claim_conflict_reason[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_source_claim_lifecycle(
  value : GoalSourceClaimLifecycle,
) -> Json {
  match value {
    GoalSourceClaimPlanned
    | GoalSourceClaimAuthorized
    | GoalSourceClaimReceipted
    | GoalSourceClaimConflict(_)
    | GoalSourceReleaseAuthorized
    | GoalSourceReleased
    | GoalSourceReleaseConflict(_) => value.to_json()
  }
}

///|
let durable_shape_goal_source_claim_receipt : GoalSourceClaimReceipt = {
  intent_id: durable_shape_goal_source_claim_intent_id,
  part_id: durable_shape_part_id,
  claimant: "",
  source_content_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shape_goal_source_release_receipt : GoalSourceReleaseReceipt = {
  intent_id: durable_shape_goal_source_claim_intent_id,
  part_id: durable_shape_part_id,
  claimant: "",
  source_content_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shape_goal_source_claim : GoalSourceClaim = {
  intent_id: durable_shape_goal_source_claim_intent_id,
  goal_id: durable_shape_goal_id,
  part_id: durable_shape_part_id,
  claimant: "",
  source_revision_digest: durable_shape_digest,
  source_content_digest: durable_shape_digest,
  lifecycle: durable_shapes_goal_source_claim_lifecycle[0],
  receipt: Some(durable_shape_goal_source_claim_receipt),
  release_receipt: Some(durable_shape_goal_source_release_receipt),
}

///|
let durable_shape_migration_production_admission_ref : @migration.MigrationProductionAdmissionRef = {
  migration_contract_ref: durable_shape_migration_contract_ref,
  contract_acceptance_digest: durable_shape_digest,
  judge_definition_digest: durable_shape_digest,
  judge_qualification_report_digest: durable_shape_digest,
  judge_qualification_evidence_ref_digest: durable_shape_digest,
  rehearsal_evidence_ref_digest: Some(durable_shape_digest),
  migration_continuation_ref_digest: Some(durable_shape_digest),
}

///|
let durable_shape_pull_request_document : PullRequestDocument = {
  title: "",
  body: "",
  draft: false,
}

///|
let durable_shape_work_order_counters : WorkOrderCounters = {
  delivered_primary_targets: 0,
  delivered_dependency_closure: 0,
  agentic_takes_started: 0,
  consecutive_idle_rounds: 0,
  consecutive_findings_free_rounds: 0,
}

///|
let durable_shapes_work_order_cutoff_policy : Array[WorkOrderCutoffPolicy] = [
  WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
  WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_work_order_cutoff_policy(
  value : WorkOrderCutoffPolicy,
) -> Json {
  match value {
    WorkOrderDrainToSafeBoundary | WorkOrderInstallCancellationCutoff =>
      value.to_json()
  }
}

///|
let durable_shapes_work_order_quota_basis : Array[WorkOrderQuotaBasis] = [
  WorkOrderQuotaBasis::WorkOrderPrimaryTargets,
  WorkOrderQuotaBasis::WorkOrderDependencyClosure,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_work_order_quota_basis(value : WorkOrderQuotaBasis) -> Json {
  match value {
    WorkOrderPrimaryTargets | WorkOrderDependencyClosure => value.to_json()
  }
}

///|
let durable_shapes_work_order_stop_policy : Array[WorkOrderStopPolicy] = [
  WorkOrderStopPolicy::WorkOrderStopAtDeadline(0L),
  WorkOrderStopPolicy::WorkOrderStopAtDeliveredQuota(
    durable_shapes_work_order_quota_basis[0],
    0,
  ),
  WorkOrderStopPolicy::WorkOrderStopWhenNoEligibleWork(0),
  WorkOrderStopPolicy::WorkOrderStopWhenNoFurtherFindings(0),
  WorkOrderStopPolicy::WorkOrderStopAtSafetyCeiling(0),
  // The only durable shape that contains itself. An empty list cuts the
  // recursion; the element shape is this same entry.
  WorkOrderStopPolicy::WorkOrderStopAtFirstOf([]),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_work_order_stop_policy(value : WorkOrderStopPolicy) -> Json {
  match value {
    WorkOrderStopAtDeadline(_)
    | WorkOrderStopAtDeliveredQuota(_, _)
    | WorkOrderStopWhenNoEligibleWork(_)
    | WorkOrderStopWhenNoFurtherFindings(_)
    | WorkOrderStopAtSafetyCeiling(_)
    | WorkOrderStopAtFirstOf(_) => value.to_json()
  }
}

///|
let durable_shapes_work_order_stop_reason : Array[WorkOrderStopReason] = [
  WorkOrderStopReason::WorkOrderDeadlineReached,
  WorkOrderStopReason::WorkOrderQuotaSatisfied(
    durable_shapes_work_order_quota_basis[0],
    0,
  ),
  WorkOrderStopReason::WorkOrderNoEligibleWorkRemains,
  WorkOrderStopReason::WorkOrderNoFurtherFindingsRemain,
  WorkOrderStopReason::WorkOrderSafetyCeilingReached,
  WorkOrderStopReason::WorkOrderFatalIntegrityStop(durable_shape_digest),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_work_order_stop_reason(value : WorkOrderStopReason) -> Json {
  match value {
    WorkOrderDeadlineReached
    | WorkOrderQuotaSatisfied(_, _)
    | WorkOrderNoEligibleWorkRemains
    | WorkOrderNoFurtherFindingsRemain
    | WorkOrderSafetyCeilingReached
    | WorkOrderFatalIntegrityStop(_) => value.to_json()
  }
}

///|
let durable_shape_work_order_budget : WorkOrderBudget = {
  accepted_at: 0L,
  stop_policy: durable_shapes_work_order_stop_policy[0],
  cutoff_policy: durable_shapes_work_order_cutoff_policy[0],
  counters: durable_shape_work_order_counters,
  stopped: Some(durable_shapes_work_order_stop_reason[0]),
}

///|
let durable_shape_workflow_id : @control.WorkflowId = @control.WorkflowId("")

///|
let durable_shape_goal_execution_record : GoalExecutionRecord = {
  goal: durable_shape_goal,
  repository_id: durable_shape_repository_id,
  selection_decision_digest: durable_shape_digest,
  base_ref: durable_shape_git_ref_name,
  base_commit_oid: durable_shape_git_oid,
  base_tree_oid: durable_shape_git_oid,
  integration_target_ref: durable_shape_git_ref_name,
  completion_mode: durable_shapes_goal_completion_mode[0],
  pull_request_document: Some(durable_shape_pull_request_document),
  migration_production_admission: Some(
    durable_shape_migration_production_admission_ref,
  ),
  goal_ref: durable_shape_git_ref_name,
  branch_initialization: durable_shape_goal_branch_initialization,
  source_claims: [durable_shape_goal_source_claim],
  maximum_parallel_parts: 0,
  policy_revisions: [durable_shape_goal_policy_revision],
  part_workflow_ids: [durable_shape_workflow_id],
  state: durable_shapes_goal_execution_state[0],
  pause: Some(durable_shape_goal_pause),
  active_input_request: Some(durable_shape_goal_input_request),
  input_answers: [durable_shape_goal_input_answer],
  cancellation_request: Some(durable_shape_goal_cancellation_request),
  work_order_budget: Some(durable_shape_work_order_budget),
  durable_version: 0,
  fencing_epoch: durable_shape_fencing_epoch,
}

///|
let durable_shapes_pull_request_readiness_drift_reason : Array[
  PullRequestReadinessDriftReason,
] = [
  PullRequestReadinessDriftReason::PullRequestCanonicalIdentityMissing,
  PullRequestReadinessDriftReason::PullRequestCanonicalIdentityChanged,
  PullRequestReadinessDriftReason::PullRequestHeadOrBaseChanged,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_readiness_drift_reason(
  value : PullRequestReadinessDriftReason,
) -> Json {
  match value {
    PullRequestCanonicalIdentityMissing
    | PullRequestCanonicalIdentityChanged
    | PullRequestHeadOrBaseChanged => value.to_json()
  }
}

///|
let durable_shapes_pull_request_readiness_needs_input_reason : Array[
  PullRequestReadinessNeedsInputReason,
] = [
  PullRequestReadinessNeedsInputReason::PullRequestNotOpen,
  PullRequestReadinessNeedsInputReason::PullRequestReadinessObservationUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_readiness_needs_input_reason(
  value : PullRequestReadinessNeedsInputReason,
) -> Json {
  match value {
    PullRequestNotOpen | PullRequestReadinessObservationUncertain =>
      value.to_json()
  }
}

///|
let durable_shapes_pull_request_readiness_decision : Array[
  PullRequestReadinessDecision,
] = [
  PullRequestReadinessDecision::PullRequestReady,
  PullRequestReadinessDecision::PullRequestAwaitingReview,
  PullRequestReadinessDecision::PullRequestAwaitingMerge,
  PullRequestReadinessDecision::PullRequestDeliveryFailed(durable_shape_digest),
  PullRequestReadinessDecision::PullRequestReadinessNeedsInput(
    durable_shapes_pull_request_readiness_needs_input_reason[0],
  ),
  PullRequestReadinessDecision::PullRequestReadinessDrift(
    durable_shapes_pull_request_readiness_drift_reason[0],
  ),
  PullRequestReadinessDecision::PullRequestReadinessAmbiguous,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_readiness_decision(
  value : PullRequestReadinessDecision,
) -> Json {
  match value {
    PullRequestReady
    | PullRequestAwaitingReview
    | PullRequestAwaitingMerge
    | PullRequestDeliveryFailed(_)
    | PullRequestReadinessNeedsInput(_)
    | PullRequestReadinessDrift(_)
    | PullRequestReadinessAmbiguous => value.to_json()
  }
}

///|
let durable_shape_pull_request_readiness_snapshot_id : PullRequestReadinessSnapshotId = PullRequestReadinessSnapshotId(
  "",
)

///|
let durable_shape_remote_pull_request_id : RemotePullRequestId = RemotePullRequestId(
  "",
)

///|
let durable_shapes_remote_pull_request_state : Array[RemotePullRequestState] = [
  RemotePullRequestState::RemotePullRequestOpen,
  RemotePullRequestState::RemotePullRequestClosed,
  RemotePullRequestState::RemotePullRequestMerged,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_remote_pull_request_state(
  value : RemotePullRequestState,
) -> Json {
  match value {
    RemotePullRequestOpen | RemotePullRequestClosed | RemotePullRequestMerged =>
      value.to_json()
  }
}

///|
let durable_shape_pull_request_readiness_snapshot : PullRequestReadinessSnapshot = {
  snapshot_id: durable_shape_pull_request_readiness_snapshot_id,
  finalization_id: durable_shape_finalization_id,
  pull_request_receipt_id: durable_shape_receipt_id,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  observed_remote_id: Some(durable_shape_remote_pull_request_id),
  observed_remote_state: Some(durable_shapes_remote_pull_request_state[0]),
  observed_head_repository_id: Some(durable_shape_remote_repository_id),
  observed_head_ref: Some(durable_shape_git_ref_name),
  observed_base_repository_id: Some(durable_shape_remote_repository_id),
  observed_base_ref: Some(durable_shape_git_ref_name),
  observed_head_oid: Some(durable_shape_git_oid),
  observed_draft: Some(false),
  observed_body_digest: Some(durable_shape_digest),
  remote_version_token: Some(""),
  observation_sequence: 0L,
  observation_started_at: 0L,
  observed_at: 0L,
  decision: durable_shapes_pull_request_readiness_decision[0],
}

///|
let durable_shape_goal_finalization_record : GoalFinalizationRecord = {
  goal_id: durable_shape_goal_id,
  repository_id: durable_shape_repository_id,
  goal_contract_digest: durable_shape_digest,
  assurance_record_digest: durable_shape_digest,
  publication_record_digest: durable_shape_digest,
  pull_request_record_digest: durable_shape_digest,
  readiness: durable_shape_pull_request_readiness_snapshot,
  durable_version: 0,
  fencing_epoch: durable_shape_fencing_epoch,
}

///|
let durable_shape_integration_lease_id : @control.IntegrationLeaseId = @control.IntegrationLeaseId(
  "",
)

///|
let durable_shape_goal_integration_lease : @control.GoalIntegrationLease = {
  id: durable_shape_integration_lease_id,
  goal_id: durable_shape_goal_id,
  fencing_epoch: durable_shape_fencing_epoch,
  holder: "",
}

///|
let durable_shape_goal_proposal_id : GoalProposalId = GoalProposalId("")

///|
let durable_shapes_goal_selection_policy : Array[GoalSelectionPolicy] = [
  GoalSelectionPolicy::ExactClosure,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_selection_policy(value : GoalSelectionPolicy) -> Json {
  match value {
    ExactClosure => value.to_json()
  }
}

///|
let durable_shape_goal_proposal : GoalProposal = {
  id: durable_shape_goal_proposal_id,
  goal_id: durable_shape_goal_id,
  conductor_draft_digest: durable_shape_digest,
  repository_id: durable_shape_repository_id,
  base_ref: durable_shape_git_ref_name,
  expected_base_commit_oid: durable_shape_git_oid,
  expected_base_tree_oid: durable_shape_git_oid,
  integration_target_ref: durable_shape_git_ref_name,
  selection_policy: durable_shapes_goal_selection_policy[0],
  completion_mode: durable_shapes_goal_completion_mode[0],
  pull_request_document: Some(durable_shape_pull_request_document),
  migration_production_admission: Some(
    durable_shape_migration_production_admission_ref,
  ),
  maximum_parallel_parts: 0,
  parts: [durable_shape_conductor_part_proposal],
  work_order_budget: Some(durable_shape_work_order_budget),
}

///|
let durable_shape_goal_publication_record : GoalPublicationRecord = {
  goal_id: durable_shape_goal_id,
  repository_id: durable_shape_repository_id,
  goal_ref: durable_shape_git_ref_name,
  goal_contract_digest: durable_shape_digest,
  assurance_record_digest: durable_shape_digest,
  goal_branch_seal: durable_shape_goal_branch_seal,
  goal_verification_receipt_set_digest: durable_shape_digest,
  goal_verification_evidence_manifest_digest: durable_shape_digest,
  goal_audit_receipt_id: durable_shape_receipt_id,
  goal_audit_result_digest: durable_shape_digest,
  intent: durable_shape_branch_publication_intent,
  receipt: Some(durable_shape_branch_publication_receipt),
  durable_version: 0,
  fencing_epoch: durable_shape_fencing_epoch,
}

///|
let durable_shapes_pull_request_cancellation_state : Array[
  PullRequestCancellationState,
] = [
  PullRequestCancellationState::PullRequestCancellationNotRequested,
  PullRequestCancellationState::PullRequestCancellationPlanned,
  PullRequestCancellationState::PullRequestNeutralizeAuthorized,
  PullRequestCancellationState::PullRequestNeutralizeMayHaveBeenIssued,
  PullRequestCancellationState::PullRequestNeutralized,
  PullRequestCancellationState::PullRequestSupersededByMerge,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_cancellation_state(
  value : PullRequestCancellationState,
) -> Json {
  match value {
    PullRequestCancellationNotRequested
    | PullRequestCancellationPlanned
    | PullRequestNeutralizeAuthorized
    | PullRequestNeutralizeMayHaveBeenIssued
    | PullRequestNeutralized
    | PullRequestSupersededByMerge => value.to_json()
  }
}

///|
let durable_shapes_pull_request_delivery_mode : Array[
  @types.PullRequestDeliveryMode,
] = [
  @types.PullRequestDeliveryMode::PullRequestReviewOnly,
  @types.PullRequestDeliveryMode::PullRequestAutoMerge,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_delivery_mode(
  value : @types.PullRequestDeliveryMode,
) -> Json {
  match value {
    PullRequestReviewOnly | PullRequestAutoMerge => value.to_json()
  }
}

///|
let durable_shapes_pull_request_merge_method : Array[
  @types.PullRequestMergeMethod,
] = [
  @types.PullRequestMergeMethod::PullRequestSquashMerge,
  @types.PullRequestMergeMethod::PullRequestRebaseMerge,
  @types.PullRequestMergeMethod::PullRequestMergeCommit,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_merge_method(
  value : @types.PullRequestMergeMethod,
) -> Json {
  match value {
    PullRequestSquashMerge | PullRequestRebaseMerge | PullRequestMergeCommit =>
      value.to_json()
  }
}

///|
let durable_shape_pull_request_delivery_policy : @types.PullRequestDeliveryPolicy = {
  mode: durable_shapes_pull_request_delivery_mode[0],
  merge_method: durable_shapes_pull_request_merge_method[0],
}

///|
let durable_shape_pull_request_identity_marker : PullRequestIdentityMarker = PullRequestIdentityMarker(
  "",
)

///|
let durable_shape_pull_request_intent_id : PullRequestIntentId = PullRequestIntentId(
  "",
)

///|
let durable_shapes_pull_request_needs_input_reason : Array[
  PullRequestNeedsInputReason,
] = [
  PullRequestNeedsInputReason::PullRequestPossibleExisting,
  PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
  PullRequestNeedsInputReason::PullRequestRemoteClosed,
  PullRequestNeedsInputReason::PullRequestRemoteDrift,
  PullRequestNeedsInputReason::PullRequestIdentityMarkerMissing,
  PullRequestNeedsInputReason::PullRequestDraftUnderAutoMerge,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_needs_input_reason(
  value : PullRequestNeedsInputReason,
) -> Json {
  match value {
    PullRequestPossibleExisting
    | PullRequestAmbiguousIdentity
    | PullRequestRemoteClosed
    | PullRequestRemoteDrift
    | PullRequestIdentityMarkerMissing
    | PullRequestDraftUnderAutoMerge => value.to_json()
  }
}

///|
let durable_shapes_pull_request_intent_state : Array[PullRequestIntentState] = [
  PullRequestIntentState::PullRequestPlanned,
  PullRequestIntentState::PullRequestAuthorized,
  PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
  PullRequestIntentState::PullRequestReceipted,
  PullRequestIntentState::PullRequestNeedsInput(
    durable_shapes_pull_request_needs_input_reason[0],
  ),
  PullRequestIntentState::PullRequestRemoteCreateUncertain,
  PullRequestIntentState::PullRequestAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_intent_state(
  value : PullRequestIntentState,
) -> Json {
  match value {
    PullRequestPlanned
    | PullRequestAuthorized
    | PullRequestCreateMayHaveBeenIssued
    | PullRequestReceipted
    | PullRequestNeedsInput(_)
    | PullRequestRemoteCreateUncertain
    | PullRequestAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shapes_pull_request_merge_state : Array[PullRequestMergeState] = [
  PullRequestMergeState::PullRequestMergeNotRequested,
  PullRequestMergeState::PullRequestMergePlanned,
  PullRequestMergeState::PullRequestMergeAuthorized,
  PullRequestMergeState::PullRequestMergeMayHaveBeenIssued,
  PullRequestMergeState::PullRequestMergeEnabled,
  PullRequestMergeState::PullRequestMergeRejected(durable_shape_digest),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_merge_state(
  value : PullRequestMergeState,
) -> Json {
  match value {
    PullRequestMergeNotRequested
    | PullRequestMergePlanned
    | PullRequestMergeAuthorized
    | PullRequestMergeMayHaveBeenIssued
    | PullRequestMergeEnabled
    | PullRequestMergeRejected(_) => value.to_json()
  }
}

///|
let durable_shapes_pull_request_provider : Array[PullRequestProvider] = [
  PullRequestProvider::GitHubPullRequestProvider,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_provider(value : PullRequestProvider) -> Json {
  match value {
    GitHubPullRequestProvider => value.to_json()
  }
}

///|
let durable_shape_pull_request_intent : PullRequestIntent = {
  id: durable_shape_pull_request_intent_id,
  goal_id: durable_shape_goal_id,
  provider: durable_shapes_pull_request_provider[0],
  canonical_repository_id: durable_shape_remote_repository_id,
  head_repository_id: durable_shape_remote_repository_id,
  head_ref: durable_shape_git_ref_name,
  base_repository_id: durable_shape_remote_repository_id,
  base_ref: durable_shape_git_ref_name,
  expected_head_oid: durable_shape_git_oid,
  goal_contract_digest: durable_shape_digest,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  combined_audit_receipt_id: durable_shape_receipt_id,
  evidence_manifest_digest: durable_shape_digest,
  document: durable_shape_pull_request_document,
  identity_marker: durable_shape_pull_request_identity_marker,
  idempotency_key: "",
  canonical_remote_pull_request_id: Some(durable_shape_remote_pull_request_id),
  state: durable_shapes_pull_request_intent_state[0],
  delivery_policy: durable_shape_pull_request_delivery_policy,
  merge_state: durable_shapes_pull_request_merge_state[0],
  cancellation_state: durable_shapes_pull_request_cancellation_state[0],
}

///|
let durable_shapes_pull_request_marker_state : Array[PullRequestMarkerState] = [
  PullRequestMarkerState::PullRequestMarkerExact,
  PullRequestMarkerState::PullRequestMarkerMissing,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_marker_state(
  value : PullRequestMarkerState,
) -> Json {
  match value {
    PullRequestMarkerExact | PullRequestMarkerMissing => value.to_json()
  }
}

///|
let durable_shape_pull_request_number : PullRequestNumber = PullRequestNumber(0)

///|
let durable_shapes_pull_request_receipt_origin : Array[PullRequestReceiptOrigin] = [
  PullRequestReceiptOrigin::PullRequestCreated,
  PullRequestReceiptOrigin::PullRequestAdopted,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_pull_request_receipt_origin(
  value : PullRequestReceiptOrigin,
) -> Json {
  match value {
    PullRequestCreated | PullRequestAdopted => value.to_json()
  }
}

///|
let durable_shape_pull_request_url : PullRequestUrl = PullRequestUrl("")

///|
let durable_shape_pull_request_receipt : PullRequestReceipt = {
  receipt_id: durable_shape_receipt_id,
  intent_id: durable_shape_pull_request_intent_id,
  idempotency_key: "",
  provider_repository_id: durable_shape_remote_repository_id,
  remote_pull_request_id: durable_shape_remote_pull_request_id,
  number: durable_shape_pull_request_number,
  url: durable_shape_pull_request_url,
  head_repository_id: durable_shape_remote_repository_id,
  head_ref: durable_shape_git_ref_name,
  base_repository_id: durable_shape_remote_repository_id,
  base_ref: durable_shape_git_ref_name,
  expected_head_oid: durable_shape_git_oid,
  observed_head_oid: durable_shape_git_oid,
  goal_branch_seal_id: durable_shape_goal_branch_seal_id,
  goal_branch_seal_digest: durable_shape_digest,
  origin: durable_shapes_pull_request_receipt_origin[0],
  observed_remote_state: durable_shapes_remote_pull_request_state[0],
  observed_marker_state: durable_shapes_pull_request_marker_state[0],
  observed_title_digest: durable_shape_digest,
  observed_body_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shape_goal_pull_request_record : GoalPullRequestRecord = {
  goal_id: durable_shape_goal_id,
  repository_id: durable_shape_repository_id,
  goal_contract_digest: durable_shape_digest,
  assurance_record_digest: durable_shape_digest,
  publication_record_digest: durable_shape_digest,
  intent: durable_shape_pull_request_intent,
  receipt: Some(durable_shape_pull_request_receipt),
  durable_version: 0,
  fencing_epoch: durable_shape_fencing_epoch,
}

///|
let durable_shapes_goal_selection_outcome : Array[GoalSelectionOutcome] = [
  GoalSelectionOutcome::GoalSelectionAccepted,
  GoalSelectionOutcome::GoalSelectionRejected,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_goal_selection_outcome(value : GoalSelectionOutcome) -> Json {
  match value {
    GoalSelectionAccepted | GoalSelectionRejected => value.to_json()
  }
}

///|
let durable_shapes_selection_rejection_reason : Array[SelectionRejectionReason] = [
  SelectionRejectionReason::SelectionNotFound,
  SelectionRejectionReason::SelectionDuplicate,
  SelectionRejectionReason::SelectionNotOpen,
  SelectionRejectionReason::SelectionAlreadyOwned,
  SelectionRejectionReason::SelectionMissingOpenDependency,
  SelectionRejectionReason::SelectionDependencyCycle,
  SelectionRejectionReason::SelectionAmbiguous,
  SelectionRejectionReason::SelectionInvalidTaskContract,
  SelectionRejectionReason::SelectionInvalidMutationDeclaration,
  SelectionRejectionReason::SelectionPolicyExcluded,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_selection_rejection_reason(
  value : SelectionRejectionReason,
) -> Json {
  match value {
    SelectionNotFound
    | SelectionDuplicate
    | SelectionNotOpen
    | SelectionAlreadyOwned
    | SelectionMissingOpenDependency
    | SelectionDependencyCycle
    | SelectionAmbiguous
    | SelectionInvalidTaskContract
    | SelectionInvalidMutationDeclaration
    | SelectionPolicyExcluded => value.to_json()
  }
}

///|
let durable_shape_part_selection_rejection : PartSelectionRejection = {
  part_id: durable_shape_part_id,
  reasons: [durable_shapes_selection_rejection_reason[0]],
}

///|
let durable_shape_selection_decision_id : SelectionDecisionId = SelectionDecisionId(
  "",
)

///|
let durable_shape_goal_selection_decision : GoalSelectionDecision = {
  id: durable_shape_selection_decision_id,
  proposal: durable_shape_goal_proposal,
  proposal_digest: durable_shape_digest,
  source_snapshot_digest: durable_shape_digest,
  proposed_part_ids: [durable_shape_part_id],
  accepted_parts: [durable_shape_accepted_goal_part],
  rejections: [durable_shape_part_selection_rejection],
  goal: Some(durable_shape_goal),
  outcome: durable_shapes_goal_selection_outcome[0],
}

///|
let durable_shape_harness_command_id : @control.HarnessCommandId = @control.HarnessCommandId(
  "",
)

///|
let durable_shape_harness_command_intent : @control.HarnessCommandIntent = {
  effect_id: durable_shape_effect_id,
  session_id: durable_shape_harness_session_id,
  command_id: durable_shape_harness_command_id,
  command_sequence: 0,
  required_provider_cursor: Some(""),
  command_artifact_digest: durable_shape_digest,
  provider_idempotency_token: Some(""),
}

///|
let durable_shape_harness_session_start_intent : @control.HarnessSessionStartIntent = {
  effect_id: durable_shape_effect_id,
  session_id: durable_shape_harness_session_id,
  take_id: durable_shape_take_id,
  provider_surface_and_profile_digest: durable_shape_digest,
  declared_surface_digest: durable_shape_digest,
  initial_command_artifact_digest: Some(durable_shape_digest),
  supervisor_key: "",
}

///|
let durable_shape_implementation_execution_result : ImplementationExecutionResult = {
  take_id: durable_shape_take_id,
  session_id: durable_shape_harness_session_id,
  result_artifact: durable_shape_artifact_reference,
  finished_at: 0L,
}

///|
let durable_shape_integration_conflict : @control.IntegrationConflict = {
  id: durable_shape_integration_conflict_id,
  intent_id: durable_shape_integration_intent_id,
  candidate_id: durable_shape_candidate_id,
  candidate_commit_oid: durable_shape_git_oid,
  expected_goal_head_oid: durable_shape_git_oid,
  expected_goal_head_tree_oid: durable_shape_git_oid,
  merge_base_oid: durable_shape_git_oid,
  conflicting_paths: [durable_shape_repo_path],
  evidence_digest: durable_shape_digest,
}

///|
let durable_shapes_integration_intent_lifecycle : Array[
  @control.IntegrationIntentLifecycle,
] = [
  @control.IntegrationIntentLifecycle::IntegrationPlanned,
  @control.IntegrationIntentLifecycle::IntegrationPrepared,
  @control.IntegrationIntentLifecycle::IntegrationAuthorized,
  @control.IntegrationIntentLifecycle::IntegrationReceipted,
  @control.IntegrationIntentLifecycle::IntegrationConflict,
  @control.IntegrationIntentLifecycle::IntegrationIntegrityBlocked,
  @control.IntegrationIntentLifecycle::IntegrationUncertain,
  @control.IntegrationIntentLifecycle::IntegrationAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_integration_intent_lifecycle(
  value : @control.IntegrationIntentLifecycle,
) -> Json {
  match value {
    IntegrationPlanned
    | IntegrationPrepared
    | IntegrationAuthorized
    | IntegrationReceipted
    | IntegrationConflict
    | IntegrationIntegrityBlocked
    | IntegrationUncertain
    | IntegrationAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shapes_promotion_strategy : Array[@control.PromotionStrategy] = [
  @control.PromotionStrategy::NoFastForwardThreeWayV1,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_promotion_strategy(value : @control.PromotionStrategy) -> Json {
  match value {
    NoFastForwardThreeWayV1 => value.to_json()
  }
}

///|
let durable_shape_integration_intent : @control.IntegrationIntent = {
  id: durable_shape_integration_intent_id,
  goal_id: durable_shape_goal_id,
  part_id: durable_shape_part_id,
  commit_title: durable_shape_semantic_commit_title,
  candidate_id: durable_shape_candidate_id,
  candidate_commit_oid: durable_shape_git_oid,
  candidate_tree_oid: durable_shape_git_oid,
  expected_goal_head_oid: durable_shape_git_oid,
  strategy: durable_shapes_promotion_strategy[0],
  promotion_metadata_digest: durable_shape_digest,
  integration_lease_epoch: durable_shape_fencing_epoch,
  lifecycle: durable_shapes_integration_intent_lifecycle[0],
  promotion_commit_oid: Some(durable_shape_git_oid),
  promotion_tree_oid: Some(durable_shape_git_oid),
  git_witness_ref: "",
}

///|
let durable_shapes_integration_witness_observation : Array[
  @control.IntegrationWitnessObservation,
] = [
  @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
    durable_shape_git_oid, durable_shape_git_oid,
  ),
  @control.IntegrationWitnessObservation::IntegrationWitnessNotApplied(
    durable_shape_git_oid,
  ),
  @control.IntegrationWitnessObservation::IntegrationWitnessDiverged,
  @control.IntegrationWitnessObservation::IntegrationWitnessIntegrityError,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_integration_witness_observation(
  value : @control.IntegrationWitnessObservation,
) -> Json {
  match value {
    IntegrationWitnessApplied(_, _)
    | IntegrationWitnessNotApplied(_)
    | IntegrationWitnessDiverged
    | IntegrationWitnessIntegrityError => value.to_json()
  }
}

///|
let durable_shape_part_command_preparation_plan : PartCommandPreparationPlan = {
  role: durable_shapes_command_role[0],
  take: durable_shape_take,
  session_id: durable_shape_harness_session_id,
  subject: durable_shapes_command_execution_subject[0],
  goal_contract_digest: durable_shape_digest,
  task_contract_revision_id: durable_shape_revision_id,
  task_contract_digest: durable_shape_digest,
  instruction_artifact_digest: durable_shape_digest,
  migration_contract_ref: Some(durable_shape_migration_contract_ref),
  provider_surface: durable_shapes_provider_surface_id[0],
  provider_surface_and_profile_digest: durable_shape_digest,
  context_assembly_policy_digest: durable_shape_digest,
  context_manifest: Some(durable_shape_part_context_manifest),
  template_digest: durable_shape_digest,
  maximum_command_bytes: 0,
}

///|
let durable_shapes_provider_availability : Array[@control.ProviderAvailability] = [
  @control.ProviderAvailability::ProviderAvailable,
  @control.ProviderAvailability::ProviderUnavailable,
  @control.ProviderAvailability::ProviderAllowanceExhausted(Some(0L)),
  @control.ProviderAvailability::ProviderRetryAfter(0L),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_provider_availability(
  value : @control.ProviderAvailability,
) -> Json {
  match value {
    ProviderAvailable
    | ProviderUnavailable
    | ProviderAllowanceExhausted(_)
    | ProviderRetryAfter(_) => value.to_json()
  }
}

///|
let durable_shape_part_dispatch_diagnostic : PartDispatchDiagnostic = {
  take_id: durable_shape_take_id,
  session_id: Some(durable_shape_harness_session_id),
  reason: Some(durable_shapes_take_uncertainty_reason[0]),
  detail: "",
  recovery: Some(""),
  availability: durable_shapes_provider_availability[0],
}

///|
let durable_shape_part_verification_subject : @control.PartVerificationSubject = {
  part_id: durable_shape_part_id,
  candidate_take_id: durable_shape_take_id,
  candidate_commit_oid: durable_shape_git_oid,
  candidate_tree_oid: durable_shape_git_oid,
  task_contract_revision_id: durable_shape_revision_id,
  task_contract_digest: durable_shape_digest,
  subject_digest: durable_shape_digest,
}

///|
let durable_shape_promotion_commit : @control.PromotionCommit = {
  intent_id: durable_shape_integration_intent_id,
  commit_oid: durable_shape_git_oid,
  tree_oid: durable_shape_git_oid,
  first_parent_oid: durable_shape_git_oid,
  second_parent_oid: durable_shape_git_oid,
}

///|
let durable_shapes_part_effect_kind : Array[PartEffectKind] = [
  PartEffectKind::PrepareImplementationSandbox(durable_shape_sandbox_lease),
  PartEffectKind::PrepareImplementationCommand(
    durable_shape_part_command_preparation_plan,
  ),
  PartEffectKind::StartImplementationHarness(
    durable_shape_harness_session, durable_shape_harness_session_start_intent,
  ),
  PartEffectKind::DispatchImplementation(
    durable_shape_take_id, durable_shape_harness_command_intent,
  ),
  PartEffectKind::NormalizeImplementationCandidate(
    durable_shape_take_id, durable_shape_digest,
  ),
  PartEffectKind::PrepareVerificationSandbox(durable_shape_sandbox_lease),
  PartEffectKind::DispatchVerification(
    durable_shape_take_id, durable_shape_part_verification_subject,
  ),
  PartEffectKind::PrepareAuditSandbox(durable_shape_sandbox_lease),
  PartEffectKind::PrepareAuditCommand(
    durable_shape_part_command_preparation_plan,
  ),
  PartEffectKind::StartAuditHarness(
    durable_shape_harness_session, durable_shape_harness_session_start_intent,
  ),
  PartEffectKind::DispatchAudit(
    durable_shape_take_id, durable_shape_harness_command_intent, durable_shape_part_audit_subject,
  ),
  PartEffectKind::GeneratePromotion(durable_shape_integration_intent),
  PartEffectKind::ApplyIntegration(
    durable_shape_integration_intent_id, durable_shape_promotion_commit,
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_part_effect_kind(value : PartEffectKind) -> Json {
  match value {
    PrepareImplementationSandbox(_)
    | PrepareImplementationCommand(_)
    | StartImplementationHarness(_, _)
    | DispatchImplementation(_, _)
    | NormalizeImplementationCandidate(_, _)
    | PrepareVerificationSandbox(_)
    | DispatchVerification(_, _)
    | PrepareAuditSandbox(_)
    | PrepareAuditCommand(_)
    | StartAuditHarness(_, _)
    | DispatchAudit(_, _, _)
    | GeneratePromotion(_)
    | ApplyIntegration(_, _) => value.to_json()
  }
}

///|
let durable_shapes_part_effect_lifecycle : Array[PartEffectLifecycle] = [
  PartEffectLifecycle::PartEffectPlanned,
  PartEffectLifecycle::PartEffectMayHaveOccurred,
  PartEffectLifecycle::PartEffectReceipted,
  PartEffectLifecycle::PartEffectUncertain,
  PartEffectLifecycle::PartEffectAbandonedByCancellation,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_part_effect_lifecycle(value : PartEffectLifecycle) -> Json {
  match value {
    PartEffectPlanned
    | PartEffectMayHaveOccurred
    | PartEffectReceipted
    | PartEffectUncertain
    | PartEffectAbandonedByCancellation => value.to_json()
  }
}

///|
let durable_shape_part_effect_intent : PartEffectIntent = {
  effect_id: durable_shape_effect_id,
  kind: durable_shapes_part_effect_kind[0],
  request_digest: durable_shape_digest,
  lifecycle: durable_shapes_part_effect_lifecycle[0],
}

///|
let durable_shape_part_prepared_command : PartPreparedCommand = {
  plan: durable_shape_part_command_preparation_plan,
  command_artifact: durable_shape_artifact_reference,
  provenance: durable_shape_command_preparation_provenance,
}

///|
let durable_shape_verification_execution_result : VerificationExecutionResult = {
  take_id: durable_shape_take_id,
  verification_execution_id: durable_shape_verification_execution_id,
  subject: durable_shape_part_verification_subject,
  verification_spec: durable_shape_verification_spec,
  environment_and_image_digest: durable_shape_digest,
  runtime_and_policy_digest: durable_shape_digest,
  subject_pre_tree_oid: durable_shape_git_oid,
  subject_post_tree_oid: durable_shape_git_oid,
  evidence: durable_shape_artifact_reference,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_verification_outcome[0],
}

///|
let durable_shapes_part_effect_observation : Array[PartEffectObservation] = [
  PartEffectObservation::ImplementationSandboxPrepared(
    durable_shape_sandbox_lease,
  ),
  PartEffectObservation::ImplementationCommandPrepared(
    durable_shape_part_prepared_command,
  ),
  PartEffectObservation::ImplementationHarnessStarted(
    durable_shape_harness_session,
  ),
  PartEffectObservation::ImplementationCompleted(
    durable_shape_implementation_execution_result,
    durable_shape_harness_session,
    [durable_shape_harness_event_envelope],
  ),
  PartEffectObservation::CandidateNormalized(
    durable_shape_candidate_commit, durable_shape_candidate_path_evidence,
  ),
  PartEffectObservation::VerificationSandboxPrepared(
    durable_shape_sandbox_lease,
  ),
  PartEffectObservation::VerificationCompleted(
    durable_shape_verification_execution_result,
  ),
  PartEffectObservation::AuditSandboxPrepared(durable_shape_sandbox_lease),
  PartEffectObservation::AuditCommandPrepared(
    durable_shape_part_prepared_command,
  ),
  PartEffectObservation::AuditHarnessStarted(durable_shape_harness_session),
  PartEffectObservation::AuditCompleted(
    durable_shape_audit_submission,
    durable_shape_harness_session,
    [durable_shape_harness_event_envelope],
  ),
  PartEffectObservation::PromotionGenerated(durable_shape_promotion_commit),
  PartEffectObservation::PromotionConflictObserved(
    durable_shape_integration_conflict,
  ),
  PartEffectObservation::IntegrationWitnessObserved(
    durable_shapes_integration_witness_observation[0],
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_part_effect_observation(value : PartEffectObservation) -> Json {
  match value {
    ImplementationSandboxPrepared(_)
    | ImplementationCommandPrepared(_)
    | ImplementationHarnessStarted(_)
    | ImplementationCompleted(_, _, _)
    | CandidateNormalized(_, _)
    | VerificationSandboxPrepared(_)
    | VerificationCompleted(_)
    | AuditSandboxPrepared(_)
    | AuditCommandPrepared(_)
    | AuditHarnessStarted(_)
    | AuditCompleted(_, _, _)
    | PromotionGenerated(_)
    | PromotionConflictObserved(_)
    | IntegrationWitnessObserved(_) => value.to_json()
  }
}

///|
let durable_shape_part_effect_receipt : PartEffectReceipt = {
  effect_id: durable_shape_effect_id,
  request_digest: durable_shape_digest,
  observation_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shape_part_effect_witness : PartEffectWitness = {
  effect_id: durable_shape_effect_id,
  request_digest: durable_shape_digest,
  observation: durable_shapes_part_effect_observation[0],
  observation_digest: durable_shape_digest,
  observed_at: 0L,
}

///|
let durable_shape_part_identity_plan : PartIdentityPlan = {
  implementation_take: durable_shape_take,
  implementation_sandbox: durable_shape_sandbox_lease,
  implementation_session: durable_shape_harness_session,
  verification_take: durable_shape_take,
  verification_sandbox: durable_shape_sandbox_lease,
  audit_take: durable_shape_take,
  audit_sandbox: durable_shape_sandbox_lease,
  audit_session: durable_shape_harness_session,
}

///|
let durable_shapes_part_workflow_stage : Array[PartWorkflowStage] = [
  PartWorkflowStage::PartAccepted,
  PartWorkflowStage::PartImplementationSandboxPrepared,
  PartWorkflowStage::PartImplementationCommandPrepared,
  PartWorkflowStage::PartImplementationHarnessStarted,
  PartWorkflowStage::PartImplementationCompleted,
  PartWorkflowStage::PartCandidateRecorded,
  PartWorkflowStage::PartVerificationSandboxPrepared,
  PartWorkflowStage::PartVerified,
  PartWorkflowStage::PartAuditSandboxPrepared,
  PartWorkflowStage::PartAuditCommandPrepared,
  PartWorkflowStage::PartAuditHarnessStarted,
  PartWorkflowStage::PartAuditResultRecorded,
  PartWorkflowStage::PartAudited,
  PartWorkflowStage::PartIntegrationPlanned,
  PartWorkflowStage::PartPromotionPrepared,
  PartWorkflowStage::PartIntegrationAuthorized,
  PartWorkflowStage::PartIntegrated,
  PartWorkflowStage::PartCanceled,
  PartWorkflowStage::PartBlocked,
  PartWorkflowStage::PartRecoveryUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_part_workflow_stage(value : PartWorkflowStage) -> Json {
  match value {
    PartAccepted
    | PartImplementationSandboxPrepared
    | PartImplementationCommandPrepared
    | PartImplementationHarnessStarted
    | PartImplementationCompleted
    | PartCandidateRecorded
    | PartVerificationSandboxPrepared
    | PartVerified
    | PartAuditSandboxPrepared
    | PartAuditCommandPrepared
    | PartAuditHarnessStarted
    | PartAuditResultRecorded
    | PartAudited
    | PartIntegrationPlanned
    | PartPromotionPrepared
    | PartIntegrationAuthorized
    | PartIntegrated
    | PartCanceled
    | PartBlocked
    | PartRecoveryUncertain => value.to_json()
  }
}

///|
let durable_shape_verification_authorization_set : @control.VerificationAuthorizationSet = {
  subject_digest: durable_shape_digest,
  receipt_ids: [durable_shape_receipt_id],
  receipt_set_digest: durable_shape_digest,
  evidence_manifest_digest: durable_shape_digest,
}

///|
let durable_shape_verification_receipt : @control.VerificationReceipt = {
  receipt_id: durable_shape_receipt_id,
  verification_take_id: durable_shape_take_id,
  verification_execution_id: durable_shape_verification_execution_id,
  subject: durable_shape_part_verification_subject,
  verification_spec: durable_shape_verification_spec,
  prepared_environment_and_image_digest: durable_shape_digest,
  sandbox_runtime_and_policy_digest: durable_shape_digest,
  subject_pre_tree_oid: durable_shape_git_oid,
  subject_post_tree_oid: durable_shape_git_oid,
  evidence: durable_shape_artifact_reference,
  started_at: 0L,
  finished_at: 0L,
  outcome: durable_shapes_verification_outcome[0],
}

///|
let durable_shape_prior_part_take_evidence : PriorPartTakeEvidence = {
  task_contract_revision_id: durable_shape_revision_id,
  implementation_result: Some(durable_shape_implementation_execution_result),
  candidate: Some(durable_shape_candidate_commit),
  verification_receipts: [durable_shape_verification_receipt],
  verification_authorization: Some(durable_shape_verification_authorization_set),
  audit_result: Some(durable_shape_audit_result),
  audit_receipt: Some(durable_shape_audit_receipt),
  integration_intent: Some(durable_shape_integration_intent),
  integration_receipt: Some(durable_shape_integration_receipt),
}

///|
let durable_shape_verification_authorization_slot : @control.VerificationAuthorizationSlot = {
  subject_digest: durable_shape_digest,
  verification_spec: durable_shape_verification_spec,
  lowest_admitted_execution_ordinal: 0,
  authorizing_receipt_id: Some(durable_shape_receipt_id),
}

///|
let durable_shape_part_workflow_snapshot : PartWorkflowSnapshot = {
  workflow_id: durable_shape_workflow_id,
  durable_version: 0,
  fencing_epoch: durable_shape_fencing_epoch,
  stage: durable_shapes_part_workflow_stage[0],
  goal: durable_shape_goal,
  part: durable_shape_goal_part,
  task_contract: durable_shape_task_contract_revision,
  task_contract_history: [durable_shape_task_contract_revision],
  part_context_manifest: Some(durable_shape_part_context_manifest),
  identities: durable_shape_part_identity_plan,
  implementation_take: durable_shape_take,
  verification_take: durable_shape_take,
  audit_take: durable_shape_take,
  prior_takes: [durable_shape_take],
  prior_take_evidence: [durable_shape_prior_part_take_evidence],
  sandbox_leases: [durable_shape_sandbox_lease],
  harness_sessions: [durable_shape_harness_session],
  harness_events: [durable_shape_harness_event_envelope],
  prepared_commands: [durable_shape_part_prepared_command],
  implementation_result: Some(durable_shape_implementation_execution_result),
  candidate: Some(durable_shape_candidate_commit),
  verification_subject: Some(durable_shape_part_verification_subject),
  verification_slots: [durable_shape_verification_authorization_slot],
  verification_receipts: [durable_shape_verification_receipt],
  verification_authorization: Some(durable_shape_verification_authorization_set),
  audit_subject: Some(durable_shape_part_audit_subject),
  audit_result: Some(durable_shape_audit_result),
  audit_receipt: Some(durable_shape_audit_receipt),
  integration_lease: Some(durable_shape_goal_integration_lease),
  integration_intent: Some(durable_shape_integration_intent),
  promotion_commit: Some(durable_shape_promotion_commit),
  integration_receipt: Some(durable_shape_integration_receipt),
  integration_conflicts: [durable_shape_integration_conflict],
  pending_effect: Some(durable_shape_part_effect_intent),
  effect_receipts: [durable_shape_part_effect_receipt],
  dispatch_diagnostic: Some(durable_shape_part_dispatch_diagnostic),
}

///|
let durable_shapes_process_execution_disposition : Array[
  @sandbox.ProcessExecutionDisposition,
] = [
  @sandbox.ProcessExecutionDisposition::ProcessStartPlanned,
  @sandbox.ProcessExecutionDisposition::ProcessStartMayHaveOccurred,
  @sandbox.ProcessExecutionDisposition::ProcessExited(0, durable_shape_digest),
  @sandbox.ProcessExecutionDisposition::ProcessTimedOut,
  @sandbox.ProcessExecutionDisposition::ProcessLimitExceeded,
  @sandbox.ProcessExecutionDisposition::ProcessInterrupted,
  @sandbox.ProcessExecutionDisposition::ProcessSandboxLost,
  @sandbox.ProcessExecutionDisposition::ProcessStartUncertain,
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_process_execution_disposition(
  value : @sandbox.ProcessExecutionDisposition,
) -> Json {
  match value {
    ProcessStartPlanned
    | ProcessStartMayHaveOccurred
    | ProcessExited(_, _)
    | ProcessTimedOut
    | ProcessLimitExceeded
    | ProcessInterrupted
    | ProcessSandboxLost
    | ProcessStartUncertain => value.to_json()
  }
}

///|
let durable_shape_process_execution_id : @sandbox.ProcessExecutionId = @sandbox.ProcessExecutionId(
  "",
)

///|
let durable_shape_runtime_execution_key : @sandbox.RuntimeExecutionKey = @sandbox.RuntimeExecutionKey(
  "",
)

///|
let durable_shapes_sandbox_process_authority : Array[
  @sandbox.SandboxProcessAuthority,
] = [
  @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
    durable_shape_take_id, durable_shape_digest,
  ),
  @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
    durable_shape_take_id, durable_shape_verification_spec_id, durable_shape_digest,
  ),
  @sandbox.SandboxProcessAuthority::SandboxAuditTool(
    durable_shape_take_id, durable_shape_digest,
  ),
]

///|
/// Exhaustive: a new variant does not compile until it is listed here and
/// in the array above.
fn durable_guard_sandbox_process_authority(
  value : @sandbox.SandboxProcessAuthority,
) -> Json {
  match value {
    SandboxImplementationTool(_, _)
    | SandboxVerificationTool(_, _, _)
    | SandboxAuditTool(_, _) => value.to_json()
  }
}

///|
let durable_shape_process_execution : @sandbox.ProcessExecution = {
  execution_id: durable_shape_process_execution_id,
  effect_intent_id: durable_shape_effect_id,
  runtime_execution_key: durable_shape_runtime_execution_key,
  take_id: durable_shape_take_id,
  process_authority: durable_shapes_sandbox_process_authority[0],
  validated_process_spec_digest: durable_shape_digest,
  sandbox_lease_id: durable_shape_sandbox_lease_id,
  sandbox_generation_id: durable_shape_sandbox_generation_id,
  capability_profile_digest: durable_shape_digest,
  input_artifact_set_digest: durable_shape_digest,
  output_artifact_set_digest: Some(durable_shape_digest),
  started_at: Some(0L),
  finished_at: Some(0L),
  disposition: durable_shapes_process_execution_disposition[0],
}

///|
/// Every type that reaches a durable record, paired with the serialized form
/// of each shape it can take. Sorted by name at use so that moving a
/// declaration in this file does not move the generation.
///
/// A type that stops being reachable from a stored record belongs out of here:
/// left behind, it keeps a dead shape able to authorize a reset.
///
/// Deliberately absent: `@storage.ArtifactRetention`. The retention ledger is
/// line-oriented text, not JSON, and its reader skips a line it cannot read, so
/// a shape change there leaks artifacts rather than wedging a decode — not
/// grounds to destroy the store. `@storage.ArtifactProvenance` is never
/// persisted at all; it is returned in an adoption receipt and dropped.
fn durable_shape_table() -> Array[(String, Array[Json])] {
  [
    ("AcceptedGoalPart", [durable_shape_accepted_goal_part.to_json()]),
    ("ArtifactReference", [durable_shape_artifact_reference.to_json()]),
    (
      "AuditGateCorruptionReason",
      durable_shapes_audit_gate_corruption_reason.map(
        durable_guard_audit_gate_corruption_reason,
      ),
    ),
    (
      "AuditGateObservation",
      durable_shapes_audit_gate_observation.map(
        durable_guard_audit_gate_observation,
      ),
    ),
    (
      "AuditGateRejectionReason",
      durable_shapes_audit_gate_rejection_reason.map(
        durable_guard_audit_gate_rejection_reason,
      ),
    ),
    (
      "AuditGateStaleReason",
      durable_shapes_audit_gate_stale_reason.map(
        durable_guard_audit_gate_stale_reason,
      ),
    ),
    (
      "AuditOutcome",
      durable_shapes_audit_outcome.map(durable_guard_audit_outcome),
    ),
    ("AuditReceipt", [durable_shape_audit_receipt.to_json()]),
    ("AuditRepairReference", [durable_shape_audit_repair_reference.to_json()]),
    (
      "AuditRepairScope",
      durable_shapes_audit_repair_scope.map(durable_guard_audit_repair_scope),
    ),
    ("AuditResult", [durable_shape_audit_result.to_json()]),
    ("AuditResultId", [durable_shape_audit_result_id.to_json()]),
    ("AuditSubmission", [durable_shape_audit_submission.to_json()]),
    (
      "BranchPublicationIntent",
      [durable_shape_branch_publication_intent.to_json()],
    ),
    (
      "BranchPublicationIntentId",
      [durable_shape_branch_publication_intent_id.to_json()],
    ),
    (
      "BranchPublicationReceipt",
      [durable_shape_branch_publication_receipt.to_json()],
    ),
    (
      "BranchPublicationReceiptOrigin",
      durable_shapes_branch_publication_receipt_origin.map(
        durable_guard_branch_publication_receipt_origin,
      ),
    ),
    (
      "BranchPublicationState",
      durable_shapes_branch_publication_state.map(
        durable_guard_branch_publication_state,
      ),
    ),
    ("CancellationSummaryId", [durable_shape_cancellation_summary_id.to_json()]),
    ("CandidateCommit", [durable_shape_candidate_commit.to_json()]),
    ("CandidateId", [durable_shape_candidate_id.to_json()]),
    ("CandidatePathEvidence", [durable_shape_candidate_path_evidence.to_json()]),
    (
      "CommandExecutionSubject",
      durable_shapes_command_execution_subject.map(
        durable_guard_command_execution_subject,
      ),
    ),
    (
      "CommandPreparationProvenance",
      [durable_shape_command_preparation_provenance.to_json()],
    ),
    ("CommandRole", durable_shapes_command_role.map(durable_guard_command_role)),
    ("ConductorPartProposal", [durable_shape_conductor_part_proposal.to_json()]),
    ("Digest", [durable_shape_digest.to_json()]),
    ("EffectId", [durable_shape_effect_id.to_json()]),
    (
      "EventRedactionState",
      durable_shapes_event_redaction_state.map(
        durable_guard_event_redaction_state,
      ),
    ),
    ("EventSequence", [durable_shape_event_sequence.to_json()]),
    (
      "EventSourcePosition",
      durable_shapes_event_source_position.map(
        durable_guard_event_source_position,
      ),
    ),
    ("FencingEpoch", [durable_shape_fencing_epoch.to_json()]),
    ("FinalizationId", [durable_shape_finalization_id.to_json()]),
    ("GitOid", [durable_shape_git_oid.to_json()]),
    ("GitRefName", [durable_shape_git_ref_name.to_json()]),
    ("Goal", [durable_shape_goal.to_json()]),
    (
      "GoalActiveCondition",
      durable_shapes_goal_active_condition.map(
        durable_guard_goal_active_condition,
      ),
    ),
    (
      "GoalAssuranceBlockReason",
      durable_shapes_goal_assurance_block_reason.map(
        durable_guard_goal_assurance_block_reason,
      ),
    ),
    (
      "GoalAssuranceEffectIntent",
      [durable_shape_goal_assurance_effect_intent.to_json()],
    ),
    (
      "GoalAssuranceEffectKind",
      durable_shapes_goal_assurance_effect_kind.map(
        durable_guard_goal_assurance_effect_kind,
      ),
    ),
    (
      "GoalAssuranceEffectLifecycle",
      durable_shapes_goal_assurance_effect_lifecycle.map(
        durable_guard_goal_assurance_effect_lifecycle,
      ),
    ),
    (
      "GoalAssuranceEffectObservation",
      durable_shapes_goal_assurance_effect_observation.map(
        durable_guard_goal_assurance_effect_observation,
      ),
    ),
    (
      "GoalAssuranceEffectReceipt",
      [durable_shape_goal_assurance_effect_receipt.to_json()],
    ),
    (
      "GoalAssuranceEffectWitness",
      [durable_shape_goal_assurance_effect_witness.to_json()],
    ),
    (
      "GoalAssuranceIdentityPlan",
      [durable_shape_goal_assurance_identity_plan.to_json()],
    ),
    ("GoalAssuranceRecord", [durable_shape_goal_assurance_record.to_json()]),
    (
      "GoalAssuranceStage",
      durable_shapes_goal_assurance_stage.map(
        durable_guard_goal_assurance_stage,
      ),
    ),
    ("GoalAuditReceipt", [durable_shape_goal_audit_receipt.to_json()]),
    ("GoalAuditResult", [durable_shape_goal_audit_result.to_json()]),
    ("GoalAuditSubject", [durable_shape_goal_audit_subject.to_json()]),
    ("GoalAuditSubmission", [durable_shape_goal_audit_submission.to_json()]),
    (
      "GoalBranchInitIntentId",
      [durable_shape_goal_branch_init_intent_id.to_json()],
    ),
    (
      "GoalBranchInitLifecycle",
      durable_shapes_goal_branch_init_lifecycle.map(
        durable_guard_goal_branch_init_lifecycle,
      ),
    ),
    (
      "GoalBranchInitReceipt",
      [durable_shape_goal_branch_init_receipt.to_json()],
    ),
    (
      "GoalBranchInitialization",
      [durable_shape_goal_branch_initialization.to_json()],
    ),
    ("GoalBranchSeal", [durable_shape_goal_branch_seal.to_json()]),
    (
      "GoalBranchSealFailureReason",
      durable_shapes_goal_branch_seal_failure_reason.map(
        durable_guard_goal_branch_seal_failure_reason,
      ),
    ),
    ("GoalBranchSealId", [durable_shape_goal_branch_seal_id.to_json()]),
    ("GoalBranchSealIntent", [durable_shape_goal_branch_seal_intent.to_json()]),
    (
      "GoalBranchSealIntentId",
      [durable_shape_goal_branch_seal_intent_id.to_json()],
    ),
    (
      "GoalBranchSealIntentLifecycle",
      durable_shapes_goal_branch_seal_intent_lifecycle.map(
        durable_guard_goal_branch_seal_intent_lifecycle,
      ),
    ),
    (
      "GoalCancellationCause",
      durable_shapes_goal_cancellation_cause.map(
        durable_guard_goal_cancellation_cause,
      ),
    ),
    (
      "GoalCancellationRequest",
      [durable_shape_goal_cancellation_request.to_json()],
    ),
    (
      "GoalCompletionMode",
      durable_shapes_goal_completion_mode.map(
        durable_guard_goal_completion_mode,
      ),
    ),
    ("GoalExecutionRecord", [durable_shape_goal_execution_record.to_json()]),
    (
      "GoalExecutionState",
      durable_shapes_goal_execution_state.map(
        durable_guard_goal_execution_state,
      ),
    ),
    (
      "GoalFinalizationRecord",
      [durable_shape_goal_finalization_record.to_json()],
    ),
    ("GoalId", [durable_shape_goal_id.to_json()]),
    ("GoalInputAnswer", [durable_shape_goal_input_answer.to_json()]),
    (
      "GoalInputReason",
      durable_shapes_goal_input_reason.map(durable_guard_goal_input_reason),
    ),
    ("GoalInputRequest", [durable_shape_goal_input_request.to_json()]),
    ("GoalInputRequestId", [durable_shape_goal_input_request_id.to_json()]),
    ("GoalIntegrationLease", [durable_shape_goal_integration_lease.to_json()]),
    (
      "GoalLifecycle",
      durable_shapes_goal_lifecycle.map(durable_guard_goal_lifecycle),
    ),
    ("GoalPart", [durable_shape_goal_part.to_json()]),
    ("GoalPause", [durable_shape_goal_pause.to_json()]),
    (
      "GoalPauseReason",
      durable_shapes_goal_pause_reason.map(durable_guard_goal_pause_reason),
    ),
    (
      "GoalPolicyChange",
      durable_shapes_goal_policy_change.map(durable_guard_goal_policy_change),
    ),
    ("GoalPolicyRevision", [durable_shape_goal_policy_revision.to_json()]),
    ("GoalProposal", [durable_shape_goal_proposal.to_json()]),
    ("GoalProposalId", [durable_shape_goal_proposal_id.to_json()]),
    ("GoalPublicationRecord", [durable_shape_goal_publication_record.to_json()]),
    (
      "GoalPullRequestRecord",
      [durable_shape_goal_pull_request_record.to_json()],
    ),
    ("GoalSelectionDecision", [durable_shape_goal_selection_decision.to_json()]),
    (
      "GoalSelectionOutcome",
      durable_shapes_goal_selection_outcome.map(
        durable_guard_goal_selection_outcome,
      ),
    ),
    (
      "GoalSelectionPolicy",
      durable_shapes_goal_selection_policy.map(
        durable_guard_goal_selection_policy,
      ),
    ),
    ("GoalSourceClaim", [durable_shape_goal_source_claim.to_json()]),
    (
      "GoalSourceClaimConflictReason",
      durable_shapes_goal_source_claim_conflict_reason.map(
        durable_guard_goal_source_claim_conflict_reason,
      ),
    ),
    (
      "GoalSourceClaimIntentId",
      [durable_shape_goal_source_claim_intent_id.to_json()],
    ),
    (
      "GoalSourceClaimLifecycle",
      durable_shapes_goal_source_claim_lifecycle.map(
        durable_guard_goal_source_claim_lifecycle,
      ),
    ),
    (
      "GoalSourceClaimReceipt",
      [durable_shape_goal_source_claim_receipt.to_json()],
    ),
    (
      "GoalSourceReleaseReceipt",
      [durable_shape_goal_source_release_receipt.to_json()],
    ),
    (
      "GoalVerificationAuthorizationSet",
      [durable_shape_goal_verification_authorization_set.to_json()],
    ),
    (
      "GoalVerificationAuthorizationSlot",
      [durable_shape_goal_verification_authorization_slot.to_json()],
    ),
    (
      "GoalVerificationExecutionResult",
      [durable_shape_goal_verification_execution_result.to_json()],
    ),
    (
      "GoalVerificationReceipt",
      [durable_shape_goal_verification_receipt.to_json()],
    ),
    (
      "GoalVerificationSpecExecution",
      [durable_shape_goal_verification_spec_execution.to_json()],
    ),
    (
      "GoalVerificationSubject",
      [durable_shape_goal_verification_subject.to_json()],
    ),
    ("HarnessCommandId", [durable_shape_harness_command_id.to_json()]),
    ("HarnessCommandIntent", [durable_shape_harness_command_intent.to_json()]),
    (
      "HarnessCursorClass",
      durable_shapes_harness_cursor_class.map(
        durable_guard_harness_cursor_class,
      ),
    ),
    ("HarnessEventEnvelope", [durable_shape_harness_event_envelope.to_json()]),
    ("HarnessEventId", [durable_shape_harness_event_id.to_json()]),
    (
      "HarnessEventKind",
      durable_shapes_harness_event_kind.map(durable_guard_harness_event_kind),
    ),
    ("HarnessSession", [durable_shape_harness_session.to_json()]),
    ("HarnessSessionId", [durable_shape_harness_session_id.to_json()]),
    (
      "HarnessSessionLifecycle",
      durable_shapes_harness_session_lifecycle.map(
        durable_guard_harness_session_lifecycle,
      ),
    ),
    (
      "HarnessSessionStartIntent",
      [durable_shape_harness_session_start_intent.to_json()],
    ),
    (
      "HarnessTerminalObservation",
      durable_shapes_harness_terminal_observation.map(
        durable_guard_harness_terminal_observation,
      ),
    ),
    (
      "HarnessToolDisposition",
      durable_shapes_harness_tool_disposition.map(
        durable_guard_harness_tool_disposition,
      ),
    ),
    (
      "ImplementationExecutionResult",
      [durable_shape_implementation_execution_result.to_json()],
    ),
    ("IntegrationConflict", [durable_shape_integration_conflict.to_json()]),
    ("IntegrationConflictId", [durable_shape_integration_conflict_id.to_json()]),
    ("IntegrationIntent", [durable_shape_integration_intent.to_json()]),
    ("IntegrationIntentId", [durable_shape_integration_intent_id.to_json()]),
    (
      "IntegrationIntentLifecycle",
      durable_shapes_integration_intent_lifecycle.map(
        durable_guard_integration_intent_lifecycle,
      ),
    ),
    ("IntegrationLeaseId", [durable_shape_integration_lease_id.to_json()]),
    ("IntegrationReceipt", [durable_shape_integration_receipt.to_json()]),
    ("IntegrationReceiptId", [durable_shape_integration_receipt_id.to_json()]),
    (
      "IntegrationWitnessObservation",
      durable_shapes_integration_witness_observation.map(
        durable_guard_integration_witness_observation,
      ),
    ),
    ("MigrationContractId", [durable_shape_migration_contract_id.to_json()]),
    ("MigrationContractRef", [durable_shape_migration_contract_ref.to_json()]),
    ("MigrationLineageId", [durable_shape_migration_lineage_id.to_json()]),
    (
      "MigrationProductionAdmissionRef",
      [durable_shape_migration_production_admission_ref.to_json()],
    ),
    (
      "ModelIdentity",
      durable_shapes_model_identity.map(durable_guard_model_identity),
    ),
    (
      "MutationClaim",
      durable_shapes_mutation_claim.map(durable_guard_mutation_claim),
    ),
    (
      "MutationDeclaration",
      durable_shapes_mutation_declaration.map(
        durable_guard_mutation_declaration,
      ),
    ),
    ("PartAuditSubject", [durable_shape_part_audit_subject.to_json()]),
    (
      "PartBlockReason",
      durable_shapes_part_block_reason.map(durable_guard_part_block_reason),
    ),
    (
      "PartCommandPreparationPlan",
      [durable_shape_part_command_preparation_plan.to_json()],
    ),
    ("PartContextManifest", [durable_shape_part_context_manifest.to_json()]),
    (
      "PartDispatchDiagnostic",
      [durable_shape_part_dispatch_diagnostic.to_json()],
    ),
    ("PartEffectIntent", [durable_shape_part_effect_intent.to_json()]),
    (
      "PartEffectKind",
      durable_shapes_part_effect_kind.map(durable_guard_part_effect_kind),
    ),
    (
      "PartEffectLifecycle",
      durable_shapes_part_effect_lifecycle.map(
        durable_guard_part_effect_lifecycle,
      ),
    ),
    (
      "PartEffectObservation",
      durable_shapes_part_effect_observation.map(
        durable_guard_part_effect_observation,
      ),
    ),
    ("PartEffectReceipt", [durable_shape_part_effect_receipt.to_json()]),
    ("PartEffectWitness", [durable_shape_part_effect_witness.to_json()]),
    ("PartId", [durable_shape_part_id.to_json()]),
    ("PartIdentityPlan", [durable_shape_part_identity_plan.to_json()]),
    (
      "PartLifecycle",
      durable_shapes_part_lifecycle.map(durable_guard_part_lifecycle),
    ),
    ("PartPreparedCommand", [durable_shape_part_prepared_command.to_json()]),
    (
      "PartSelectionRejection",
      [durable_shape_part_selection_rejection.to_json()],
    ),
    (
      "PartVerificationSubject",
      [durable_shape_part_verification_subject.to_json()],
    ),
    ("PartWorkflowSnapshot", [durable_shape_part_workflow_snapshot.to_json()]),
    (
      "PartWorkflowStage",
      durable_shapes_part_workflow_stage.map(durable_guard_part_workflow_stage),
    ),
    (
      "PriorPartTakeEvidence",
      [durable_shape_prior_part_take_evidence.to_json()],
    ),
    ("ProcessExecution", [durable_shape_process_execution.to_json()]),
    (
      "ProcessExecutionDisposition",
      durable_shapes_process_execution_disposition.map(
        durable_guard_process_execution_disposition,
      ),
    ),
    ("ProcessExecutionId", [durable_shape_process_execution_id.to_json()]),
    ("PromotionCommit", [durable_shape_promotion_commit.to_json()]),
    (
      "PromotionStrategy",
      durable_shapes_promotion_strategy.map(durable_guard_promotion_strategy),
    ),
    (
      "ProviderAvailability",
      durable_shapes_provider_availability.map(
        durable_guard_provider_availability,
      ),
    ),
    (
      "ProviderSurfaceId",
      durable_shapes_provider_surface_id.map(durable_guard_provider_surface_id),
    ),
    (
      "PullRequestCancellationState",
      durable_shapes_pull_request_cancellation_state.map(
        durable_guard_pull_request_cancellation_state,
      ),
    ),
    (
      "PullRequestDeliveryMode",
      durable_shapes_pull_request_delivery_mode.map(
        durable_guard_pull_request_delivery_mode,
      ),
    ),
    (
      "PullRequestDeliveryPolicy",
      [durable_shape_pull_request_delivery_policy.to_json()],
    ),
    ("PullRequestDocument", [durable_shape_pull_request_document.to_json()]),
    (
      "PullRequestIdentityMarker",
      [durable_shape_pull_request_identity_marker.to_json()],
    ),
    ("PullRequestIntent", [durable_shape_pull_request_intent.to_json()]),
    ("PullRequestIntentId", [durable_shape_pull_request_intent_id.to_json()]),
    (
      "PullRequestIntentState",
      durable_shapes_pull_request_intent_state.map(
        durable_guard_pull_request_intent_state,
      ),
    ),
    (
      "PullRequestMarkerState",
      durable_shapes_pull_request_marker_state.map(
        durable_guard_pull_request_marker_state,
      ),
    ),
    (
      "PullRequestMergeMethod",
      durable_shapes_pull_request_merge_method.map(
        durable_guard_pull_request_merge_method,
      ),
    ),
    (
      "PullRequestMergeState",
      durable_shapes_pull_request_merge_state.map(
        durable_guard_pull_request_merge_state,
      ),
    ),
    (
      "PullRequestNeedsInputReason",
      durable_shapes_pull_request_needs_input_reason.map(
        durable_guard_pull_request_needs_input_reason,
      ),
    ),
    ("PullRequestNumber", [durable_shape_pull_request_number.to_json()]),
    (
      "PullRequestProvider",
      durable_shapes_pull_request_provider.map(
        durable_guard_pull_request_provider,
      ),
    ),
    (
      "PullRequestReadinessDecision",
      durable_shapes_pull_request_readiness_decision.map(
        durable_guard_pull_request_readiness_decision,
      ),
    ),
    (
      "PullRequestReadinessDriftReason",
      durable_shapes_pull_request_readiness_drift_reason.map(
        durable_guard_pull_request_readiness_drift_reason,
      ),
    ),
    (
      "PullRequestReadinessNeedsInputReason",
      durable_shapes_pull_request_readiness_needs_input_reason.map(
        durable_guard_pull_request_readiness_needs_input_reason,
      ),
    ),
    (
      "PullRequestReadinessSnapshot",
      [durable_shape_pull_request_readiness_snapshot.to_json()],
    ),
    (
      "PullRequestReadinessSnapshotId",
      [durable_shape_pull_request_readiness_snapshot_id.to_json()],
    ),
    ("PullRequestReceipt", [durable_shape_pull_request_receipt.to_json()]),
    (
      "PullRequestReceiptOrigin",
      durable_shapes_pull_request_receipt_origin.map(
        durable_guard_pull_request_receipt_origin,
      ),
    ),
    ("PullRequestUrl", [durable_shape_pull_request_url.to_json()]),
    ("ReceiptId", [durable_shape_receipt_id.to_json()]),
    ("RemoteName", [durable_shape_remote_name.to_json()]),
    ("RemotePullRequestId", [durable_shape_remote_pull_request_id.to_json()]),
    (
      "RemotePullRequestState",
      durable_shapes_remote_pull_request_state.map(
        durable_guard_remote_pull_request_state,
      ),
    ),
    ("RemoteRepositoryId", [durable_shape_remote_repository_id.to_json()]),
    ("RepoPath", [durable_shape_repo_path.to_json()]),
    ("RepositoryId", [durable_shape_repository_id.to_json()]),
    (
      "RepositoryPathMode",
      durable_shapes_repository_path_mode.map(
        durable_guard_repository_path_mode,
      ),
    ),
    ("RevisionId", [durable_shape_revision_id.to_json()]),
    ("RuntimeExecutionKey", [durable_shape_runtime_execution_key.to_json()]),
    ("SandboxGenerationId", [durable_shape_sandbox_generation_id.to_json()]),
    ("SandboxLease", [durable_shape_sandbox_lease.to_json()]),
    ("SandboxLeaseId", [durable_shape_sandbox_lease_id.to_json()]),
    (
      "SandboxLeaseLifecycle",
      durable_shapes_sandbox_lease_lifecycle.map(
        durable_guard_sandbox_lease_lifecycle,
      ),
    ),
    (
      "SandboxProcessAuthority",
      durable_shapes_sandbox_process_authority.map(
        durable_guard_sandbox_process_authority,
      ),
    ),
    ("SelectionDecisionId", [durable_shape_selection_decision_id.to_json()]),
    (
      "SelectionRejectionReason",
      durable_shapes_selection_rejection_reason.map(
        durable_guard_selection_rejection_reason,
      ),
    ),
    ("SemanticCommitTitle", [durable_shape_semantic_commit_title.to_json()]),
    ("Take", [durable_shape_take.to_json()]),
    (
      "TakeFailureReason",
      durable_shapes_take_failure_reason.map(durable_guard_take_failure_reason),
    ),
    ("TakeId", [durable_shape_take_id.to_json()]),
    (
      "TakeLifecycle",
      durable_shapes_take_lifecycle.map(durable_guard_take_lifecycle),
    ),
    ("TakePurpose", durable_shapes_take_purpose.map(durable_guard_take_purpose)),
    (
      "TakeTerminalDisposition",
      durable_shapes_take_terminal_disposition.map(
        durable_guard_take_terminal_disposition,
      ),
    ),
    (
      "TakeUncertaintyReason",
      durable_shapes_take_uncertainty_reason.map(
        durable_guard_take_uncertainty_reason,
      ),
    ),
    ("TakeUsage", [durable_shape_take_usage.to_json()]),
    ("TaskContractRevision", [durable_shape_task_contract_revision.to_json()]),
    (
      "UnknownMutationReason",
      durable_shapes_unknown_mutation_reason.map(
        durable_guard_unknown_mutation_reason,
      ),
    ),
    (
      "VerificationAuthorizationSet",
      [durable_shape_verification_authorization_set.to_json()],
    ),
    (
      "VerificationAuthorizationSlot",
      [durable_shape_verification_authorization_slot.to_json()],
    ),
    (
      "VerificationExecutionId",
      [durable_shape_verification_execution_id.to_json()],
    ),
    (
      "VerificationExecutionResult",
      [durable_shape_verification_execution_result.to_json()],
    ),
    (
      "VerificationGateCorruptionReason",
      durable_shapes_verification_gate_corruption_reason.map(
        durable_guard_verification_gate_corruption_reason,
      ),
    ),
    (
      "VerificationGateObservation",
      durable_shapes_verification_gate_observation.map(
        durable_guard_verification_gate_observation,
      ),
    ),
    (
      "VerificationGateRejectionReason",
      durable_shapes_verification_gate_rejection_reason.map(
        durable_guard_verification_gate_rejection_reason,
      ),
    ),
    (
      "VerificationGateStaleReason",
      durable_shapes_verification_gate_stale_reason.map(
        durable_guard_verification_gate_stale_reason,
      ),
    ),
    (
      "VerificationOutcome",
      durable_shapes_verification_outcome.map(
        durable_guard_verification_outcome,
      ),
    ),
    ("VerificationReceipt", [durable_shape_verification_receipt.to_json()]),
    (
      "VerificationRepairReference",
      [durable_shape_verification_repair_reference.to_json()],
    ),
    (
      "VerificationRepairScope",
      durable_shapes_verification_repair_scope.map(
        durable_guard_verification_repair_scope,
      ),
    ),
    ("VerificationSpec", [durable_shape_verification_spec.to_json()]),
    ("VerificationSpecId", [durable_shape_verification_spec_id.to_json()]),
    ("WorkOrderBudget", [durable_shape_work_order_budget.to_json()]),
    ("WorkOrderCounters", [durable_shape_work_order_counters.to_json()]),
    (
      "WorkOrderCutoffPolicy",
      durable_shapes_work_order_cutoff_policy.map(
        durable_guard_work_order_cutoff_policy,
      ),
    ),
    (
      "WorkOrderQuotaBasis",
      durable_shapes_work_order_quota_basis.map(
        durable_guard_work_order_quota_basis,
      ),
    ),
    (
      "WorkOrderStopPolicy",
      durable_shapes_work_order_stop_policy.map(
        durable_guard_work_order_stop_policy,
      ),
    ),
    (
      "WorkOrderStopReason",
      durable_shapes_work_order_stop_reason.map(
        durable_guard_work_order_stop_reason,
      ),
    ),
    ("WorkflowId", [durable_shape_workflow_id.to_json()]),
  ]
}

///|
/// Render a serialized shape so that only its structure matters.
///
/// Object keys are sorted, because MoonBit emits them in declaration order and
/// reordering a declaration does not change what decodes. Values are kept: the
/// tag of an enum variant is a string in the serialized form, and losing it
/// would let a renamed variant pass unnoticed. Every value below is a fixed
/// placeholder, so nothing but the shape can move the result.
fn durable_shape_text(value : Json) -> String {
  let rendered = StringBuilder::new()
  match value {
    Json::Object(fields) => {
      let keys : Array[String] = []
      for key in fields.keys() {
        keys.push(key)
      }
      keys.sort_by(fn(left, right) { left.compare(right) })
      rendered.write_string("{")
      for key in keys {
        rendered.write_string(key)
        rendered.write_string(":")
        match fields.get(key) {
          Some(field) => rendered.write_string(durable_shape_text(field))
          None => ()
        }
        rendered.write_string(",")
      }
      rendered.write_string("}")
    }
    Json::Array(items) => {
      rendered.write_string("[")
      for item in items {
        rendered.write_string(durable_shape_text(item))
        rendered.write_string(",")
      }
      rendered.write_string("]")
    }
    Json::String(text) => {
      rendered.write_string("\"")
      rendered.write_string(text)
      rendered.write_string("\"")
    }
    Json::Number(number, ..) => rendered.write_string(number.to_string())
    Json::True => rendered.write_string("true")
    Json::False => rendered.write_string("false")
    Json::Null => rendered.write_string("null")
  }
  rendered.to_string()
}

///|
/// The full serialized shape of everything this build can store, as one text.
///
/// Public because the generation is otherwise a digest with nothing behind it:
/// this is the evidence a reset is decided on, and it is what lets a test
/// check that a record's real keys are the ones being digested.
pub fn durable_value_shape_manifest() -> String {
  let table = durable_shape_table()
  table.sort_by(fn(left, right) { left.0.compare(right.0) })
  let rendered = StringBuilder::new()
  for entry in table {
    rendered.write_string(entry.0)
    for shape in entry.1 {
      rendered.write_string(" ")
      rendered.write_string(durable_shape_text(shape))
    }
    rendered.write_string("\n")
  }
  rendered.to_string()
}

///|
/// What this build calls the durable shapes it can decode.
///
/// Recorded in the control store when it is created or adopted, and compared
/// on every start. A mismatch is affirmative evidence that the store holds
/// records this build cannot read.
pub fn durable_value_shape_generation() -> String {
  "choir-durable-shape-" +
  @storage.digest_text(
    @storage.artifact_digest(@utf8.encode(durable_value_shape_manifest())),
  )
}
