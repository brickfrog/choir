///|
pub(all) enum CommandRole {
  ImplementationCommand
  PartAuditCommand
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum CommandExecutionSubject {
  ImplementationCommandSubject(
    @control.PartId,
    @control.RevisionId,
    @control.Digest
  )
  PartAuditCommandSubject(@control.PartAuditSubject)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CommandTemplate {
  schema_version : Int
  role : CommandRole
  digest : @control.Digest
  content : Bytes
} derive(Debug, Eq)

///|
pub(all) struct CommandContextArtifact {
  digest : @control.Digest
  content : Bytes
} derive(Debug, Eq)

///|
pub(all) struct CommandPreparationRequest {
  schema_version : Int
  take : @control.Take
  subject : CommandExecutionSubject
  goal_contract_digest : @control.Digest
  task_contract_revision_id : @control.RevisionId
  task_contract_digest : @control.Digest
  instruction_artifact_digest : @control.Digest
  migration_contract_ref : @control.MigrationContractRef?
  provider_surface : @control.ProviderSurfaceId
  provider_surface_and_profile_digest : @control.Digest
  context_assembly_policy_digest : @control.Digest
  context_manifest : @migration.PartContextManifest?
  template : CommandTemplate
  context_artifacts : Array[CommandContextArtifact]
  maximum_command_bytes : Int
} derive(Debug, Eq)

///|
pub(all) struct CommandPreparationProvenance {
  schema_version : Int
  take_id : @control.TakeId
  take_purpose_digest : @control.Digest
  subject_digest : @control.Digest
  goal_contract_digest : @control.Digest
  task_contract_revision_id : @control.RevisionId
  task_contract_digest : @control.Digest
  migration_contract_ref : @control.MigrationContractRef?
  template_digest : @control.Digest
  provider_surface : @control.ProviderSurfaceId
  provider_surface_and_profile_digest : @control.Digest
  context_assembly_policy_digest : @control.Digest
  context_manifest_digest : @control.Digest?
  context_projection_digest : @control.Digest
  maximum_command_bytes : Int
  command_artifact_digest : @control.Digest
  command_byte_length : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PreparedCommand {
  command_bytes : Bytes
  provenance : CommandPreparationProvenance
} derive(Debug, Eq)
