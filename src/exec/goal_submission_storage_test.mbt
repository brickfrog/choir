///|
let selection_store_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
fn selection_store_decision() -> @workflow.GoalSelectionDecision raise {
  let goal_id = @control.GoalId("goal-selection-store")
  let part_id = @control.PartId("part-selection-store")
  let repository_id = @workflow.RepositoryId("repository-selection-store")
  let source : @workflow.GoalSelectionSourcePart = {
    part_id,
    source_revision_digest: selection_store_digest,
    source_content_digest: selection_store_digest,
    dependency_ids: [],
    state: @workflow.SelectionSourceState::SelectionSourceOpen,
  }
  let contract : @control.TaskContractRevision = {
    id: @control.RevisionId("revision-selection-store"),
    goal_id,
    part_id,
    revision: 1,
    digest: selection_store_digest,
    repair_conflict_id: None,
    instruction_artifact: {
      artifact_id: "instruction-selection-store",
      digest: selection_store_digest,
    },
    base_commit_oid: @control.GitOid("base-selection-store"),
    base_tree_oid: @control.GitOid("tree-selection-store"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath("src/selection_store.mbt"),
        ),
      ],
    ),
    verification_specs: [
      {
        id: @control.VerificationSpecId("verify-selection-store"),
        version: 1,
        digest: selection_store_digest,
        process_spec_digest: selection_store_digest,
      },
    ],
    audit_policy_digest: selection_store_digest,
    migration_contract_ref: None,
    migration_continuation_ref_digest: None,
    implementation_capability_profile_digest: selection_store_digest,
    verification_capability_profile_digest: selection_store_digest,
    audit_capability_profile_digest: selection_store_digest,
  }
  match
    @workflow.evaluate_goal_proposal(
      {
        id: @workflow.GoalProposalId("proposal-selection-store"),
        goal_id,
        repository_id,
        base_ref: @workflow.GitRefName("refs/heads/main"),
        expected_base_commit_oid: @control.GitOid("base-selection-store"),
        expected_base_tree_oid: @control.GitOid("tree-selection-store"),
        integration_target_ref: @workflow.GitRefName("refs/heads/main"),
        selection_policy: @workflow.GoalSelectionPolicy::ExactClosure,
        completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
        pull_request_document: Some({
          title: "test: persist Goal selection",
          body: "Exercises persisted Goal selection.",
        }),
        migration_production_admission: None,
        maximum_parallel_parts: 1,
        parts: [
          {
            part_id,
            source_revision_digest: selection_store_digest,
            source_content_digest: selection_store_digest,
            dependency_ids: [],
            task_contract: contract,
            provider_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
            part_context_manifest: None,
          },
        ],
      },
      {
        repository_id,
        base_commit_oid: @control.GitOid("base-selection-store"),
        base_tree_oid: @control.GitOid("tree-selection-store"),
        parts: [source],
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
test "Goal selection decision persists once and reloads after restart" {
  let root = "/tmp/choir-selection-store-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create selection storage root")
  }
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/state.db" },
    artifact_store: { root: root + "/artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  let decision = selection_store_decision()
  let first = match
    @workflow.persist_goal_selection_decision(repository, adapters, {
      decision,
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    first.transaction_outcome,
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  let restarted = match
    @workflow.load_goal_selection_decision(
      repository,
      adapters,
      decision.proposal.goal_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => fail("selection decision was absent after restart")
    Err(error) => fail(error.message())
  }
  assert_eq(restarted.decision, decision)
  assert_eq(restarted.state_record.value_digest, first.decision_digest)
  let replay = match
    @workflow.persist_goal_selection_decision(repository, adapters, {
      decision,
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    replay.transaction_outcome,
    @storage.StateTransactionOutcome::StateTransactionReplayed,
  )
  ignore(@sys.rm_rf(root))
}
