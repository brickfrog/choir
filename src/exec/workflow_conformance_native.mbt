///|
pub(all) struct OnePartConformanceReport {
  passed : Bool
  effect_receipt_count : Int
  verification_receipt_count : Int
  audit_receipt_count : Int
  integration_receipt_count : Int
  restart_executed_effect_count : Int
  persistence_boundaries_checked : Int
  failure : String?
} derive(Debug, Eq, ToJson)

///|
let conformance_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let conformance_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn conformance_take(
  id : String,
  purpose : @control.TakePurpose,
) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id: @control.GoalId("goal-conformance"),
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn conformance_snapshot() -> Result[
  @workflow.OnePartWorkflowSnapshot,
  @types.ChoirError,
] {
  let goal : @control.Goal = {
    id: @control.GoalId("goal-conformance"),
    contract_digest: conformance_digest_a,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let part : @control.GoalPart = {
    id: @control.PartId("part-conformance"),
    goal_id: goal.id,
    dependency_ids: [],
    task_contract_revision_id: @control.RevisionId("revision-conformance"),
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let contract : @control.TaskContractRevision = {
    id: part.task_contract_revision_id,
    goal_id: goal.id,
    part_id: part.id,
    revision: 1,
    digest: conformance_digest_a,
    instruction_artifact: {
      artifact_id: "instruction-conformance",
      digest: conformance_digest_a,
    },
    base_commit_oid: @control.GitOid("base-conformance"),
    base_tree_oid: @control.GitOid("base-tree-conformance"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath("src/conformance.mbt"),
        ),
      ],
    ),
    verification_specs: [
      {
        id: @control.VerificationSpecId("verify-conformance"),
        version: 1,
        digest: conformance_digest_a,
        process_spec_digest: conformance_digest_b,
      },
    ],
    audit_policy_digest: conformance_digest_a,
    implementation_capability_profile_digest: conformance_digest_a,
    verification_capability_profile_digest: conformance_digest_b,
    audit_capability_profile_digest: conformance_digest_a,
  }
  let implementation = conformance_take(
    "implementation-conformance",
    @control.TakePurpose::Implementation(part.id, contract.id),
  )
  let verification = conformance_take(
    "verification-conformance",
    @control.TakePurpose::PartVerification(
      part.id,
      implementation.id,
      conformance_digest_a,
    ),
  )
  let audit = conformance_take(
    "audit-conformance",
    @control.TakePurpose::PartAudit(
      part.id,
      implementation.id,
      conformance_digest_a,
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
      runtime_policy_digest: conformance_digest_b,
      lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
    }
  }
  let implementation_sandbox = sandbox(
    "implementation-sandbox-conformance",
    "implementation-generation-conformance",
    implementation,
    contract.implementation_capability_profile_digest,
  )
  let verification_sandbox = sandbox(
    "verification-sandbox-conformance",
    "verification-generation-conformance",
    verification,
    contract.verification_capability_profile_digest,
  )
  let audit_sandbox = sandbox(
    "audit-sandbox-conformance",
    "audit-generation-conformance",
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
      effective_surface_manifest_digest: conformance_digest_a,
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
      "implementation-session-conformance", implementation, implementation_sandbox,
    ),
    verification_take: verification,
    verification_sandbox,
    verification_session: session(
      "verification-session-conformance", verification, verification_sandbox,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: session("audit-session-conformance", audit, audit_sandbox),
  }
  @workflow.initialize_one_part_workflow(
    "workflow-conformance",
    goal,
    part,
    contract,
    identities,
    @control.FencingEpoch(7L),
    fn(_) { true },
  )
}

///|
fn conformance_repository(root : String) -> @workflow.OnePartWorkflowRepository {
  {
    state_store: { path: root + ".db" },
    artifact_store: { root: root + "-artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
}

///|
fn clear_conformance_repository(
  repository : @workflow.OnePartWorkflowRepository,
) -> Unit {
  ignore(@sys.rm_rf(repository.state_store.path))
  ignore(@sys.rm_rf(repository.state_store.path + "-shm"))
  ignore(@sys.rm_rf(repository.state_store.path + "-wal"))
  ignore(@sys.rm_rf(repository.artifact_store.root))
}

///|
fn conformance_started_session(
  session : @control.HarnessSession,
) -> @control.HarnessSession {
  {
    ..session,
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  }
}

///|
fn conformance_trace(
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
    sanitized_payload_digest: conformance_digest_a,
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
    sanitized_payload_digest: conformance_digest_b,
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
fn conformance_effect_observation(
  snapshot : @workflow.OnePartWorkflowSnapshot,
  intent : @workflow.OnePartEffectIntent,
) -> Result[@workflow.OnePartEffectObservation, @types.ChoirError] {
  match intent.kind {
    @workflow.OnePartEffectKind::PrepareImplementationSandbox(lease) =>
      Ok(
        @workflow.OnePartEffectObservation::ImplementationSandboxPrepared({
          ..lease,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        }),
      )
    @workflow.OnePartEffectKind::StartImplementationHarness(session) =>
      Ok(
        @workflow.OnePartEffectObservation::ImplementationHarnessStarted(
          conformance_started_session(session),
        ),
      )
    @workflow.OnePartEffectKind::DispatchImplementation(take_id, session_id) => {
      let started = conformance_started_session(
        snapshot.identities.implementation_session,
      )
      let (closed, events) = conformance_trace(started, "implementation")
      Ok(
        @workflow.OnePartEffectObservation::ImplementationCompleted(
          {
            take_id,
            session_id,
            result_artifact: {
              artifact_id: "implementation-result-conformance",
              digest: conformance_digest_b,
            },
            finished_at: 102L,
          },
          closed,
          events,
        ),
      )
    }
    @workflow.OnePartEffectKind::NormalizeImplementationCandidate(take_id, _) =>
      Ok(
        @workflow.OnePartEffectObservation::CandidateNormalized(
          {
            id: @control.CandidateId("candidate-conformance"),
            goal_id: snapshot.goal.id,
            part_id: snapshot.part.id,
            take_id,
            base_commit_oid: snapshot.task_contract.base_commit_oid,
            commit_oid: @control.GitOid("candidate-commit-conformance"),
            tree_oid: @control.GitOid("candidate-tree-conformance"),
            canonical_change_digest: conformance_digest_b,
            changed_paths: [@control.RepoPath("src/conformance.mbt")],
          },
          {
            candidate_tree_paths: [@control.RepoPath("src/conformance.mbt")],
            symlink_prefix_paths: [],
            normalization_collision_paths: [],
          },
        ),
      )
    @workflow.OnePartEffectKind::PrepareVerificationSandbox(lease) =>
      Ok(
        @workflow.OnePartEffectObservation::VerificationSandboxPrepared({
          ..lease,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        }),
      )
    @workflow.OnePartEffectKind::StartVerificationHarness(session) =>
      Ok(
        @workflow.OnePartEffectObservation::VerificationHarnessStarted(
          conformance_started_session(session),
        ),
      )
    @workflow.OnePartEffectKind::DispatchVerification(
      take_id,
      session_id,
      subject
    ) => {
      let started = conformance_started_session(
        snapshot.identities.verification_session,
      )
      let (closed, events) = conformance_trace(started, "verification")
      let candidate = match snapshot.candidate {
        Some(value) => value
        None =>
          return Err(@types.ChoirError::validation_error("candidate is absent"))
      }
      Ok(
        @workflow.OnePartEffectObservation::VerificationCompleted(
          {
            take_id,
            session_id,
            verification_execution_id: @control.VerificationExecutionId(
              "verification-execution-conformance",
            ),
            subject,
            verification_spec: snapshot.task_contract.verification_specs[0],
            environment_and_image_digest: conformance_digest_b,
            runtime_and_policy_digest: snapshot.identities.verification_sandbox.runtime_policy_digest,
            subject_pre_tree_oid: candidate.tree_oid,
            subject_post_tree_oid: candidate.tree_oid,
            evidence: {
              artifact_id: "verification-evidence-conformance",
              digest: conformance_digest_b,
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
    @workflow.OnePartEffectKind::PrepareAuditSandbox(lease) =>
      Ok(
        @workflow.OnePartEffectObservation::AuditSandboxPrepared({
          ..lease,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        }),
      )
    @workflow.OnePartEffectKind::StartAuditHarness(session) =>
      Ok(
        @workflow.OnePartEffectObservation::AuditHarnessStarted(
          conformance_started_session(session),
        ),
      )
    @workflow.OnePartEffectKind::DispatchAudit(take_id, session_id, subject) => {
      let started = conformance_started_session(
        snapshot.identities.audit_session,
      )
      let (closed, events) = conformance_trace(started, "audit")
      Ok(
        @workflow.OnePartEffectObservation::AuditCompleted(
          {
            audit_take_id: take_id,
            take_fencing_epoch: snapshot.fencing_epoch,
            audit_harness_session_id: session_id,
            subject,
            provider_conformance_report_digest: conformance_digest_a,
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
    @workflow.OnePartEffectKind::GeneratePromotion(intent) =>
      Ok(
        @workflow.OnePartEffectObservation::PromotionGenerated({
          intent_id: intent.id,
          commit_oid: @control.GitOid("promotion-commit-conformance"),
          tree_oid: @control.GitOid("promotion-tree-conformance"),
          first_parent_oid: intent.expected_goal_head_oid,
          second_parent_oid: intent.candidate_commit_oid,
        }),
      )
    @workflow.OnePartEffectKind::ApplyIntegration(_, promotion) =>
      Ok(
        @workflow.OnePartEffectObservation::IntegrationWitnessObserved(
          @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
            promotion.commit_oid,
            promotion.commit_oid,
          ),
        ),
      )
  }
}

///|
fn conformance_dependencies(
  execute_count : Ref[Int],
  fault : (@workflow.OnePartPersistenceBoundary) -> @storage.StateStoreFaultPoint?,
) -> @workflow.OnePartWorkflowDriverDependencies {
  {
    now: fn() { 110L },
    persistence_fault: fault,
    effects: {
      execute: async fn(snapshot, intent) {
        execute_count.val = execute_count.val + 1
        conformance_effect_observation(snapshot, intent)
      },
      reconcile: async fn(snapshot, intent) {
        match conformance_effect_observation(snapshot, intent) {
          Ok(observation) =>
            Ok(
              @workflow.OnePartEffectRecovery::EffectObservationRecovered(
                observation,
              ),
            )
          Err(error) => Err(error)
        }
      },
    },
    artifact_exists: fn(_) { true },
    artifact_digest_exists: fn(_) { true },
    is_nfc: fn(_) { true },
    audit_receipt_metadata: fn(_) {
      Ok({
        receipt_id: @control.ReceiptId("audit-receipt-conformance"),
        provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_identity: "claude-code-conformance",
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "claude-conformance",
        ),
      })
    },
    integration_plan: fn(snapshot) {
      Ok({
        lease: {
          id: @control.IntegrationLeaseId("integration-lease-conformance"),
          goal_id: snapshot.goal.id,
          fencing_epoch: snapshot.fencing_epoch,
          holder: "choird-conformance",
        },
        intent_id: @control.IntegrationIntentId(
          "integration-intent-conformance",
        ),
        expected_goal_head_oid: @control.GitOid("goal-head-conformance"),
        promotion_metadata_digest: conformance_digest_a,
        git_witness_ref: "refs/choir/witness/integration-conformance",
      })
    },
    verification_environment_digest: fn(_) { conformance_digest_b },
    verification_runtime_digest: fn(snapshot) {
      snapshot.identities.verification_sandbox.runtime_policy_digest
    },
  }
}

///|
fn failed_one_part_report(message : String) -> OnePartConformanceReport {
  {
    passed: false,
    effect_receipt_count: 0,
    verification_receipt_count: 0,
    audit_receipt_count: 0,
    integration_receipt_count: 0,
    restart_executed_effect_count: 0,
    persistence_boundaries_checked: 0,
    failure: Some(message),
  }
}

///|
pub async fn run_one_part_conformance_fixture(
  root : String,
) -> OnePartConformanceReport {
  let snapshot = match conformance_snapshot() {
    Ok(value) => value
    Err(error) => return failed_one_part_report(error.message())
  }
  let repository = conformance_repository(root + "/uninterrupted")
  clear_conformance_repository(repository)
  let execute_count = @ref.new(0)
  let dependencies = conformance_dependencies(execute_count, fn(_) { None })
  let result = match
    @workflow.run_new_one_part_workflow(
      repository,
      local_one_part_workflow_repository_adapters(),
      snapshot,
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => {
      clear_conformance_repository(repository)
      return failed_one_part_report(error.message())
    }
  }
  if result.outcome != @workflow.OnePartWorkflowRunOutcome::OnePartRunIntegrated {
    clear_conformance_repository(repository)
    return failed_one_part_report("uninterrupted workflow did not integrate")
  }
  let executed_before_restart = execute_count.val
  let resumed = match
    @workflow.resume_one_part_workflow(
      repository,
      local_one_part_workflow_repository_adapters(),
      "workflow-conformance",
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => {
      clear_conformance_repository(repository)
      return failed_one_part_report(error.message())
    }
  }
  let restart_executed = execute_count.val - executed_before_restart
  clear_conformance_repository(repository)
  if resumed.outcome !=
    @workflow.OnePartWorkflowRunOutcome::OnePartRunIntegrated ||
    restart_executed != 0 {
    return failed_one_part_report("restart repeated completed workflow work")
  }
  let audit_receipt_count = if result.snapshot.audit_receipt is Some(_) {
    1
  } else {
    0
  }
  let integration_receipt_count = if result.snapshot.integration_receipt
    is Some(_) {
    1
  } else {
    0
  }
  if result.snapshot.effect_receipts.length() != 12 ||
    result.snapshot.verification_receipts.length() != 1 ||
    audit_receipt_count != 1 ||
    integration_receipt_count != 1 ||
    result.snapshot.identities.implementation_sandbox.generation_id ==
    result.snapshot.identities.audit_sandbox.generation_id ||
    result.snapshot.identities.implementation_session.id ==
    result.snapshot.identities.audit_session.id {
    return failed_one_part_report(
      "integrated workflow violated receipt or independence cardinality",
    )
  }
  let boundaries = [
    @workflow.OnePartPersistenceBoundary::WorkflowAcceptedSnapshot,
    @workflow.OnePartPersistenceBoundary::WorkflowEffectPlanned,
    @workflow.OnePartPersistenceBoundary::WorkflowEffectAuthorized,
    @workflow.OnePartPersistenceBoundary::WorkflowEffectObserved,
    @workflow.OnePartPersistenceBoundary::WorkflowAuditReceiptRecorded,
    @workflow.OnePartPersistenceBoundary::WorkflowIntegrationPlanned,
    @workflow.OnePartPersistenceBoundary::WorkflowIntegrationAuthorized,
  ]
  for index, boundary in boundaries {
    let fault_repository = conformance_repository(
      root + "/fault-" + index.to_string(),
    )
    clear_conformance_repository(fault_repository)
    let injected = @ref.new(false)
    let fault_count = @ref.new(0)
    let first = match
      @workflow.run_new_one_part_workflow(
        fault_repository,
        local_one_part_workflow_repository_adapters(),
        snapshot,
        conformance_dependencies(fault_count, fn(actual) {
          if !injected.val && actual == boundary {
            injected.val = true
            Some(@storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox)
          } else {
            None
          }
        }),
      ) {
      Ok(value) => value
      Err(error) => {
        clear_conformance_repository(fault_repository)
        return failed_one_part_report(error.message())
      }
    }
    if first.outcome !=
      @workflow.OnePartWorkflowRunOutcome::OnePartRunPersistenceFault(
        boundary,
        @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
      ) {
      clear_conformance_repository(fault_repository)
      return failed_one_part_report("fault was not observed at its boundary")
    }
    let recovered = if boundary ==
      @workflow.OnePartPersistenceBoundary::WorkflowAcceptedSnapshot {
      @workflow.run_new_one_part_workflow(
        fault_repository,
        local_one_part_workflow_repository_adapters(),
        snapshot,
        conformance_dependencies(fault_count, fn(_) { None }),
      )
    } else {
      @workflow.resume_one_part_workflow(
        fault_repository,
        local_one_part_workflow_repository_adapters(),
        "workflow-conformance",
        conformance_dependencies(fault_count, fn(_) { None }),
      )
    }
    match recovered {
      Ok(
        {
          outcome: @workflow.OnePartWorkflowRunOutcome::OnePartRunIntegrated,
          snapshot: recovered_snapshot,
          ..,
        }
      ) =>
        if recovered_snapshot.effect_receipts.length() != 12 ||
          recovered_snapshot.verification_receipts.length() != 1 ||
          recovered_snapshot.audit_receipt is None ||
          recovered_snapshot.integration_receipt is None {
          clear_conformance_repository(fault_repository)
          return failed_one_part_report(
            "fault recovery violated receipt cardinality",
          )
        }
      Ok(_) => {
        clear_conformance_repository(fault_repository)
        return failed_one_part_report("fault recovery did not integrate")
      }
      Err(error) => {
        clear_conformance_repository(fault_repository)
        return failed_one_part_report(error.message())
      }
    }
    clear_conformance_repository(fault_repository)
  }
  {
    passed: true,
    effect_receipt_count: result.snapshot.effect_receipts.length(),
    verification_receipt_count: result.snapshot.verification_receipts.length(),
    audit_receipt_count,
    integration_receipt_count,
    restart_executed_effect_count: restart_executed,
    persistence_boundaries_checked: boundaries.length(),
    failure: None,
  }
}
