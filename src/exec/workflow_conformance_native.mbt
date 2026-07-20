///|
pub(all) struct PartConformanceReport {
  passed : Bool
  effect_receipt_count : Int
  verification_receipt_count : Int
  audit_receipt_count : Int
  integration_receipt_count : Int
  restart_executed_effect_count : Int
  persistence_boundaries_checked : Int
  audit_result_recovery_checked : Bool
  audit_receipt_recovery_checked : Bool
  audit_protocol_conflict_checked : Bool
  failure : String?
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ScaleConformanceReport {
  passed : Bool
  manifest_digest : @control.Digest
  part_count : Int
  concurrency_limits : Array[Int]
  observed_parallelism : Array[Int]
  promotion_order : Array[@control.PartId]
  semantic_projection_digest : @control.Digest?
  part_verification_receipt_count : Int
  part_audit_receipt_count : Int
  integration_receipt_count : Int
  goal_verification_receipt_count : Int
  goal_audit_receipt_count : Int
  publication_receipt_count : Int
  pull_request_receipt_count : Int
  failure : String?
} derive(Debug, Eq, ToJson)

///|
priv struct ScalePartManifestEntry {
  part_id : @control.PartId
  dependency_ids : Array[@control.PartId]
  surface : @control.ProviderSurfaceId
} derive(ToJson)

///|
priv struct ScaleRunResult {
  snapshots : Array[@workflow.PartWorkflowSnapshot]
  observed_parallelism : Int
  promotion_order : Array[@control.PartId]
  projection : @workflow.SemanticRunProjection
}

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
  goal_id : @control.GoalId,
  id : String,
  purpose : @control.TakePurpose,
) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id,
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn conformance_snapshot_for(
  key : String,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  dependency_ids : Array[@control.PartId],
  surface : @control.ProviderSurfaceId,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  let semantic_digest = @storage.artifact_digest(
    @utf8.encode("choir.conformance-part.v1\u{00}" + part_id.0),
  )
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest: @storage.artifact_digest(
      @utf8.encode("choir.conformance-goal.v1\u{00}" + goal_id.0),
    ),
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let part : @control.GoalPart = {
    id: part_id,
    goal_id: goal.id,
    dependency_ids,
    task_contract_revision_id: @control.RevisionId("revision-" + key),
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let contract : @control.TaskContractRevision = {
    id: part.task_contract_revision_id,
    goal_id: goal.id,
    part_id: part.id,
    revision: 1,
    digest: semantic_digest,
    repair_conflict_id: None,
    instruction_artifact: {
      artifact_id: "instruction-" + key,
      digest: semantic_digest,
    },
    base_commit_oid: @control.GitOid("base-conformance"),
    base_tree_oid: @control.GitOid("base-tree-conformance"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath("src/" + part_id.0 + ".mbt"),
        ),
      ],
    ),
    verification_specs: [
      {
        id: @control.VerificationSpecId("verify-" + part_id.0),
        version: 1,
        digest: semantic_digest,
        process_spec_digest: conformance_digest_b,
      },
    ],
    audit_policy_digest: semantic_digest,
    implementation_capability_profile_digest: conformance_digest_a,
    verification_capability_profile_digest: conformance_digest_b,
    audit_capability_profile_digest: conformance_digest_a,
  }
  let implementation = conformance_take(
    goal.id,
    "implementation-" + key,
    @control.TakePurpose::Implementation(part.id, contract.id),
  )
  let verification = conformance_take(
    goal.id,
    "verification-" + key,
    @control.TakePurpose::PartVerification(
      part.id,
      implementation.id,
      semantic_digest,
    ),
  )
  let audit = conformance_take(
    goal.id,
    "audit-" + key,
    @control.TakePurpose::PartAudit(part.id, implementation.id, semantic_digest),
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
    "implementation-sandbox-" + key,
    "implementation-generation-" + key,
    implementation,
    contract.implementation_capability_profile_digest,
  )
  let verification_sandbox = sandbox(
    "verification-sandbox-" + key,
    "verification-generation-" + key,
    verification,
    contract.verification_capability_profile_digest,
  )
  let audit_sandbox = sandbox(
    "audit-sandbox-" + key,
    "audit-generation-" + key,
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
      surface,
      effective_surface_manifest_digest: conformance_digest_a,
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
      "implementation-session-" + key,
      implementation,
      implementation_sandbox,
    ),
    verification_take: verification,
    verification_sandbox,
    verification_session: session(
      "verification-session-" + key,
      verification,
      verification_sandbox,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: session("audit-session-" + key, audit, audit_sandbox),
  }
  @workflow.initialize_part_workflow(
    "workflow-" + key,
    goal,
    part,
    contract,
    identities,
    @control.FencingEpoch(7L),
    fn(_) { true },
  )
}

///|
fn conformance_snapshot() -> Result[
  @workflow.PartWorkflowSnapshot,
  @types.ChoirError,
] {
  conformance_snapshot_for(
    "conformance",
    @control.GoalId("goal-conformance"),
    @control.PartId("part-conformance"),
    [],
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
}

///|
fn conformance_repository(root : String) -> @workflow.PartWorkflowRepository {
  {
    state_store: { path: root + ".db" },
    artifact_store: { root: root + "-artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
}

///|
fn clear_conformance_repository(
  repository : @workflow.PartWorkflowRepository,
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
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  let key = snapshot.part.id.0
  let change_digest = @storage.artifact_digest(
    @utf8.encode("choir.conformance-change.v1\u{00}" + key),
  )
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
          conformance_started_session(session),
        ),
      )
    @workflow.PartEffectKind::DispatchImplementation(take_id, session_id) => {
      let started = conformance_started_session(
        snapshot.identities.implementation_session,
      )
      let (closed, events) = conformance_trace(started, "implementation-" + key)
      Ok(
        @workflow.PartEffectObservation::ImplementationCompleted(
          {
            take_id,
            session_id,
            result_artifact: {
              artifact_id: "implementation-result-" + key,
              digest: change_digest,
            },
            finished_at: 102L,
          },
          closed,
          events,
        ),
      )
    }
    @workflow.PartEffectKind::NormalizeImplementationCandidate(take_id, _) =>
      Ok(
        @workflow.PartEffectObservation::CandidateNormalized(
          {
            id: @control.CandidateId("candidate-" + key),
            goal_id: snapshot.goal.id,
            part_id: snapshot.part.id,
            take_id,
            base_commit_oid: snapshot.task_contract.base_commit_oid,
            commit_oid: @control.GitOid("candidate-commit-" + key),
            tree_oid: @control.GitOid("candidate-tree-" + key),
            canonical_change_digest: change_digest,
            changed_paths: [@control.RepoPath("src/" + key + ".mbt")],
          },
          {
            candidate_tree_paths: [@control.RepoPath("src/" + key + ".mbt")],
            symlink_prefix_paths: [],
            normalization_collision_paths: [],
          },
        ),
      )
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
          conformance_started_session(session),
        ),
      )
    @workflow.PartEffectKind::DispatchVerification(take_id, session_id, subject) => {
      let started = conformance_started_session(
        snapshot.identities.verification_session,
      )
      let (closed, events) = conformance_trace(started, "verification-" + key)
      let candidate = match snapshot.candidate {
        Some(value) => value
        None =>
          return Err(@types.ChoirError::validation_error("candidate is absent"))
      }
      Ok(
        @workflow.PartEffectObservation::VerificationCompleted(
          {
            take_id,
            session_id,
            verification_execution_id: @control.VerificationExecutionId(
              "verification-execution-" + key,
            ),
            subject,
            verification_spec: snapshot.task_contract.verification_specs[0],
            environment_and_image_digest: conformance_digest_b,
            runtime_and_policy_digest: snapshot.identities.verification_sandbox.runtime_policy_digest,
            subject_pre_tree_oid: candidate.tree_oid,
            subject_post_tree_oid: candidate.tree_oid,
            evidence: {
              artifact_id: "verification-evidence-" + key,
              digest: change_digest,
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
          conformance_started_session(session),
        ),
      )
    @workflow.PartEffectKind::DispatchAudit(take_id, session_id, subject) => {
      let started = conformance_started_session(
        snapshot.identities.audit_session,
      )
      let (closed, events) = conformance_trace(started, "audit-" + key)
      Ok(
        @workflow.PartEffectObservation::AuditCompleted(
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
    @workflow.PartEffectKind::GeneratePromotion(intent) =>
      Ok(
        @workflow.PartEffectObservation::PromotionGenerated({
          intent_id: intent.id,
          commit_oid: @control.GitOid(
            "promotion-commit-" +
            key +
            "-after-" +
            intent.expected_goal_head_oid.0,
          ),
          tree_oid: @control.GitOid(
            "promotion-tree-" +
            key +
            "-after-" +
            intent.expected_goal_head_oid.0,
          ),
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
fn conformance_dependencies(
  repository : @workflow.PartWorkflowRepository,
  execute_count : Ref[Int],
  fault : (@workflow.PartPersistenceBoundary) -> @storage.StateStoreFaultPoint?,
  inject_audit_conflict? : Bool = false,
  implementation_dispatch_count? : Ref[Int]? = None,
  integration_head? : @control.GitOid? = Some(
    @control.GitOid("goal-head-conformance"),
  ),
) -> @workflow.PartWorkflowDriverDependencies {
  let now = fn() { 110L }
  let dependencies : @workflow.PartWorkflowDriverDependencies = {
    now,
    persistence_fault: fault,
    effects: {
      execute: async fn(snapshot, intent) {
        execute_count.val = execute_count.val + 1
        match (implementation_dispatch_count, intent.kind) {
          (Some(count), @workflow.PartEffectKind::DispatchImplementation(_, _)) =>
            count.val = count.val + 1
          _ => ()
        }
        let observation = match
          conformance_effect_observation(snapshot, intent) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if inject_audit_conflict {
          match (intent.kind, observation) {
            (
              @workflow.PartEffectKind::DispatchAudit(_, _, _),
              @workflow.PartEffectObservation::AuditCompleted(
                result,
                session,
                events
              ),
            ) => {
              match
                @workflow.record_part_effect_witness(
                  repository,
                  local_part_workflow_repository_adapters(),
                  snapshot,
                  intent,
                  observation,
                  now(),
                ) {
                Ok(_) => ()
                Err(error) => return Err(error)
              }
              Ok(
                @workflow.PartEffectObservation::AuditCompleted(
                  { ..result, finished_at: result.finished_at + 1L },
                  session,
                  events,
                ),
              )
            }
            _ => Ok(observation)
          }
        } else {
          Ok(observation)
        }
      },
      reconcile: async fn(snapshot, intent) {
        match conformance_effect_observation(snapshot, intent) {
          Ok(observation) =>
            Ok(
              @workflow.PartEffectRecovery::EffectObservationRecovered(
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
    audit_receipt_metadata: fn(snapshot) {
      Ok({
        receipt_id: @control.ReceiptId("audit-receipt-" + snapshot.part.id.0),
        provider_surface_id: snapshot.identities.audit_session.surface,
        provider_identity: "provider-conformance-" + snapshot.part.id.0,
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "model-conformance-" + snapshot.part.id.0,
        ),
      })
    },
    goal_authorizes_new_effects: fn() {
      Ok(@workflow.PartGoalAuthorization::PartGoalAuthorized(None))
    },
    integration_admission: fn(snapshot) {
      match integration_head {
        None => Ok(@workflow.PartIntegrationAdmission::PartIntegrationDeferred)
        Some(expected_goal_head_oid) =>
          Ok(
            @workflow.PartIntegrationAdmission::PartIntegrationAdmitted({
              lease: {
                id: @control.IntegrationLeaseId(
                  "integration-lease-" + snapshot.part.id.0,
                ),
                goal_id: snapshot.goal.id,
                fencing_epoch: snapshot.fencing_epoch,
                holder: "choird-conformance",
              },
              intent_id: @control.IntegrationIntentId(
                "integration-intent-" + snapshot.part.id.0,
              ),
              expected_goal_head_oid,
              promotion_metadata_digest: conformance_digest_a,
              git_witness_ref: "refs/choir/witness/integration-" +
              snapshot.part.id.0,
            }),
          )
      }
    },
    verification_environment_digest: fn(_) { conformance_digest_b },
    verification_runtime_digest: fn(snapshot) {
      snapshot.identities.verification_sandbox.runtime_policy_digest
    },
  }
  {
    ..dependencies,
    effects: @workflow.witnessed_part_effect_adapters(
      repository,
      local_part_workflow_repository_adapters(),
      dependencies.effects,
      now,
    ),
  }
}

///|
fn failed_part_report(message : String) -> PartConformanceReport {
  {
    passed: false,
    effect_receipt_count: 0,
    verification_receipt_count: 0,
    audit_receipt_count: 0,
    integration_receipt_count: 0,
    restart_executed_effect_count: 0,
    persistence_boundaries_checked: 0,
    audit_result_recovery_checked: false,
    audit_receipt_recovery_checked: false,
    audit_protocol_conflict_checked: false,
    failure: Some(message),
  }
}

///|
pub async fn run_part_conformance_fixture(
  root : String,
) -> PartConformanceReport {
  let snapshot = match conformance_snapshot() {
    Ok(value) => value
    Err(error) => return failed_part_report(error.message())
  }
  let repository = conformance_repository(root + "/uninterrupted")
  clear_conformance_repository(repository)
  let execute_count = @ref.new(0)
  let dependencies = conformance_dependencies(repository, execute_count, fn(_) {
    None
  })
  let result = match
    @workflow.run_new_part_workflow(
      repository,
      local_part_workflow_repository_adapters(),
      snapshot,
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => {
      clear_conformance_repository(repository)
      return failed_part_report(error.message())
    }
  }
  if result.outcome != @workflow.PartWorkflowRunOutcome::PartRunIntegrated {
    clear_conformance_repository(repository)
    return failed_part_report("uninterrupted workflow did not integrate")
  }
  let executed_before_restart = execute_count.val
  let resumed = match
    @workflow.resume_part_workflow(
      repository,
      local_part_workflow_repository_adapters(),
      "workflow-conformance",
      dependencies,
    ) {
    Ok(value) => value
    Err(error) => {
      clear_conformance_repository(repository)
      return failed_part_report(error.message())
    }
  }
  let restart_executed = execute_count.val - executed_before_restart
  clear_conformance_repository(repository)
  if resumed.outcome != @workflow.PartWorkflowRunOutcome::PartRunIntegrated ||
    restart_executed != 0 {
    return failed_part_report("restart repeated completed workflow work")
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
    return failed_part_report(
      "integrated workflow violated receipt or independence cardinality",
    )
  }
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
  let audit_result_recovery_checked = @ref.new(false)
  let audit_receipt_recovery_checked = @ref.new(false)
  for index, boundary in boundaries {
    let fault_repository = conformance_repository(
      root + "/fault-" + index.to_string(),
    )
    clear_conformance_repository(fault_repository)
    let injected = @ref.new(false)
    let fault_count = @ref.new(0)
    let effect_observation_count = @ref.new(0)
    let implementation_dispatch_count = @ref.new(0)
    let first = match
      @workflow.run_new_part_workflow(
        fault_repository,
        local_part_workflow_repository_adapters(),
        snapshot,
        conformance_dependencies(
          fault_repository,
          fault_count,
          fn(actual) {
            if actual ==
              @workflow.PartPersistenceBoundary::WorkflowEffectObserved {
              effect_observation_count.val = effect_observation_count.val + 1
            }
            let target_occurrence = boundary !=
              @workflow.PartPersistenceBoundary::WorkflowEffectObserved ||
              effect_observation_count.val == 3
            if !injected.val && actual == boundary && target_occurrence {
              injected.val = true
              Some(
                @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
              )
            } else {
              None
            }
          },
          implementation_dispatch_count=Some(implementation_dispatch_count),
        ),
      ) {
      Ok(value) => value
      Err(error) => {
        clear_conformance_repository(fault_repository)
        return failed_part_report(error.message())
      }
    }
    if first.outcome !=
      @workflow.PartWorkflowRunOutcome::PartRunPersistenceFault(
        boundary,
        @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
      ) {
      clear_conformance_repository(fault_repository)
      return failed_part_report("fault was not observed at its boundary")
    }
    let recovered = if boundary ==
      @workflow.PartPersistenceBoundary::WorkflowAcceptedSnapshot {
      @workflow.run_new_part_workflow(
        fault_repository,
        local_part_workflow_repository_adapters(),
        snapshot,
        conformance_dependencies(
          fault_repository,
          fault_count,
          fn(_) { None },
          implementation_dispatch_count=Some(implementation_dispatch_count),
        ),
      )
    } else {
      @workflow.resume_part_workflow(
        fault_repository,
        local_part_workflow_repository_adapters(),
        "workflow-conformance",
        conformance_dependencies(
          fault_repository,
          fault_count,
          fn(_) { None },
          implementation_dispatch_count=Some(implementation_dispatch_count),
        ),
      )
    }
    match recovered {
      Ok(
        {
          outcome: @workflow.PartWorkflowRunOutcome::PartRunIntegrated,
          snapshot: recovered_snapshot,
          ..,
        }
      ) =>
        if boundary == @workflow.PartPersistenceBoundary::WorkflowEffectObserved &&
          implementation_dispatch_count.val != 1 {
          clear_conformance_repository(fault_repository)
          return failed_part_report(
            "effect-observation recovery redispatched provider work",
          )
        } else if recovered_snapshot.effect_receipts.length() != 12 ||
          recovered_snapshot.verification_receipts.length() != 1 ||
          recovered_snapshot.audit_receipt is None ||
          recovered_snapshot.integration_receipt is None {
          clear_conformance_repository(fault_repository)
          return failed_part_report(
            "fault recovery violated receipt cardinality",
          )
        } else {
          if boundary ==
            @workflow.PartPersistenceBoundary::WorkflowAuditResultRecorded {
            audit_result_recovery_checked.val = true
          }
          if boundary ==
            @workflow.PartPersistenceBoundary::WorkflowAuditReceiptRecorded {
            audit_receipt_recovery_checked.val = true
          }
        }
      Ok(_) => {
        clear_conformance_repository(fault_repository)
        return failed_part_report("fault recovery did not integrate")
      }
      Err(error) => {
        clear_conformance_repository(fault_repository)
        return failed_part_report(error.message())
      }
    }
    clear_conformance_repository(fault_repository)
  }
  let conflict_repository = conformance_repository(root + "/audit-conflict")
  clear_conformance_repository(conflict_repository)
  let conflict_count = @ref.new(0)
  let conflict_result = match
    @workflow.run_new_part_workflow(
      conflict_repository,
      local_part_workflow_repository_adapters(),
      snapshot,
      conformance_dependencies(
        conflict_repository,
        conflict_count,
        fn(_) { None },
        inject_audit_conflict=true,
      ),
    ) {
    Ok(value) => value
    Err(error) => {
      clear_conformance_repository(conflict_repository)
      return failed_part_report(error.message())
    }
  }
  let conflict_intent = match conflict_result.snapshot.pending_effect {
    Some(value) => value
    None => {
      clear_conformance_repository(conflict_repository)
      return failed_part_report("audit conflict lost its effect intent")
    }
  }
  let first_witness = @workflow.load_part_effect_witness(
    conflict_repository,
    local_part_workflow_repository_adapters(),
    conflict_intent,
  )
  let audit_session_violated = conflict_result.snapshot.harness_sessions.any(fn(
    session,
  ) {
    session.id == conflict_result.snapshot.identities.audit_session.id &&
    session.lifecycle ==
    @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated
  })
  let audit_take_uncertain = match
    conflict_result.snapshot.audit_take.lifecycle {
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeRecoveryUncertain(
        @control.TakeUncertaintyReason::TakeProtocolViolation
      )
    ) => true
    _ => false
  }
  let first_audit_witness_retained = match first_witness {
    Ok(
      Some(
        {
          observation: @workflow.PartEffectObservation::AuditCompleted(
            { finished_at: 102L, .. },
            _,
            _
          ),
          ..,
        }
      )
    ) => true
    _ => false
  }
  let audit_protocol_conflict_checked = conflict_result.outcome ==
    @workflow.PartWorkflowRunOutcome::PartRunRecoveryUncertain &&
    conflict_result.snapshot.stage ==
    @workflow.PartWorkflowStage::PartRecoveryUncertain &&
    conflict_result.snapshot.audit_receipt is None &&
    audit_session_violated &&
    audit_take_uncertain &&
    first_audit_witness_retained
  clear_conformance_repository(conflict_repository)
  if !audit_protocol_conflict_checked {
    return failed_part_report("audit protocol conflict was not durably fenced")
  }
  {
    passed: true,
    effect_receipt_count: result.snapshot.effect_receipts.length(),
    verification_receipt_count: result.snapshot.verification_receipts.length(),
    audit_receipt_count,
    integration_receipt_count,
    restart_executed_effect_count: restart_executed,
    persistence_boundaries_checked: boundaries.length(),
    audit_result_recovery_checked: audit_result_recovery_checked.val,
    audit_receipt_recovery_checked: audit_receipt_recovery_checked.val,
    audit_protocol_conflict_checked,
    failure: None,
  }
}

///|
fn scale_manifest() -> Array[ScalePartManifestEntry] {
  [
    {
      part_id: @control.PartId("part-a"),
      dependency_ids: [],
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    },
    {
      part_id: @control.PartId("part-b"),
      dependency_ids: [],
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    },
    {
      part_id: @control.PartId("part-c"),
      dependency_ids: [@control.PartId("part-a")],
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    },
    {
      part_id: @control.PartId("part-d"),
      dependency_ids: [@control.PartId("part-b")],
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    },
    {
      part_id: @control.PartId("part-e"),
      dependency_ids: [@control.PartId("part-c"), @control.PartId("part-d")],
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    },
    {
      part_id: @control.PartId("part-f"),
      dependency_ids: [@control.PartId("part-e")],
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    },
  ]
}

///|
fn scale_snapshot_for_part(
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  part_id : @control.PartId,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  for snapshot in snapshots {
    if snapshot.part.id == part_id {
      return Ok(snapshot)
    }
  }
  Err(@types.ChoirError::validation_error("scale Part is absent"))
}

///|
fn load_scale_snapshot(
  repository : @workflow.PartWorkflowRepository,
  part_id : @control.PartId,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      "workflow-" + part_id.0,
    ) {
    Ok(Some(stored)) => Ok(stored.snapshot)
    Ok(None) =>
      Err(@types.ChoirError::validation_error("scale snapshot is absent"))
    Err(error) => Err(error)
  }
}

///|
fn scale_scheduling_record(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.GoalPartSchedulingRecord {
  { part: snapshot.part, task_contract: snapshot.task_contract }
}

///|
fn scale_pending_record(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.GoalPartSchedulingRecord {
  {
    part: { ..snapshot.part, lifecycle: @control.PartLifecycle::PartPending },
    task_contract: snapshot.task_contract,
  }
}

///|
fn scale_initialized_branch(
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
fn scale_sandbox(
  id : String,
  take : @control.Take,
  capability : @control.Digest,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId(id),
    take_id: take.id,
    generation_id: @control.SandboxGenerationId(id + "-generation"),
    capability_profile_digest: capability,
    runtime_policy_digest: conformance_digest_b,
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn scale_session(
  id : String,
  take : @control.Take,
  sandbox : @control.SandboxLease,
  surface : @control.ProviderSurfaceId,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id: take.id,
    sandbox_generation_id: sandbox.generation_id,
    surface,
    effective_surface_manifest_digest: conformance_digest_a,
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn scale_assurance_identities(
  goal : @control.Goal,
  head_oid : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification = conformance_take(
    goal.id,
    "goal-verification-scale",
    @control.TakePurpose::GoalVerification(
      goal.id,
      head_oid,
      goal.contract_digest,
    ),
  )
  let audit = conformance_take(
    goal.id,
    "goal-audit-scale",
    @control.TakePurpose::GoalAudit(goal.id, goal.contract_digest),
  )
  let verification_sandbox = scale_sandbox(
    "goal-verification-sandbox-scale", verification, conformance_digest_b,
  )
  let audit_sandbox = scale_sandbox(
    "goal-audit-sandbox-scale", audit, conformance_digest_a,
  )
  {
    verification_take: verification,
    verification_sandbox,
    verification_session: scale_session(
      "goal-verification-session-scale",
      verification,
      verification_sandbox,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: scale_session(
      "goal-audit-session-scale",
      audit,
      audit_sandbox,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    ),
  }
}

///|
fn apply_scale_assurance_observation(
  record : @workflow.GoalAssuranceRecord,
  observation : @workflow.GoalAssuranceEffectObservation,
  observed_at : Int64,
) -> Result[@workflow.GoalAssuranceRecord, @types.ChoirError] {
  let intent = match @workflow.plan_next_goal_assurance_effect(record) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        @types.ChoirError::validation_error(
          "scale Goal assurance has no planned effect",
        ),
      )
    Err(error) => return Err(error)
  }
  let planned = match
    @workflow.persist_planned_goal_assurance_effect(record, intent) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let authorized = match
    @workflow.authorize_pending_goal_assurance_effect(planned) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  @workflow.apply_goal_assurance_effect_observation(
    authorized,
    observation,
    observed_at,
    fn(_) { true },
  )
}

///|
fn scale_terminal_projection(
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  promotion_order : Array[@control.PartId],
  maximum_parallel_parts : Int,
) -> Result[@workflow.SemanticRunProjection, @types.ChoirError] {
  if snapshots.length() == 0 || promotion_order.length() != snapshots.length() {
    return Err(
      @types.ChoirError::validation_error(
        "scale terminal evidence has inconsistent Part cardinality",
      ),
    )
  }
  let final_snapshot = match
    scale_snapshot_for_part(
      snapshots,
      promotion_order[promotion_order.length() - 1],
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard final_snapshot.integration_receipt is Some(final_integration) else {
    return Err(
      @types.ChoirError::validation_error(
        "scale terminal evidence lacks the final integration receipt",
      ),
    )
  }
  let goal = final_snapshot.goal
  let repository_id = @workflow.RepositoryId("repository-scale-mixed")
  let goal_ref = @workflow.goal_execution_ref(goal.id)
  let base_oid = @control.GitOid("base-conformance")
  let execution : @workflow.GoalExecutionRecord = {
    goal,
    repository_id,
    selection_decision_digest: @storage.artifact_digest(
      @utf8.encode(scale_manifest().to_json().stringify(indent=0)),
    ),
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: base_oid,
    base_tree_oid: @control.GitOid("base-tree-conformance"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref,
    branch_initialization: scale_initialized_branch(
      goal.id,
      repository_id,
      goal_ref,
      base_oid,
    ),
    maximum_parallel_parts,
    policy_revisions: [@workflow.initial_goal_policy_revision(goal.id, 1)],
    part_workflow_ids: snapshots.map(fn(snapshot) { snapshot.workflow_id }),
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 3,
    fencing_epoch: final_snapshot.fencing_epoch,
  }
  let goal_verification_spec : @control.VerificationSpec = {
    id: @control.VerificationSpecId("verify-goal-scale"),
    version: 1,
    digest: @storage.artifact_digest(
      @utf8.encode("choir.scale-goal-verification.v1"),
    ),
    process_spec_digest: conformance_digest_b,
  }
  let planned = match
    @workflow.initialize_goal_assurance(
      execution,
      snapshots,
      final_integration.promotion_commit_oid,
      final_integration.promotion_tree_oid,
      [goal_verification_spec],
      scale_assurance_identities(goal, final_integration.promotion_commit_oid),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let authorized = match
    @workflow.authorize_goal_assurance_seal(
      planned,
      goal,
      final_integration.promotion_commit_oid,
      final_integration.promotion_tree_oid,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witnessed = match
    @workflow.record_goal_assurance_seal_witness(
      authorized,
      @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
        final_integration.promotion_commit_oid,
        final_integration.promotion_commit_oid,
        final_integration.promotion_tree_oid,
      ),
      200L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut assurance = match
    @workflow.commit_goal_assurance_seal(
      witnessed,
      @control.GoalBranchSealId("seal-goal-scale"),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  assurance = match
    apply_scale_assurance_observation(
      assurance,
      @workflow.GoalAssuranceEffectObservation::GoalVerificationSandboxPrepared({
          ..assurance.identities.verification_sandbox,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
        },
      ),
      201L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let verification_session = conformance_started_session(
    assurance.identities.verification_session,
  )
  assurance = match
    apply_scale_assurance_observation(
      assurance,
      @workflow.GoalAssuranceEffectObservation::GoalVerificationHarnessStarted(
        verification_session,
      ),
      202L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard assurance.verification_subject is Some(verification_subject) else {
    return Err(
      @types.ChoirError::validation_error(
        "scale Goal verification subject is absent",
      ),
    )
  }
  let (verification_closed, verification_events) = conformance_trace(
    verification_session, "goal-verification-scale",
  )
  assurance = match
    apply_scale_assurance_observation(
      assurance,
      @workflow.GoalAssuranceEffectObservation::GoalVerificationCompleted(
        {
          take_id: assurance.verification_take.id,
          session_id: verification_session.id,
          subject: verification_subject,
          executions: [
            {
              verification_execution_id: @control.VerificationExecutionId(
                "goal-verification-execution-scale",
              ),
              verification_spec: goal_verification_spec,
              environment_and_image_digest: conformance_digest_a,
              runtime_and_policy_digest: assurance.identities.verification_sandbox.runtime_policy_digest,
              subject_pre_tree_oid: final_integration.promotion_tree_oid,
              subject_post_tree_oid: final_integration.promotion_tree_oid,
              evidence: {
                artifact_id: "goal-verification-evidence-scale",
                digest: conformance_digest_b,
              },
              started_at: 203L,
              finished_at: 204L,
              outcome: @control.VerificationOutcome::VerificationPassed,
            },
          ],
          evidence_manifest: {
            artifact_id: "goal-verification-manifest-scale",
            digest: conformance_digest_a,
          },
        },
        verification_closed,
        verification_events,
      ),
      205L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  assurance = match
    apply_scale_assurance_observation(
      assurance,
      @workflow.GoalAssuranceEffectObservation::GoalAuditSandboxPrepared({
        ..assurance.identities.audit_sandbox,
        lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive,
      }),
      206L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let audit_session = conformance_started_session(
    assurance.identities.audit_session,
  )
  assurance = match
    apply_scale_assurance_observation(
      assurance,
      @workflow.GoalAssuranceEffectObservation::GoalAuditHarnessStarted(
        audit_session,
      ),
      207L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard assurance.audit_subject is Some(audit_subject) else {
    return Err(
      @types.ChoirError::validation_error("scale Goal audit subject is absent"),
    )
  }
  let (audit_closed, audit_events) = conformance_trace(
    audit_session, "goal-audit-scale",
  )
  assurance = match
    apply_scale_assurance_observation(
      assurance,
      @workflow.GoalAssuranceEffectObservation::GoalAuditCompleted(
        {
          audit_take_id: assurance.audit_take.id,
          take_fencing_epoch: assurance.fencing_epoch,
          audit_harness_session_id: audit_session.id,
          subject: audit_subject,
          provider_conformance_report_digest: conformance_digest_a,
          findings_artifact: None,
          total_findings_count: 0,
          blocking_findings_count: 0,
          started_at: 208L,
          finished_at: 209L,
          outcome: @control.AuditOutcome::AuditPassed,
        },
        audit_closed,
        audit_events,
      ),
      210L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  assurance = match
    @workflow.mint_goal_audit_receipt(
      assurance,
      {
        receipt_id: @control.ReceiptId("goal-audit-receipt-scale"),
        provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_identity: "claude-scale-conformance",
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "claude-scale",
        ),
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let assured_execution = {
    ..execution,
    state: @workflow.GoalExecutionState::GoalExecutionAssured,
    durable_version: execution.durable_version + 1,
  }
  let publication = match
    @workflow.initialize_goal_publication(
      assured_execution,
      assurance,
      @workflow.RemoteRepositoryId("remote-scale-mixed"),
      @workflow.RemoteName("origin"),
      @workflow.GitRefName("refs/heads/choir/goals/scale-mixed"),
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let authorized_publication = match
    @workflow.authorize_goal_publication(
      publication,
      assured_execution,
      assurance,
      final_integration.promotion_commit_oid,
      @workflow.RemoteBranchObservation::RemoteBranchAbsent,
      false,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let published = match
    @workflow.record_goal_publication_observation(
      authorized_publication,
      @workflow.RemoteBranchObservation::RemoteBranchAt(
        final_integration.promotion_commit_oid,
      ),
      @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
      None,
      211L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let marker = match
    @workflow.goal_pull_request_identity_marker(
      assured_execution,
      published,
      @workflow.RemoteRepositoryId("remote-scale-mixed"),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let pull_request = match
    @workflow.initialize_goal_pull_request(
      assured_execution,
      assurance,
      published,
      @workflow.PullRequestProvider::GitHubPullRequestProvider,
      @workflow.RemoteRepositoryId("remote-scale-mixed"),
      {
        title: "feat: complete scale Goal",
        body: "Scale evidence\n\n" + marker.0,
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let remote_pull_request : @workflow.RemotePullRequestSnapshot = {
    remote_id: @workflow.RemotePullRequestId("PR_scale_mixed"),
    number: @workflow.PullRequestNumber(42),
    url: @workflow.PullRequestUrl("https://example.invalid/choir/pull/42"),
    provider_repository_id: published.intent.canonical_repository_id,
    head_repository_id: published.intent.canonical_repository_id,
    head_ref: published.intent.remote_head_ref,
    base_repository_id: @workflow.RemoteRepositoryId("remote-scale-mixed"),
    base_ref: assured_execution.integration_target_ref,
    observed_head_oid: final_integration.promotion_commit_oid,
    state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
    marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
    title_digest: @storage.artifact_digest(@utf8.encode("scale-title")),
    body_digest: @storage.artifact_digest(@utf8.encode("scale-body")),
    goal_contract_link_present: true,
    evidence_manifest_link_present: true,
  }
  let adopted = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assurance,
      published,
      final_integration.promotion_commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        remote_pull_request,
      ),
      212L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let finalization = match
    @workflow.observe_goal_pull_request_readiness(
      assured_execution,
      assurance,
      published,
      adopted,
      @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
        remote_pull_request,
      ),
      Some("remote-version-scale"),
      1L,
      213L,
      214L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let succeeded = match
    @workflow.authorize_goal_execution_success(
      assured_execution, assurance, published, adopted, finalization,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    @workflow.semantic_run_projection(
      succeeded,
      snapshots,
      Some(assurance),
      Some(published),
      Some(adopted),
      Some(finalization),
    ) {
    Ok(Some(value)) => Ok(value)
    Ok(None) =>
      Err(
        @types.ChoirError::validation_error(
          "scale Goal semantic projection is absent",
        ),
      )
    Err(error) => Err(error)
  }
}

///|
async fn run_scale_once(
  root : String,
  maximum_parallel_parts : Int,
) -> Result[ScaleRunResult, @types.ChoirError] {
  let repository = conformance_repository(
    root + "/concurrency-" + maximum_parallel_parts.to_string(),
  )
  clear_conformance_repository(repository)
  let goal_id = @control.GoalId("goal-scale-mixed")
  let snapshots : Array[@workflow.PartWorkflowSnapshot] = []
  for entry in scale_manifest() {
    let snapshot = match
      conformance_snapshot_for(
        entry.part_id.0,
        goal_id,
        entry.part_id,
        entry.dependency_ids,
        entry.surface,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    snapshots.push(snapshot)
  }
  let initial_records = snapshots.map(scale_pending_record)
  let initial_schedule = match
    @workflow.schedule_goal_parts(initial_records, maximum_parallel_parts) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let head = @ref.new(@control.GitOid("base-conformance"))
  let execute_count = @ref.new(0)
  let run = @workflow.run_goal_parts(initial_records, maximum_parallel_parts, {
    advance_part: async fn(record) {
      let initial = match scale_snapshot_for_part(snapshots, record.part.id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let observed = @workflow.run_new_part_workflow(
        repository,
        local_part_workflow_repository_adapters(),
        initial,
        conformance_dependencies(
          repository,
          execute_count,
          fn(_) { None },
          integration_head=None,
        ),
      )
      let observed = match observed {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if observed.outcome !=
        @workflow.PartWorkflowRunOutcome::PartRunAwaitingPromotion {
        return Err(
          @types.ChoirError::validation_error(
            "scale Part did not stop at promotion admission",
          ),
        )
      }
      Ok(scale_scheduling_record(observed.snapshot))
    },
    read_goal_head: async fn() { Ok(head.val) },
    promote_part: async fn(record, selection) {
      let stored = match load_scale_snapshot(repository, record.part.id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let promoted = match
        @workflow.resume_part_workflow(
          repository,
          local_part_workflow_repository_adapters(),
          stored.workflow_id,
          conformance_dependencies(
            repository,
            execute_count,
            fn(_) { None },
            integration_head=Some(selection.expected_goal_head_oid),
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if promoted.outcome != @workflow.PartWorkflowRunOutcome::PartRunIntegrated {
        return Err(
          @types.ChoirError::validation_error(
            "scale Part promotion did not integrate",
          ),
        )
      }
      guard promoted.snapshot.integration_receipt is Some(receipt) else {
        return Err(
          @types.ChoirError::validation_error(
            "scale Part promotion lacks a receipt",
          ),
        )
      }
      head.val = receipt.promotion_commit_oid
      Ok(scale_scheduling_record(promoted.snapshot))
    },
    resume_promotion: async fn(record) {
      let stored = match load_scale_snapshot(repository, record.part.id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let resumed = match
        @workflow.resume_part_workflow(
          repository,
          local_part_workflow_repository_adapters(),
          stored.workflow_id,
          conformance_dependencies(
            repository,
            execute_count,
            fn(_) { None },
            integration_head=Some(head.val),
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(scale_scheduling_record(resumed.snapshot))
    },
  })
  let result = match run {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.outcome != @workflow.GoalRunOutcome::GoalRunSucceeded {
    return Err(
      @types.ChoirError::validation_error("scale Goal did not succeed"),
    )
  }
  let final_snapshots : Array[@workflow.PartWorkflowSnapshot] = []
  for entry in scale_manifest() {
    let stored = match load_scale_snapshot(repository, entry.part_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    final_snapshots.push(stored)
  }
  let projection = match
    scale_terminal_projection(
      final_snapshots,
      result.promotion_order,
      maximum_parallel_parts,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  clear_conformance_repository(repository)
  Ok({
    snapshots: final_snapshots,
    observed_parallelism: initial_schedule.admitted_part_ids.length(),
    promotion_order: result.promotion_order,
    projection,
  })
}

///|
fn failed_scale_report(
  manifest_digest : @control.Digest,
  message : String,
) -> ScaleConformanceReport {
  {
    passed: false,
    manifest_digest,
    part_count: scale_manifest().length(),
    concurrency_limits: [1, 2, 4],
    observed_parallelism: [],
    promotion_order: [],
    semantic_projection_digest: None,
    part_verification_receipt_count: 0,
    part_audit_receipt_count: 0,
    integration_receipt_count: 0,
    goal_verification_receipt_count: 0,
    goal_audit_receipt_count: 0,
    publication_receipt_count: 0,
    pull_request_receipt_count: 0,
    failure: Some(message),
  }
}

///|
pub async fn run_scale_mixed_conformance_fixture(
  root : String,
) -> ScaleConformanceReport {
  let manifest = scale_manifest()
  let manifest_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.scale-mixed-manifest.v1\u{00}" +
      manifest.to_json().stringify(indent=0),
    ),
  )
  if !@sys.create_dir_all(root) {
    return failed_scale_report(
      manifest_digest, "failed to create the scale conformance root",
    )
  }
  let limits = [1, 2, 4]
  let runs : Array[ScaleRunResult] = []
  for limit in limits {
    match run_scale_once(root, limit) {
      Ok(value) => runs.push(value)
      Err(error) => return failed_scale_report(manifest_digest, error.message())
    }
  }
  let baseline = runs[0]
  if runs.any(fn(run) {
      run.projection != baseline.projection ||
      run.promotion_order != baseline.promotion_order
    }) {
    return failed_scale_report(
      manifest_digest, "semantic projection changed with concurrency",
    )
  }
  if runs[0].observed_parallelism != 1 ||
    runs[1].observed_parallelism < 2 ||
    runs[2].observed_parallelism < 2 {
    return failed_scale_report(
      manifest_digest,
      "scale fixture did not exercise parallel scheduling: " +
      runs
      .map(fn(run) { run.observed_parallelism })
      .to_json()
      .stringify(indent=0),
    )
  }
  let mut part_verification_receipt_count = 0
  let mut part_audit_receipt_count = 0
  let mut integration_receipt_count = 0
  for snapshot in baseline.snapshots {
    part_verification_receipt_count = part_verification_receipt_count +
      snapshot.verification_receipts.length()
    if snapshot.audit_receipt is Some(_) {
      part_audit_receipt_count = part_audit_receipt_count + 1
    }
    if snapshot.integration_receipt is Some(_) {
      integration_receipt_count = integration_receipt_count + 1
    }
  }
  if part_verification_receipt_count != manifest.length() ||
    part_audit_receipt_count != manifest.length() ||
    integration_receipt_count != manifest.length() ||
    baseline.projection.receipt_cardinalities.goal_verification != 1 ||
    baseline.projection.receipt_cardinalities.goal_audit != 1 ||
    baseline.projection.receipt_cardinalities.publication != 1 ||
    baseline.projection.receipt_cardinalities.pull_request != 1 {
    return failed_scale_report(
      manifest_digest, "scale fixture receipt cardinality is inconsistent",
    )
  }
  let projection_digest = @storage.artifact_digest(
    @utf8.encode(baseline.projection.to_json().stringify(indent=0)),
  )
  {
    passed: true,
    manifest_digest,
    part_count: manifest.length(),
    concurrency_limits: limits,
    observed_parallelism: runs.map(fn(run) { run.observed_parallelism }),
    promotion_order: baseline.promotion_order,
    semantic_projection_digest: Some(projection_digest),
    part_verification_receipt_count,
    part_audit_receipt_count,
    integration_receipt_count,
    goal_verification_receipt_count: baseline
    .projection
    .receipt_cardinalities
    .goal_verification,
    goal_audit_receipt_count: baseline
    .projection
    .receipt_cardinalities
    .goal_audit,
    publication_receipt_count: baseline
    .projection
    .receipt_cardinalities
    .publication,
    pull_request_receipt_count: baseline
    .projection
    .receipt_cardinalities
    .pull_request,
    failure: None,
  }
}
