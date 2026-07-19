///|
let workflow_store_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let workflow_store_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn workflow_store_take(
  id : String,
  purpose : @control.TakePurpose,
) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id: @control.GoalId("goal-store"),
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn workflow_store_fixture() -> @workflow.OnePartWorkflowSnapshot raise {
  let goal : @control.Goal = {
    id: @control.GoalId("goal-store"),
    contract_digest: workflow_store_digest_a,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let part : @control.GoalPart = {
    id: @control.PartId("part-store"),
    goal_id: goal.id,
    dependency_ids: [],
    task_contract_revision_id: @control.RevisionId("revision-store"),
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let contract : @control.TaskContractRevision = {
    id: part.task_contract_revision_id,
    goal_id: goal.id,
    part_id: part.id,
    revision: 1,
    digest: workflow_store_digest_a,
    base_commit_oid: @control.GitOid("base-store"),
    base_tree_oid: @control.GitOid("base-tree-store"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/store.mbt")),
      ],
    ),
    verification_specs: [
      {
        id: @control.VerificationSpecId("verify-store"),
        version: 1,
        digest: workflow_store_digest_a,
        process_spec_digest: workflow_store_digest_b,
      },
    ],
    audit_policy_digest: workflow_store_digest_a,
    implementation_capability_profile_digest: workflow_store_digest_a,
    verification_capability_profile_digest: workflow_store_digest_b,
    audit_capability_profile_digest: workflow_store_digest_a,
  }
  let implementation = workflow_store_take(
    "implementation-store",
    @control.TakePurpose::Implementation(part.id, contract.id),
  )
  let verification = workflow_store_take(
    "verification-store",
    @control.TakePurpose::PartVerification(
      part.id,
      implementation.id,
      workflow_store_digest_a,
    ),
  )
  let audit = workflow_store_take(
    "audit-store",
    @control.TakePurpose::PartAudit(
      part.id,
      implementation.id,
      workflow_store_digest_a,
    ),
  )
  let sandbox = fn(
    id : String,
    generation : String,
    take : @control.Take,
    capability : @control.Digest,
  ) -> @control.SandboxLease {
    {
      id: @control.SandboxLeaseId(id),
      take_id: take.id,
      generation_id: @control.SandboxGenerationId(generation),
      capability_profile_digest: capability,
      runtime_policy_digest: workflow_store_digest_b,
      lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
    }
  }
  let implementation_sandbox = sandbox(
    "implementation-sandbox-store",
    "implementation-generation-store",
    implementation,
    contract.implementation_capability_profile_digest,
  )
  let verification_sandbox = sandbox(
    "verification-sandbox-store",
    "verification-generation-store",
    verification,
    contract.verification_capability_profile_digest,
  )
  let audit_sandbox = sandbox(
    "audit-sandbox-store",
    "audit-generation-store",
    audit,
    contract.audit_capability_profile_digest,
  )
  let session = fn(
    id : String,
    take : @control.Take,
    lease : @control.SandboxLease,
  ) -> @control.HarnessSession {
    {
      id: @control.HarnessSessionId(id),
      take_id: take.id,
      sandbox_generation_id: lease.generation_id,
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      effective_surface_manifest_digest: workflow_store_digest_a,
      cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
      provider_cursor: None,
      last_choir_sequence: @control.EventSequence(0L),
      open_tool_execution_ids: [],
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
    }
  }
  let identities : @workflow.OnePartIdentityPlan = {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: session(
      "implementation-session-store", implementation, implementation_sandbox,
    ),
    verification_take: verification,
    verification_sandbox,
    verification_session: session(
      "verification-session-store", verification, verification_sandbox,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: session("audit-session-store", audit, audit_sandbox),
  }
  match
    @workflow.initialize_one_part_workflow(
      "workflow-store",
      goal,
      part,
      contract,
      identities,
      @control.FencingEpoch(7L),
      fn(_) { true },
    ) {
    Ok(snapshot) => snapshot
    Err(error) => fail(error.message())
  }
}

///|
fn workflow_repository(suffix : String) -> @workflow.OnePartWorkflowRepository {
  let root = storage_test_path("workflow-" + suffix)
  {
    state_store: { path: root + ".db" },
    artifact_store: { root: root + "-artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
}

///|
fn clean_workflow_repository(
  repository : @workflow.OnePartWorkflowRepository,
) -> Unit {
  ignore(@sys.rm_rf(repository.state_store.path))
  ignore(@sys.rm_rf(repository.state_store.path + "-shm"))
  ignore(@sys.rm_rf(repository.state_store.path + "-wal"))
  ignore(@sys.rm_rf(repository.artifact_store.root))
}

///|
fn workflow_repository_adapters() -> @workflow.OnePartWorkflowRepositoryAdapters {
  local_one_part_workflow_repository_adapters()
}

///|
test "workflow snapshots survive restart and replay after advancement" {
  let repository = workflow_repository("restart")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_one_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize workflow repository")
  }
  let initial = workflow_store_fixture()
  let first = match
    @workflow.persist_one_part_snapshot(repository, adapters, {
      snapshot: initial,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(receipt) => receipt
    Err(error) => fail(error.message())
  }
  assert_eq(
    first.transaction_outcome,
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  let restarted = workflow_repository("restart")
  match
    @workflow.load_one_part_snapshot(restarted, adapters, "workflow-store") {
    Ok(Some(stored)) => {
      assert_eq(stored.state_record.version, 1)
      assert_eq(stored.snapshot, initial)
    }
    Ok(None) => fail("durable workflow snapshot was absent")
    Err(error) => fail(error.message())
  }
  let intent = match @workflow.plan_next_one_part_effect(initial) {
    Ok(Some(value)) => value
    _ => fail("initial workflow had no next effect")
  }
  let advanced = match
    @workflow.persist_planned_one_part_effect(initial, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let second = match
    @workflow.persist_one_part_snapshot(restarted, adapters, {
      snapshot: advanced,
      expected_store_version: Some(1),
      fault_point: None,
    }) {
    Ok(receipt) => receipt
    Err(error) => fail(error.message())
  }
  assert_eq(second.store_version, 2)
  assert_eq(
    second.transaction_outcome,
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  match
    @workflow.load_one_part_snapshot(restarted, adapters, "workflow-store") {
    Ok(Some(stored)) => {
      assert_eq(stored.state_record.version, 2)
      assert_eq(stored.snapshot, advanced)
    }
    _ => fail("advanced workflow snapshot was not recovered")
  }
  let replay = match
    @workflow.persist_one_part_snapshot(restarted, adapters, {
      snapshot: initial,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(receipt) => receipt
    Err(error) => fail(error.message())
  }
  assert_eq(
    replay.transaction_outcome,
    @storage.StateTransactionOutcome::StateTransactionReplayed,
  )
  clean_workflow_repository(repository)
}

///|
test "workflow persistence rolls back injected faults and reconciles ack loss" {
  for
    point in [
      @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
      @storage.StateStoreFaultPoint::StateAfterOutboxBeforeCommit,
    ] {
    let repository = workflow_repository(point.to_json().stringify(indent=0))
    clean_workflow_repository(repository)
    let adapters = workflow_repository_adapters()
    guard @workflow.initialize_one_part_workflow_repository(
        repository, adapters,
      )
      is Ok(_) else {
      fail("initialize rollback repository")
    }
    let snapshot = workflow_store_fixture()
    let receipt = match
      @workflow.persist_one_part_snapshot(repository, adapters, {
        snapshot,
        expected_store_version: None,
        fault_point: Some(point),
      }) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
    assert_eq(
      receipt.transaction_outcome,
      @storage.StateTransactionOutcome::StateTransactionFaultRolledBack(point),
    )
    assert_true(
      @workflow.load_one_part_snapshot(repository, adapters, "workflow-store")
      is Ok(None),
    )
    match
      @workflow.persist_one_part_snapshot(repository, adapters, {
        snapshot,
        expected_store_version: None,
        fault_point: None,
      }) {
      Ok(
        {
          transaction_outcome: @storage.StateTransactionOutcome::StateTransactionCommitted,
          ..,
        }
      ) => ()
      _ => fail("rolled-back workflow did not retry cleanly")
    }
    clean_workflow_repository(repository)
  }
  let repository = workflow_repository("ack-loss")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_one_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize acknowledgment-loss repository")
  }
  let snapshot = workflow_store_fixture()
  match
    @workflow.persist_one_part_snapshot(repository, adapters, {
      snapshot,
      expected_store_version: None,
      fault_point: Some(
        @storage.StateStoreFaultPoint::StateAfterCommitBeforeAck,
      ),
    }) {
    Ok(
      {
        transaction_outcome: @storage.StateTransactionOutcome::StateTransactionCommittedAckLost,
        ..,
      }
    ) => ()
    _ => fail("acknowledgment loss was not surfaced")
  }
  let restarted = workflow_repository("ack-loss")
  assert_true(
    @workflow.load_one_part_snapshot(restarted, adapters, "workflow-store")
    is Ok(Some(_)),
  )
  match
    @workflow.persist_one_part_snapshot(restarted, adapters, {
      snapshot,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(
      {
        transaction_outcome: @storage.StateTransactionOutcome::StateTransactionReplayed,
        ..,
      }
    ) => ()
    _ => fail("acknowledgment loss did not reconcile by semantic replay")
  }
  clean_workflow_repository(repository)
}
