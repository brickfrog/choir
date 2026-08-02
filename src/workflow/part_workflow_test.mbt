///|
let workflow_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let workflow_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
let workflow_digest_c : @control.Digest = @control.Digest(
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
)

///|
let workflow_digest_d : @control.Digest = @control.Digest(
  "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
)

///|
let workflow_digest_e : @control.Digest = @control.Digest(
  "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
)

///|
fn workflow_take(id : String, purpose : @control.TakePurpose) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id: @control.GoalId("goal-1"),
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn workflow_sandbox(
  id : String,
  generation : String,
  take_id : @control.TakeId,
  capability : @control.Digest,
  runtime : @control.Digest,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId(id),
    take_id,
    generation_id: @control.SandboxGenerationId(generation),
    capability_profile_digest: capability,
    runtime_policy_digest: runtime,
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn workflow_session(
  id : String,
  take_id : @control.TakeId,
  generation : @control.SandboxGenerationId,
  surface : @control.ProviderSurfaceId,
  manifest : @control.Digest,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id,
    sandbox_generation_id: generation,
    surface,
    effective_surface_manifest_digest: manifest,
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
    usage: None,
  }
}

///|
fn workflow_goal_assurance_identities(
  goal : @control.Goal,
  head_oid : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification = workflow_take(
    "goal-verification-take-1",
    @control.TakePurpose::GoalVerification(
      goal.id,
      head_oid,
      goal.contract_digest,
    ),
  )
  let audit = workflow_take(
    "goal-audit-take-1",
    @control.TakePurpose::GoalAudit(goal.id, goal.contract_digest),
  )
  let verification_sandbox = workflow_sandbox(
    "goal-verification-sandbox-1",
    "goal-verification-generation-1",
    verification.id,
    workflow_digest_b,
    workflow_digest_c,
  )
  let audit_sandbox = workflow_sandbox(
    "goal-audit-sandbox-1",
    "goal-audit-generation-1",
    audit.id,
    workflow_digest_c,
    workflow_digest_c,
  )
  {
    verification_take: verification,
    verification_sandbox,
    audit_take: audit,
    audit_sandbox,
    audit_session: workflow_session(
      "goal-audit-session-1",
      audit.id,
      audit_sandbox.generation_id,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
      workflow_digest_e,
    ),
  }
}

///|
fn workflow_fixture() -> @workflow.PartWorkflowSnapshot raise {
  let goal : @control.Goal = {
    id: @control.GoalId("goal-1"),
    contract_digest: workflow_digest_a,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let part : @control.GoalPart = {
    id: @control.PartId("part-1"),
    goal_id: goal.id,
    dependency_ids: [],
    task_contract_revision_id: @control.RevisionId("revision-1"),
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let spec : @control.VerificationSpec = {
    id: @control.VerificationSpecId("moon-test"),
    version: 1,
    digest: workflow_digest_b,
    process_spec_digest: workflow_digest_c,
  }
  let contract : @control.TaskContractRevision = {
    id: part.task_contract_revision_id,
    goal_id: goal.id,
    part_id: part.id,
    revision: 1,
    digest: workflow_digest_a,
    commit_title: @control.SemanticCommitTitle("test: exercise Part workflow"),
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: None,
    instruction_artifact: {
      artifact_id: "instruction-workflow",
      digest: workflow_digest_a,
    },
    base_commit_oid: @control.GitOid("base-commit"),
    base_tree_oid: @control.GitOid("base-tree"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/feature.mbt")),
      ],
    ),
    verification_specs: [spec],
    audit_policy_digest: workflow_digest_b,
    migration_contract_ref: None,
    migration_continuation_ref_digest: None,
    implementation_capability_profile_digest: workflow_digest_a,
    verification_capability_profile_digest: workflow_digest_b,
    audit_capability_profile_digest: workflow_digest_c,
  }
  let implementation = workflow_take(
    "implementation-take-1",
    @control.TakePurpose::Implementation(part.id, contract.id),
  )
  let verification = workflow_take(
    "verification-take-1",
    @control.TakePurpose::PartVerification(
      part.id,
      implementation.id,
      workflow_digest_a,
    ),
  )
  let audit = workflow_take(
    "audit-take-1",
    @control.TakePurpose::PartAudit(
      part.id,
      implementation.id,
      workflow_digest_a,
    ),
  )
  let implementation_sandbox = workflow_sandbox(
    "implementation-sandbox-1",
    "implementation-generation-1",
    implementation.id,
    contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "verification-sandbox-1",
    "verification-generation-1",
    verification.id,
    contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "audit-sandbox-1",
    "audit-generation-1",
    audit.id,
    contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let identities : @workflow.PartIdentityPlan = {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: workflow_session(
      "implementation-session-1",
      implementation.id,
      implementation_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_a,
    ),
    verification_take: verification,
    verification_sandbox,
    audit_take: audit,
    audit_sandbox,
    audit_session: workflow_session(
      "audit-session-1",
      audit.id,
      audit_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_c,
    ),
  }
  match
    @workflow.initialize_part_workflow(
      "workflow-1",
      goal,
      part,
      contract,
      identities,
      @control.FencingEpoch(7L),
      fn(_) { true },
      admitted_provider_surfaces=[
        @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      ],
    ) {
    Ok(snapshot) => snapshot
    Err(error) => fail(error.message())
  }
}

///|
fn workflow_revision_identities(
  snapshot : @workflow.PartWorkflowSnapshot,
  contract : @control.TaskContractRevision,
) -> @workflow.PartIdentityPlan {
  let implementation = {
    ..workflow_take(
      "implementation-take-revision",
      @control.TakePurpose::Implementation(snapshot.part.id, contract.id),
    ),
    ordinal: snapshot.implementation_take.ordinal + 1,
  }
  let verification = {
    ..workflow_take(
      "verification-take-revision",
      @control.TakePurpose::PartVerification(
        snapshot.part.id,
        implementation.id,
        contract.digest,
      ),
    ),
    ordinal: snapshot.verification_take.ordinal + 1,
  }
  let audit = {
    ..workflow_take(
      "audit-take-revision",
      @control.TakePurpose::PartAudit(
        snapshot.part.id,
        implementation.id,
        contract.digest,
      ),
    ),
    ordinal: snapshot.audit_take.ordinal + 1,
  }
  let implementation_sandbox = workflow_sandbox(
    "implementation-sandbox-revision",
    "implementation-generation-revision",
    implementation.id,
    contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "verification-sandbox-revision",
    "verification-generation-revision",
    verification.id,
    contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "audit-sandbox-revision",
    "audit-generation-revision",
    audit.id,
    contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: workflow_session(
      "implementation-session-revision",
      implementation.id,
      implementation_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_a,
    ),
    verification_take: verification,
    verification_sandbox,
    audit_take: audit,
    audit_sandbox,
    audit_session: workflow_session(
      "audit-session-revision",
      audit.id,
      audit_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_c,
    ),
  }
}

///|
test "in-place migration revision invalidates only an impacted Part" {
  let base = workflow_fixture()
  let previous_ref : @control.MigrationContractRef = {
    contract_id: @control.MigrationContractId("revision-contract"),
    migration_lineage_id: @control.MigrationLineageId("revision-lineage"),
    revision: 1,
    contract_artifact_digest: workflow_digest_a,
  }
  let next_ref = {
    ..previous_ref,
    revision: 2,
    contract_artifact_digest: workflow_digest_b,
  }
  let previous_contract = {
    ..base.task_contract,
    migration_contract_ref: Some(previous_ref),
  }
  let migration_snapshot = {
    ..base,
    task_contract: previous_contract,
    task_contract_history: [previous_contract],
    part_context_manifest: Some({
      migration_contract_ref: previous_ref,
      part_task_contract_revision_id: previous_contract.id,
      part_task_contract_digest: previous_contract.digest,
      context_assembly_policy_digest: workflow_digest_a,
      rulebook_section_digests: [workflow_digest_b],
      dependency_neighborhood_digest: workflow_digest_c,
      applicable_gap_entry_digests: [],
      source_path_manifest_digest: workflow_digest_d,
      prior_take_context_digest: None,
    }),
  }
  let impact_set : @migration.MigrationContractRevisionImpactSet = {
    previous_contract_ref: previous_ref,
    next_contract_ref: next_ref,
    changes: [
      {
        kind: @migration.MigrationChangedArtifactKind::ChangedRulebook,
        previous_digest: workflow_digest_b,
        next_digest: workflow_digest_c,
      },
    ],
    impacted_parts: [
      {
        part_id: base.part.id,
        reasons: [
          @migration.MigrationImpactReason::MigrationDirectArtifactImpact(
            @migration.MigrationChangedArtifactKind::ChangedRulebook,
          ),
        ],
        was_integrated: false,
      },
    ],
    carried_forward_task_contract_revision_ids: [],
    application: @migration.MigrationContractRevisionApplication::MigrationRevisionAppliesInPlace,
  }
  let revised_contract = {
    ..previous_contract,
    id: @control.RevisionId("revision-2"),
    revision: 2,
    digest: workflow_digest_e,
    migration_contract_ref: Some(next_ref),
  }
  let revised = @workflow.plan_part_migration_revision(
    migration_snapshot,
    impact_set,
    revised_contract,
    workflow_revision_identities(migration_snapshot, revised_contract),
    fn(_) { true },
  ).unwrap()
  assert_eq(revised.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(revised.task_contract, revised_contract)
  assert_eq(revised.task_contract_history.length(), 2)
  assert_eq(revised.prior_take_evidence.length(), 1)
  assert_eq(revised.verification_receipts, [])
  assert_eq(revised.audit_receipt, None)
  assert_eq(revised.integration_receipt, None)
  assert_true(
    @workflow.plan_part_migration_revision(
      migration_snapshot,
      { ..impact_set, impacted_parts: [] },
      revised_contract,
      workflow_revision_identities(migration_snapshot, revised_contract),
      fn(_) { true },
    )
    is Err(_),
  )
  assert_true(
    @workflow.plan_part_migration_revision(
      {
        ..migration_snapshot,
        stage: @workflow.PartWorkflowStage::PartIntegrated,
      },
      impact_set,
      revised_contract,
      workflow_revision_identities(migration_snapshot, revised_contract),
      fn(_) { true },
    )
    is Err(_),
  )
}

///|
fn active_sandbox(lease : @control.SandboxLease) -> @control.SandboxLease {
  { ..lease, lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseActive }
}

///|
fn started_session(
  session : @control.HarnessSession,
) -> @control.HarnessSession {
  {
    ..session,
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
  }
}

///|
fn successful_trace(
  session : @control.HarnessSession,
  prefix : String,
  first_observed_at : Int64,
) -> (@control.HarnessSession, Array[@control.HarnessEventEnvelope]) {
  let started : @control.HarnessEventEnvelope = {
    id: @control.HarnessEventId(prefix + "-started"),
    take_id: session.take_id,
    session_id: session.id,
    source_position: @control.EventSourcePosition::EventNonResumableOrdinal(
      prefix, 1,
    ),
    choir_sequence: @control.EventSequence(1L),
    observed_at: first_observed_at,
    kind: @control.HarnessEventKind::HarnessStarted,
    sanitized_payload_digest: workflow_digest_a,
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
    observed_at: first_observed_at + 1L,
    kind: @control.HarnessEventKind::HarnessTerminal(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
    sanitized_payload_digest: workflow_digest_b,
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
fn authorize_next(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.PartWorkflowSnapshot raise {
  let intent = match @workflow.plan_next_part_effect(snapshot) {
    Ok(Some(value)) => value
    Ok(None) => fail("expected another workflow effect")
    Err(error) => fail(error.message())
  }
  let planned = match @workflow.persist_planned_part_effect(snapshot, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  match @workflow.authorize_pending_part_effect(planned, fn(_) { true }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn apply_observation(
  snapshot : @workflow.PartWorkflowSnapshot,
  observation : @workflow.PartEffectObservation,
  observed_at : Int64,
) -> @workflow.PartWorkflowSnapshot raise {
  let authorized = authorize_next(snapshot)
  match
    @workflow.apply_part_effect_observation(
      authorized,
      observation,
      observed_at,
      fn(_) { true },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn prepared_command_fixture(
  plan : @workflow.PartCommandPreparationPlan,
) -> @workflow.PartPreparedCommand {
  let context_manifest_digest = match plan.context_manifest {
    None => None
    Some(manifest) => Some(@migration.part_context_manifest_digest(manifest))
  }
  let command_artifact : @control.ArtifactReference = {
    artifact_id: "prepared-command-" + plan.take.id.0,
    digest: plan.template_digest,
  }
  {
    plan,
    command_artifact,
    provenance: {
      schema_version: 1,
      take_id: plan.take.id,
      take_purpose_digest: @command.take_purpose_digest(plan.take.purpose),
      subject_digest: @command.command_subject_digest(plan.subject),
      goal_contract_digest: plan.goal_contract_digest,
      task_contract_revision_id: plan.task_contract_revision_id,
      task_contract_digest: plan.task_contract_digest,
      migration_contract_ref: plan.migration_contract_ref,
      template_digest: plan.template_digest,
      provider_surface: plan.provider_surface,
      provider_surface_and_profile_digest: plan.provider_surface_and_profile_digest,
      context_assembly_policy_digest: plan.context_assembly_policy_digest,
      context_manifest_digest,
      context_projection_digest: plan.template_digest,
      maximum_command_bytes: plan.maximum_command_bytes,
      command_artifact_digest: command_artifact.digest,
      command_byte_length: 1,
    },
  }
}

///|
fn apply_command_preparation(
  snapshot : @workflow.PartWorkflowSnapshot,
  observed_at : Int64,
) -> @workflow.PartWorkflowSnapshot raise {
  let observation = match @workflow.plan_next_part_effect(snapshot) {
    Ok(
      Some(
        {
          kind: @workflow.PartEffectKind::PrepareImplementationCommand(plan),
          ..,
        }
      )
    ) =>
      @workflow.PartEffectObservation::ImplementationCommandPrepared(
        prepared_command_fixture(plan),
      )
    Ok(Some({ kind: @workflow.PartEffectKind::PrepareAuditCommand(plan), .. })) =>
      @workflow.PartEffectObservation::AuditCommandPrepared(
        prepared_command_fixture(plan),
      )
    Ok(_) => fail("expected command preparation effect")
    Err(error) => fail(error.message())
  }
  apply_observation(snapshot, observation, observed_at)
}

///|
test "command authorization is passive and requires persisted exact bytes" {
  let initial = workflow_fixture()
  let sandbox_prepared = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(
      active_sandbox(initial.identities.implementation_sandbox),
    ),
    10L,
  )
  let command_prepared = apply_command_preparation(sandbox_prepared, 11L)
  let start = @workflow.plan_next_part_effect(command_prepared)
    .unwrap()
    .unwrap()
  let planned_start = @workflow.persist_planned_part_effect(
    command_prepared, start,
  ).unwrap()
  let checks = @ref.new(0)
  let blocked_start = @workflow.authorize_pending_part_effect(planned_start, fn(
    _,
  ) {
    checks.val = checks.val + 1
    false
  })
  assert_true(
    blocked_start is Err(error) && error.is_command_preparation_blocked(),
  )
  assert_eq(checks.val, 1)
  assert_eq(
    planned_start.pending_effect.unwrap().lifecycle,
    @workflow.PartEffectLifecycle::PartEffectPlanned,
  )
  let running = apply_observation(
    command_prepared,
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      started_session(initial.identities.implementation_session),
    ),
    12L,
  )
  let dispatch = @workflow.plan_next_part_effect(running).unwrap().unwrap()
  let planned_dispatch = @workflow.persist_planned_part_effect(
    running, dispatch,
  ).unwrap()
  assert_true(
    @workflow.authorize_pending_part_effect(planned_dispatch, fn(_) { false })
    is Err(error) &&
    error.is_command_preparation_blocked(),
  )
  let stale = {
    ..planned_dispatch,
    task_contract: {
      ..planned_dispatch.task_contract,
      digest: workflow_digest_e,
    },
  }
  assert_true(
    @workflow.authorize_pending_part_effect(stale, fn(_) { true }) is Err(error) &&
    error.is_command_preparation_blocked(),
  )
}

///|
fn authorize_next_goal_assurance(
  record : @workflow.GoalAssuranceRecord,
) -> @workflow.GoalAssuranceRecord raise {
  let intent = match @workflow.plan_next_goal_assurance_effect(record) {
    Ok(Some(value)) => value
    Ok(None) => fail("expected another Goal assurance effect")
    Err(error) => fail(error.message())
  }
  let planned = match
    @workflow.persist_planned_goal_assurance_effect(record, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  match @workflow.authorize_pending_goal_assurance_effect(planned) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn apply_goal_assurance_observation(
  record : @workflow.GoalAssuranceRecord,
  observation : @workflow.GoalAssuranceEffectObservation,
  observed_at : Int64,
) -> @workflow.GoalAssuranceRecord raise {
  match
    @workflow.apply_goal_assurance_effect_observation(
      authorize_next_goal_assurance(record),
      observation,
      observed_at,
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn round_trip(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.PartWorkflowSnapshot raise {
  let encoded = @workflow.part_snapshot_bytes(snapshot)
  let decoded = match @workflow.decode_part_snapshot(encoded) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(decoded, snapshot)
  assert_eq(
    @workflow.part_snapshot_digest(decoded),
    @workflow.part_snapshot_digest(snapshot),
  )
  decoded
}

///|
fn workflow_initialized_branch(
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
fn workflow_execution_for_attach(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.GoalExecutionRecord {
  let repository_id = @workflow.RepositoryId("repository-attach")
  let goal_ref = @workflow.goal_execution_ref(snapshot.goal.id)
  let base_oid = @control.GitOid("base-commit")
  {
    goal: snapshot.goal,
    repository_id,
    selection_decision_digest: workflow_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: base_oid,
    base_tree_oid: @control.GitOid("base-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise Part workflow",
      body: "Exercises the Part workflow.",
      draft: false,
    }),
    migration_production_admission: None,
    goal_ref,
    branch_initialization: workflow_initialized_branch(
      snapshot.goal.id,
      repository_id,
      goal_ref,
      base_oid,
    ),
    source_claims: [
      receipted_goal_source_claim(
        snapshot.goal.id,
        snapshot.part.id,
        workflow_digest_a,
        workflow_digest_a,
        1L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(snapshot.goal.id, 1),
    ],
    part_workflow_ids: [snapshot.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    work_order_id: None,
    durable_version: 2,
    fencing_epoch: snapshot.fencing_epoch,
  }
}

///|
test "Goal attach projects one Take's durable events without changing state" {
  let initial = workflow_fixture()
  let (closed, trace) = successful_trace(
    started_session(initial.identities.implementation_session),
    "attach",
    10L,
  )
  let reversed = [trace[1], trace[0]]
  let snapshot = {
    ..initial,
    harness_sessions: [closed],
    harness_events: reversed,
  }
  let execution = workflow_execution_for_attach(snapshot)
  let report = @workflow.goal_attach_report(
      execution,
      [snapshot],
      None,
      initial.implementation_take.id,
    )
    .unwrap()
    .unwrap()
  assert_eq(report.goal_id, initial.goal.id)
  assert_eq(report.take, initial.implementation_take)
  assert_eq(
    report.origin,
    @workflow.GoalTakeOrigin::GoalTakeFromPart(initial.part.id),
  )
  assert_eq(report.sessions.length(), 1)
  assert_eq(report.sessions[0].session, closed)
  assert_eq(report.sessions[0].events, trace)
  assert_eq(execution, workflow_execution_for_attach(snapshot))
}

///|
test "Goal attach rejects a cursor that outruns the durable event journal" {
  let initial = workflow_fixture()
  let (closed, trace) = successful_trace(
    started_session(initial.identities.implementation_session),
    "attach-gap",
    10L,
  )
  let snapshot = {
    ..initial,
    harness_sessions: [closed],
    harness_events: [trace[0]],
  }
  assert_true(
    @workflow.goal_attach_report(
      workflow_execution_for_attach(snapshot),
      [snapshot],
      None,
      initial.implementation_take.id,
    )
    is Err(_),
  )
}

///|
test "Goal cancellation records a clean Part that never ran" {
  let initial = workflow_fixture()
  let canceled = match @workflow.record_part_goal_cancellation(initial) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(canceled.stage, @workflow.PartWorkflowStage::PartCanceled)
  assert_eq(canceled.part.lifecycle, @control.PartLifecycle::PartCanceledNotRun)
  assert_eq(
    canceled.implementation_take.lifecycle,
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeCanceled,
    ),
  )
  assert_true(@workflow.part_cancellation_disposition_is_known(canceled))
  assert_eq(
    @workflow.record_part_goal_cancellation(canceled).unwrap(),
    canceled,
  )
}

///|
test "Goal cancellation records an authorized provider effect as uncertain" {
  let initial = workflow_fixture()
  let sandbox = active_sandbox(initial.identities.implementation_sandbox)
  let prepared = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(sandbox),
    10L,
  )
  let session = started_session(initial.identities.implementation_session)
  let command_prepared = apply_command_preparation(prepared, 11L)
  let started = apply_observation(
    command_prepared,
    @workflow.PartEffectObservation::ImplementationHarnessStarted(session),
    11L,
  )
  let authorized = authorize_next(started)
  let canceled = match @workflow.record_part_goal_cancellation(authorized) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(canceled.stage, @workflow.PartWorkflowStage::PartBlocked)
  assert_eq(
    canceled.part.lifecycle,
    @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain,
    ),
  )
  assert_eq(
    canceled.implementation_take.lifecycle,
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeInterrupted,
    ),
  )
  assert_true(
    canceled.pending_effect
    is Some(
      { lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain, .. }
    ),
  )
  assert_true(
    canceled.sandbox_leases.all(fn(lease) {
      lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeaseUncertain
    }),
  )
  assert_true(
    canceled.harness_sessions.all(fn(observed) {
      observed.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain
    }),
  )
  assert_true(@workflow.part_cancellation_disposition_is_known(canceled))
}

///|
test "provider protocol violation terminally fences its Take and Part" {
  let initial = workflow_fixture()
  let implementation_session = started_session(
    initial.identities.implementation_session,
  )
  let prepared = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(
      active_sandbox(initial.identities.implementation_sandbox),
    ),
    10L,
  )
  let running = apply_observation(
    apply_command_preparation(prepared, 11L),
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      implementation_session,
    ),
    11L,
  )
  let authorized = authorize_next(running)
  let intent = match authorized.pending_effect {
    Some(value) => value
    None => fail("implementation dispatch was not authorized")
  }
  let violated = @workflow.record_part_provider_protocol_violation(
    authorized,
    intent,
    "codex driver: provider lifecycle is incomplete",
    observed_at=12L,
  ).unwrap()
  assert_eq(violated.stage, @workflow.PartWorkflowStage::PartRecoveryUncertain)
  assert_eq(
    violated.part.lifecycle,
    @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain,
    ),
  )
  assert_eq(
    violated.implementation_take.lifecycle,
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeRecoveryUncertain(
        @control.TakeUncertaintyReason::TakeProtocolViolation,
      ),
    ),
  )
  assert_true(
    violated.harness_sessions.any(fn(session) {
      session.id == implementation_session.id &&
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated
    }),
  )
  assert_true(
    violated.pending_effect
    is Some(
      { lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain, .. }
    ),
  )
  assert_eq(
    violated.dispatch_diagnostic,
    Some({
      take_id: violated.implementation_take.id,
      session_id: Some(implementation_session.id),
      reason: Some(@control.TakeUncertaintyReason::TakeProtocolViolation),
      recovery: None,
      detail: "codex driver: provider lifecycle is incomplete",
      availability: @control.ProviderAvailability::ProviderUnavailable,
      observed_at: 12L,
    }),
  )
}

///|
test "a recovery verdict never overwrites the failure that was observed" {
  let initial = workflow_fixture()
  let implementation_session = started_session(
    initial.identities.implementation_session,
  )
  let running = apply_observation(
    apply_command_preparation(
      apply_observation(
        initial,
        @workflow.PartEffectObservation::ImplementationSandboxPrepared(
          active_sandbox(initial.identities.implementation_sandbox),
        ),
        10L,
      ),
      11L,
    ),
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      implementation_session,
    ),
    11L,
  )
  let authorized = authorize_next(running)
  let intent = match authorized.pending_effect {
    Some(value) => value
    None => fail("implementation dispatch was not authorized")
  }
  // The tick that actually ran the Take is the only one that sees why it died.
  let observed = @workflow.record_part_dispatch_failure(
    authorized,
    intent,
    "transport error: BoxLite Take runtime: result archive failed",
    observed_at=12L,
  ).unwrap()
  assert_eq(
    observed.dispatch_diagnostic,
    Some({
      take_id: observed.implementation_take.id,
      session_id: Some(implementation_session.id),
      reason: None,
      recovery: None,
      detail: "transport error: BoxLite Take runtime: result archive failed",
      availability: @control.ProviderAvailability::ProviderUnavailable,
      observed_at: 12L,
    }),
  )
  assert_eq(observed.stage, authorized.stage)
  // A later tick can only report that recovery is impossible. That verdict is
  // recorded beside the cause, never in place of it.
  let lost = @workflow.record_part_provider_process_loss(
    observed,
    intent,
    "nonresumable Claude Take lost its owning Goal worker",
    observed_at=40L,
  ).unwrap()
  assert_eq(
    lost.dispatch_diagnostic,
    Some({
      take_id: lost.implementation_take.id,
      session_id: Some(implementation_session.id),
      reason: Some(@control.TakeUncertaintyReason::TakeEffectUncertain),
      recovery: Some("nonresumable Claude Take lost its owning Goal worker"),
      detail: "transport error: BoxLite Take runtime: result archive failed",
      availability: @control.ProviderAvailability::ProviderUnavailable,
      // The cause survives the later verdict, but its date does not: the
      // availability recorded here is the one that will be aged out, so it is
      // dated when it was read rather than when the Take first failed.
      observed_at: 40L,
    }),
  )
  assert_eq(lost.stage, @workflow.PartWorkflowStage::PartRecoveryUncertain)
}

///|
fn drive_to_verified() -> @workflow.PartWorkflowSnapshot raise {
  let initial = workflow_fixture()
  let implementation_session = started_session(
    initial.identities.implementation_session,
  )
  let mut snapshot = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(
      active_sandbox(initial.identities.implementation_sandbox),
    ),
    10L,
  )
  snapshot = apply_observation(
    apply_command_preparation(snapshot, 11L),
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      implementation_session,
    ),
    11L,
  )
  let (implementation_final, implementation_events) = successful_trace(
    implementation_session, "implementation", 12L,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::ImplementationCompleted(
      {
        take_id: snapshot.implementation_take.id,
        session_id: implementation_session.id,
        result_artifact: {
          artifact_id: "implementation-result-1",
          digest: workflow_digest_c,
        },
        finished_at: 13L,
      },
      implementation_final,
      implementation_events,
    ),
    14L,
  )
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId("candidate-1"),
    goal_id: snapshot.goal.id,
    part_id: snapshot.part.id,
    take_id: snapshot.implementation_take.id,
    base_commit_oid: snapshot.task_contract.base_commit_oid,
    commit_oid: @control.GitOid("candidate-commit"),
    tree_oid: @control.GitOid("candidate-tree"),
    canonical_change_digest: workflow_digest_d,
    changed_paths: [@control.RepoPath("src/feature.mbt")],
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::CandidateNormalized(candidate, {
      candidate_tree_paths: [@control.RepoPath("src/feature.mbt")],
      symlink_prefix_paths: [],
      normalization_collision_paths: [],
    }),
    15L,
  )
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::VerificationSandboxPrepared(
      active_sandbox(snapshot.identities.verification_sandbox),
    ),
    16L,
  )
  let verification_dispatch = match @workflow.plan_next_part_effect(snapshot) {
    Ok(Some(value)) => value
    Ok(None) => fail("verification process dispatch was not planned")
    Err(error) => fail(error.message())
  }
  match verification_dispatch.kind {
    @workflow.PartEffectKind::DispatchVerification(take_id, _) =>
      assert_eq(take_id, snapshot.verification_take.id)
    _ => fail("verification planned a provider effect")
  }
  assert_false(
    snapshot.harness_sessions.any(fn(session) {
      session.take_id == snapshot.verification_take.id
    }),
  )
  let subject = match snapshot.verification_subject {
    Some(value) => value
    None => fail("verification subject was not created")
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::VerificationCompleted({
      take_id: snapshot.verification_take.id,
      verification_execution_id: @control.VerificationExecutionId(
        "verification-execution-1",
      ),
      subject,
      verification_spec: snapshot.task_contract.verification_specs[0],
      environment_and_image_digest: workflow_digest_e,
      runtime_and_policy_digest: snapshot.identities.verification_sandbox.runtime_policy_digest,
      subject_pre_tree_oid: candidate.tree_oid,
      subject_post_tree_oid: candidate.tree_oid,
      evidence: {
        artifact_id: "verification-evidence-1",
        digest: workflow_digest_e,
      },
      started_at: 18L,
      finished_at: 19L,
      outcome: @control.VerificationOutcome::VerificationPassed,
    }),
    20L,
  )
  round_trip(snapshot)
}

///|
fn drive_to_audited() -> @workflow.PartWorkflowSnapshot raise {
  let mut snapshot = drive_to_verified()
  let audit_session = started_session(snapshot.identities.audit_session)
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::AuditSandboxPrepared(
      active_sandbox(snapshot.identities.audit_sandbox),
    ),
    21L,
  )
  snapshot = apply_observation(
    apply_command_preparation(snapshot, 22L),
    @workflow.PartEffectObservation::AuditHarnessStarted(audit_session),
    22L,
  )
  let (audit_final, audit_events) = successful_trace(
    audit_session, "audit", 23L,
  )
  let subject = match snapshot.audit_subject {
    Some(value) => value
    None => fail("audit subject was not created")
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::AuditCompleted(
      {
        audit_take_id: snapshot.audit_take.id,
        take_fencing_epoch: snapshot.fencing_epoch,
        audit_harness_session_id: audit_session.id,
        subject,
        provider_conformance_report_digest: workflow_digest_d,
        findings_artifact: None,
        total_findings_count: 0,
        blocking_findings_count: 0,
        started_at: 23L,
        finished_at: 24L,
        outcome: @control.AuditOutcome::AuditPassed,
      },
      audit_final,
      audit_events,
    ),
    25L,
  )
  snapshot = round_trip(snapshot)
  snapshot = match
    @workflow.mint_part_audit_receipt(
      snapshot,
      {
        receipt_id: @control.ReceiptId("audit-receipt-1"),
        provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_identity: "claude-code-test",
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "claude-test",
        ),
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  round_trip(snapshot)
}

///|
fn drive_to_integration_authorized() -> @workflow.PartWorkflowSnapshot raise {
  let mut snapshot = drive_to_audited()
  snapshot = match
    @workflow.plan_part_integration(snapshot, {
      lease: {
        id: @control.IntegrationLeaseId("integration-lease-1"),
        goal_id: snapshot.goal.id,
        fencing_epoch: snapshot.fencing_epoch,
        holder: "choird-test",
      },
      intent_id: @control.IntegrationIntentId("integration-intent-1"),
      expected_goal_head_oid: @control.GitOid("goal-head"),
      promotion_metadata_digest: workflow_digest_c,
      git_witness_ref: "refs/choir/witness/integration-intent-1",
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let promotion : @control.PromotionCommit = {
    intent_id: @control.IntegrationIntentId("integration-intent-1"),
    commit_oid: @control.GitOid("promotion-commit"),
    tree_oid: @control.GitOid("promotion-tree"),
    first_parent_oid: @control.GitOid("goal-head"),
    second_parent_oid: @control.GitOid("candidate-commit"),
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::PromotionGenerated(promotion),
    26L,
  )
  snapshot = match
    @workflow.authorize_part_integration(
      snapshot,
      workflow_digest_e,
      snapshot.identities.verification_sandbox.runtime_policy_digest,
      fn(_) { true },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  snapshot
}

///|
test "Part reaches a verified audited integration result" {
  let mut snapshot = drive_to_integration_authorized()
  guard snapshot.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  snapshot = apply_observation(
    snapshot,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  snapshot = round_trip(snapshot)
  assert_eq(snapshot.stage, @workflow.PartWorkflowStage::PartIntegrated)
  assert_eq(snapshot.verification_receipts.length(), 1)
  assert_true(snapshot.audit_receipt is Some(_))
  assert_true(snapshot.integration_receipt is Some(_))
  assert_eq(snapshot.effect_receipts.length(), 13)
  assert_true(
    snapshot.identities.implementation_sandbox.generation_id !=
    snapshot.identities.audit_sandbox.generation_id,
  )
  assert_true(
    snapshot.identities.implementation_session.id !=
    snapshot.identities.audit_session.id,
  )
}

///|
test "Goal audit repair reopens an integrated Part and preserves its receipt" {
  let mut integrated = drive_to_integration_authorized()
  guard integrated.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  integrated = apply_observation(
    integrated,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  guard integrated.integration_receipt is Some(integration_receipt) else {
    fail("integrated Part has no receipt")
  }
  let repair : @control.AuditRepairReference = {
    scope: @control.AuditRepairScope::GoalAuditRepair,
    audit_result_id: @control.AuditResultId("goal-audit-result-repair-1"),
    audit_result_digest: workflow_digest_d,
    findings_artifact: {
      artifact_id: "goal-audit-findings-repair-1",
      digest: workflow_digest_e,
    },
    affected_paths: [@control.RepoPath("src/feature.mbt")],
  }
  let contract : @control.TaskContractRevision = {
    ..integrated.task_contract,
    id: @control.RevisionId("audit-repair-revision-2"),
    revision: integrated.task_contract.revision + 1,
    digest: workflow_digest_d,
    repair_conflict_id: None,
    repair_audit: Some(repair),
    repair_verification: None,
    instruction_artifact: {
      artifact_id: "audit-repair-instruction-2",
      digest: workflow_digest_e,
    },
    base_commit_oid: promotion.commit_oid,
    base_tree_oid: promotion.tree_oid,
  }
  let implementation = {
    ..workflow_take(
      "audit-repair-implementation-take-2",
      @control.TakePurpose::Implementation(integrated.part.id, contract.id),
    ),
    ordinal: 2,
  }
  let verification = {
    ..workflow_take(
      "audit-repair-verification-take-2",
      @control.TakePurpose::PartVerification(
        integrated.part.id,
        implementation.id,
        contract.verification_specs[0].digest,
      ),
    ),
    ordinal: 2,
  }
  let audit = {
    ..workflow_take(
      "audit-repair-audit-take-2",
      @control.TakePurpose::PartAudit(
        integrated.part.id,
        implementation.id,
        contract.audit_policy_digest,
      ),
    ),
    ordinal: 2,
  }
  let implementation_sandbox = workflow_sandbox(
    "audit-repair-implementation-sandbox-2",
    "audit-repair-implementation-generation-2",
    implementation.id,
    contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "audit-repair-verification-sandbox-2",
    "audit-repair-verification-generation-2",
    verification.id,
    contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "audit-repair-audit-sandbox-2",
    "audit-repair-audit-generation-2",
    audit.id,
    contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let repaired = match
    @workflow.plan_part_audit_repair(
      integrated,
      repair,
      { commit_oid: contract.base_commit_oid, tree_oid: contract.base_tree_oid },
      contract,
      {
        implementation_take: implementation,
        implementation_sandbox,
        implementation_session: workflow_session(
          "audit-repair-implementation-session-2",
          implementation.id,
          implementation_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_a,
        ),
        verification_take: verification,
        verification_sandbox,
        audit_take: audit,
        audit_sandbox,
        audit_session: workflow_session(
          "audit-repair-audit-session-2",
          audit.id,
          audit_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_c,
        ),
      },
      fn(_) { true },
    ) {
    Ok(@workflow.PartAuditRepairDecision::PartAuditRepairPlanned(value)) =>
      value
    Ok(_) => fail("first audit repair reached its retry limit")
    Err(error) => fail(error.message())
  }
  assert_eq(repaired.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(
    repaired.part.lifecycle,
    @control.PartLifecycle::PartExecuting(implementation.id),
  )
  assert_eq(repaired.task_contract.repair_audit, Some(repair))
  assert_true(repaired.integration_receipt is None)
  assert_eq(
    repaired.prior_take_evidence[0].integration_receipt,
    Some(integration_receipt),
  )
}

///|
test "combined verification repair reopens an integrated Part on routed paths" {
  let mut integrated = drive_to_integration_authorized()
  guard integrated.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  integrated = apply_observation(
    integrated,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  guard integrated.integration_receipt is Some(integration_receipt) else {
    fail("integrated Part has no receipt")
  }
  let repair : @control.VerificationRepairReference = {
    scope: @control.VerificationRepairScope::GoalVerificationRepair,
    receipt_id: @control.ReceiptId("goal-verification-receipt-repair-1"),
    verification_execution_id: @control.VerificationExecutionId(
      "goal-verification-execution-repair-1",
    ),
    subject_digest: workflow_digest_d,
    verification_spec: integrated.task_contract.verification_specs[0],
    evidence_artifact: {
      artifact_id: "goal-verification-evidence-repair-1",
      digest: workflow_digest_e,
    },
    affected_paths: [@control.RepoPath("src/feature.mbt")],
  }
  let contract : @control.TaskContractRevision = {
    ..integrated.task_contract,
    id: @control.RevisionId("goal-verification-repair-revision-2"),
    revision: integrated.task_contract.revision + 1,
    digest: workflow_digest_d,
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: Some(repair),
    instruction_artifact: {
      artifact_id: "goal-verification-repair-instruction-2",
      digest: workflow_digest_e,
    },
    base_commit_oid: promotion.commit_oid,
    base_tree_oid: promotion.tree_oid,
  }
  let identities = goal_verification_repair_identities(integrated, contract)
  assert_true(
    @workflow.plan_part_verification_repair(
      integrated,
      repair,
      {
        commit_oid: integrated.task_contract.base_commit_oid,
        tree_oid: integrated.task_contract.base_tree_oid,
      },
      contract,
      identities,
      fn(_) { true },
    )
    is Err(_),
  )
  let repaired = match
    @workflow.plan_part_verification_repair(
      integrated,
      repair,
      { commit_oid: promotion.commit_oid, tree_oid: promotion.tree_oid },
      contract,
      identities,
      fn(_) { true },
    ) {
    Ok(
      @workflow.PartVerificationRepairDecision::PartVerificationRepairPlanned(
        value
      )
    ) => value
    Ok(_) => fail("first combined verification repair reached its retry limit")
    Err(error) => fail(error.message())
  }
  assert_eq(repaired.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(
    repaired.part.lifecycle,
    @control.PartLifecycle::PartExecuting(identities.implementation_take.id),
  )
  assert_eq(repaired.task_contract.repair_verification, Some(repair))
  assert_eq(
    repaired.task_contract.mutation_declaration,
    integrated.task_contract.mutation_declaration,
  )
  assert_eq(
    repaired.task_contract.verification_specs,
    integrated.task_contract.verification_specs,
  )
  assert_true(repaired.integration_receipt is None)
  assert_eq(
    repaired.prior_take_evidence[0].integration_receipt,
    Some(integration_receipt),
  )
  // Goal-scope repair exists only to carry routed paths: an unrouteable
  // failure must not reopen an integrated Part at all.
  let unrouted = { ..repair, affected_paths: [] }
  assert_true(
    @workflow.plan_part_verification_repair(
      integrated,
      unrouted,
      { commit_oid: promotion.commit_oid, tree_oid: promotion.tree_oid },
      { ..contract, repair_verification: Some(unrouted) },
      identities,
      fn(_) { true },
    )
    is Err(_),
  )
  // Nor may Goal-scope evidence be replayed as a Part-scope repair, whose
  // eligibility depends on the Part's own failing receipt.
  let part_scoped = {
    ..repair,
    scope: @control.VerificationRepairScope::PartVerificationRepair,
    affected_paths: [],
  }
  assert_true(
    @workflow.plan_part_verification_repair(
      integrated,
      part_scoped,
      { commit_oid: promotion.commit_oid, tree_oid: promotion.tree_oid },
      { ..contract, repair_verification: Some(part_scoped) },
      identities,
      fn(_) { true },
    )
    is Err(_),
  )
}

///|
fn goal_verification_repair_identities(
  snapshot : @workflow.PartWorkflowSnapshot,
  contract : @control.TaskContractRevision,
) -> @workflow.PartIdentityPlan {
  let implementation = {
    ..workflow_take(
      "goal-verification-repair-implementation-take-2",
      @control.TakePurpose::Implementation(snapshot.part.id, contract.id),
    ),
    ordinal: 2,
  }
  let verification = {
    ..workflow_take(
      "goal-verification-repair-verification-take-2",
      @control.TakePurpose::PartVerification(
        snapshot.part.id,
        implementation.id,
        contract.verification_specs[0].digest,
      ),
    ),
    ordinal: 2,
  }
  let audit = {
    ..workflow_take(
      "goal-verification-repair-audit-take-2",
      @control.TakePurpose::PartAudit(
        snapshot.part.id,
        implementation.id,
        contract.audit_policy_digest,
      ),
    ),
    ordinal: 2,
  }
  let implementation_sandbox = workflow_sandbox(
    "goal-verification-repair-implementation-sandbox-2",
    "goal-verification-repair-implementation-generation-2",
    implementation.id,
    contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "goal-verification-repair-verification-sandbox-2",
    "goal-verification-repair-verification-generation-2",
    verification.id,
    contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "goal-verification-repair-audit-sandbox-2",
    "goal-verification-repair-audit-generation-2",
    audit.id,
    contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: workflow_session(
      "goal-verification-repair-implementation-session-2",
      implementation.id,
      implementation_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_a,
    ),
    verification_take: verification,
    verification_sandbox,
    audit_take: audit,
    audit_sandbox,
    audit_session: workflow_session(
      "goal-verification-repair-audit-session-2",
      audit.id,
      audit_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_c,
    ),
  }
}

///|
test "failed verification plans a bounded evidence-carrying repair revision" {
  let verified = drive_to_verified()
  guard verified.verification_receipts is [passed] else {
    fail("verified Part has no single receipt")
  }
  let failed = {
    ..passed,
    receipt_id: @control.ReceiptId("verification-failed-receipt-1"),
    verification_execution_id: @control.VerificationExecutionId(
      "verification-failed-execution-1",
    ),
    evidence: {
      artifact_id: "verification-failed-evidence-1",
      digest: workflow_digest_d,
    },
    outcome: @control.VerificationOutcome::VerificationFailed,
  }
  let blocked_part = match
    @control.transition_part(
      verified.part,
      @control.PartTransition::BlockPart(
        @control.PartBlockReason::PartVerificationFailed,
      ),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let blocked = {
    ..verified,
    stage: @workflow.PartWorkflowStage::PartBlocked,
    part: blocked_part,
    verification_receipts: [failed],
    verification_authorization: None,
    audit_subject: None,
  }
  let repair : @control.VerificationRepairReference = {
    scope: @control.VerificationRepairScope::PartVerificationRepair,
    receipt_id: failed.receipt_id,
    verification_execution_id: failed.verification_execution_id,
    subject_digest: failed.subject.subject_digest,
    verification_spec: failed.verification_spec,
    evidence_artifact: failed.evidence,
    affected_paths: [],
  }
  let contract : @control.TaskContractRevision = {
    ..blocked.task_contract,
    id: @control.RevisionId("verification-repair-revision-2"),
    revision: blocked.task_contract.revision + 1,
    digest: workflow_digest_b,
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: Some(repair),
    instruction_artifact: {
      artifact_id: "verification-repair-instruction-2",
      digest: workflow_digest_e,
    },
  }
  let implementation = {
    ..workflow_take(
      "verification-repair-implementation-take-2",
      @control.TakePurpose::Implementation(blocked.part.id, contract.id),
    ),
    ordinal: 2,
  }
  let verification = {
    ..workflow_take(
      "verification-repair-verification-take-2",
      @control.TakePurpose::PartVerification(
        blocked.part.id,
        implementation.id,
        contract.verification_specs[0].digest,
      ),
    ),
    ordinal: 2,
  }
  let audit = {
    ..workflow_take(
      "verification-repair-audit-take-2",
      @control.TakePurpose::PartAudit(
        blocked.part.id,
        implementation.id,
        contract.audit_policy_digest,
      ),
    ),
    ordinal: 2,
  }
  let implementation_sandbox = workflow_sandbox(
    "verification-repair-implementation-sandbox-2",
    "verification-repair-implementation-generation-2",
    implementation.id,
    contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "verification-repair-verification-sandbox-2",
    "verification-repair-verification-generation-2",
    verification.id,
    contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "verification-repair-audit-sandbox-2",
    "verification-repair-audit-generation-2",
    audit.id,
    contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let repaired = match
    @workflow.plan_part_verification_repair(
      blocked,
      repair,
      { commit_oid: contract.base_commit_oid, tree_oid: contract.base_tree_oid },
      contract,
      {
        implementation_take: implementation,
        implementation_sandbox,
        implementation_session: workflow_session(
          "verification-repair-implementation-session-2",
          implementation.id,
          implementation_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_a,
        ),
        verification_take: verification,
        verification_sandbox,
        audit_take: audit,
        audit_sandbox,
        audit_session: workflow_session(
          "verification-repair-audit-session-2",
          audit.id,
          audit_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_c,
        ),
      },
      fn(_) { true },
    ) {
    Ok(
      @workflow.PartVerificationRepairDecision::PartVerificationRepairPlanned(
        value
      )
    ) => value
    Ok(_) => fail("first verification repair reached its retry limit")
    Err(error) => fail(error.message())
  }
  assert_eq(repaired.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(
    repaired.part.lifecycle,
    @control.PartLifecycle::PartExecuting(implementation.id),
  )
  assert_eq(repaired.task_contract.repair_verification, Some(repair))
  assert_eq(repaired.prior_take_evidence[0].verification_receipts, [failed])
  assert_true(repaired.verification_receipts.length() == 0)
  let exhausted_contract : @control.TaskContractRevision = {
    ..contract,
    id: @control.RevisionId("verification-repair-revision-3"),
    revision: 3,
    digest: workflow_digest_c,
  }
  let exhausted_failed = {
    ..failed,
    receipt_id: @control.ReceiptId("verification-failed-receipt-3"),
    verification_execution_id: @control.VerificationExecutionId(
      "verification-failed-execution-3",
    ),
    subject: {
      ..failed.subject,
      task_contract_revision_id: exhausted_contract.id,
    },
  }
  let exhausted_repair : @control.VerificationRepairReference = {
    scope: @control.VerificationRepairScope::PartVerificationRepair,
    receipt_id: exhausted_failed.receipt_id,
    verification_execution_id: exhausted_failed.verification_execution_id,
    subject_digest: exhausted_failed.subject.subject_digest,
    verification_spec: exhausted_failed.verification_spec,
    evidence_artifact: exhausted_failed.evidence,
    affected_paths: [],
  }
  let exhausted = {
    ..blocked,
    part: { ..blocked.part, task_contract_revision_id: exhausted_contract.id },
    task_contract: exhausted_contract,
    task_contract_history: [blocked.task_contract, contract, exhausted_contract],
    verification_receipts: [exhausted_failed],
  }
  match
    @workflow.plan_part_verification_repair(
      exhausted,
      exhausted_repair,
      { commit_oid: contract.base_commit_oid, tree_oid: contract.base_tree_oid },
      contract,
      {
        implementation_take: implementation,
        implementation_sandbox,
        implementation_session: workflow_session(
          "unused-exhausted-implementation-session",
          implementation.id,
          implementation_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_a,
        ),
        verification_take: verification,
        verification_sandbox,
        audit_take: audit,
        audit_sandbox,
        audit_session: workflow_session(
          "unused-exhausted-audit-session",
          audit.id,
          audit_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_c,
        ),
      },
      fn(_) { true },
    ) {
    Ok(
      @workflow.PartVerificationRepairDecision::PartVerificationRepairLimitReached
    ) => ()
    Ok(_) => fail("third verification repair was not bounded")
    Err(error) => fail(error.message())
  }
}

///|
test "Goal audit repair routes paths to their deterministic Part owners" {
  let first = workflow_fixture()
  let second_part = {
    ..first.part,
    id: @control.PartId("part-2"),
    task_contract_revision_id: @control.RevisionId("part-2-revision-1"),
  }
  let second = {
    ..first,
    workflow_id: @control.WorkflowId("part-2-workflow"),
    part: second_part,
    task_contract: {
      ..first.task_contract,
      id: second_part.task_contract_revision_id,
      part_id: second_part.id,
      mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
          @control.MutationClaim::ExactPath(
            @control.RepoPath("src/lint/lint.mbt"),
          ),
        ],
      ),
    },
  }
  let routes = match
    @workflow.plan_goal_repair_routes([second, first], [
      @control.RepoPath("src/feature.mbt"),
      @control.RepoPath("src/lint/lint.mbt"),
    ]) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(routes, [
    {
      part_id: first.part.id,
      affected_paths: [@control.RepoPath("src/feature.mbt")],
    },
    {
      part_id: second.part.id,
      affected_paths: [@control.RepoPath("src/lint/lint.mbt")],
    },
  ])
}

///|
test "integrated Parts authorize one immutable Goal branch seal" {
  let mut integrated = drive_to_integration_authorized()
  guard integrated.promotion_commit is Some(promotion) else {
    fail("authorized integration has no promotion commit")
  }
  integrated = apply_observation(
    integrated,
    @workflow.PartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
    ),
    27L,
  )
  let execution : @workflow.GoalExecutionRecord = {
    goal: integrated.goal,
    repository_id: @workflow.RepositoryId("repository-assurance"),
    selection_decision_digest: workflow_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("goal-head"),
    base_tree_oid: @control.GitOid("goal-tree-before"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise assurance workflow",
      body: "Exercises Goal assurance from a Part workflow.",
      draft: false,
    }),
    migration_production_admission: None,
    goal_ref: @workflow.goal_execution_ref(integrated.goal.id),
    branch_initialization: workflow_initialized_branch(
      integrated.goal.id,
      @workflow.RepositoryId("repository-assurance"),
      @workflow.goal_execution_ref(integrated.goal.id),
      @control.GitOid("goal-head"),
    ),
    source_claims: [
      receipted_goal_source_claim(
        integrated.goal.id,
        integrated.part.id,
        workflow_digest_a,
        workflow_digest_a,
        1L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [
      @workflow.initial_goal_policy_revision(integrated.goal.id, 1),
    ],
    part_workflow_ids: [integrated.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    work_order_id: None,
    durable_version: 3,
    fencing_epoch: integrated.fencing_epoch,
  }
  let planned = match
    @workflow.initialize_goal_assurance(
      execution,
      [integrated],
      promotion.commit_oid,
      promotion.tree_oid,
      integrated.task_contract.verification_specs,
      workflow_goal_assurance_identities(execution.goal, promotion.commit_oid),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(planned.stage, @workflow.GoalAssuranceStage::GoalSealPlanned)
  assert_eq(planned.integration_receipts.length(), 1)
  assert_eq(
    planned.verification_specs,
    integrated.task_contract.verification_specs,
  )
  let canceled_planned = @workflow.record_goal_assurance_cancellation(planned).unwrap()
  assert_eq(
    canceled_planned.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceCanceled,
  )
  assert_eq(
    canceled_planned.seal_intent.lifecycle,
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealAbandonedByCancellation,
  )
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(canceled_planned),
  )
  assert_eq(
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(canceled_planned),
    ).unwrap(),
    canceled_planned,
  )
  let authorized = match
    @workflow.authorize_goal_assurance_seal(
      planned,
      execution.goal,
      promotion.commit_oid,
      promotion.tree_oid,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    @workflow.record_goal_assurance_cancellation(authorized).unwrap(),
    authorized,
  )
  assert_false(
    @workflow.goal_assurance_cancellation_disposition_is_known(authorized),
  )
  let witnessed = match
    @workflow.record_goal_assurance_seal_witness(
      authorized,
      @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
        promotion.tree_oid,
      ),
      28L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let canceled_witnessed = @workflow.record_goal_assurance_cancellation(
    witnessed,
  ).unwrap()
  assert_eq(
    canceled_witnessed.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceCanceled,
  )
  assert_eq(
    canceled_witnessed.seal_intent.lifecycle,
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealWitnessed,
  )
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(
      canceled_witnessed,
    ),
  )
  let completed_seal = match
    @workflow.commit_goal_assurance_seal(
      witnessed,
      @control.GoalBranchSealId("seal-goal-1"),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(completed_seal.stage, @workflow.GoalAssuranceStage::GoalSealed)
  assert_eq(completed_seal.durable_version, 4)
  let canceled_sealed = @workflow.record_goal_assurance_cancellation(
    completed_seal,
  ).unwrap()
  assert_eq(
    canceled_sealed.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceCanceled,
  )
  assert_true(canceled_sealed.seal is Some(_))
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(canceled_sealed),
  )
  let planned_effect = @workflow.persist_planned_goal_assurance_effect(
    completed_seal,
    @workflow.plan_next_goal_assurance_effect(completed_seal).unwrap().unwrap(),
  ).unwrap()
  let canceled_planned_effect = @workflow.record_goal_assurance_cancellation(
    planned_effect,
  ).unwrap()
  assert_true(
    canceled_planned_effect.pending_effect
    is Some(
      {
        lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectAbandonedByCancellation,
        ..,
      }
    ),
  )
  let authorized_effect = @workflow.authorize_pending_goal_assurance_effect(
    planned_effect,
  ).unwrap()
  let canceled_authorized_effect = @workflow.record_goal_assurance_cancellation(
    authorized_effect,
  ).unwrap()
  assert_true(
    canceled_authorized_effect.pending_effect
    is Some(
      {
        lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectUncertain,
        ..,
      }
    ),
  )
  assert_true(
    @workflow.goal_assurance_cancellation_disposition_is_known(
      canceled_authorized_effect,
    ),
  )
  let mut assured = apply_goal_assurance_observation(
    completed_seal,
    @workflow.GoalAssuranceEffectObservation::GoalVerificationSandboxPrepared(
      active_sandbox(completed_seal.identities.verification_sandbox),
    ),
    29L,
  )
  let goal_verification_dispatch = match
    @workflow.plan_next_goal_assurance_effect(assured) {
    Ok(Some(value)) => value
    Ok(None) => fail("Goal verification process dispatch was not planned")
    Err(error) => fail(error.message())
  }
  match goal_verification_dispatch.kind {
    @workflow.GoalAssuranceEffectKind::DispatchGoalVerification(take_id, _) =>
      assert_eq(take_id, assured.verification_take.id)
    _ => fail("Goal verification planned a provider effect")
  }
  assert_false(
    assured.harness_sessions.any(fn(session) {
      session.take_id == assured.verification_take.id
    }),
  )
  let verification_subject = match assured.verification_subject {
    Some(value) => value
    None => fail("combined verification subject is absent")
  }
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalVerificationCompleted({
      take_id: assured.verification_take.id,
      subject: verification_subject,
      executions: [
        {
          verification_execution_id: @control.VerificationExecutionId(
            "goal-verification-execution-1",
          ),
          verification_spec: assured.verification_specs[0],
          environment_and_image_digest: workflow_digest_d,
          runtime_and_policy_digest: assured.identities.verification_sandbox.runtime_policy_digest,
          subject_pre_tree_oid: promotion.tree_oid,
          subject_post_tree_oid: promotion.tree_oid,
          evidence: {
            artifact_id: "goal-verification-evidence-1",
            digest: workflow_digest_e,
          },
          started_at: 31L,
          finished_at: 32L,
          outcome: @control.VerificationOutcome::VerificationPassed,
        },
      ],
      evidence_manifest: {
        artifact_id: "goal-verification-manifest-1",
        digest: workflow_digest_c,
      },
    }),
    33L,
  )
  assert_eq(assured.stage, @workflow.GoalAssuranceStage::GoalVerified)
  assert_eq(assured.verification_receipts.length(), 1)
  assert_true(assured.verification_authorization is Some(_))
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditSandboxPrepared(
      active_sandbox(assured.identities.audit_sandbox),
    ),
    34L,
  )
  let audit_session = started_session(assured.identities.audit_session)
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditHarnessStarted(
      audit_session,
    ),
    35L,
  )
  let audit_subject = match assured.audit_subject {
    Some(value) => value
    None => fail("combined audit subject is absent")
  }
  let (audit_final, audit_events) = successful_trace(
    audit_session, "goal-audit", 36L,
  )
  let (findings_final, findings_events) = successful_trace(
    audit_session, "goal-audit-findings", 36L,
  )
  let with_findings = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditCompleted(
      {
        audit_take_id: assured.audit_take.id,
        take_fencing_epoch: assured.fencing_epoch,
        audit_harness_session_id: audit_session.id,
        subject: audit_subject,
        provider_conformance_report_digest: workflow_digest_b,
        findings_artifact: Some({
          artifact_id: "goal-audit-findings-1",
          digest: workflow_digest_e,
        }),
        total_findings_count: 2,
        blocking_findings_count: 1,
        started_at: 36L,
        finished_at: 37L,
        outcome: @control.AuditOutcome::AuditFindings,
      },
      findings_final,
      findings_events,
    ),
    38L,
  )
  let blocked_by_findings = match
    @workflow.mint_goal_audit_receipt(
      with_findings,
      {
        receipt_id: @control.ReceiptId("goal-audit-receipt-findings-1"),
        provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
        provider_identity: "codex-cli",
        model_identity: @control.ModelIdentity::ReportedModelIdentity("codex"),
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    blocked_by_findings.stage,
    @workflow.GoalAssuranceStage::GoalAssuranceBlocked,
  )
  assert_true(blocked_by_findings.audit_receipt is Some(_))
  assert_eq(
    blocked_by_findings.blocked_reason,
    Some(
      @workflow.GoalAssuranceBlockReason::GoalAssuranceAuditBlocked(
        @control.AuditGateObservation::AuditGateRejected(
          @control.AuditGateRejectionReason::AuditHasBlockingFindings,
        ),
      ),
    ),
  )
  let blocked_status = match
    @workflow.goal_status_report(
      execution,
      [integrated],
      Some(blocked_by_findings),
      None,
      None,
      None,
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    blocked_status.assurance_block_reason,
    blocked_by_findings.blocked_reason,
  )
  assert_true(blocked_status.goal_audit_receipt_present)
  assured = apply_goal_assurance_observation(
    assured,
    @workflow.GoalAssuranceEffectObservation::GoalAuditCompleted(
      {
        audit_take_id: assured.audit_take.id,
        take_fencing_epoch: assured.fencing_epoch,
        audit_harness_session_id: audit_session.id,
        subject: audit_subject,
        provider_conformance_report_digest: workflow_digest_b,
        findings_artifact: None,
        total_findings_count: 0,
        blocking_findings_count: 0,
        started_at: 36L,
        finished_at: 37L,
        outcome: @control.AuditOutcome::AuditPassed,
      },
      audit_final,
      audit_events,
    ),
    38L,
  )
  assured = match
    @workflow.mint_goal_audit_receipt(
      assured,
      {
        receipt_id: @control.ReceiptId("goal-audit-receipt-1"),
        provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
        provider_identity: "codex-cli",
        model_identity: @control.ModelIdentity::ReportedModelIdentity("codex"),
      },
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(assured.stage, @workflow.GoalAssuranceStage::GoalAudited)
  assert_true(assured.audit_receipt is Some(_))
  assert_true(
    assured.identities.verification_sandbox.generation_id !=
    assured.identities.audit_sandbox.generation_id,
  )
  assert_eq(assured.effect_receipts.length(), 5)
  let status = match
    @workflow.goal_status_report(
      execution,
      [integrated],
      Some(assured),
      None,
      None,
      None,
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    status.assurance_stage,
    Some(@workflow.GoalAssuranceStage::GoalAudited),
  )
  assert_true(status.goal_branch_seal is Some(_))
  assert_eq(status.assurance_sandbox_count, 2)
  assert_eq(status.assurance_harness_session_count, 1)
  assert_eq(status.assurance_effect_receipt_count, 5)
  assert_eq(status.goal_verification_receipt_count, 1)
  assert_true(status.goal_audit_receipt_present)
  assert_eq(
    status.parts[0].implementation_take_lifecycle,
    integrated.implementation_take.lifecycle,
  )
  assert_eq(
    status.parts[0].verification_take_lifecycle,
    integrated.verification_take.lifecycle,
  )
  assert_eq(
    status.parts[0].audit_take_lifecycle,
    integrated.audit_take.lifecycle,
  )
  let assured_execution = {
    ..execution,
    state: @workflow.GoalExecutionState::GoalExecutionAssured,
    durable_version: execution.durable_version + 1,
  }
  let evidence_only_execution = {
    ..assured_execution,
    completion_mode: @workflow.GoalCompletionMode::GoalEvidenceOnly(
      workflow_digest_b,
    ),
    pull_request_document: None,
  }
  let evidence_only_completion = @workflow.authorize_goal_evidence_only_completion(
    evidence_only_execution, assured,
  ).unwrap()
  assert_eq(
    evidence_only_completion.cause,
    @workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
      workflow_digest_b,
      @workflow.goal_assurance_record_digest(assured),
    ),
  )
  assert_eq(
    evidence_only_completion.requested_at,
    assured.audit_receipt.unwrap().finished_at,
  )
  assert_true(
    @workflow.authorize_goal_evidence_only_completion(
      assured_execution, assured,
    )
    is Err(_),
  )
  let qualification_assurance_digest = @workflow.goal_assurance_record_digest(
    assured,
  )
  let judge_definition : @migration.MigrationJudgeDefinition = {
    schema_version: 1,
    source_revision: workflow_digest_a,
    scenario_count: 1,
    baseline_policy: @migration.JudgeBaselinePolicy::JudgeCleanBaseline,
    negative_controls: [
      {
        scenario_id: @migration.MigrationScenarioId("broken-rule-control"),
        class: @migration.JudgeNegativeControlClass::JudgeRuleViolationControl,
        expected_failure_digest: workflow_digest_b,
      },
    ],
    excluded_surfaces_artifact_digest: workflow_digest_a,
    permitted_nondeterminism_artifact_digest: workflow_digest_b,
    substitute_oracle_artifact_digest: None,
  }
  let judge_report : @migration.JudgeQualificationReport = {
    judge_definition_digest: @migration.migration_judge_definition_digest(
      judge_definition,
    ),
    source_revision: workflow_digest_a,
    baseline_results: [
      {
        scenario_id: @migration.MigrationScenarioId("source-baseline"),
        normalized_outcome_digest: workflow_digest_a,
        classification: @migration.JudgeBaselineClassification::JudgeBaselinePassed,
      },
    ],
    negative_control_results: [
      {
        scenario_id: @migration.MigrationScenarioId("broken-rule-control"),
        class: @migration.JudgeNegativeControlClass::JudgeRuleViolationControl,
        observed_failure_digest: workflow_digest_b,
        rejected: true,
      },
    ],
    goal_verification_receipt_ids: assured.verification_receipts.map(fn(
      receipt,
    ) {
      receipt.receipt_id
    }),
    goal_audit_receipt_id: assured.audit_receipt.unwrap().receipt_id,
  }
  let migration_contract : @migration.MigrationContract = {
    id: @control.MigrationContractId("migration-admission-contract"),
    migration_lineage_id: @control.MigrationLineageId(
      "migration-admission-lineage",
    ),
    revision: 1,
    source_revision: workflow_digest_a,
    workflow_shape: @migration.MigrationWorkflowShape::StructurePreservingPort,
    feasibility_report_artifact_digest: workflow_digest_a,
    target_architecture_artifact_digest: workflow_digest_b,
    rulebook_artifact_digest: workflow_digest_a,
    dependency_map_artifact_digest: workflow_digest_b,
    gap_inventory_artifact_digest: workflow_digest_a,
    inventory_generator_artifact_digest: workflow_digest_b,
    qualified_inventory_artifact_digest: workflow_digest_a,
    transformation_plan_artifact_digest: workflow_digest_b,
    context_assembly_policy_digest: workflow_digest_a,
    judge_definition_digest: @migration.migration_judge_definition_digest(
      judge_definition,
    ),
    judge_qualification_assurance_record_digest: qualification_assurance_digest,
    parity_definition_digest: None,
    validation_plan_digest: workflow_digest_a,
    rehearsal_policy: @migration.RehearsalPolicy::RehearsalNotRequired,
  }
  let seal = assured.seal.unwrap()
  let qualification_binding : @migration.JudgeQualificationBinding = {
    qualifying_goal_id: assured_execution.goal.id,
    qualifying_goal_contract_digest: assured_execution.goal.contract_digest,
    goal_branch_seal_id: seal.id,
    goal_branch_seal_digest: seal.seal_digest,
    judge_definition_digest: migration_contract.judge_definition_digest,
    source_revision: migration_contract.source_revision,
  }
  let qualification_completion_binding = @migration.judge_qualification_binding_digest(
    qualification_binding,
  )
  let succeeded_qualification = @workflow.advance_goal_execution_state(
    assured_execution,
    @workflow.GoalExecutionState::GoalExecutionSucceeded,
  ).unwrap()
  guard succeeded_qualification.goal.lifecycle
    is @control.GoalLifecycle::GoalSucceeded(finalization_id) else {
    fail("qualifying Goal did not retain finalization identity")
  }
  let qualification_reference : @migration.JudgeQualificationEvidenceRef = {
    binding: qualification_binding,
    completion_binding_digest: qualification_completion_binding,
    assurance_record_digest: qualification_assurance_digest,
    terminal: @migration.JudgeQualificationTerminal::JudgeQualificationSucceeded(
      finalization_id,
    ),
  }
  assert_true(
    @workflow.validate_judge_qualification_admission(
      migration_contract, qualification_reference, succeeded_qualification, assured,
    )
    is Ok(_),
  )
  assert_true(
    @workflow.validate_judge_qualification_admission(
      migration_contract, qualification_reference, assured_execution, assured,
    )
    is Err(_),
  )
  let migration_contract_ref = @migration.migration_contract_reference(
    migration_contract,
  ).unwrap()
  let migration_acceptance : @migration.MigrationContractAcceptance = {
    contract_ref: migration_contract_ref,
    authorization: @migration.MigrationContractAuthorization::MigrationContractExplicitUserInput(
      workflow_digest_a,
    ),
    accepted_event_sequence: @control.EventSequence(1L),
    accepted_at: 1L,
  }
  let production_admission = @workflow.validate_migration_production_admission(
    migration_contract,
    migration_acceptance,
    judge_definition,
    judge_report,
    qualification_reference,
    succeeded_qualification,
    assured,
    None,
    None,
    None,
  ).unwrap()
  assert_eq(production_admission.migration_contract_ref, migration_contract_ref)
  assert_eq(
    production_admission.contract_acceptance_digest,
    @migration.migration_contract_acceptance_digest(migration_acceptance),
  )
  assert_eq(
    production_admission.judge_definition_digest,
    migration_contract.judge_definition_digest,
  )
  assert_eq(
    production_admission.judge_qualification_report_digest,
    @migration.judge_qualification_report_digest(judge_report),
  )
  assert_eq(
    production_admission.judge_qualification_evidence_ref_digest,
    @migration.judge_qualification_evidence_ref_digest(qualification_reference),
  )
  let surviving_control_report = {
    ..judge_report,
    negative_control_results: [
      { ..judge_report.negative_control_results[0], rejected: false },
    ],
  }
  assert_true(
    @workflow.validate_migration_production_admission(
      migration_contract,
      migration_acceptance,
      judge_definition,
      surviving_control_report,
      qualification_reference,
      succeeded_qualification,
      assured,
      None,
      None,
      None,
    )
    is Err(_),
  )
  guard @workflow.request_goal_execution_cancellation(
      evidence_only_execution,
      evidence_only_completion.requested_at,
      cause=evidence_only_completion.cause,
    ).unwrap()
    is @workflow.GoalCancellationDecision::GoalCancellationRequested(
      rehearsal_canceling
    ) else {
    fail("rehearsal cancellation request was not accepted")
  }
  let mut rehearsal_releasing = rehearsal_canceling
  for claim in rehearsal_releasing.source_claims {
    rehearsal_releasing = @workflow.authorize_goal_source_release(
      rehearsal_releasing,
      claim.part_id,
    ).unwrap()
    rehearsal_releasing = @workflow.reconcile_goal_source_release(
      rehearsal_releasing,
      claim.part_id,
      @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
      evidence_only_completion.requested_at + 1L,
    ).unwrap()
  }
  let rehearsal_canceled = @workflow.commit_goal_execution_cancellation(
    rehearsal_releasing,
  ).unwrap()
  guard rehearsal_canceled.goal.lifecycle
    is @control.GoalLifecycle::GoalCanceled(rehearsal_summary_id) else {
    fail("rehearsal Goal did not retain cancellation summary identity")
  }
  let sampled_inventory_digest = workflow_digest_b
  let rehearsal_binding : @migration.RehearsalBinding = {
    migration_contract_ref,
    sampled_inventory_digest,
  }
  let rehearsal_reference : @migration.RehearsalEvidenceRef = {
    rehearsal_goal_id: rehearsal_canceled.goal.id,
    migration_contract_ref,
    sampled_inventory_digest,
    completion_binding_digest: @migration.rehearsal_binding_digest(
      rehearsal_binding,
    ),
    assurance_record_digest: qualification_assurance_digest,
    cancellation_summary_id: rehearsal_summary_id,
  }
  let rebound_rehearsal = {
    ..rehearsal_canceled,
    completion_mode: @workflow.GoalCompletionMode::GoalEvidenceOnly(
      rehearsal_reference.completion_binding_digest,
    ),
    pull_request_document: None,
    cancellation_request: rehearsal_canceled.cancellation_request.map(fn(
      request,
    ) {
      {
        ..request,
        cause: @workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
          rehearsal_reference.completion_binding_digest,
          qualification_assurance_digest,
        ),
      }
    }),
  }
  assert_true(
    @workflow.validate_rehearsal_admission(
      migration_contract_ref, sampled_inventory_digest, rehearsal_reference, rebound_rehearsal,
      assured,
    )
    is Ok(_),
  )
  let required_contract = {
    ..migration_contract,
    rehearsal_policy: @migration.RehearsalPolicy::RehearsalRequired(
      sampled_inventory_digest,
    ),
  }
  let required_contract_ref = @migration.migration_contract_reference(
    required_contract,
  ).unwrap()
  let required_rehearsal_binding : @migration.RehearsalBinding = {
    migration_contract_ref: required_contract_ref,
    sampled_inventory_digest,
  }
  let required_rehearsal_reference = {
    ..rehearsal_reference,
    migration_contract_ref: required_contract_ref,
    completion_binding_digest: @migration.rehearsal_binding_digest(
      required_rehearsal_binding,
    ),
  }
  let required_rehearsal_execution = {
    ..rebound_rehearsal,
    completion_mode: @workflow.GoalCompletionMode::GoalEvidenceOnly(
      required_rehearsal_reference.completion_binding_digest,
    ),
    pull_request_document: None,
    cancellation_request: rebound_rehearsal.cancellation_request.map(fn(
      request,
    ) {
      {
        ..request,
        cause: @workflow.GoalCancellationCause::GoalCancellationEvidenceOnlyCompleted(
          required_rehearsal_reference.completion_binding_digest,
          qualification_assurance_digest,
        ),
      }
    }),
  }
  let failed_rehearsal_execution = {
    ..required_rehearsal_execution,
    goal: {
      ..required_rehearsal_execution.goal,
      lifecycle: @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalIntegrityBlocked,
      ),
    },
    state: @workflow.GoalExecutionState::GoalExecutionBlocked,
    cancellation_request: None,
    work_order_id: None,
  }
  assert_true(
    @workflow.validate_rehearsal_admission(
      required_contract_ref, sampled_inventory_digest, required_rehearsal_reference,
      failed_rehearsal_execution, assured,
    )
    is Err(_),
  )
  let required_acceptance = {
    ..migration_acceptance,
    contract_ref: required_contract_ref,
  }
  assert_true(
    @workflow.validate_migration_production_admission(
      required_contract,
      required_acceptance,
      judge_definition,
      judge_report,
      qualification_reference,
      succeeded_qualification,
      assured,
      Some(required_rehearsal_reference),
      Some(required_rehearsal_execution),
      Some(assured),
    )
    is Ok(_),
  )
  let revised_contract = { ..required_contract, revision: 2 }
  let revised_acceptance = {
    ..required_acceptance,
    contract_ref: @migration.migration_contract_reference(revised_contract).unwrap(),
  }
  assert_true(
    @workflow.validate_migration_production_admission(
      revised_contract,
      revised_acceptance,
      judge_definition,
      judge_report,
      qualification_reference,
      succeeded_qualification,
      assured,
      Some(required_rehearsal_reference),
      Some(required_rehearsal_execution),
      Some(assured),
    )
    is Err(_),
  )
  let user_canceled_rehearsal = {
    ..rebound_rehearsal,
    cancellation_request: rebound_rehearsal.cancellation_request.map(fn(
      request,
    ) {
      {
        ..request,
        cause: @workflow.GoalCancellationCause::GoalCancellationUserRequested,
      }
    }),
  }
  assert_true(
    @workflow.validate_rehearsal_admission(
      migration_contract_ref, sampled_inventory_digest, rehearsal_reference, user_canceled_rehearsal,
      assured,
    )
    is Err(_),
  )
  assert_true(
    @workflow.initialize_goal_publication(
      evidence_only_execution,
      assured,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      @workflow.RemoteName("origin"),
      @workflow.GitRefName("refs/heads/choir/goals/assurance"),
      None,
    )
    is Err(_),
  )
  let publication = match
    @workflow.initialize_goal_publication(
      assured_execution,
      assured,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      @workflow.RemoteName("origin"),
      @workflow.GitRefName("refs/heads/choir/goals/assurance"),
      None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    publication.intent.state,
    @workflow.BranchPublicationState::BranchPublicationPlanned,
  )
  let authorized_publication = match
    @workflow.authorize_goal_publication(
      publication,
      assured_execution,
      assured,
      promotion.commit_oid,
      @workflow.RemoteBranchObservation::RemoteBranchAbsent,
      false,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let published = match
    @workflow.record_goal_publication_observation(
      authorized_publication,
      @workflow.RemoteBranchObservation::RemoteBranchAt(promotion.commit_oid),
      @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
      None,
      39L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    published.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  guard published.receipt is Some(publication_receipt) else {
    fail("publication receipt is absent")
  }
  assert_eq(publication_receipt.published_oid, promotion.commit_oid)
  let published_status = match
    @workflow.goal_status_report(
      assured_execution,
      [integrated],
      Some(assured),
      Some(published),
      None,
      None,
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    published_status.publication_state,
    Some(@workflow.BranchPublicationState::BranchPublicationReceipted),
  )
  assert_true(published_status.publication_receipt_present)
  assert_eq(published_status.published_oid, Some(promotion.commit_oid))
  match
    @workflow.decode_goal_publication_record(
      @workflow.goal_publication_record_bytes(published),
    ) {
    Ok(decoded) => assert_eq(decoded, published)
    Err(error) => fail(error.message())
  }
  // A receipted publication is a maximal instance of the record — its one
  // optional field is populated — so it is the oracle the shape manifest is
  // checked against. Asserted here rather than in the manifest test because
  // this is where the workflow produces one.
  assert_manifest_names_stored_keys(
    "GoalPublicationRecord",
    @workflow.goal_publication_record_bytes(published),
  )
  let drifted = match
    @workflow.authorize_goal_publication(
      publication,
      assured_execution,
      assured,
      promotion.commit_oid,
      @workflow.RemoteBranchObservation::RemoteBranchAt(
        @control.GitOid("other-remote-head"),
      ),
      false,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    drifted.intent.state,
    @workflow.BranchPublicationState::BranchPublicationDrift,
  )
  let abandoned_publication = @workflow.record_goal_publication_cancellation(
    publication,
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
    39L,
  ).unwrap()
  assert_eq(
    abandoned_publication.intent.state,
    @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation,
  )
  assert_true(
    @workflow.goal_publication_cancellation_disposition_is_known(
      abandoned_publication,
    ),
  )
  let cancellation_witnessed_publication = @workflow.record_goal_publication_cancellation(
    authorized_publication,
    @workflow.RemoteBranchObservation::RemoteBranchAt(promotion.commit_oid),
    40L,
  ).unwrap()
  assert_eq(
    cancellation_witnessed_publication.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  assert_true(
    @workflow.goal_publication_cancellation_disposition_is_known(
      cancellation_witnessed_publication,
    ),
  )
  let preflight_uncertain = @workflow.authorize_goal_publication(
    publication,
    assured_execution,
    assured,
    promotion.commit_oid,
    @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
    false,
  ).unwrap()
  assert_eq(
    preflight_uncertain.intent.state,
    @workflow.BranchPublicationState::BranchPublicationPreflightUncertain,
  )
  let preflight_recovered = @workflow.authorize_goal_publication(
    preflight_uncertain,
    assured_execution,
    assured,
    promotion.commit_oid,
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
    false,
  ).unwrap()
  assert_eq(
    preflight_recovered.intent.state,
    @workflow.BranchPublicationState::BranchPublicationAuthorized,
  )
  let mutation_uncertain = @workflow.record_goal_publication_observation(
    authorized_publication,
    @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
    @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
    None,
    40L,
  ).unwrap()
  assert_eq(
    mutation_uncertain.intent.state,
    @workflow.BranchPublicationState::BranchPublicationMutationUncertain,
  )
  let mutation_recovered = @workflow.record_goal_publication_observation(
    mutation_uncertain,
    @workflow.RemoteBranchObservation::RemoteBranchAt(promotion.commit_oid),
    @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
    None,
    41L,
  ).unwrap()
  assert_eq(
    mutation_recovered.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  let pr_marker = match
    @workflow.goal_pull_request_identity_marker(
      assured_execution,
      published,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let pr_document : @workflow.PullRequestDocument = {
    title: "feat: complete assurance Goal",
    body: "Goal evidence\n\n" + pr_marker.0,
    draft: false,
  }
  assert_true(
    @workflow.initialize_goal_pull_request(
      evidence_only_execution,
      assured,
      published,
      @workflow.PullRequestProvider::GitHubPullRequestProvider,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      pr_document,
    )
    is Err(_),
  )
  let pull_request = match
    @workflow.initialize_goal_pull_request(
      assured_execution,
      assured,
      published,
      @workflow.PullRequestProvider::GitHubPullRequestProvider,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      pr_document,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestPlanned,
  )
  let stacked_base = @workflow.GitRefName("refs/heads/choir/goals/parent-stack")
  let stacked_execution = {
    ..assured_execution,
    integration_target_ref: stacked_base,
  }
  let stacked_marker = match
    @workflow.goal_pull_request_identity_marker(
      stacked_execution,
      published,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let stacked_pull_request = match
    @workflow.initialize_goal_pull_request(
      stacked_execution,
      assured,
      published,
      @workflow.PullRequestProvider::GitHubPullRequestProvider,
      @workflow.RemoteRepositoryId("remote-repository-assurance"),
      {
        title: "feat: stack dependent Goal",
        body: "Stacks on its open dependency.\n\n" + stacked_marker.0,
        draft: false,
      },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(stacked_pull_request.intent.base_ref, stacked_base)
  let remote_pull_request : @workflow.RemotePullRequestSnapshot = {
    remote_id: @workflow.RemotePullRequestId("PR_kwDO_assurance"),
    number: @workflow.PullRequestNumber(42),
    url: @workflow.PullRequestUrl("https://example.invalid/choir/pull/42"),
    provider_repository_id: published.intent.canonical_repository_id,
    head_repository_id: published.intent.canonical_repository_id,
    head_ref: published.intent.remote_head_ref,
    base_repository_id: @workflow.RemoteRepositoryId(
      "remote-repository-assurance",
    ),
    base_ref: assured_execution.integration_target_ref,
    observed_head_oid: promotion.commit_oid,
    state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
    draft: false,
    auto_merge_enabled: false,
    marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
    title_digest: @storage.artifact_digest(@utf8.encode(pr_document.title)),
    body_digest: @storage.artifact_digest(@utf8.encode(pr_document.body)),
  }
  let authorized_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestNoMatch,
      40L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    authorized_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestAuthorized,
  )
  let issued_pull_request = match
    @workflow.mark_goal_pull_request_create_may_have_been_issued(
      authorized_pull_request, assured_execution, assured, published,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let uncertain_pull_request = match
    @workflow.reconcile_goal_pull_request_after_create(
      issued_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestNoMatch,
      41L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    uncertain_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain,
  )
  // An uncertain remote keeps the Goal canceling: releasing claims here could
  // strand a pull request the forge still has authority to merge.
  assert_false(
    @workflow.goal_pull_request_cancellation_disposition_is_known(
      uncertain_pull_request,
    ),
  )
  let cancellation_witnessed_pull_request = @workflow.record_goal_pull_request_cancellation(
    uncertain_pull_request,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
      remote_pull_request,
    ),
    42L,
  ).unwrap()
  assert_eq(
    cancellation_witnessed_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestReceipted,
  )
  assert_eq(
    cancellation_witnessed_pull_request.intent.cancellation_state,
    @workflow.PullRequestCancellationState::PullRequestCancellationPlanned,
  )
  assert_false(
    @workflow.goal_pull_request_cancellation_disposition_is_known(
      cancellation_witnessed_pull_request,
    ),
  )
  let abandoned_pull_request = @workflow.record_goal_pull_request_cancellation(
    authorized_pull_request,
    @workflow.PullRequestLookupObservation::PullRequestNoMatch,
    42L,
  ).unwrap()
  assert_eq(
    abandoned_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestAbandonedByCancellation,
  )
  let adopted_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        remote_pull_request,
      ),
      42L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    adopted_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestReceipted,
  )
  let automatic_pull_request = @workflow.initialize_goal_pull_request(
    assured_execution,
    assured,
    published,
    @workflow.PullRequestProvider::GitHubPullRequestProvider,
    @workflow.RemoteRepositoryId("remote-repository-assurance"),
    pr_document,
    delivery_policy={
      mode: @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
    },
  ).unwrap()
  let automatic_receipted = @workflow.authorize_goal_pull_request(
    automatic_pull_request,
    assured_execution,
    assured,
    published,
    promotion.commit_oid,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
      remote_pull_request,
    ),
    43L,
  ).unwrap()
  assert_eq(
    automatic_receipted.intent.merge_state,
    @workflow.PullRequestMergeState::PullRequestMergePlanned,
  )
  let merge_authorized = @workflow.authorize_goal_pull_request_merge(
    automatic_receipted,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
      remote_pull_request,
    ),
  ).unwrap()
  assert_eq(
    merge_authorized.intent.merge_state,
    @workflow.PullRequestMergeState::PullRequestMergeAuthorized,
  )
  let merge_issued = @workflow.mark_goal_pull_request_merge_may_have_been_issued(
    merge_authorized,
  ).unwrap()
  let merge_enabled = @workflow.reconcile_goal_pull_request_merge(
    merge_issued,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
      ..remote_pull_request,
      auto_merge_enabled: true,
    }),
  ).unwrap()
  assert_eq(
    merge_enabled.intent.merge_state,
    @workflow.PullRequestMergeState::PullRequestMergeEnabled,
  )
  let awaiting_merge = @workflow.observe_goal_pull_request_readiness(
    assured_execution,
    assured,
    published,
    merge_enabled,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
      ..remote_pull_request,
      auto_merge_enabled: true,
    }),
    None,
    1L,
    44L,
    44L,
  ).unwrap()
  assert_eq(
    awaiting_merge.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestAwaitingMerge,
  )
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, merge_enabled, awaiting_merge,
    )
    is Err(_),
  )
  let merged_delivery = @workflow.observe_goal_pull_request_readiness(
    assured_execution,
    assured,
    published,
    merge_enabled,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
      ..remote_pull_request,
      state: @workflow.RemotePullRequestState::RemotePullRequestMerged,
      auto_merge_enabled: false,
    }),
    None,
    2L,
    45L,
    45L,
  ).unwrap()
  assert_eq(
    merged_delivery.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReady,
  )
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, merge_enabled, merged_delivery,
    )
    is Ok(_),
  )
  // Draft is presentation state. It never rewrites the checked-in delivery
  // mode, and an automatic-merge Goal that asked for a draft is rejected with
  // retained evidence instead of being downgraded to review-only.
  let draft_document = { ..pr_document, draft: true }
  let draft_automatic = @workflow.initialize_goal_pull_request(
    assured_execution,
    assured,
    published,
    @workflow.PullRequestProvider::GitHubPullRequestProvider,
    @workflow.RemoteRepositoryId("remote-repository-assurance"),
    draft_document,
    delivery_policy={
      mode: @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
    },
  ).unwrap()
  assert_eq(
    draft_automatic.intent.delivery_policy.mode,
    @types.PullRequestDeliveryMode::PullRequestAutoMerge,
  )
  assert_eq(
    draft_automatic.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestDraftUnderAutoMerge,
    ),
  )
  assert_true(
    draft_automatic.intent.merge_state
    is @workflow.PullRequestMergeState::PullRequestMergeRejected(_),
  )
  // The rejected intent never reaches an exact remote pull request, so nothing
  // can adopt it and close source Beads.
  assert_true(
    @workflow.authorize_goal_pull_request(
      draft_automatic,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        draft: true,
      }),
      46L,
    )
    is Err(_),
  )

  // A review-only draft keeps its delivery mode and stays nonterminal until it
  // is observed ready for review.
  let draft_review_only = @workflow.initialize_goal_pull_request(
    assured_execution,
    assured,
    published,
    @workflow.PullRequestProvider::GitHubPullRequestProvider,
    @workflow.RemoteRepositoryId("remote-repository-assurance"),
    draft_document,
  ).unwrap()
  let draft_receipted = @workflow.authorize_goal_pull_request(
    draft_review_only,
    assured_execution,
    assured,
    published,
    promotion.commit_oid,
    @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
      ..remote_pull_request,
      draft: true,
    }),
    47L,
  ).unwrap()
  let awaiting_review = @workflow.observe_goal_pull_request_readiness(
    assured_execution,
    assured,
    published,
    draft_receipted,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
      ..remote_pull_request,
      draft: true,
    }),
    None,
    1L,
    48L,
    48L,
  ).unwrap()
  assert_eq(
    awaiting_review.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestAwaitingReview,
  )
  assert_eq(awaiting_review.readiness.observed_draft, Some(true))
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, draft_receipted, awaiting_review,
    )
    is Err(_),
  )
  // Ready for review advances at the configured boundary.
  let ready_for_review = @workflow.observe_goal_pull_request_readiness(
    assured_execution,
    assured,
    published,
    draft_receipted,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
      remote_pull_request,
    ),
    None,
    2L,
    49L,
    49L,
  ).unwrap()
  assert_eq(
    ready_for_review.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReady,
  )
  assert_eq(ready_for_review.readiness.observed_draft, Some(false))
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, draft_receipted, ready_for_review,
    )
    is Ok(_),
  )
  // Cancellation of the review-only draft still binds to the exact remote
  // identity: a foreign pull request neutralizes nothing.
  let draft_canceling = @workflow.record_goal_pull_request_cancellation(
    draft_receipted,
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
      ..remote_pull_request,
      draft: true,
    }),
    50L,
  ).unwrap()
  assert_false(
    @workflow.goal_pull_request_cancellation_disposition_is_known(
      draft_canceling,
    ),
  )
  match
    @workflow.authorize_goal_pull_request_neutralization(
      draft_canceling,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        remote_id: @workflow.RemotePullRequestId("PR_other_draft"),
        draft: true,
      }),
    ) {
    Ok(value) => assert_eq(value, draft_canceling)
    Err(error) => fail(error.message())
  }
  guard adopted_pull_request.receipt is Some(pull_request_receipt) else {
    fail("pull request receipt is absent")
  }
  assert_eq(pull_request_receipt.number, @workflow.PullRequestNumber(42))
  assert_eq(
    pull_request_receipt.origin,
    @workflow.PullRequestReceiptOrigin::PullRequestAdopted,
  )
  let pull_request_status = match
    @workflow.goal_status_report(
      assured_execution,
      [integrated],
      Some(assured),
      Some(published),
      Some(adopted_pull_request),
      None,
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    pull_request_status.pull_request_state,
    Some(@workflow.PullRequestIntentState::PullRequestReceipted),
  )
  assert_true(pull_request_status.pull_request_receipt_present)
  assert_eq(
    pull_request_status.pull_request_number,
    Some(@workflow.PullRequestNumber(42)),
  )
  let finalization = match
    @workflow.observe_goal_pull_request_readiness(
      assured_execution,
      assured,
      published,
      adopted_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
        remote_pull_request,
      ),
      Some("remote-version-42"),
      1L,
      46L,
      47L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    finalization.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReady,
  )
  let final_status = match
    @workflow.goal_status_report(
      assured_execution,
      [integrated],
      Some(assured),
      Some(published),
      Some(adopted_pull_request),
      Some(finalization),
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    final_status.readiness_decision,
    Some(@workflow.PullRequestReadinessDecision::PullRequestReady),
  )
  assert_true(final_status.semantic_run_projection is None)
  match
    @workflow.decode_goal_finalization_record(
      @workflow.goal_finalization_record_bytes(finalization),
    ) {
    Ok(decoded) => assert_eq(decoded, finalization)
    Err(error) => fail(error.message())
  }
  assert_manifest_names_stored_keys(
    "GoalFinalizationRecord",
    @workflow.goal_finalization_record_bytes(finalization),
  )
  // An open, exact pull request is the deliverable: success authorizes
  // directly from Assured, with no merge observation.
  let succeeded = match
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, adopted_pull_request, finalization,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    succeeded.state,
    @workflow.GoalExecutionState::GoalExecutionSucceeded,
  )
  let succeeded_status = match
    @workflow.goal_status_report(
      succeeded,
      [integrated],
      Some(assured),
      Some(published),
      Some(adopted_pull_request),
      Some(finalization),
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard succeeded_status.semantic_run_projection is Some(projection) else {
    fail("successful Goal semantic projection is absent")
  }
  assert_eq(projection.accepted_part_ids, [integrated.part.id])
  assert_eq(projection.dependency_edges, [])
  assert_eq(projection.ordered_parts.length(), 1)
  assert_eq(projection.ordered_parts[0].part_id, integrated.part.id)
  assert_eq(
    projection.ordered_parts[0].task_contract_digest,
    integrated.task_contract.digest,
  )
  assert_eq(
    projection.ordered_parts[0].candidate_change_digest,
    integrated.candidate.unwrap().canonical_change_digest,
  )
  assert_eq(projection.ordered_parts[0].verification_results.length(), 1)
  assert_eq(
    projection.ordered_parts[0].audit_outcome,
    @control.AuditOutcome::AuditPassed,
  )
  assert_eq(projection.promotions, [
    {
      part_id: integrated.part.id,
      rank: 1,
      resulting_tree_oid: promotion.tree_oid,
    },
  ])
  assert_eq(projection.final_tree_oid, promotion.tree_oid)
  assert_eq(projection.goal_verification_results.length(), 1)
  assert_eq(
    projection.combined_audit_outcome,
    @control.AuditOutcome::AuditPassed,
  )
  assert_eq(projection.receipt_cardinalities, {
    part_verification: 1,
    part_audit: 1,
    integration: 1,
    goal_verification: 1,
    goal_audit: 1,
    publication: 1,
    pull_request: 1,
  })
  assert_eq(
    projection.terminal_goal_outcome,
    @workflow.GoalExecutionState::GoalExecutionSucceeded,
  )
  let semantic_json = projection.to_json().stringify(indent=0)
  assert_false(semantic_json.contains(integrated.implementation_take.id.0))
  assert_false(semantic_json.contains(integrated.verification_take.id.0))
  assert_false(semantic_json.contains(integrated.audit_take.id.0))
  assert_false(
    semantic_json.contains(integrated.audit_receipt.unwrap().receipt_id.0),
  )
  assert_false(semantic_json.contains(publication_receipt.receipt_id.0))
  assert_false(semantic_json.contains(pull_request_receipt.receipt_id.0))
  assert_false(semantic_json.contains(pull_request_receipt.url.0))
  assert_false(
    semantic_json.contains(integrated.candidate.unwrap().commit_oid.0),
  )
  assert_false(semantic_json.contains(promotion.commit_oid.0))
  assert_false(semantic_json.contains("codex-cli"))
  let other_concurrency_status = @workflow.goal_status_report(
    { ..succeeded, maximum_parallel_parts: 4 },
    [integrated],
    Some(assured),
    Some(published),
    Some(adopted_pull_request),
    Some(finalization),
    provider_capacity=None,
  ).unwrap()
  assert_eq(other_concurrency_status.semantic_run_projection, Some(projection))
  let edited_prose = match
    @workflow.observe_goal_pull_request_readiness(
      assured_execution,
      assured,
      published,
      adopted_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
        ..remote_pull_request,
        title_digest: @storage.artifact_digest(@utf8.encode("edited title")),
        body_digest: @storage.artifact_digest(@utf8.encode("edited body")),
      }),
      None,
      2L,
      48L,
      49L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    edited_prose.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReady,
  )
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, adopted_pull_request, edited_prose,
    )
    is Ok(_),
  )
  let missing_marker = match
    @workflow.observe_goal_pull_request_readiness(
      assured_execution,
      assured,
      published,
      adopted_pull_request,
      @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch({
        ..remote_pull_request,
        marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerMissing,
      }),
      None,
      3L,
      50L,
      51L,
    ) {
    Ok(value) => value
    Err(error) => fail("missing-marker observation: " + error.message())
  }
  assert_eq(
    missing_marker.readiness.decision,
    @workflow.PullRequestReadinessDecision::PullRequestReadinessDrift(
      @workflow.PullRequestReadinessDriftReason::PullRequestCanonicalIdentityChanged,
    ),
  )
  assert_true(
    @workflow.authorize_goal_execution_success(
      assured_execution, assured, published, adopted_pull_request, missing_marker,
    )
    is Err(_),
  )
  match
    @workflow.decode_goal_pull_request_record(
      @workflow.goal_pull_request_record_bytes(adopted_pull_request),
    ) {
    Ok(decoded) => assert_eq(decoded, adopted_pull_request)
    Err(error) => fail(error.message())
  }
  assert_manifest_names_stored_keys(
    "GoalPullRequestRecord",
    @workflow.goal_pull_request_record_bytes(adopted_pull_request),
  )
  let ambiguous_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches,
      43L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    ambiguous_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestAmbiguousIdentity,
    ),
  )
  let drifted_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        observed_head_oid: @control.GitOid("other-pr-head"),
      }),
      44L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    drifted_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteDrift,
    ),
  )
  let edited_title_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        title_digest: @storage.artifact_digest(@utf8.encode("edited title")),
      }),
      44L,
    ) {
    Ok(value) => value
    Err(error) => fail("edited-title adoption: " + error.message())
  }
  assert_eq(
    edited_title_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteDrift,
    ),
  )
  let edited_body_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        body_digest: @storage.artifact_digest(
          @utf8.encode("edited body\n" + pr_marker.0),
        ),
      }),
      44L,
    ) {
    Ok(value) => value
    Err(error) => fail("edited-body adoption: " + error.message())
  }
  assert_eq(
    edited_body_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteDrift,
    ),
  )
  let retargeted_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        base_ref: @workflow.GitRefName("refs/heads/release"),
      }),
      44L,
    ) {
    Ok(value) => value
    Err(error) => fail("retargeted adoption: " + error.message())
  }
  assert_eq(
    retargeted_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteDrift,
    ),
  )
  let closed_pull_request = match
    @workflow.authorize_goal_pull_request(
      pull_request,
      assured_execution,
      assured,
      published,
      promotion.commit_oid,
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..remote_pull_request,
        state: @workflow.RemotePullRequestState::RemotePullRequestClosed,
      }),
      45L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(
    closed_pull_request.intent.state,
    @workflow.PullRequestIntentState::PullRequestNeedsInput(
      @workflow.PullRequestNeedsInputReason::PullRequestRemoteClosed,
    ),
  )
  assert_true(closed_pull_request.receipt is Some(_))
  match
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(assured),
    ) {
    Ok(decoded) => assert_eq(decoded, assured)
    Err(error) => fail(error.message())
  }
  // An audited record has no pending effect and no block reason — a record is
  // not simultaneously blocked and mid-effect — so the maximal instance is
  // `assured` carrying the two the same drive produced elsewhere. Still a
  // workflow product rather than a hand-written literal.
  assert_manifest_names_stored_keys(
    "GoalAssuranceRecord",
    @workflow.goal_assurance_record_bytes({
      ..assured,
      pending_effect: planned_effect.pending_effect,
      blocked_reason: blocked_by_findings.blocked_reason,
    }),
  )
  let corrupted = { ..assured, base_commit_oid: @control.GitOid("other-base") }
  assert_true(
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(corrupted),
    )
    is Err(_),
  )
}

///|
test "cancellation preserves an authorized integration for reconciliation" {
  let authorized = authorize_next(drive_to_integration_authorized())
  guard authorized.pending_effect is Some(effect) else {
    fail("authorized integration has no pending effect")
  }
  assert_true(effect.kind is @workflow.PartEffectKind::ApplyIntegration(_, _))
  assert_eq(
    effect.lifecycle,
    @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
  )
  let canceled = match @workflow.record_part_goal_cancellation(authorized) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard canceled.pending_effect is Some(pending) else {
    fail("cancellation discarded the unresolved integration")
  }
  assert_eq(pending, effect)
  assert_false(@workflow.part_cancellation_disposition_is_known(canceled))
  let repeated = match @workflow.record_part_goal_cancellation(canceled) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(repeated, canceled)
}

///|
test "verified Part cannot plan or authorize integration without audit" {
  let snapshot = drive_to_verified()
  match @workflow.plan_next_part_effect(snapshot) {
    Ok(Some({ kind: @workflow.PartEffectKind::PrepareAuditSandbox(_), .. })) =>
      ()
    _ => fail("verified Part did not require the audit Take")
  }
  let reads = @ref.new(0)
  assert_true(
    @workflow.authorize_part_integration(
      snapshot,
      workflow_digest_e,
      snapshot.identities.verification_sandbox.runtime_policy_digest,
      fn(_) {
        reads.val = reads.val + 1
        true
      },
      fn(_) {
        reads.val = reads.val + 1
        true
      },
    )
    is Err(_),
  )
  assert_eq(reads.val, 0)
  assert_true(
    @workflow.plan_part_integration(snapshot, {
      lease: {
        id: @control.IntegrationLeaseId("lease-invalid"),
        goal_id: snapshot.goal.id,
        fencing_epoch: snapshot.fencing_epoch,
        holder: "choird-test",
      },
      intent_id: @control.IntegrationIntentId("intent-invalid"),
      expected_goal_head_oid: @control.GitOid("goal-head"),
      promotion_metadata_digest: workflow_digest_a,
      git_witness_ref: "refs/choir/witness/intent-invalid",
    })
    is Err(_),
  )
}

///|
test "promotion conflict blocks the Part without minting integration evidence" {
  let audited = drive_to_audited()
  let planned = match
    @workflow.plan_part_integration(audited, {
      lease: {
        id: @control.IntegrationLeaseId("integration-lease-conflict"),
        goal_id: audited.goal.id,
        fencing_epoch: audited.fencing_epoch,
        holder: "choird-test",
      },
      intent_id: @control.IntegrationIntentId("integration-intent-conflict"),
      expected_goal_head_oid: @control.GitOid("goal-head"),
      promotion_metadata_digest: workflow_digest_c,
      git_witness_ref: "refs/choir/witness/integration-intent-conflict",
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let blocked = apply_observation(
    planned,
    @workflow.PartEffectObservation::PromotionConflictObserved({
      id: @control.IntegrationConflictId("conflict-1"),
      intent_id: @control.IntegrationIntentId("integration-intent-conflict"),
      candidate_id: planned.candidate.unwrap().id,
      candidate_commit_oid: planned.candidate.unwrap().commit_oid,
      expected_goal_head_oid: @control.GitOid("goal-head"),
      expected_goal_head_tree_oid: @control.GitOid("goal-head-tree"),
      merge_base_oid: planned.candidate.unwrap().base_commit_oid,
      conflicting_paths: [@control.RepoPath("src/feature.mbt")],
      evidence_digest: workflow_digest_a,
    }),
    26L,
  )
  assert_eq(blocked.stage, @workflow.PartWorkflowStage::PartBlocked)
  assert_true(
    blocked.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict
    ),
  )
  guard blocked.integration_intent is Some(intent) else {
    fail("conflicted integration intent is absent")
  }
  assert_eq(
    intent.lifecycle,
    @control.IntegrationIntentLifecycle::IntegrationConflict,
  )
  assert_true(blocked.integration_receipt is None)
  assert_eq(blocked.integration_conflicts.length(), 1)
  assert_eq(blocked.effect_receipts.length(), 12)
  let conflict = blocked.integration_conflicts[0]
  let repair_contract : @control.TaskContractRevision = {
    ..blocked.task_contract,
    id: @control.RevisionId("revision-2"),
    revision: 2,
    digest: workflow_digest_d,
    repair_conflict_id: Some(conflict.id),
    repair_audit: None,
    repair_verification: None,
    base_commit_oid: conflict.expected_goal_head_oid,
    base_tree_oid: conflict.expected_goal_head_tree_oid,
  }
  let implementation = {
    ..workflow_take(
      "implementation-take-2",
      @control.TakePurpose::Implementation(blocked.part.id, repair_contract.id),
    ),
    ordinal: 2,
  }
  let verification = {
    ..workflow_take(
      "verification-take-2",
      @control.TakePurpose::PartVerification(
        blocked.part.id,
        implementation.id,
        workflow_digest_d,
      ),
    ),
    ordinal: 2,
  }
  let audit = {
    ..workflow_take(
      "audit-take-2",
      @control.TakePurpose::PartAudit(
        blocked.part.id,
        implementation.id,
        repair_contract.audit_policy_digest,
      ),
    ),
    ordinal: 2,
  }
  let implementation_sandbox = workflow_sandbox(
    "implementation-sandbox-2",
    "implementation-generation-2",
    implementation.id,
    repair_contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let verification_sandbox = workflow_sandbox(
    "verification-sandbox-2",
    "verification-generation-2",
    verification.id,
    repair_contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let audit_sandbox = workflow_sandbox(
    "audit-sandbox-2",
    "audit-generation-2",
    audit.id,
    repair_contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let repair = match
    @workflow.plan_part_conflict_repair(
      blocked,
      repair_contract,
      {
        implementation_take: implementation,
        implementation_sandbox,
        implementation_session: workflow_session(
          "implementation-session-2",
          implementation.id,
          implementation_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_a,
        ),
        verification_take: verification,
        verification_sandbox,
        audit_take: audit,
        audit_sandbox,
        audit_session: workflow_session(
          "audit-session-2",
          audit.id,
          audit_sandbox.generation_id,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          workflow_digest_c,
        ),
      },
      fn(_) { true },
    ) {
    Ok(@workflow.PartConflictRepairDecision::PartConflictRepairPlanned(value)) =>
      value
    Ok(_) => fail("first conflict repair reached the retry limit")
    Err(error) => fail(error.message())
  }
  assert_eq(repair.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(repair.task_contract, repair_contract)
  assert_eq(repair.task_contract_history.length(), 2)
  assert_eq(repair.prior_takes.length(), 3)
  assert_eq(repair.prior_take_evidence.length(), 1)
  assert_eq(repair.prior_take_evidence[0].candidate, blocked.candidate)
  assert_eq(repair.prior_take_evidence[0].audit_receipt, blocked.audit_receipt)
  assert_eq(repair.integration_conflicts, [conflict])
  assert_true(repair.candidate is None)
  assert_true(repair.verification_receipts.length() == 0)
  assert_true(repair.audit_receipt is None)
  assert_true(repair.integration_intent is None)
  assert_eq(
    repair.part.lifecycle,
    @control.PartLifecycle::PartExecuting(implementation.id),
  )
  // A user retry refuses integration conflicts (they require conflict
  // repair) but re-arms any other block reason under the same contract.
  let retry_implementation = {
    ..workflow_take(
      "implementation-take-3",
      @control.TakePurpose::Implementation(
        blocked.part.id,
        blocked.task_contract.id,
      ),
    ),
    ordinal: 2,
  }
  let retry_verification = {
    ..workflow_take(
      "verification-take-3",
      @control.TakePurpose::PartVerification(
        blocked.part.id,
        retry_implementation.id,
        blocked.task_contract.verification_specs[0].digest,
      ),
    ),
    ordinal: 2,
  }
  let retry_audit = {
    ..workflow_take(
      "audit-take-3",
      @control.TakePurpose::PartAudit(
        blocked.part.id,
        retry_implementation.id,
        blocked.task_contract.audit_policy_digest,
      ),
    ),
    ordinal: 2,
  }
  let retry_implementation_sandbox = workflow_sandbox(
    "implementation-sandbox-3",
    "implementation-generation-3",
    retry_implementation.id,
    blocked.task_contract.implementation_capability_profile_digest,
    workflow_digest_a,
  )
  let retry_verification_sandbox = workflow_sandbox(
    "verification-sandbox-3",
    "verification-generation-3",
    retry_verification.id,
    blocked.task_contract.verification_capability_profile_digest,
    workflow_digest_d,
  )
  let retry_audit_sandbox = workflow_sandbox(
    "audit-sandbox-3",
    "audit-generation-3",
    retry_audit.id,
    blocked.task_contract.audit_capability_profile_digest,
    workflow_digest_e,
  )
  let retry_identities : @workflow.PartIdentityPlan = {
    implementation_take: retry_implementation,
    implementation_sandbox: retry_implementation_sandbox,
    implementation_session: workflow_session(
      "implementation-session-3",
      retry_implementation.id,
      retry_implementation_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_a,
    ),
    verification_take: retry_verification,
    verification_sandbox: retry_verification_sandbox,
    audit_take: retry_audit,
    audit_sandbox: retry_audit_sandbox,
    audit_session: workflow_session(
      "audit-session-3",
      retry_audit.id,
      retry_audit_sandbox.generation_id,
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      workflow_digest_c,
    ),
  }
  assert_true(
    @workflow.plan_part_retry(blocked, retry_identities, fn(_) { true })
    is Err(_),
  )
  let verification_blocked = {
    ..blocked,
    part: {
      ..blocked.part,
      lifecycle: @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartVerificationFailed,
      ),
    },
  }
  let retried = match
    @workflow.plan_part_retry(verification_blocked, retry_identities, fn(_) {
      true
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(retried.stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(retried.task_contract, verification_blocked.task_contract)
  assert_eq(
    retried.task_contract_history,
    verification_blocked.task_contract_history,
  )
  assert_eq(retried.prior_takes.length(), 3)
  assert_eq(retried.prior_take_evidence.length(), 1)
  assert_eq(
    retried.part.lifecycle,
    @control.PartLifecycle::PartExecuting(retry_implementation.id),
  )
  assert_eq(retried.durable_version, verification_blocked.durable_version + 1)
}

///|
test "planned and authorized effects survive snapshot restart exactly once" {
  let initial = workflow_fixture()
  let intent = match @workflow.plan_next_part_effect(initial) {
    Ok(Some(value)) => value
    _ => fail("expected initial sandbox effect")
  }
  let planned = match @workflow.persist_planned_part_effect(initial, intent) {
    Ok(value) => round_trip(value)
    Err(error) => fail(error.message())
  }
  match @workflow.plan_next_part_effect(planned) {
    Ok(Some(recovered)) => assert_eq(recovered, intent)
    _ => fail("planned effect did not survive restart")
  }
  let authorized = match
    @workflow.authorize_pending_part_effect(planned, fn(_) { true }) {
    Ok(value) => round_trip(value)
    Err(error) => fail(error.message())
  }
  match @workflow.plan_next_part_effect(authorized) {
    Ok(Some(recovered)) => {
      assert_eq(recovered.effect_id, intent.effect_id)
      assert_eq(recovered.request_digest, intent.request_digest)
      assert_eq(
        recovered.lifecycle,
        @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
      )
    }
    _ => fail("authorized effect was not recoverable")
  }
  let observed = match
    @workflow.apply_part_effect_observation(
      authorized,
      @workflow.PartEffectObservation::ImplementationSandboxPrepared(
        active_sandbox(initial.identities.implementation_sandbox),
      ),
      10L,
      fn(_) { true },
      fn(_) { true },
    ) {
    Ok(value) => round_trip(value)
    Err(error) => fail(error.message())
  }
  assert_eq(observed.effect_receipts.length(), 1)
  assert_true(observed.pending_effect is None)
  match @workflow.plan_next_part_effect(observed) {
    Ok(Some(next)) => assert_true(next.effect_id != intent.effect_id)
    _ => fail("workflow did not advance after receipting the observation")
  }
}

///|
fn uncertain_implementation_dispatch() -> @workflow.PartWorkflowSnapshot raise {
  let initial = workflow_fixture()
  let implementation_session = started_session(
    initial.identities.implementation_session,
  )
  let prepared = apply_observation(
    initial,
    @workflow.PartEffectObservation::ImplementationSandboxPrepared(
      active_sandbox(initial.identities.implementation_sandbox),
    ),
    10L,
  )
  let running = apply_observation(
    apply_command_preparation(prepared, 11L),
    @workflow.PartEffectObservation::ImplementationHarnessStarted(
      implementation_session,
    ),
    11L,
  )
  let authorized = authorize_next(running)
  let intent = match authorized.pending_effect {
    Some(value) => value
    None => fail("implementation dispatch was not authorized")
  }
  @workflow.record_part_event_ingestion_overflow(
    authorized,
    intent,
    "harness event ingestion overflowed",
    observed_at=12L,
  ).unwrap()
}

///|
test "ownership violation gets one bounded repair without widening its contract" {
  let initial = workflow_fixture()
  let blocked = {
    ..initial,
    stage: @workflow.PartWorkflowStage::PartBlocked,
    part: {
      ..initial.part,
      lifecycle: @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartOwnershipViolation,
      ),
    },
    pending_effect: None,
    dispatch_diagnostic: Some({
      take_id: initial.implementation_take.id,
      session_id: None,
      reason: None,
      detail: "candidate failed normalization: [\"CandidateOwnershipViolation\"]",
      recovery: None,
      availability: @control.ProviderAvailability::ProviderAvailable,
      observed_at: 10L,
    }),
  }
  let planned = match
    @workflow.plan_part_ownership_repair(
      blocked,
      workflow_revision_identities(blocked, blocked.task_contract),
      fn(_) { true },
    ) {
    Ok(@workflow.PartOwnershipRepairDecision::PartOwnershipRepairPlanned(value)) =>
      value
    Ok(_) => fail("first ownership repair was exhausted")
    Err(error) => fail(error.message())
  }
  assert_eq(planned.task_contract, blocked.task_contract)
  assert_eq(planned.prior_take_evidence.length(), 1)
  assert_eq(planned.prior_take_evidence[0].candidate, blocked.candidate)
  let exhausted = {
    ..blocked,
    prior_takes: Array::make(
      @workflow.maximum_part_recovery_retries() * 3,
      blocked.implementation_take,
    ),
  }
  assert_eq(
    @workflow.plan_part_ownership_repair(
      exhausted,
      workflow_revision_identities(exhausted, exhausted.task_contract),
      fn(_) { true },
    ).unwrap(),
    @workflow.PartOwnershipRepairDecision::PartOwnershipRepairLimitReached,
  )
}

///|
test "every Goal assurance block names its bounded repair owner" {
  assert_eq(
    @workflow.unattended_goal_assurance_block_disposition(
      @workflow.GoalAssuranceBlockReason::GoalAssuranceVerificationBlocked(
        @control.VerificationGateObservation::VerificationGateRejected(
          @control.VerificationGateRejectionReason::VerificationOutcomeNotPassing,
        ),
      ),
    ),
    @workflow.UnattendedGoalAssuranceBlockDisposition::UnattendedGoalAssuranceVerificationRepair,
  )
  assert_eq(
    @workflow.unattended_goal_assurance_block_disposition(
      @workflow.GoalAssuranceBlockReason::GoalAssuranceAuditBlocked(
        @control.AuditGateObservation::AuditGateRejected(
          @control.AuditGateRejectionReason::AuditHasBlockingFindings,
        ),
      ),
    ),
    @workflow.UnattendedGoalAssuranceBlockDisposition::UnattendedGoalAssuranceAuditRepair,
  )
}

///|
test "an uncertain Take that left no candidate is discharged and retryable" {
  let uncertain = uncertain_implementation_dispatch()
  assert_eq(uncertain.stage, @workflow.PartWorkflowStage::PartRecoveryUncertain)
  assert_true(uncertain.candidate is None)
  // The dispatch left no candidate, so it did not occur and the Part returns to
  // the ordinary blocked path rather than parking for a human.
  let reconciled = match
    @workflow.reconcile_part_recovery_uncertainty(uncertain) {
    Ok(
      @workflow.PartUncertaintyReconciliation::PartUncertaintyDischarged(value)
    ) => value
    _ => fail("uncertainty was not discharged")
  }
  assert_eq(reconciled.stage, @workflow.PartWorkflowStage::PartBlocked)
  assert_true(reconciled.pending_effect is None)
  // The block reason stays truthful about why the Part stopped.
  assert_eq(
    reconciled.part.lifecycle,
    @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartRecoveryUncertain,
    ),
  )
  assert_eq(reconciled.durable_version, uncertain.durable_version + 1)
  // The point of discharging: retry accepts the Part afterwards and refuses it
  // before, which is what left recovery-uncertain Parts with no way forward.
  assert_true(
    @workflow.plan_part_retry(
      reconciled,
      workflow_revision_identities(reconciled, reconciled.task_contract),
      fn(_) { true },
    )
    is Ok(_),
  )
  assert_true(
    @workflow.plan_part_retry(
      uncertain,
      workflow_revision_identities(uncertain, uncertain.task_contract),
      fn(_) { true },
    )
    is Err(_),
  )
}

///|
test "an uncertain Take that left a candidate keeps its uncertainty" {
  let uncertain = uncertain_implementation_dispatch()
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId("candidate-uncertain"),
    goal_id: uncertain.goal.id,
    part_id: uncertain.part.id,
    take_id: uncertain.implementation_take.id,
    base_commit_oid: uncertain.task_contract.base_commit_oid,
    commit_oid: @control.GitOid("candidate-commit"),
    tree_oid: @control.GitOid("candidate-tree"),
    canonical_change_digest: workflow_digest_d,
    changed_paths: [@control.RepoPath("src/feature.mbt")],
  }
  // The same uncertain shape, except the dispatch did leave its artifact behind.
  // Discharging here would re-run work that already landed.
  assert_true(
    @workflow.reconcile_part_recovery_uncertainty({
      ..uncertain,
      candidate: Some(candidate),
    })
    is Ok(@workflow.PartUncertaintyReconciliation::PartUncertaintyRetained),
  )
}

///|
test "reconciliation refuses a Part that is not parked on uncertainty" {
  assert_true(
    @workflow.reconcile_part_recovery_uncertainty(workflow_fixture()) is Err(_),
  )
}

///|
test "provider loss with no artifact re-arms the Part without a user message" {
  let uncertain = uncertain_implementation_dispatch()
  let identities = workflow_revision_identities(
    uncertain,
    uncertain.task_contract,
  )
  let recovered = match
    @workflow.plan_part_recovery_retry(uncertain, fn(_) { identities }, fn(_) {
      true
    }) {
    Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(value)) =>
      value
    Ok(_) => fail("recovery was not planned")
    Err(error) => fail(error.message())
  }
  // The Part is armed again under its existing contract with fresh identities,
  // so the Goal worker dispatches it on the next tick with no operator step.
  assert_eq(recovered.task_contract, uncertain.task_contract)
  assert_eq(
    recovered.part.lifecycle,
    @control.PartLifecycle::PartExecuting(identities.implementation_take.id),
  )
  assert_true(recovered.pending_effect is None)
  assert_true(
    recovered.implementation_take.id != uncertain.implementation_take.id,
  )
  assert_eq(recovered.prior_takes.length(), uncertain.prior_takes.length() + 3)

  // An effect that did leave its artifact is never guessed at.
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId("candidate-recovery"),
    goal_id: uncertain.goal.id,
    part_id: uncertain.part.id,
    take_id: uncertain.implementation_take.id,
    base_commit_oid: uncertain.task_contract.base_commit_oid,
    commit_oid: @control.GitOid("candidate-commit"),
    tree_oid: @control.GitOid("candidate-tree"),
    canonical_change_digest: workflow_digest_d,
    changed_paths: [@control.RepoPath("src/feature.mbt")],
  }
  let retained = { ..uncertain, candidate: Some(candidate) }
  assert_true(
    @workflow.plan_part_recovery_retry(
      retained,
      fn(_) { workflow_revision_identities(retained, retained.task_contract) },
      fn(_) { true },
    )
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryRetained),
  )

  // A surface that keeps dying stops at the bound instead of looping forever.
  let exhausted = {
    ..uncertain,
    prior_takes: uncertain.prior_takes +
    Array::makei(@workflow.maximum_part_recovery_retries() * 3, fn(index) {
      workflow_take(
        "exhausted-prior-take-" + index.to_string(),
        @control.TakePurpose::Implementation(
          uncertain.part.id,
          uncertain.task_contract.id,
        ),
      )
    }),
  }
  assert_true(
    @workflow.plan_part_recovery_retry(
      exhausted,
      fn(_) { workflow_revision_identities(exhausted, exhausted.task_contract) },
      fn(_) { true },
    )
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryLimitReached),
  )
}

///|
test "a spent provider allowance defers recovery instead of burning a Take" {
  let uncertain = uncertain_implementation_dispatch()
  let identities = workflow_revision_identities(
    uncertain,
    uncertain.task_contract,
  )
  guard uncertain.dispatch_diagnostic is Some(diagnostic) else {
    fail("uncertain dispatch recorded no diagnostic")
  }
  // With no trusted reset evidence the surface is not retried straight away:
  // an invented reset would burn the recovery budget against a spent
  // allowance. It is asked again once the observation ages out, which is the
  // only thing keeping the Part from waiting on evidence nobody will produce.
  let exhausted = {
    ..uncertain,
    dispatch_diagnostic: Some({
      ..diagnostic,
      availability: @control.ProviderAvailability::ProviderAllowanceExhausted(
        None,
      ),
      observed_at: 500L,
    }),
  }
  let retry_at = fn(now) {
    @workflow.plan_part_recovery_retry(
      exhausted,
      fn(_) { identities },
      fn(_) { true },
      now~,
    )
  }
  match retry_at(559L) {
    Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(observed)) =>
      assert_eq(
        observed,
        @control.ProviderAvailability::ProviderAllowanceExhausted(None),
      )
    _ => fail("a spent allowance did not defer recovery")
  }
  assert_true(
    retry_at(560L)
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(_)),
  )
  // Reported reset evidence is a wait, then an ordinary recovery.
  let resets_at = {
    ..uncertain,
    dispatch_diagnostic: Some({
      ..diagnostic,
      availability: @control.ProviderAvailability::ProviderRetryAfter(1_000L),
    }),
  }
  assert_true(
    @workflow.plan_part_recovery_retry(
      resets_at,
      fn(_) { identities },
      fn(_) { true },
      now=999L,
    )
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(_)),
  )
  assert_true(
    @workflow.plan_part_recovery_retry(
      resets_at,
      fn(_) { identities },
      fn(_) { true },
      now=1_000L,
    )
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(_)),
  )
  // Deferral never rewrites which provider the contract authorized.
  match
    @workflow.plan_part_recovery_retry(
      resets_at,
      fn(_) { identities },
      fn(_) { true },
      now=1_000L,
    ) {
    Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(planned)) =>
      assert_eq(planned.task_contract, uncertain.task_contract)
    _ => fail("recovery was not planned after the reset instant")
  }
}

///|
/// Retry identities on a named surface, the way the native host mints them.
fn workflow_identities_on_surface(
  snapshot : @workflow.PartWorkflowSnapshot,
  surface : @control.ProviderSurfaceId,
) -> @workflow.PartIdentityPlan {
  let base = workflow_revision_identities(snapshot, snapshot.task_contract)
  {
    ..base,
    implementation_session: { ..base.implementation_session, surface, },
    audit_session: { ..base.audit_session, surface, },
  }
}

///|
/// A Part parked on a spent surface, admitted under the surfaces given.
fn spent_surface_part(
  admitted : Array[@control.ProviderSurfaceId],
  availability : @control.ProviderAvailability,
) -> @workflow.PartWorkflowSnapshot raise {
  let uncertain = uncertain_implementation_dispatch()
  guard uncertain.dispatch_diagnostic is Some(diagnostic) else {
    fail("the lost dispatch recorded no diagnostic")
  }
  {
    ..uncertain,
    admitted_provider_surfaces: admitted,
    // Dated at the clock reading these cases decide against, so what they
    // observe is the surface refusing now rather than an observation that has
    // already aged out of the re-check schedule.
    dispatch_diagnostic: Some({ ..diagnostic, availability, observed_at: 500L }),
  }
}

///|
test "a spent surface moves the next Take to a surface the contract admits" {
  let spent = spent_surface_part(
    [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  let (planned, moved) = match
    @workflow.plan_part_recovery_retry(
      spent,
      fn(surface) { workflow_identities_on_surface(spent, surface) },
      fn(_) { true },
      now=500L,
    ) {
    Ok(
      @workflow.PartRecoveryRetryDecision::PartRecoveryRetryFailedOver(
        planned,
        moved
      )
    ) => (planned, moved)
    _ => fail("an admitted alternate surface was not selected")
  }
  // The move is to the admitted surface, from the one that said it is spent.
  assert_eq(
    moved.from_surface,
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  assert_eq(moved.to_surface, @control.ProviderSurfaceId::CodexSubscriptionCli)
  assert_eq(
    moved.cause,
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  // The next Take actually runs there, and the change is readable from durable
  // state rather than inferred by comparing identity plans.
  assert_eq(
    planned.identities.implementation_session.surface,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  assert_eq(
    planned.identities.audit_session.surface,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  assert_eq(planned.provider_failovers, [moved])
  // Only the surface moved: the contract, and the authority it captured, did
  // not.
  assert_eq(planned.task_contract, spent.task_contract)
  assert_eq(
    planned.admitted_provider_surfaces,
    spent.admitted_provider_surfaces,
  )
  assert_true(planned.pending_effect is None)
  // The Conductor only ever sees a Part through the status report, so a move
  // that never reaches the report is a move nobody can explain — and the
  // material-change fingerprint that is supposed to wake the Conductor for it
  // would be inert.
  let report = match
    @workflow.goal_status_report(
      workflow_execution_for_attach(planned),
      [planned],
      None,
      None,
      None,
      None,
      provider_capacity=None,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(report.parts[0].provider_failovers, [moved])
  assert_eq(
    report.parts[0].provider_surface,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
}

///|
test "a Part admitted under one surface waits instead of changing provider" {
  let spent = spent_surface_part(
    [@control.ProviderSurfaceId::ClaudeSubscriptionCli],
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  match
    @workflow.plan_part_recovery_retry(
      spent,
      fn(surface) { workflow_identities_on_surface(spent, surface) },
      fn(_) { true },
      now=500L,
    ) {
    Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(observed)) =>
      assert_eq(
        observed,
        @control.ProviderAvailability::ProviderAllowanceExhausted(None),
      )
    _ => fail("a Part with no admitted alternate did not wait")
  }
}

///|
/// The report says a Part is waiting on its provider exactly when the machine
/// would make it wait.
///
/// The two cases above are the machine's: with an admitted alternate the next
/// Take moves there, and without one the Part waits. The report is read at the
/// same instant and has to agree — which it can only do by carrying the
/// admitted set, because that set is the whole difference between them.
test "the report counts a Part as waiting only when recovery would defer it" {
  let waiting_count = fn(admitted : Array[@control.ProviderSurfaceId]) raise {
    let spent = spent_surface_part(
      admitted,
      @control.ProviderAvailability::ProviderAllowanceExhausted(None),
    )
    let report = match
      @workflow.goal_status_report(
        workflow_execution_for_attach(spent),
        [spent],
        None,
        None,
        None,
        None,
        provider_capacity=None,
      ) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
    @workflow.work_order_portfolio(report, 500L).provider_deferred
  }
  assert_eq(
    waiting_count([@control.ProviderSurfaceId::ClaudeSubscriptionCli]),
    1,
  )
  assert_eq(
    waiting_count([
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ]),
    0,
  )
}

///|
test "failover never returns a Part to a surface it already found spent" {
  let spent = spent_surface_part(
    [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  // The Part already left Claude on a spent allowance and is now on Codex,
  // which has just reported the same. Sending it back would be a loop between
  // two surfaces that both said they cannot serve.
  let left_claude : @workflow.PartProviderFailover = {
    from_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    to_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    cause: @control.ProviderAvailability::ProviderAllowanceExhausted(None),
    retry_ordinal: 1,
    decided_at: 500L,
  }
  let on_codex = {
    ..spent,
    identities: workflow_identities_on_surface(
      spent,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
    provider_failovers: [left_claude],
  }
  assert_true(
    @workflow.plan_part_recovery_retry(
      on_codex,
      fn(surface) { workflow_identities_on_surface(on_codex, surface) },
      fn(_) { true },
      now=500L,
    )
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(_)),
  )
  // The memory is a wait, not a ban: a surface left on a retry-after that has
  // since passed can take the work again.
  let returnable = {
    ..on_codex,
    provider_failovers: [
      {
        ..left_claude,
        cause: @control.ProviderAvailability::ProviderRetryAfter(400L),
      },
    ],
  }
  match
    @workflow.plan_part_recovery_retry(
      returnable,
      fn(surface) { workflow_identities_on_surface(returnable, surface) },
      fn(_) { true },
      now=500L,
    ) {
    Ok(
      @workflow.PartRecoveryRetryDecision::PartRecoveryRetryFailedOver(
        planned,
        moved
      )
    ) => {
      assert_eq(
        moved.to_surface,
        @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      )
      // Re-arming the Part keeps the moves it already made. Losing them would
      // erase the memory this decision reads, and a Part that had bounced
      // between surfaces would look like one that never moved.
      assert_eq(
        planned.provider_failovers,
        returnable.provider_failovers + [moved],
      )
    }
    _ => fail("a recovered surface did not take the work back")
  }
  // Nor is an allowance that named no instant a ban: the surface the Part left
  // is asked again once that observation ages out, even while the surface it
  // moved to is still waiting on a reset it did report.
  let codex_resets_late = {
    ..on_codex,
    dispatch_diagnostic: on_codex.dispatch_diagnostic.map(fn(diagnostic) {
      {
        ..diagnostic,
        availability: @control.ProviderAvailability::ProviderAllowanceExhausted(
          Some(100_000L),
        ),
      }
    }),
  }
  let retry_at = fn(now) {
    @workflow.plan_part_recovery_retry(
      codex_resets_late,
      fn(surface) { workflow_identities_on_surface(codex_resets_late, surface) },
      fn(_) { true },
      now~,
    )
  }
  assert_true(
    retry_at(559L)
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(_)),
  )
  match retry_at(560L) {
    Ok(
      @workflow.PartRecoveryRetryDecision::PartRecoveryRetryFailedOver(_, moved)
    ) =>
      assert_eq(
        moved.to_surface,
        @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      )
    _ => fail("an aged-out observation still excluded its surface")
  }
}

///|
/// The liveness this Bead exists for: an effect is never left parked forever.
///
/// Both surfaces the contract admits reported a spent allowance and neither
/// named a reset instant, which is the state a subscription actually reports.
/// Under the earlier rule that state admitted dispatch at no clock reading at
/// all, so the Part deferred at every tick with nothing scheduled to wake it.
/// It now becomes eligible again once the observations age out, and the
/// bounded recovery budget — not an unbounded wait — is what ends the retrying.
test "a Part on two spent surfaces becomes eligible again, not parked" {
  let spent = spent_surface_part(
    [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  let on_codex = {
    ..spent,
    identities: workflow_identities_on_surface(
      spent,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
    provider_failovers: [
      {
        from_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        to_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        cause: @control.ProviderAvailability::ProviderAllowanceExhausted(None),
        retry_ordinal: 1,
        decided_at: 500L,
      },
    ],
  }
  let retry_at = fn(now) {
    @workflow.plan_part_recovery_retry(
      on_codex,
      fn(surface) { workflow_identities_on_surface(on_codex, surface) },
      fn(_) { true },
      now~,
    )
  }
  // Nowhere to go while both observations still hold.
  assert_true(
    retry_at(500L)
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(_)),
  )
  assert_true(
    retry_at(559L)
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryDeferred(_)),
  )
  // A minute after they were observed both have aged out, and the Part is
  // re-armed on the surface it is already on rather than waiting for evidence
  // no one is scheduled to produce.
  match retry_at(560L) {
    Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(planned)) => {
      assert_eq(
        planned.identities.implementation_session.surface,
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      )
      // Ageing an observation out is not evidence that anything reset, so the
      // moves the Part already made are still on the record.
      assert_eq(planned.provider_failovers, on_codex.provider_failovers)
    }
    _ => fail("a Part on two spent surfaces stayed parked")
  }
}

///|
test "an uncertain effect that may have occurred is not failed over either" {
  let spent = spent_surface_part(
    [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  // The dispatch left a candidate, so it may have run. Moving it to another
  // surface would duplicate the side effect the uncertainty exists to protect.
  let retained = {
    ..spent,
    candidate: Some({
      id: @control.CandidateId("candidate-failover"),
      goal_id: spent.goal.id,
      part_id: spent.part.id,
      take_id: spent.implementation_take.id,
      base_commit_oid: spent.task_contract.base_commit_oid,
      commit_oid: @control.GitOid("candidate-failover-commit"),
      tree_oid: @control.GitOid("candidate-failover-tree"),
      canonical_change_digest: workflow_digest_d,
      changed_paths: [@control.RepoPath("src/feature.mbt")],
    }),
  }
  assert_true(
    @workflow.plan_part_recovery_retry(
      retained,
      fn(surface) { workflow_identities_on_surface(retained, surface) },
      fn(_) { true },
      now=500L,
    )
    is Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryRetained),
  )
}

///|
test "the host cannot answer a failover with a plan on another surface" {
  let spent = spent_surface_part(
    [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  // The host mints identities; the surface is the control plane's decision.
  // A plan that came back on the surface the Part was already on would move
  // nothing while reporting that it had.
  assert_true(
    @workflow.plan_part_recovery_retry(
      spent,
      fn(_) {
        workflow_identities_on_surface(
          spent,
          @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        )
      },
      fn(_) { true },
      now=500L,
    )
    is Err(_),
  )
}

///|
test "a Part may not be initialized on a surface its contract never admitted" {
  let fixture = workflow_fixture()
  assert_eq(fixture.admitted_provider_surfaces, [
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  ])
  assert_true(
    @workflow.initialize_part_workflow(
      @control.WorkflowId("workflow-unadmitted"),
      fixture.goal,
      { ..fixture.part, lifecycle: @control.PartLifecycle::PartPending },
      fixture.task_contract,
      workflow_identities_on_surface(
        fixture,
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      ),
      fixture.fencing_epoch,
      fn(_) { true },
      admitted_provider_surfaces=[
        @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      ],
    )
    is Err(_),
  )
  // The same plan is accepted once the contract admits that surface.
  assert_true(
    @workflow.initialize_part_workflow(
      @control.WorkflowId("workflow-admitted"),
      fixture.goal,
      { ..fixture.part, lifecycle: @control.PartLifecycle::PartPending },
      fixture.task_contract,
      workflow_identities_on_surface(
        fixture,
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      ),
      fixture.fencing_epoch,
      fn(_) { true },
      admitted_provider_surfaces=[
        @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        @control.ProviderSurfaceId::CodexSubscriptionCli,
      ],
    )
    is Ok(_),
  )
}

///|
test "the driver classifies the same text it records as the failure cause" {
  // Live provider output reaches the deferral decision instead of being
  // flattened into a generic "the Take was lost".
  assert_eq(
    @control.classify_provider_availability(
      1, "provider process lost: Claude usage limit reached",
    ),
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  assert_eq(
    @control.classify_provider_availability(
      1, "transport error: BoxLite Take runtime: result archive failed",
    ),
    @control.ProviderAvailability::ProviderUnavailable,
  )
}

///|
test "a surface that reported its reset is deferred to that instant, not text" {
  // The surface states the reset in its protocol, not in prose. Before this,
  // the wording had to match a known phrase or the reset was discarded and the
  // Take waited forever on an allowance nobody was scheduled to recheck.
  let observed = @control.classify_provider_availability(
    1,
    "provider process lost: Codex turn failed against a spent allowance",
    reset_at=Some(1_785_614_465L),
  )
  assert_eq(
    observed,
    @control.ProviderAvailability::ProviderAllowanceExhausted(
      Some(1_785_614_465L),
    ),
  )
  // Which makes the wait finite: the surface is admitted again at its reset.
  // The observation is dated more than an hour earlier than the instant the
  // surface reported, so Choir's own re-check schedule would have expired long
  // before — evidence the surface stated outranks it either way.
  let admits = fn(now) {
    @control.provider_availability_admits_dispatch(
      observed,
      observed_at=1_785_610_000L,
      prior_deferrals=0,
      policy=@control.provider_recheck_policy(
        base_seconds=60L,
        growth=2L,
        ceiling_seconds=1_800L,
        reset_horizon_seconds=691_200L,
      ).unwrap(),
      now~,
    )
  }
  assert_false(admits(1_785_614_464L))
  assert_true(admits(1_785_614_465L))
  // A failure the surface said nothing about still waits on nothing invented.
  assert_eq(
    @control.classify_provider_availability(
      1, "provider process lost: nonresumable Claude process exited",
    ),
    @control.ProviderAvailability::ProviderUnavailable,
  )
}
