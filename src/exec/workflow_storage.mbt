///|
pub fn local_one_part_workflow_repository_adapters() -> @workflow.OnePartWorkflowRepositoryAdapters {
  {
    state: sqlite_state_store_adapters(),
    artifacts: local_artifact_store_adapters(),
  }
}
