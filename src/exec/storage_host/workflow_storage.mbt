///|
pub fn local_part_workflow_repository_adapters() -> @workflow.PartWorkflowRepositoryAdapters {
  {
    state: sqlite_state_store_adapters(),
    artifacts: local_artifact_store_adapters(),
  }
}
