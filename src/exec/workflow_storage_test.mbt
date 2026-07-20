///|
let workflow_store_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let workflow_store_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn workflow_store_initialized_branch(
  goal_id : @control.GoalId,
  repository_id : @workflow.RepositoryId,
  goal_ref : @workflow.GitRefName,
  base_oid : @control.GitOid,
) -> @workflow.GoalBranchInitialization {
  let planned = @workflow.initial_goal_branch_initialization(
    goal_id, repository_id, goal_ref, base_oid,
  )
  {
    ..planned,
    lifecycle: @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
    receipt: Some({
      intent_id: planned.intent_id,
      idempotency_key: planned.idempotency_key,
      repository_id,
      goal_ref,
      initialized_oid: base_oid,
      initialization_witness_ref: planned.initialization_witness_ref,
      observed_at: 1L,
    }),
  }
}

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
fn workflow_store_goal_assurance_identities(
  goal : @control.Goal,
  head_oid : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification = workflow_store_take(
    "goal-verification-store",
    @control.TakePurpose::GoalVerification(
      goal.id,
      head_oid,
      goal.contract_digest,
    ),
  )
  let audit = workflow_store_take(
    "goal-audit-store",
    @control.TakePurpose::GoalAudit(goal.id, goal.contract_digest),
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
  let verification_sandbox = sandbox(
    "goal-verification-sandbox-store", "goal-verification-generation-store", verification,
    workflow_store_digest_a,
  )
  let audit_sandbox = sandbox(
    "goal-audit-sandbox-store", "goal-audit-generation-store", audit, workflow_store_digest_b,
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
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      effective_surface_manifest_digest: workflow_store_digest_a,
      cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
      provider_cursor: None,
      last_choir_sequence: @control.EventSequence(0L),
      open_tool_execution_ids: [],
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
    }
  }
  {
    verification_take: verification,
    verification_sandbox,
    verification_session: session(
      "goal-verification-session-store", verification, verification_sandbox,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: session("goal-audit-session-store", audit, audit_sandbox),
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
    repair_conflict_id: None,
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
    goal_authorizes_new_effects: fn() {
      Ok(@workflow.PartGoalAuthorization::PartGoalAuthorized(None))
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
async test "Goal cutoff stops Part effect planning without producing work" {
  let repository = workflow_repository("driver-goal-cutoff")
  clean_workflow_repository(repository)
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let admitted = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let cut_off : @workflow.PartWorkflowDriverDependencies = {
    ..admitted,
    goal_authorizes_new_effects: fn() {
      Ok(@workflow.PartGoalAuthorization::PartGoalNotAuthorized)
    },
  }
  let result = match
    @workflow.run_new_part_workflow(
      repository,
      workflow_repository_adapters(),
      workflow_store_fixture(),
      cut_off,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    result.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunGoalNotAuthorizing,
  )
  assert_eq(result.snapshot.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_true(result.snapshot.pending_effect is None)
  assert_eq(execute_count.val, 0)
  assert_eq(reconcile_count.val, 0)
  clean_workflow_repository(repository)
}

///|
async test "Goal cutoff atomically rejects a concurrently authorized Part effect" {
  let repository = workflow_repository("driver-goal-cutoff-race")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize cutoff-race repository")
  }
  let initial = workflow_store_fixture()
  let initial_receipt = @workflow.persist_part_snapshot(repository, adapters, {
    snapshot: initial,
    expected_store_version: None,
    fault_point: None,
  }).unwrap()
  let intent = @workflow.plan_next_part_effect(initial).unwrap().unwrap()
  let planned = @workflow.persist_planned_part_effect(initial, intent).unwrap()
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: planned,
      expected_store_version: Some(initial_receipt.store_version),
      fault_point: None,
    }).unwrap(),
  )
  let running_request : @storage.StateTransactionRequest = {
    state: {
      key: @storage.StateRecordKey("goal-run:cutoff-race"),
      expected_version: None,
      next_version: 1,
      fencing_epoch: @control.FencingEpoch(7L),
      value_digest: workflow_store_digest_a,
    },
    outbox: {
      semantic_key: @storage.SemanticEventKey("goal-run:cutoff-race:running"),
      payload_digest: workflow_store_digest_a,
    },
    fault_point: None,
  }
  assert_true(
    (adapters.state.commit)(repository.state_store, running_request)
    is Ok(@storage.StateTransactionOutcome::StateTransactionCommitted),
  )
  let running_record = (adapters.state.read_state)(
      repository.state_store,
      running_request.state.key,
    )
    .unwrap()
    .unwrap()
  let cutoff_written = @ref.new(false)
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let admitted = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let racing : @workflow.PartWorkflowDriverDependencies = {
    ..admitted,
    goal_authorizes_new_effects: fn() {
      if !cutoff_written.val {
        let cutoff : @storage.StateTransactionRequest = {
          state: {
            ..running_request.state,
            expected_version: Some(1),
            next_version: 2,
            value_digest: workflow_store_digest_b,
          },
          outbox: {
            semantic_key: @storage.SemanticEventKey(
              "goal-run:cutoff-race:canceling",
            ),
            payload_digest: workflow_store_digest_b,
          },
          fault_point: None,
        }
        guard (adapters.state.commit)(repository.state_store, cutoff)
          is Ok(@storage.StateTransactionOutcome::StateTransactionCommitted) else {
          return Err(@types.ChoirError::workspace_error("cutoff commit failed"))
        }
        cutoff_written.val = true
      }
      Ok(
        @workflow.PartGoalAuthorization::PartGoalAuthorized(
          Some({ record: running_record }),
        ),
      )
    },
  }
  let result = @workflow.resume_part_workflow(
    repository,
    adapters,
    planned.workflow_id,
    racing,
  ).unwrap()
  assert_eq(
    result.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunGoalNotAuthorizing,
  )
  assert_eq(result.snapshot, planned)
  assert_eq(execute_count.val, 0)
  assert_eq(reconcile_count.val, 0)
  let reloaded = @workflow.load_part_snapshot(
      repository,
      adapters,
      planned.workflow_id,
    )
    .unwrap()
    .unwrap()
  assert_eq(reloaded.snapshot, planned)
  clean_workflow_repository(repository)
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
async test "Goal cancellation persists an applied integration witness before finishing" {
  let repository = workflow_repository("cancel-integration-witness")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let admitted = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let interrupted : @workflow.PartWorkflowDriverDependencies = {
    ..admitted,
    effects: {
      execute: async fn(snapshot, intent) {
        execute_count.val = execute_count.val + 1
        if intent.kind is @workflow.PartEffectKind::ApplyIntegration(_, _) {
          Err(
            @types.ChoirError::canceled(
              "cancel after integration authorization",
            ),
          )
        } else {
          workflow_driver_observation(snapshot, intent)
        }
      },
      reconcile: admitted.effects.reconcile,
    },
  }
  assert_true(
    @workflow.run_new_part_workflow(
      repository,
      adapters,
      workflow_store_fixture(),
      interrupted,
    )
    is Err(_),
  )
  let authorized = @workflow.load_part_snapshot(
      repository, adapters, "workflow-store",
    )
    .unwrap()
    .unwrap()
  guard authorized.snapshot.pending_effect
    is Some(
      {
        lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
        kind: @workflow.PartEffectKind::ApplyIntegration(_, promotion),
        ..,
      } as intent
    ) else {
    fail("integration effect was not durably authorized")
  }
  let witnessed = @workflow.persist_recovered_part_effect_observation(
    repository,
    adapters,
    authorized,
    intent,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    130L,
    fn(_) { true },
    fn(_) { true },
  ).unwrap()
  assert_eq(
    witnessed.snapshot.stage,
    @workflow.PartWorkflowStage::PartIntegrated,
  )
  assert_true(witnessed.snapshot.integration_receipt is Some(_))
  assert_true(witnessed.snapshot.pending_effect is None)
  let canceled = @workflow.persist_part_goal_cancellation(
    repository, adapters, witnessed,
  ).unwrap()
  assert_true(
    @workflow.part_cancellation_disposition_is_known(canceled.snapshot),
  )
  assert_true(canceled.snapshot.integration_receipt is Some(_))
  let replay = @workflow.load_part_snapshot(
      repository, adapters, "workflow-store",
    )
    .unwrap()
    .unwrap()
  assert_eq(replay, canceled)
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
async test "Goal adapter accepts the exact stored contract revision" {
  let repository = workflow_repository("goal-adapter-contract-revision")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize revised-contract repository")
  }
  let initial = workflow_store_fixture()
  let initial_record : @workflow.GoalPartSchedulingRecord = {
    part: initial.part,
    task_contract: initial.task_contract,
  }
  let revised_contract : @control.TaskContractRevision = {
    ..initial.task_contract,
    id: @control.RevisionId("revision-store-2"),
    revision: 2,
    digest: workflow_store_digest_b,
  }
  let revised_part : @control.GoalPart = {
    ..initial.part,
    task_contract_revision_id: revised_contract.id,
    lifecycle: @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrityBlocked,
    ),
  }
  let revised = {
    ..initial,
    durable_version: initial.durable_version + 1,
    stage: @workflow.PartWorkflowStage::PartBlocked,
    part: revised_part,
    task_contract: revised_contract,
    task_contract_history: initial.task_contract_history + [revised_contract],
  }
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: revised,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let config : @exec.GoalPartWorkflowAdapterConfig = {
    bindings: [{
      scheduling_record: initial_record,
      initial_snapshot: initial,
      repository,
    }],
    repository_adapters: adapters,
    dependencies: fn(_, admission) {
      Ok({
        ..dependencies,
        integration_admission: fn(_) { Ok(admission) },
      })
    },
    integration_input: fn(_, _) {
      Err(@types.ChoirError::validation_error("integration is not expected"))
    },
    plan_conflict_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    read_goal_head: async fn() { Ok(@control.GitOid("goal-head-store")) },
  }
  let record : @workflow.GoalPartSchedulingRecord = {
    part: revised_part,
    task_contract: revised_contract,
  }
  let observed = match
    (@exec.goal_part_workflow_adapters(config).advance_part)(record) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(observed, record)
  assert_eq(execute_count.val, 0)
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
    plan_conflict_repair: fn(_) {
      Ok(@workflow.PartConflictRepairDecision::PartConflictRepairLimitReached)
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
async test "Goal cancellation atomically rejects stale seal authorization" {
  let repository = workflow_repository("goal-assurance-cutoff")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let snapshot = workflow_store_fixture()
  let scheduling_record : @workflow.GoalPartSchedulingRecord = {
    part: { ..snapshot.part, lifecycle: @control.PartLifecycle::PartPending },
    task_contract: snapshot.task_contract,
  }
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let config : @exec.GoalPartWorkflowAdapterConfig = {
    bindings: [{ scheduling_record, initial_snapshot: snapshot, repository }],
    repository_adapters: adapters,
    dependencies: fn(_, admission) {
      let dependencies = workflow_driver_dependencies(
        execute_count,
        reconcile_count,
        fn(_) { None },
        workflow_driver_recover_observation,
      )
      Ok({ ..dependencies, integration_admission: fn(_) { Ok(admission) } })
    },
    integration_input: fn(current, selection) {
      Ok({
        lease: {
          id: @control.IntegrationLeaseId("assurance-cutoff-lease"),
          goal_id: current.goal.id,
          fencing_epoch: current.fencing_epoch,
          holder: "choird-test",
        },
        intent_id: @control.IntegrationIntentId("assurance-cutoff-intent"),
        expected_goal_head_oid: selection.expected_goal_head_oid,
        promotion_metadata_digest: workflow_store_digest_a,
        git_witness_ref: "refs/choir/witness/assurance-cutoff-intent",
      })
    },
    plan_conflict_repair: fn(_) {
      Ok(@workflow.PartConflictRepairDecision::PartConflictRepairLimitReached)
    },
    read_goal_head: async fn() { Ok(@control.GitOid("goal-head-store")) },
  }
  let result = match
    @workflow.run_goal_parts(
      [scheduling_record],
      1,
      @exec.goal_part_workflow_adapters(config),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(result.outcome, @workflow.GoalRunOutcome::GoalRunSucceeded)
  let integrated = @workflow.load_part_snapshot(
      repository,
      adapters,
      snapshot.workflow_id,
    )
    .unwrap()
    .unwrap().snapshot
  let execution : @workflow.GoalExecutionRecord = {
    goal: integrated.goal,
    repository_id: @workflow.RepositoryId("repository-assurance-cutoff"),
    selection_decision_digest: workflow_store_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("goal-head-store"),
    base_tree_oid: @control.GitOid("goal-tree-store"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref: @workflow.goal_execution_ref(integrated.goal.id),
    branch_initialization: workflow_store_initialized_branch(
      integrated.goal.id,
      @workflow.RepositoryId("repository-assurance-cutoff"),
      @workflow.goal_execution_ref(integrated.goal.id),
      @control.GitOid("goal-head-store"),
    ),
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(integrated.goal.id, 1),
    ],
    part_workflow_ids: [integrated.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 1,
    fencing_epoch: integrated.fencing_epoch,
  }
  let execution_receipt = @workflow.persist_goal_execution_record(
    repository,
    adapters,
    { record: execution, expected_store_version: None, fault_point: None },
  ).unwrap()
  assert_eq(
    execution_receipt.transaction_outcome,
    @storage.StateTransactionOutcome::StateTransactionCommitted,
  )
  let assurance_transition = match
    @workflow.run_next_goal_execution_tick(repository, adapters, {
      initialize: async fn(_) { Ok(true) },
      execute: async fn(_, _) {
        fail("integrated Goal dispatched another Part")
      },
      assure: async fn(_, _) {
        fail("Goal assurance ran before its durable state transition")
      },
      finalize: async fn(_, _) {
        fail("Goal finalization ran before assurance")
      },
      cancel: async fn(_, _) { fail("running Goal entered cancellation") },
    }) {
    Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced)) =>
      advanced
    Ok(_) => fail("integrated Goal did not enter assurance")
    Err(error) => fail(error.message())
  }
  assert_eq(
    assurance_transition.state,
    @workflow.GoalExecutionState::GoalExecutionAssuring,
  )
  assert_eq(
    assurance_transition.goal.lifecycle,
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  )
  let planned = @workflow.initialize_goal_assurance(
    assurance_transition,
    [integrated],
    @control.GitOid("promotion-commit-store"),
    @control.GitOid("promotion-tree-store"),
    integrated.task_contract.verification_specs,
    workflow_store_goal_assurance_identities(
      assurance_transition.goal,
      @control.GitOid("promotion-commit-store"),
    ),
  ).unwrap()
  let planned_receipt = @workflow.persist_goal_assurance_record(
    repository,
    adapters,
    {
      record: planned,
      expected_store_version: None,
      goal_precondition: @workflow.goal_execution_state_precondition(
        assurance_transition,
      ),
      fault_point: None,
    },
  ).unwrap()
  assert_eq(
    planned_receipt.outcome,
    @workflow.GoalAssurancePersistenceOutcome::GoalAssurancePersistenceCompleted(
      @storage.StateTransactionOutcome::StateTransactionCommitted,
    ),
  )
  let authorized = @workflow.authorize_goal_assurance_seal(
    planned,
    assurance_transition.goal,
    @control.GitOid("promotion-commit-store"),
    @control.GitOid("promotion-tree-store"),
  ).unwrap()
  match
    @workflow.persist_goal_cancellation_request(
      repository,
      adapters,
      assurance_transition.goal.id,
      1000L,
    ) {
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(_)
    ) => ()
    Ok(_) => fail("Goal cancellation did not install its cutoff")
    Err(error) => fail(error.message())
  }
  let rejected = @workflow.persist_goal_assurance_record(repository, adapters, {
    record: authorized,
    expected_store_version: Some(1),
    goal_precondition: @workflow.goal_execution_state_precondition(
      assurance_transition,
    ),
    fault_point: None,
  }).unwrap()
  assert_eq(
    rejected.outcome,
    @workflow.GoalAssurancePersistenceOutcome::GoalAssuranceGoalPreconditionConflict,
  )
  let replay = @workflow.load_goal_assurance_record(
      repository,
      adapters,
      assurance_transition.goal.id,
    )
    .unwrap()
    .unwrap()
  assert_eq(replay.record, planned)
  clean_workflow_repository(repository)
}

///|
async test "Goal steering persists revision history and paused Goals do not run" {
  let repository = workflow_repository("goal-steering")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, adapters).unwrap()
  let fixture = workflow_store_fixture()
  let execution : @workflow.GoalExecutionRecord = {
    goal: fixture.goal,
    repository_id: @workflow.RepositoryId("repository-goal-steering"),
    selection_decision_digest: workflow_store_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("goal-steering-head"),
    base_tree_oid: @control.GitOid("goal-steering-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref: @workflow.goal_execution_ref(fixture.goal.id),
    branch_initialization: @workflow.initial_goal_branch_initialization(
      fixture.goal.id,
      @workflow.RepositoryId("repository-goal-steering"),
      @workflow.goal_execution_ref(fixture.goal.id),
      @control.GitOid("goal-steering-head"),
    ),
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(fixture.goal.id, 1),
    ],
    part_workflow_ids: [fixture.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionQueued,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 1,
    fencing_epoch: fixture.fencing_epoch,
  }
  ignore(
    @workflow.persist_goal_execution_record(repository, adapters, {
      record: execution,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  guard @workflow.persist_goal_steering(
      repository,
      adapters,
      fixture.goal.id,
      @workflow.GoalPolicyChange::GoalPolicySetMaximumParallelParts(3),
    ).unwrap()
    is @workflow.GoalSteeringPersistenceResult::GoalSteeringPersisted(
      concurrent,
      concurrency_revision
    ) else {
    fail("concurrency policy was not persisted")
  }
  assert_eq(concurrent.maximum_parallel_parts, 3)
  assert_eq(concurrency_revision.ordinal, 2)
  guard @workflow.persist_goal_steering(
      repository,
      adapters,
      fixture.goal.id,
      @workflow.GoalPolicyChange::GoalPolicySetMaximumParallelParts(3),
    ).unwrap()
    is @workflow.GoalSteeringPersistenceResult::GoalSteeringNoChange(_) else {
    fail("identical concurrency policy was not idempotent")
  }
  guard @workflow.persist_goal_steering(
      repository,
      adapters,
      fixture.goal.id,
      @workflow.GoalPolicyChange::GoalPolicyPause,
    ).unwrap()
    is @workflow.GoalSteeringPersistenceResult::GoalSteeringPersisted(paused, _) else {
    fail("pause policy was not persisted")
  }
  assert_eq(paused.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  assert_eq(
    paused.pause.map(fn(value) { value.reason }),
    Some(@workflow.GoalPauseReason::GoalPauseRequested),
  )
  let tick = @workflow.run_next_goal_execution_tick(repository, adapters, {
    initialize: async fn(_) { fail("paused Goal initialized") },
    execute: async fn(_, _) { fail("paused Goal executed") },
    assure: async fn(_, _) { fail("paused Goal entered assurance") },
    finalize: async fn(_, _) { fail("paused Goal entered finalization") },
    cancel: async fn(_, _) { fail("paused Goal entered cancellation") },
  }).unwrap()
  assert_eq(tick, @workflow.GoalExecutionTickResult::GoalExecutionTickIdle)
  guard @workflow.persist_goal_steering(
      repository,
      adapters,
      fixture.goal.id,
      @workflow.GoalPolicyChange::GoalPolicyResume,
    ).unwrap()
    is @workflow.GoalSteeringPersistenceResult::GoalSteeringPersisted(
      resumed,
      _
    ) else {
    fail("resume policy was not persisted")
  }
  assert_eq(resumed.state, @workflow.GoalExecutionState::GoalExecutionQueued)
  assert_eq(resumed.policy_revisions.length(), 4)
  assert_eq(
    @workflow.load_goal_execution_record(
      repository,
      workflow_repository_adapters(),
      fixture.goal.id,
    )
    .unwrap()
    .unwrap().record,
    resumed,
  )
  clean_workflow_repository(repository)
}

///|
async test "Goal finalization input request and answer survive restart" {
  let repository = workflow_repository("goal-input-answer")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, adapters).unwrap()
  let fixture = workflow_store_fixture()
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: fixture,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let execution : @workflow.GoalExecutionRecord = {
    goal: fixture.goal,
    repository_id: @workflow.RepositoryId("repository-goal-input"),
    selection_decision_digest: workflow_store_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("goal-input-head"),
    base_tree_oid: @control.GitOid("goal-input-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref: @workflow.goal_execution_ref(fixture.goal.id),
    branch_initialization: workflow_store_initialized_branch(
      fixture.goal.id,
      @workflow.RepositoryId("repository-goal-input"),
      @workflow.goal_execution_ref(fixture.goal.id),
      @control.GitOid("goal-input-head"),
    ),
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(fixture.goal.id, 1),
    ],
    part_workflow_ids: [fixture.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionAssured,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 1,
    fencing_epoch: fixture.fencing_epoch,
  }
  ignore(
    @workflow.persist_goal_execution_record(repository, adapters, {
      record: execution,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let tick = @workflow.run_next_goal_execution_tick(repository, adapters, {
    initialize: async fn(_) { fail("assured Goal initialized") },
    execute: async fn(_, _) { fail("answered Goal executed Parts") },
    assure: async fn(_, _) { fail("answered Goal repeated assurance") },
    finalize: async fn(_, _) {
      Ok(
        @workflow.GoalFinalizationTickOutcome::GoalFinalizationPublicationRemoteUnavailable,
      )
    },
    cancel: async fn(_, _) { fail("answered Goal entered cancellation") },
  }).unwrap()
  guard tick
    is @workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(paused) else {
    fail("finalization input did not pause the Goal")
  }
  guard paused.active_input_request is Some(request) else {
    fail("durable input request is absent")
  }
  assert_eq(
    request.reason,
    @workflow.GoalInputReason::GoalInputPublicationRemoteUnavailable,
  )
  assert_eq(paused.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  let idle = @workflow.run_next_goal_execution_tick(repository, adapters, {
    initialize: async fn(_) { fail("input-blocked Goal initialized") },
    execute: async fn(_, _) { fail("input-blocked Goal executed Parts") },
    assure: async fn(_, _) { fail("input-blocked Goal repeated assurance") },
    finalize: async fn(_, _) { fail("input-blocked Goal retried finalization") },
    cancel: async fn(_, _) { fail("input-blocked Goal entered cancellation") },
  }).unwrap()
  assert_eq(idle, @workflow.GoalExecutionTickResult::GoalExecutionTickIdle)
  guard @workflow.persist_goal_input_answer(
      workflow_repository("goal-input-answer"),
      workflow_repository_adapters(),
      request.id,
      "The origin remote is configured.",
      20L,
    ).unwrap()
    is @workflow.GoalInputAnswerPersistenceResult::GoalInputAnswerPersisted(
      resumed,
      answer
    ) else {
    fail("durable input answer was not persisted")
  }
  assert_eq(resumed.state, @workflow.GoalExecutionState::GoalExecutionAssured)
  assert_eq(resumed.active_input_request, None)
  assert_eq(resumed.input_answers, [answer])
  guard @workflow.persist_goal_input_answer(
      workflow_repository("goal-input-answer"),
      workflow_repository_adapters(),
      request.id,
      "The origin remote is configured.",
      21L,
    ).unwrap()
    is @workflow.GoalInputAnswerPersistenceResult::GoalInputAnswerPersistenceReplayed(
      replayed,
      _
    ) else {
    fail("durable input answer did not replay")
  }
  assert_eq(replayed, resumed)
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
test "Goal cancellation disposition persists across restart" {
  let repository = workflow_repository("cancel-disposition")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize cancellation repository")
  }
  let initial = workflow_store_fixture()
  let initial_receipt = @workflow.persist_part_snapshot(repository, adapters, {
    snapshot: initial,
    expected_store_version: None,
    fault_point: None,
  }).unwrap()
  let intent = @workflow.plan_next_part_effect(initial).unwrap().unwrap()
  let planned = @workflow.persist_planned_part_effect(initial, intent).unwrap()
  let planned_receipt = @workflow.persist_part_snapshot(repository, adapters, {
    snapshot: planned,
    expected_store_version: Some(initial_receipt.store_version),
    fault_point: None,
  }).unwrap()
  let authorized = @workflow.authorize_pending_part_effect(planned).unwrap()
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: authorized,
      expected_store_version: Some(planned_receipt.store_version),
      fault_point: None,
    }).unwrap(),
  )
  let stored = @workflow.load_part_snapshot(
      repository,
      adapters,
      authorized.workflow_id,
    )
    .unwrap()
    .unwrap()
  let canceled = @workflow.persist_part_goal_cancellation(
    repository, adapters, stored,
  ).unwrap()
  assert_true(
    @workflow.part_cancellation_disposition_is_known(canceled.snapshot),
  )
  assert_true(
    canceled.snapshot.pending_effect
    is Some(
      { lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain, .. }
    ),
  )
  let replay = @workflow.load_part_snapshot(
      repository,
      adapters,
      authorized.workflow_id,
    )
    .unwrap()
    .unwrap()
  assert_eq(replay, canceled)
  assert_eq(
    @workflow.persist_part_goal_cancellation(repository, adapters, replay).unwrap(),
    canceled,
  )
  clean_workflow_repository(repository)
}

///|
async test "driver recovers every persisted transition after rollback" {
  let boundaries = [
    @workflow.PartPersistenceBoundary::WorkflowAcceptedSnapshot,
    @workflow.PartPersistenceBoundary::WorkflowEffectPlanned,
    @workflow.PartPersistenceBoundary::WorkflowEffectAuthorized,
    @workflow.PartPersistenceBoundary::WorkflowEffectObserved,
    @workflow.PartPersistenceBoundary::WorkflowAuditResultRecorded,
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
