///|
pub(all) enum MigrationFeasibilityOutcome {
  MigrationProceed
  MigrationDecline
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationWorkflowShape {
  MechanicalEvolution
  StructurePreservingPort
  ArchitectureRedesign
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationUnitGranularity {
  FileUnit
  PackageUnit
  SubsystemUnit
  SymbolUnit
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationCapacityEstimate {
  CapacityUnknown
  CapacityEvidenceRange(Int, Int, @control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationFeasibilityReport {
  schema_version : Int
  source_revision : @control.Digest
  reason_artifact_digest : @control.Digest
  workflow_shape : MigrationWorkflowShape
  unit_granularity : MigrationUnitGranularity
  estimated_minimum_units : Int
  estimated_maximum_units : Int
  deterministic_scope_artifact_digest : @control.Digest
  judgment_scope_artifact_digest : @control.Digest
  judge_assessment_artifact_digest : @control.Digest
  evidence_gap_artifact_digest : @control.Digest
  expensive_check_topology_artifact_digest : @control.Digest
  capacity_estimate : MigrationCapacityEstimate
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationFeasibilityProposal {
  report_artifact_digest : @control.Digest
  outcome : MigrationFeasibilityOutcome
  proposed_contract_artifact_digest : @control.Digest?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum RehearsalPolicy {
  RehearsalNotRequired
  RehearsalRequired(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationContract {
  id : @control.MigrationContractId
  migration_lineage_id : @control.MigrationLineageId
  revision : Int
  source_revision : @control.Digest
  workflow_shape : MigrationWorkflowShape
  feasibility_report_artifact_digest : @control.Digest
  target_architecture_artifact_digest : @control.Digest
  rulebook_artifact_digest : @control.Digest
  dependency_map_artifact_digest : @control.Digest
  gap_inventory_artifact_digest : @control.Digest
  inventory_generator_artifact_digest : @control.Digest
  qualified_inventory_artifact_digest : @control.Digest
  transformation_plan_artifact_digest : @control.Digest
  context_assembly_policy_digest : @control.Digest
  judge_definition_digest : @control.Digest
  judge_qualification_assurance_record_digest : @control.Digest
  parity_definition_digest : @control.Digest?
  validation_plan_digest : @control.Digest
  rehearsal_policy : RehearsalPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationContractAuthorization {
  MigrationContractExplicitUserInput(@control.Digest)
  MigrationContractPreacceptedGoalPolicy(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationContractAcceptance {
  contract_ref : @control.MigrationContractRef
  authorization : MigrationContractAuthorization
  accepted_event_sequence : @control.EventSequence
  accepted_at : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PartContextManifest {
  migration_contract_ref : @control.MigrationContractRef
  part_task_contract_revision_id : @control.RevisionId
  part_task_contract_digest : @control.Digest
  context_assembly_policy_digest : @control.Digest
  rulebook_section_digests : Array[@control.Digest]
  dependency_neighborhood_digest : @control.Digest
  applicable_gap_entry_digests : Array[@control.Digest]
  source_path_manifest_digest : @control.Digest
  prior_take_context_digest : @control.Digest?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationFindingId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct MigrationRuleId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct MigrationScenarioId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct InventoryStableKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct MigrationExternalDependencyKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct MigrationOwnershipClaim(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum AgentAssistedReason {
  SemanticJudgment
  CrossUnitContext
  ArchitecturalChoice
  UnsupportedMechanicalTool
  MechanicalQualificationFailed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum UnresolvedGapClass {
  MissingRule
  AmbiguousApplicability
  MissingDependency
  OwnershipConflict
  UnsupportedLanguage
  MissingJudge
  ContextLimit
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum UnitDisposition {
  Irrelevant(MigrationRuleId)
  Mechanical(MigrationRuleId)
  AgentAssisted(AgentAssistedReason)
  Unresolved(UnresolvedGapClass)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationInventoryDependency {
  InventoryUnitDependency(InventoryStableKey)
  InventoryExternalDependency(MigrationExternalDependencyKey)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationInventoryUnit {
  stable_key : InventoryStableKey
  source_paths : Array[@control.RepoPath]
  dependency_keys : Array[MigrationInventoryDependency]
  ownership_claim : MigrationOwnershipClaim
  gap_classes : Array[UnresolvedGapClass]
  disposition : UnitDisposition
  transformation_rule_ids : Array[MigrationRuleId]
  proposed_verification_specs : Array[@control.VerificationSpec]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationInventory {
  schema_version : Int
  source_revision : @control.GitOid
  generator_digest : @control.Digest
  units : Array[MigrationInventoryUnit]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct QualifiedMigrationInventoryRef {
  source_revision : @control.GitOid
  generator_digest : @control.Digest
  inventory_artifact_digest : @control.Digest
  canonical_inventory_digest : @control.Digest
  verification_receipt_id : @control.ReceiptId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeQualificationBinding {
  qualifying_goal_id : @control.GoalId
  qualifying_goal_contract_digest : @control.Digest
  goal_branch_seal_id : @control.GoalBranchSealId
  goal_branch_seal_digest : @control.Digest
  judge_definition_digest : @control.Digest
  source_revision : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum JudgeQualificationTerminal {
  JudgeQualificationSucceeded(@control.FinalizationId)
  JudgeQualificationEvidenceOnlyCanceled(@control.CancellationSummaryId)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeQualificationEvidenceRef {
  binding : JudgeQualificationBinding
  completion_binding_digest : @control.Digest
  assurance_record_digest : @control.Digest
  terminal : JudgeQualificationTerminal
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RehearsalBinding {
  migration_contract_ref : @control.MigrationContractRef
  sampled_inventory_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RehearsalEvidenceRef {
  rehearsal_goal_id : @control.GoalId
  migration_contract_ref : @control.MigrationContractRef
  sampled_inventory_digest : @control.Digest
  completion_binding_digest : @control.Digest
  assurance_record_digest : @control.Digest
  cancellation_summary_id : @control.CancellationSummaryId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationBeadId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum MigrationBeadKind {
  MigrationImplementationBead(AgentAssistedReason)
  MigrationGapBead(UnresolvedGapClass)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationBeadProposal {
  id : MigrationBeadId
  idempotency_key : @control.Digest
  stable_key : InventoryStableKey
  migration_contract_ref : @control.MigrationContractRef
  kind : MigrationBeadKind
  title : String
  ownership_claim : MigrationOwnershipClaim
  source_paths : Array[@control.RepoPath]
  blocking_dependency_ids : Array[MigrationBeadId]
  verification_specs : Array[@control.VerificationSpec]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationFindingClass {
  RuleViolation
  RuleGap
  JudgeFalsePositive
  JudgeFalseNegative
  InventoryOmission
  DependencyMismatch
  OwnershipMismatch
  ApplicabilityMismatch
  BehavioralMismatch
  UnsupportedCase
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationFindingSeverity {
  Advisory
  Blocking
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationFindingDisposition {
  RepairPart
  ReviseContract
  ReviseJudge
  FollowUpGoalRequired
  AwaitUserDecision
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationFindingAnchor {
  Rule(MigrationRuleId)
  JudgeScenario(MigrationScenarioId)
  InventoryUnit(InventoryStableKey)
  DependencyEdge(InventoryStableKey, InventoryStableKey)
  OwnershipClaim(InventoryStableKey)
  ParityScenario(MigrationScenarioId)
  Contract(@control.MigrationContractRef)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationFinding {
  schema_version : Int
  id : MigrationFindingId
  pattern_key : @control.Digest
  class : MigrationFindingClass
  severity : MigrationFindingSeverity
  anchor : MigrationFindingAnchor
  audit_take_id : @control.TakeId
  audit_subject_digest : @control.Digest
  evidence_digest : @control.Digest
  disposition : MigrationFindingDisposition
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationFindingsArtifact {
  schema_version : Int
  findings : Array[MigrationFinding]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationFindingPatternObservation {
  pattern_key : @control.Digest
  class : MigrationFindingClass
  anchor : MigrationFindingAnchor
  occurrence_ids : Array[MigrationFindingId]
} derive(Debug, Eq, ToJson, FromJson)
