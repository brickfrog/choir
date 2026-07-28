///|
let selection_store_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
fn selection_store_decision(
  label? : String = "selection-store",
) -> @workflow.GoalSelectionDecision raise {
  let goal_id = @control.GoalId("goal-" + label)
  let part_id = @control.PartId("part-" + label)
  let repository_id = @workflow.RepositoryId("repository-selection-store")
  let source : @workflow.GoalSelectionSourcePart = {
    part_id,
    source_revision_digest: selection_store_digest,
    source_content_digest: selection_store_digest,
    dependency_ids: [],
    state: @workflow.SelectionSourceState::SelectionSourceOpen,
  }
  let contract : @control.TaskContractRevision = {
    id: @control.RevisionId("revision-" + label),
    goal_id,
    part_id,
    revision: 1,
    digest: selection_store_digest,
    commit_title: @control.SemanticCommitTitle("test: persist submission"),
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: None,
    instruction_artifact: {
      artifact_id: "instruction-" + label,
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
        id: @control.VerificationSpecId("verify-" + label),
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
        id: @workflow.GoalProposalId("proposal-" + label),
        goal_id,
        conductor_draft_digest: selection_store_digest,
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
          draft: false,
        }),
        migration_production_admission: None,
        work_order_id: None,
        work_order_objective: None,
        work_order_selection_policy: None,
        work_order_planner: None,
        work_order_primary_target_ids: [part_id],
        work_order_budget: None,
        maximum_parallel_parts: 1,
        parts: [
          {
            part_id,
            source_revision_digest: selection_store_digest,
            source_content_digest: selection_store_digest,
            dependency_ids: [],
            task_contract: contract,
            provider_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
            provider_failover_surfaces: [],
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
fn work_order_store_record(label : String) -> @workflow.WorkOrderRecord raise {
  let decision = selection_store_decision(label~)
  let part_id = decision.accepted_parts[0].part.id
  let id = @workflow.work_order_id(
    decision.proposal.repository_id,
    decision.proposal.id,
  )
  {
    id,
    repository_id: decision.proposal.repository_id,
    objective: "Persist the campaign owner before its Goal.",
    selection_policy: @workflow.WorkOrderSelectionPolicy::WorkOrderExactBeadClosure,
    planner: {
      primary_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      failover_surfaces: [],
    },
    initial_primary_target_ids: [part_id],
    initial_prerequisite_closure_ids: [],
    max_active_child_goals: 1,
    budget: @workflow.accept_work_order_budget(
      @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(10),
      @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
      1_000L,
    ).unwrap(),
    child_goals: [
      {
        goal_id: decision.proposal.goal_id,
        selection_decision_digest: @workflow.goal_selection_decision_digest(
          decision,
        ),
        primary_target_ids: [part_id],
        prerequisite_closure_ids: [],
        outcome: @workflow.WorkOrderChildOutcome::WorkOrderChildActive,
      },
    ],
    lifecycle: @workflow.WorkOrderLifecycle::WorkOrderActive,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
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

///|
test "WorkOrder persistence rolls back or reconciles every crash boundary" {
  let points = [
    @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
    @storage.StateStoreFaultPoint::StateAfterOutboxBeforeCommit,
    @storage.StateStoreFaultPoint::StateAfterCommitBeforeAck,
  ]
  for index = 0; index < points.length(); index = index + 1 {
    let root = "/tmp/choir-work-order-fault-" +
      index.to_string() +
      "-" +
      @sys.get_pid().to_string()
    ignore(@sys.rm_rf(root))
    if !@sys.create_dir_all(root) {
      fail("failed to create WorkOrder fault root")
    }
    let repository : @workflow.PartWorkflowRepository = {
      state_store: { path: root + "/state.db" },
      artifact_store: { root: root + "/artifacts" },
      max_snapshot_bytes: 1024 * 1024,
    }
    let adapters = local_part_workflow_repository_adapters()
    @workflow.initialize_part_workflow_repository(repository, adapters).unwrap()
    let record = work_order_store_record("fault-" + index.to_string())
    let receipt = @workflow.persist_work_order_record(repository, adapters, {
      record,
      expected_store_version: None,
      fault_point: Some(points[index]),
    }).unwrap()
    match points[index] {
      @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox
      | @storage.StateStoreFaultPoint::StateAfterOutboxBeforeCommit => {
        assert_eq(
          receipt.transaction_outcome,
          @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(
            points[index],
          ),
        )
        assert_true(
          @workflow.load_work_order_record(repository, adapters, record.id).unwrap()
          is None,
        )
        let retried = @workflow.persist_work_order_record(
          repository,
          adapters,
          { record, expected_store_version: None, fault_point: None },
        ).unwrap()
        assert_eq(
          retried.transaction_outcome,
          @storage.StateTransactionOutcome::StateTransactionCommitted,
        )
      }
      @storage.StateStoreFaultPoint::StateAfterCommitBeforeAck => {
        assert_eq(
          receipt.transaction_outcome,
          @storage.StateTransactionOutcome::StateTransactionCommittedAckLost,
        )
        assert_eq(
          @workflow.load_work_order_record(repository, adapters, record.id)
          .unwrap()
          .unwrap().record,
          record,
        )
        let replayed = @workflow.persist_work_order_record(
          repository,
          adapters,
          { record, expected_store_version: None, fault_point: None },
        ).unwrap()
        assert_eq(
          replayed.transaction_outcome,
          @storage.StateTransactionOutcome::StateTransactionReplayed,
        )
      }
    }
    ignore(@sys.rm_rf(root))
  }
}
