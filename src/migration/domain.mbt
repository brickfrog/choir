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
  execution_evidence_digest : @control.Digest
  verification_receipt_id : @control.ReceiptId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationInventoryExecutionEvidence {
  validated_process_spec_digest : @control.Digest
  input_artifact_set_digest : @control.Digest
  first_execution_id : @sandbox.ProcessExecutionId
  second_execution_id : @sandbox.ProcessExecutionId
  first_inventory_artifact_digest : @control.Digest
  second_inventory_artifact_digest : @control.Digest
  canonical_inventory_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum JudgeNegativeControlClass {
  JudgeRuleViolationControl
  JudgeBehavioralMismatchControl
  JudgeDependencyFaultControl
  JudgeTypeFaultControl
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeBaselineExpectation {
  scenario_id : MigrationScenarioId
  normalized_outcome_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum JudgeBaselinePolicy {
  JudgeCleanBaseline
  JudgeExpectedBaselineFailures(Array[JudgeBaselineExpectation])
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeNegativeControl {
  scenario_id : MigrationScenarioId
  class : JudgeNegativeControlClass
  expected_failure_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationJudgeDefinition {
  schema_version : Int
  source_revision : @control.Digest
  scenario_count : Int
  baseline_policy : JudgeBaselinePolicy
  negative_controls : Array[JudgeNegativeControl]
  excluded_surfaces_artifact_digest : @control.Digest
  permitted_nondeterminism_artifact_digest : @control.Digest
  substitute_oracle_artifact_digest : @control.Digest?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum JudgeBaselineClassification {
  JudgeBaselinePassed
  JudgeInheritedSourceFailure
  JudgeEnvironmentMismatch
  JudgeDefect
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeBaselineResult {
  scenario_id : MigrationScenarioId
  normalized_outcome_digest : @control.Digest
  classification : JudgeBaselineClassification
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeNegativeControlResult {
  scenario_id : MigrationScenarioId
  class : JudgeNegativeControlClass
  observed_failure_digest : @control.Digest
  rejected : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JudgeQualificationReport {
  judge_definition_digest : @control.Digest
  source_revision : @control.Digest
  baseline_results : Array[JudgeBaselineResult]
  negative_control_results : Array[JudgeNegativeControlResult]
  goal_verification_receipt_ids : Array[@control.ReceiptId]
  goal_audit_receipt_id : @control.ReceiptId
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
pub(all) struct MigrationProductionAdmissionRef {
  migration_contract_ref : @control.MigrationContractRef
  contract_acceptance_digest : @control.Digest
  judge_definition_digest : @control.Digest
  judge_qualification_report_digest : @control.Digest
  judge_qualification_evidence_ref_digest : @control.Digest
  rehearsal_evidence_ref_digest : @control.Digest?
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
pub(all) enum MigrationBeadScope {
  MigrationProductionBead
  MigrationRehearsalBead(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationBeadProposal {
  id : MigrationBeadId
  idempotency_key : @control.Digest
  stable_key : InventoryStableKey
  migration_contract_ref : @control.MigrationContractRef
  scope : MigrationBeadScope
  kind : MigrationBeadKind
  title : String
  ownership_claim : MigrationOwnershipClaim
  source_paths : Array[@control.RepoPath]
  blocking_dependency_ids : Array[MigrationBeadId]
  verification_specs : Array[@control.VerificationSpec]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationChangedArtifactKind {
  ChangedRulebook
  ChangedJudgeDefinition
  ChangedDependencyMap
  ChangedInventoryGenerator
  ChangedSourceRevision
  ChangedContextAssemblyPolicy
  ChangedValidationPlan
  ChangedGapInventory
  ChangedTransformationPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationContractArtifactChange {
  kind : MigrationChangedArtifactKind
  previous_digest : @control.Digest
  next_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationPartRevisionDependency {
  part_id : @control.PartId
  effective_task_contract_revision_id : @control.RevisionId
  dependency_artifact_digests : Array[@control.Digest]
  integrated : Bool
  dependency_complete : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationImpactReason {
  MigrationDirectArtifactImpact(MigrationChangedArtifactKind)
  MigrationGeneralValidationImpact(MigrationChangedArtifactKind)
  MigrationUncertainDependencyImpact
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationPartImpact {
  part_id : @control.PartId
  reasons : Array[MigrationImpactReason]
  was_integrated : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationContractRevisionApplication {
  MigrationRevisionAppliesInPlace
  MigrationRevisionRequiresGoalSupersession
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationContractRevisionImpactSet {
  previous_contract_ref : @control.MigrationContractRef
  next_contract_ref : @control.MigrationContractRef
  changes : Array[MigrationContractArtifactChange]
  impacted_parts : Array[MigrationPartImpact]
  carried_forward_task_contract_revision_ids : Array[@control.RevisionId]
  application : MigrationContractRevisionApplication
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationSupersession {
  prior_goal_id : @control.GoalId
  previous_contract_ref : @control.MigrationContractRef
  next_contract_ref : @control.MigrationContractRef
  impacted_integrated_part_ids : Array[@control.PartId]
  observed_goal_head : @control.GitOid
  cutoff_sequence : @control.EventSequence
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationContinuationRef {
  prior_goal_id : @control.GoalId
  supersession_artifact_digest : @control.Digest
  cancellation_summary_id : @control.CancellationSummaryId
  terminal_preserved_head : @control.GitOid
  next_contract_ref : @control.MigrationContractRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationUnitExecutionStatus {
  stable_key : InventoryStableKey
  effective_contract_ref : @control.MigrationContractRef
  task_contract_revision_id : @control.RevisionId
  integrated : Bool
  continuation_ref_digest : @control.Digest?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationEffectiveContractCount {
  contract_ref : @control.MigrationContractRef
  unit_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationOperationalCounts {
  queued_parts : Int
  active_takes : Int
  waiting_verification_slots : Int
  running_verification_slots : Int
  invalidated_verification_slots : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationNextRoute {
  MigrationNoFurtherRoute
  MigrationRepairRoute
  MigrationContractRevisionRoute
  MigrationUserInputRoute
  MigrationContinuationRoute
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum MigrationCompletionCondition {
  MigrationCompletionReady
  MigrationCompletionBlockedByUnresolvedUnits
  MigrationCompletionBlockedByUnintegratedUnits
  MigrationCompletionBlockedByContinuation
  MigrationCompletionBlockedByUnsupportedMechanicalUnits
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MigrationStatusProjection {
  denominator : Int
  irrelevant_units : Int
  mechanical_units : Int
  agent_assisted_units : Int
  unresolved_units : Int
  integrated_units : Int
  effective_contract_counts : Array[MigrationEffectiveContractCount]
  affected_part_ids : Array[@control.PartId]
  operational_counts : MigrationOperationalCounts
  next_route : MigrationNextRoute
  completion : MigrationCompletionCondition
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
