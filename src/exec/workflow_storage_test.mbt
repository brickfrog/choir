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
fn workflow_store_fixture() -> @workflow.PartWorkflowSnapshot raise {
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
    instruction_artifact: {
      artifact_id: "instruction-store",
      digest: workflow_store_digest_a,
    },
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
  let identities : @workflow.PartIdentityPlan = {
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
    @workflow.initialize_part_workflow(
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
fn workflow_repository(suffix : String) -> @workflow.PartWorkflowRepository {
  let root = storage_test_path("workflow-" + suffix)
  {
    state_store: { path: root + ".db" },
    artifact_store: { root: root + "-artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
}

///|
fn clean_workflow_repository(
  repository : @workflow.PartWorkflowRepository,
) -> Unit {
  ignore(@sys.rm_rf(repository.state_store.path))
  ignore(@sys.rm_rf(repository.state_store.path + "-shm"))
  ignore(@sys.rm_rf(repository.state_store.path + "-wal"))
  ignore(@sys.rm_rf(repository.artifact_store.root))
}

///|
fn workflow_repository_adapters() -> @workflow.PartWorkflowRepositoryAdapters {
  local_part_workflow_repository_adapters()
}

///|
test "workflow snapshots survive restart and replay after advancement" {
  let repository = workflow_repository("restart")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize workflow repository")
  }
  let initial = workflow_store_fixture()
  let first = match
    @workflow.persist_part_snapshot(repository, adapters, {
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
  match @workflow.load_part_snapshot(restarted, adapters, "workflow-store") {
    Ok(Some(stored)) => {
      assert_eq(stored.state_record.version, 1)
      assert_eq(stored.snapshot, initial)
    }
    Ok(None) => fail("durable workflow snapshot was absent")
    Err(error) => fail(error.message())
  }
  let intent = match @workflow.plan_next_part_effect(initial) {
    Ok(Some(value)) => value
    _ => fail("initial workflow had no next effect")
  }
  let advanced = match @workflow.persist_planned_part_effect(initial, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let second = match
    @workflow.persist_part_snapshot(restarted, adapters, {
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
  match @workflow.load_part_snapshot(restarted, adapters, "workflow-store") {
    Ok(Some(stored)) => {
      assert_eq(stored.state_record.version, 2)
      assert_eq(stored.snapshot, advanced)
    }
    _ => fail("advanced workflow snapshot was not recovered")
  }
  let replay = match
    @workflow.persist_part_snapshot(restarted, adapters, {
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
    guard @workflow.initialize_part_workflow_repository(repository, adapters)
      is Ok(_) else {
      fail("initialize rollback repository")
    }
    let snapshot = workflow_store_fixture()
    let receipt = match
      @workflow.persist_part_snapshot(repository, adapters, {
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
      @workflow.load_part_snapshot(repository, adapters, "workflow-store")
      is Ok(None),
    )
    match
      @workflow.persist_part_snapshot(repository, adapters, {
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
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize acknowledgment-loss repository")
  }
  let snapshot = workflow_store_fixture()
  match
    @workflow.persist_part_snapshot(repository, adapters, {
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
    @workflow.load_part_snapshot(restarted, adapters, "workflow-store")
    is Ok(Some(_)),
  )
  match
    @workflow.persist_part_snapshot(restarted, adapters, {
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

///|
fn workflow_driver_started_session(
  session : @control.HarnessSession,
) -> @control.HarnessSession {
  {
    ..session,
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  }
}

///|
fn workflow_driver_trace(
  session : @control.HarnessSession,
  prefix : String,
) -> (@control.HarnessSession, Array[@control.HarnessEventEnvelope]) {
  let started : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId(prefix + "-started"),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventNonResumableOrdinal(
      prefix, 1,
    ),
    choir_sequence: @control.EventSequence(1L),
    observed_at: 100L,
    kind: @control.HarnessEventKind::HarnessStarted,
    sanitized_payload_digest: workflow_store_digest_a,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
  let terminal : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId(prefix + "-terminal"),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventNonResumableOrdinal(
      prefix, 2,
    ),
    choir_sequence: @control.EventSequence(2L),
    observed_at: 101L,
    kind: @control.HarnessEventKind::HarnessTerminal(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
    sanitized_payload_digest: workflow_store_digest_b,
    redaction_state: @control.EventRedactionState::EventNotSensitive,
    late: false,
  }
  (
    {
      ..session,
      last_choir_sequence: @control.EventSequence(2L),
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
        @control.HarnessTerminalObservation::HarnessCompleted,
      ),
    },
    [started, terminal],
  )
}

///|
fn workflow_driver_observation(
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  match intent.kind {
    @workflow.PartEffectKind::PrepareImplementationSandbox(lease) =>
      Ok(
        @workflow.PartEffectObservation::ImplementationSandboxPrepared({
          ..lease,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        }),
      )
    @workflow.PartEffectKind::StartImplementationHarness(session) =>
      Ok(
        @workflow.PartEffectObservation::ImplementationHarnessStarted(
          workflow_driver_started_session(session),
        ),
      )
    @workflow.PartEffectKind::DispatchImplementation(take_id, session_id) => {
      let started = workflow_driver_started_session(
        snapshot.identities.implementation_session,
      )
      let (closed, events) = workflow_driver_trace(started, "implementation")
      Ok(
        @workflow.PartEffectObservation::ImplementationCompleted(
          {
            take_id,
            session_id,
            result_artifact: {
              artifact_id: "implementation-result-store",
              digest: workflow_store_digest_b,
            },
            finished_at: 102L,
          },
          closed,
          events,
        ),
      )
    }
    @workflow.PartEffectKind::NormalizeImplementationCandidate(take_id, _) => {
      let candidate : @control.CandidateCommit = {
        id: @control.CandidateId("candidate-store"),
        goal_id: snapshot.goal.id,
        part_id: snapshot.part.id,
        take_id,
        base_commit_oid: snapshot.task_contract.base_commit_oid,
        commit_oid: @control.GitOid("candidate-commit-store"),
        tree_oid: @control.GitOid("candidate-tree-store"),
        canonical_change_digest: workflow_store_digest_b,
        changed_paths: [@control.RepoPath("src/store.mbt")],
      }
      Ok(
        @workflow.PartEffectObservation::CandidateNormalized(candidate, {
          candidate_tree_paths: [@control.RepoPath("src/store.mbt")],
          symlink_prefix_paths: [],
          normalization_collision_paths: [],
        }),
      )
    }
    @workflow.PartEffectKind::PrepareVerificationSandbox(lease) =>
      Ok(
        @workflow.PartEffectObservation::VerificationSandboxPrepared({
          ..lease,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        }),
      )
    @workflow.PartEffectKind::StartVerificationHarness(session) =>
      Ok(
        @workflow.PartEffectObservation::VerificationHarnessStarted(
          workflow_driver_started_session(session),
        ),
      )
    @workflow.PartEffectKind::DispatchVerification(take_id, session_id, subject) => {
      let started = workflow_driver_started_session(
        snapshot.identities.verification_session,
      )
      let (closed, events) = workflow_driver_trace(started, "verification")
      let candidate = match snapshot.candidate {
        Some(value) => value
        None =>
          return Err(@types.ChoirError::validation_error("candidate absent"))
      }
      Ok(
        @workflow.PartEffectObservation::VerificationCompleted(
          {
            take_id,
            session_id,
            verification_execution_id: @control.VerificationExecutionId(
              "verification-execution-store",
            ),
            subject,
            verification_spec: snapshot.task_contract.verification_specs[0],
            environment_and_image_digest: workflow_store_digest_b,
            runtime_and_policy_digest: snapshot.identities.verification_sandbox.runtime_policy_digest,
            subject_pre_tree_oid: candidate.tree_oid,
            subject_post_tree_oid: candidate.tree_oid,
            evidence: {
              artifact_id: "verification-evidence-store",
              digest: workflow_store_digest_b,
            },
            started_at: 100L,
            finished_at: 102L,
            outcome: @control.VerificationOutcome::VerificationPassed,
          },
          closed,
          events,
        ),
      )
    }
    @workflow.PartEffectKind::PrepareAuditSandbox(lease) =>
      Ok(
        @workflow.PartEffectObservation::AuditSandboxPrepared({
          ..lease,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        }),
      )
    @workflow.PartEffectKind::StartAuditHarness(session) =>
      Ok(
        @workflow.PartEffectObservation::AuditHarnessStarted(
          workflow_driver_started_session(session),
        ),
      )
    @workflow.PartEffectKind::DispatchAudit(take_id, session_id, subject) => {
      let started = workflow_driver_started_session(
        snapshot.identities.audit_session,
      )
      let (closed, events) = workflow_driver_trace(started, "audit")
      Ok(
        @workflow.PartEffectObservation::AuditCompleted(
          {
            audit_take_id: take_id,
            take_fencing_epoch: snapshot.fencing_epoch,
            audit_harness_session_id: session_id,
            subject,
            provider_conformance_report_digest: workflow_store_digest_a,
            findings_artifact: None,
            total_findings_count: 0,
            blocking_findings_count: 0,
            started_at: 100L,
            finished_at: 102L,
            outcome: @control.AuditOutcome::AuditPassed,
          },
          closed,
          events,
        ),
      )
    }
    @workflow.PartEffectKind::GeneratePromotion(intent) =>
      Ok(
        @workflow.PartEffectObservation::PromotionGenerated({
          intent_id: intent.id,
          commit_oid: @control.GitOid("promotion-commit-store"),
          tree_oid: @control.GitOid("promotion-tree-store"),
          first_parent_oid: intent.expected_goal_head_oid,
          second_parent_oid: intent.candidate_commit_oid,
        }),
      )
    @workflow.PartEffectKind::ApplyIntegration(_, promotion) =>
      Ok(
        @workflow.PartEffectObservation::IntegrationWitnessObserved(
          @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
            promotion.commit_oid,
            promotion.commit_oid,
          ),
        ),
      )
  }
}

///|
fn workflow_driver_dependencies(
  execute_count : Ref[Int],
  reconcile_count : Ref[Int],
  fault : (@workflow.PartPersistenceBoundary) -> @storage.StateStoreFaultPoint?,
  reconcile : async (@workflow.PartWorkflowSnapshot, @workflow.PartEffectIntent) -> Result[
    @workflow.PartEffectRecovery,
    @types.ChoirError,
  ],
) -> @workflow.PartWorkflowDriverDependencies {
  {
    now: fn() { 110L },
    persistence_fault: fault,
    effects: {
      execute: async fn(snapshot, intent) {
        execute_count.val = execute_count.val + 1
        workflow_driver_observation(snapshot, intent)
      },
      reconcile: async fn(snapshot, intent) {
        reconcile_count.val = reconcile_count.val + 1
        reconcile(snapshot, intent)
      },
    },
    artifact_exists: fn(_) { true },
    artifact_digest_exists: fn(_) { true },
    is_nfc: fn(_) { true },
    audit_receipt_metadata: fn(_) {
      Ok({
        receipt_id: @control.ReceiptId("audit-receipt-store"),
        provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_identity: "claude-code-test",
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "claude-test",
        ),
      })
    },
    integration_admission: fn(snapshot) {
      Ok(
        @workflow.PartIntegrationAdmission::PartIntegrationAdmitted({
          lease: {
            id: @control.IntegrationLeaseId("integration-lease-store"),
            goal_id: snapshot.goal.id,
            fencing_epoch: snapshot.fencing_epoch,
            holder: "choird-test",
          },
          intent_id: @control.IntegrationIntentId("integration-intent-store"),
          expected_goal_head_oid: @control.GitOid("goal-head-store"),
          promotion_metadata_digest: workflow_store_digest_a,
          git_witness_ref: "refs/choir/witness/integration-intent-store",
        }),
      )
    },
    verification_environment_digest: fn(_) { workflow_store_digest_b },
    verification_runtime_digest: fn(snapshot) {
      snapshot.identities.verification_sandbox.runtime_policy_digest
    },
  }
}

///|
async fn workflow_driver_recover_observation(
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[@workflow.PartEffectRecovery, @types.ChoirError] {
  match workflow_driver_observation(snapshot, intent) {
    Ok(value) =>
      Ok(@workflow.PartEffectRecovery::EffectObservationRecovered(value))
    Err(error) => Err(error)
  }
}

///|
async test "Part driver persists an integrated result and resumes without work" {
  let repository = workflow_repository("driver-integrated")
  clean_workflow_repository(repository)
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let result = match
    @workflow.run_new_part_workflow(
      repository,
      workflow_repository_adapters(),
      workflow_store_fixture(),
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(result.outcome, @workflow.PartWorkflowRunOutcome::PartRunIntegrated)
  assert_eq(result.snapshot.effect_receipts.length(), 12)
  assert_eq(result.snapshot.verification_receipts.length(), 1)
  assert_true(result.snapshot.audit_receipt is Some(_))
  assert_true(result.snapshot.integration_receipt is Some(_))
  let executed_before_resume = execute_count.val
  let resumed = match
    @workflow.resume_part_workflow(
      repository,
      workflow_repository_adapters(),
      "workflow-store",
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    resumed.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunIntegrated,
  )
  assert_eq(execute_count.val, executed_before_resume)
  assert_eq(reconcile_count.val, 0)
  clean_workflow_repository(repository)
}

///|
async test "audited Part waits durably for Goal promotion admission" {
  let repository = workflow_repository("driver-awaiting-promotion")
  clean_workflow_repository(repository)
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let admitted = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let deferred : @workflow.PartWorkflowDriverDependencies = {
    ..admitted,
    integration_admission: fn(_) {
      Ok(@workflow.PartIntegrationAdmission::PartIntegrationDeferred)
    },
  }
  let waiting = match
    @workflow.run_new_part_workflow(
      repository,
      workflow_repository_adapters(),
      workflow_store_fixture(),
      deferred,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    waiting.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunAwaitingPromotion,
  )
  assert_eq(waiting.snapshot.stage, @workflow.PartWorkflowStage::PartAudited)
  assert_true(waiting.snapshot.integration_intent is None)
  assert_true(waiting.snapshot.integration_lease is None)
  let executed_before_resume = execute_count.val
  let resumed = match
    @workflow.resume_part_workflow(
      repository,
      workflow_repository_adapters(),
      waiting.snapshot.workflow_id,
      deferred,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    resumed.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunAwaitingPromotion,
  )
  assert_eq(execute_count.val, executed_before_resume)
  assert_eq(reconcile_count.val, 0)
  clean_workflow_repository(repository)
}

///|
async test "Goal adapter resumes promotion after a durable rollback" {
  let repository = workflow_repository("goal-adapter-recovery")
  clean_workflow_repository(repository)
  let snapshot = workflow_store_fixture()
  let scheduling_record : @workflow.GoalPartSchedulingRecord = {
    part: { ..snapshot.part, lifecycle: @control.PartLifecycle::PartPending },
    task_contract: snapshot.task_contract,
  }
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let inject_fault = @ref.new(true)
  let config : @exec.GoalPartWorkflowAdapterConfig = {
    bindings: [{ scheduling_record, initial_snapshot: snapshot, repository }],
    repository_adapters: workflow_repository_adapters(),
    dependencies: fn(_, admission) {
      let dependencies = workflow_driver_dependencies(
        execute_count,
        reconcile_count,
        fn(boundary) {
          if inject_fault.val &&
            boundary ==
            @workflow.PartPersistenceBoundary::WorkflowIntegrationPlanned {
            inject_fault.val = false
            Some(@storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox)
          } else {
            None
          }
        },
        workflow_driver_recover_observation,
      )
      Ok({ ..dependencies, integration_admission: fn(_) { Ok(admission) } })
    },
    integration_input: fn(snapshot, selection) {
      Ok({
        lease: {
          id: @control.IntegrationLeaseId("goal-adapter-lease"),
          goal_id: snapshot.goal.id,
          fencing_epoch: snapshot.fencing_epoch,
          holder: "choird-test",
        },
        intent_id: @control.IntegrationIntentId("goal-adapter-intent"),
        expected_goal_head_oid: selection.expected_goal_head_oid,
        promotion_metadata_digest: workflow_store_digest_a,
        git_witness_ref: "refs/choir/witness/goal-adapter-intent",
      })
    },
    read_goal_head: async fn() { Ok(@control.GitOid("goal-head-store")) },
  }
  let adapters = @exec.goal_part_workflow_adapters(config)
  let paused = match
    @workflow.run_goal_parts([scheduling_record], 1, adapters) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(paused.outcome, @workflow.GoalRunOutcome::GoalRunPaused)
  assert_true(
    paused.records[0].part.lifecycle
    is @control.PartLifecycle::PartAudited(_, _, _),
  )
  let executed_before_resume = execute_count.val
  let recovered = match @workflow.run_goal_parts(paused.records, 1, adapters) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(recovered.outcome, @workflow.GoalRunOutcome::GoalRunSucceeded)
  assert_eq(recovered.promotion_order, [scheduling_record.part.id])
  assert_eq(execute_count.val, executed_before_resume + 2)
  assert_eq(reconcile_count.val, 0)
  clean_workflow_repository(repository)
}

///|
async test "restarted authorized effect waits for a witness without executing" {
  let repository = workflow_repository("driver-uncertain")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize uncertain driver repository")
  }
  let initial = workflow_store_fixture()
  let initial_receipt = match
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: initial,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let intent = match @workflow.plan_next_part_effect(initial) {
    Ok(Some(value)) => value
    _ => fail("initial effect missing")
  }
  let planned = match @workflow.persist_planned_part_effect(initial, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let planned_receipt = match
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: planned,
      expected_store_version: Some(initial_receipt.store_version),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let authorized = match @workflow.authorize_pending_part_effect(planned) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: authorized,
      expected_store_version: Some(planned_receipt.store_version),
      fault_point: None,
    })
    is Ok(_) else {
    fail("persist authorized effect")
  }
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let result = match
    @workflow.resume_part_workflow(
      repository,
      adapters,
      "workflow-store",
      workflow_driver_dependencies(
        execute_count,
        reconcile_count,
        fn(_) { None },
        async fn(_, _) {
          Ok(@workflow.PartEffectRecovery::EffectWitnessUnavailable)
        },
      ),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(
    result.outcome
    is @workflow.PartWorkflowRunOutcome::PartRunWaitingForEffectWitness(_),
  )
  assert_eq(execute_count.val, 0)
  assert_eq(reconcile_count.val, 1)
  clean_workflow_repository(repository)
}

///|
test "effect witnesses are durable idempotent and bound to the request" {
  let repository = workflow_repository("effect-witness")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize effect witness repository")
  }
  let initial = workflow_store_fixture()
  let intent = match @workflow.plan_next_part_effect(initial) {
    Ok(Some(value)) => value
    _ => fail("effect intent is missing")
  }
  let planned = match @workflow.persist_planned_part_effect(initial, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let authorized = match @workflow.authorize_pending_part_effect(planned) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let observation = match
    workflow_driver_observation(authorized, {
      ..intent,
      lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let authorized_intent = match authorized.pending_effect {
    Some(value) => value
    None => fail("authorized effect is missing")
  }
  let first = match
    @workflow.record_part_effect_witness(
      repository, adapters, authorized, authorized_intent, observation, 120L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let replay = match
    @workflow.record_part_effect_witness(
      repository, adapters, authorized, authorized_intent, observation, 120L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(first, replay)
  assert_eq(
    first.observation_digest,
    @workflow.part_effect_observation_digest(observation),
  )
  match
    @workflow.load_part_effect_witness(repository, adapters, authorized_intent) {
    Ok(Some(stored)) => assert_eq(stored, first)
    Ok(None) => fail("effect witness was not stored")
    Err(error) => fail(error.message())
  }
  clean_workflow_repository(repository)
}

///|
async test "driver recovers every persisted transition after rollback" {
  let boundaries = [
    @workflow.PartPersistenceBoundary::WorkflowAcceptedSnapshot,
    @workflow.PartPersistenceBoundary::WorkflowEffectPlanned,
    @workflow.PartPersistenceBoundary::WorkflowEffectAuthorized,
    @workflow.PartPersistenceBoundary::WorkflowEffectObserved,
    @workflow.PartPersistenceBoundary::WorkflowAuditReceiptRecorded,
    @workflow.PartPersistenceBoundary::WorkflowIntegrationPlanned,
    @workflow.PartPersistenceBoundary::WorkflowIntegrationAuthorized,
  ]
  for index, boundary in boundaries {
    let repository = workflow_repository("driver-rollback-" + index.to_string())
    clean_workflow_repository(repository)
    let injected = @ref.new(false)
    let execute_count = @ref.new(0)
    let reconcile_count = @ref.new(0)
    let first_dependencies = workflow_driver_dependencies(
      execute_count,
      reconcile_count,
      fn(actual) {
        if !injected.val && actual == boundary {
          injected.val = true
          Some(@storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox)
        } else {
          None
        }
      },
      workflow_driver_recover_observation,
    )
    let first = match
      @workflow.run_new_part_workflow(
        repository,
        workflow_repository_adapters(),
        workflow_store_fixture(),
        first_dependencies,
      ) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
    assert_eq(
      first.outcome,
      @workflow.PartWorkflowRunOutcome::PartRunPersistenceFault(
        boundary,
        @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
      ),
    )
    let recovery_dependencies = workflow_driver_dependencies(
      execute_count,
      reconcile_count,
      fn(_) { None },
      workflow_driver_recover_observation,
    )
    let recovered = if boundary ==
      @workflow.PartPersistenceBoundary::WorkflowAcceptedSnapshot {
      @workflow.run_new_part_workflow(
        repository,
        workflow_repository_adapters(),
        workflow_store_fixture(),
        recovery_dependencies,
      )
    } else {
      @workflow.resume_part_workflow(
        repository,
        workflow_repository_adapters(),
        "workflow-store",
        recovery_dependencies,
      )
    }
    let result = match recovered {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
    assert_eq(
      result.outcome,
      @workflow.PartWorkflowRunOutcome::PartRunIntegrated,
    )
    assert_eq(result.snapshot.effect_receipts.length(), 12)
    assert_eq(result.snapshot.verification_receipts.length(), 1)
    assert_true(result.snapshot.audit_receipt is Some(_))
    assert_true(result.snapshot.integration_receipt is Some(_))
    clean_workflow_repository(repository)
  }
}
