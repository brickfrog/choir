///|
fn publication_digest(label : String) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode("publication-conformance\u{00}" + label),
  )
}

///|
fn publication_initialized_branch(
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
fn publication_take(
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
fn publication_sandbox(
  id : String,
  generation : String,
  take : @control.Take,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId(id),
    take_id: take.id,
    generation_id: @control.SandboxGenerationId(generation),
    capability_profile_digest: publication_digest(id + "-capability"),
    runtime_policy_digest: publication_digest(id + "-runtime"),
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn publication_session(
  id : String,
  take : @control.Take,
  sandbox : @control.SandboxLease,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id: take.id,
    sandbox_generation_id: sandbox.generation_id,
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: publication_digest(id + "-surface"),
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
    usage: None,
  }
}

///|
fn publication_assurance_identities(
  goal_id : @control.GoalId,
  head : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification = publication_take(
    goal_id,
    "publication-goal-verification",
    @control.TakePurpose::GoalVerification(
      goal_id,
      head,
      publication_digest("goal-verification"),
    ),
  )
  let audit = publication_take(
    goal_id,
    "publication-goal-audit",
    @control.TakePurpose::GoalAudit(goal_id, publication_digest("goal-audit")),
  )
  let verification_sandbox = publication_sandbox(
    "publication-goal-verification-sandbox", "publication-goal-verification-generation",
    verification,
  )
  let audit_sandbox = publication_sandbox(
    "publication-goal-audit-sandbox", "publication-goal-audit-generation", audit,
  )
  {
    verification_take: verification,
    verification_sandbox,
    audit_take: audit,
    audit_sandbox,
    audit_session: publication_session(
      "publication-goal-audit-session", audit, audit_sandbox,
    ),
  }
}

///|
fn publication_integrated_part(
  goal : @control.Goal,
  base : @control.GitOid,
  tree : @control.GitOid,
  head : @control.GitOid,
) -> @workflow.PartWorkflowSnapshot {
  let part_id = @control.PartId("publication-part")
  let contract_id = @control.RevisionId("publication-contract")
  let implementation = publication_take(
    goal.id,
    "publication-implementation",
    @control.TakePurpose::Implementation(part_id, contract_id),
  )
  let verification = publication_take(
    goal.id,
    "publication-verification",
    @control.TakePurpose::PartVerification(
      part_id,
      implementation.id,
      publication_digest("part-verification"),
    ),
  )
  let audit = publication_take(
    goal.id,
    "publication-audit",
    @control.TakePurpose::PartAudit(
      part_id,
      implementation.id,
      publication_digest("part-audit"),
    ),
  )
  let implementation_sandbox = publication_sandbox(
    "publication-implementation-sandbox", "publication-implementation-generation",
    implementation,
  )
  let verification_sandbox = publication_sandbox(
    "publication-verification-sandbox", "publication-verification-generation", verification,
  )
  let audit_sandbox = publication_sandbox(
    "publication-audit-sandbox", "publication-audit-generation", audit,
  )
  let receipt_id = @control.IntegrationReceiptId("publication-integration")
  let receipt : @control.IntegrationReceipt = {
    id: receipt_id,
    intent_id: @control.IntegrationIntentId("publication-integration-intent"),
    goal_id: goal.id,
    part_id,
    candidate_id: @control.CandidateId("publication-candidate"),
    candidate_commit_oid: head,
    candidate_tree_oid: tree,
    from_head_oid: base,
    promotion_commit_oid: head,
    promotion_tree_oid: tree,
    witness_ref: "refs/choir/witness/publication-integration",
    integrated_at: 1L,
  }
  {
    workflow_id: @control.WorkflowId("publication-workflow"),
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
    stage: @workflow.PartWorkflowStage::PartIntegrated,
    goal,
    part: {
      id: part_id,
      goal_id: goal.id,
      dependency_ids: [],
      task_contract_revision_id: contract_id,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId(receipt_id.0),
      ),
    },
    task_contract: {
      id: contract_id,
      goal_id: goal.id,
      part_id,
      revision: 1,
      digest: publication_digest("contract"),
      commit_title: @control.SemanticCommitTitle("test: publish fixture"),
      repair_conflict_id: None,
      repair_audit: None,
      repair_verification: None,
      instruction_artifact: {
        artifact_id: "publication-instruction",
        digest: publication_digest("instruction"),
      },
      base_commit_oid: base,
      base_tree_oid: tree,
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([],
      ),
      verification_specs: [
        {
          id: @control.VerificationSpecId("publication-verification-spec"),
          version: 1,
          digest: publication_digest("verification-spec"),
          process_spec_digest: publication_digest("verification-process"),
        },
      ],
      audit_policy_digest: publication_digest("part-audit-policy"),
      migration_contract_ref: None,
      migration_continuation_ref_digest: None,
      implementation_capability_profile_digest: publication_digest(
        "implementation-capability",
      ),
      verification_capability_profile_digest: publication_digest(
        "verification-capability",
      ),
      audit_capability_profile_digest: publication_digest("audit-capability"),
    },
    task_contract_history: [],
    part_context_manifest: None,
    identities: {
      implementation_take: implementation,
      implementation_sandbox,
      implementation_session: publication_session(
        "publication-implementation-session", implementation, implementation_sandbox,
      ),
      verification_take: verification,
      verification_sandbox,
      audit_take: audit,
      audit_sandbox,
      audit_session: publication_session(
        "publication-audit-session", audit, audit_sandbox,
      ),
    },
    admitted_provider_surfaces: [
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
    provider_failovers: [],
    implementation_take: implementation,
    verification_take: verification,
    audit_take: audit,
    prior_takes: [],
    prior_take_evidence: [],
    sandbox_leases: [],
    harness_sessions: [],
    harness_events: [],
    prepared_commands: [],
    implementation_result: None,
    candidate: None,
    verification_subject: None,
    verification_slots: [],
    verification_receipts: [],
    verification_authorization: None,
    audit_subject: None,
    audit_result: None,
    audit_receipt: None,
    integration_lease: None,
    integration_intent: None,
    promotion_commit: None,
    integration_receipt: Some(receipt),
    integration_conflicts: [],
    pending_effect: None,
    effect_receipts: [],
    dispatch_diagnostic: None,
  }
}

///|
fn publication_audited_assurance(
  planned : @workflow.GoalAssuranceRecord,
  head : @control.GitOid,
  tree : @control.GitOid,
) -> @workflow.GoalAssuranceRecord {
  let unfinished : @control.GoalBranchSeal = {
    id: @control.GoalBranchSealId("publication-seal"),
    intent_id: planned.seal_intent.id,
    goal_id: planned.goal_id,
    seal_epoch: planned.fencing_epoch,
    goal_ref: planned.goal_ref.0,
    seal_witness_ref: planned.seal_intent.seal_witness_ref,
    head_oid: head,
    tree_oid: tree,
    goal_contract_digest: planned.goal_contract_digest,
    assurance_policy_revision: planned.assurance_policy_revision,
    assurance_policy_digest: planned.assurance_policy_digest,
    integration_receipt_set_digest: planned.integration_receipt_set_digest,
    sealed_at: 2L,
    seal_digest: publication_digest("unfinished-seal"),
  }
  let seal = {
    ..unfinished,
    seal_digest: @workflow.goal_branch_seal_digest(unfinished),
  }
  let authorization : @control.GoalVerificationAuthorizationSet = {
    subject_digest: publication_digest("verification-subject"),
    receipt_ids: [@control.ReceiptId("publication-verification-receipt")],
    receipt_set_digest: publication_digest("verification-receipt-set"),
    evidence_manifest_digest: publication_digest("verification-evidence"),
  }
  let audit_subject : @control.GoalAuditSubject = {
    goal_id: planned.goal_id,
    goal_branch_seal_id: seal.id,
    goal_branch_seal_digest: seal.seal_digest,
    goal_head_oid: head,
    goal_tree_oid: tree,
    goal_contract_digest: planned.goal_contract_digest,
    assurance_policy_revision: planned.assurance_policy_revision,
    integration_receipt_set_digest: planned.integration_receipt_set_digest,
    goal_verification_receipt_set_digest: authorization.receipt_set_digest,
    goal_verification_evidence_manifest_digest: authorization.evidence_manifest_digest,
    subject_digest: publication_digest("audit-subject"),
  }
  let result_digest = publication_digest("audit-result")
  let result : @control.GoalAuditResult = {
    id: @control.AuditResultId("publication-audit-result"),
    audit_take_id: planned.audit_take.id,
    take_fencing_epoch: planned.fencing_epoch,
    audit_harness_session_id: planned.identities.audit_session.id,
    subject: audit_subject,
    auditor_capability_profile_digest: publication_digest("auditor-capability"),
    effective_surface_manifest_digest: publication_digest("audit-surface"),
    provider_conformance_report_digest: publication_digest(
      "provider-conformance",
    ),
    audit_policy_digest: publication_digest("goal-audit-policy"),
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 3L,
    finished_at: 4L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest,
  }
  let receipt : @control.GoalAuditReceipt = {
    receipt_id: @control.ReceiptId("publication-audit-receipt"),
    audit_result_id: result.id,
    audit_result_digest: result.result_digest,
    subject: audit_subject,
    audit_take_id: planned.audit_take.id,
    audit_harness_session_id: planned.identities.audit_session.id,
    audit_sandbox_generation_id: planned.identities.audit_sandbox.generation_id,
    auditor_capability_profile_digest: result.auditor_capability_profile_digest,
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: @harness.provider_receipt_identity(
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
    model_identity: @control.ModelIdentity::ReportedModelIdentity("codex"),
    provider_conformance_report_digest: result.provider_conformance_report_digest,
    audit_policy_digest: result.audit_policy_digest,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: result.started_at,
    finished_at: result.finished_at,
    outcome: @control.AuditOutcome::AuditPassed,
  }
  {
    ..planned,
    seal_intent: {
      ..planned.seal_intent,
      lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
    },
    seal_witnessed_at: Some(2L),
    seal: Some(seal),
    verification_authorization: Some(authorization),
    audit_subject: Some(audit_subject),
    audit_result: Some(result),
    audit_receipt: Some(receipt),
    stage: @workflow.GoalAssuranceStage::GoalAudited,
  }
}

///|
pub(all) struct NativePublicationFaultObservation {
  fault : @workflow.GoalPublicationFaultPoint
  interrupted_state : @workflow.BranchPublicationState
  remote_updated : Bool
  recovered : Bool
  replay_stable : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePublicationFaultConformanceReport {
  observations : Array[NativePublicationFaultObservation]
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
async fn prove_publication_fault_recovery(
  label : String,
  fault : @workflow.GoalPublicationFaultPoint,
  expected_state : @workflow.BranchPublicationState,
  remote_updated : Bool,
) -> (String, String, @control.GoalId, NativePublicationFaultObservation) {
  let root = "/tmp/choir-publication-fault-" +
    @sys.get_pid().to_string() +
    "-" +
    label
  let remote = root + "-remote.git"
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
  assert_true(@sys.create_dir_all(root))
  let git = async fn(cwd : String, arguments : Array[String]) -> (Int, String) {
    let captured = @process.collect_output_merged(
      "/usr/bin/git",
      arguments,
      extra_env={
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
      },
      inherit_env=false,
      cwd~,
    ) catch {
      _ => fail("publication Git command failed")
    }
    let output = captured.1.text() catch {
      _ => fail("publication Git output was not UTF-8")
    }
    (captured.0, output)
  }
  assert_eq(git(root, ["init", "-q"]).0, 0)
  assert_eq(git(root, ["init", "--bare", "-q", remote]).0, 0)
  let tree = git(root, ["hash-object", "-w", "-t", "tree", "/dev/null"])
  let tree_oid = tree.1.trim().to_owned()
  let base = git(root, [
    "-c", "user.name=Choir Test", "-c", "user.email=choir@example.invalid", "commit-tree",
    tree_oid, "-m", "publication base",
  ])
  let base_oid = base.1.trim().to_owned()
  let head = git(root, [
    "-c", "user.name=Choir Test", "-c", "user.email=choir@example.invalid", "commit-tree",
    tree_oid, "-p", base_oid, "-m", "publication head",
  ])
  let head_oid = head.1.trim().to_owned()
  assert_eq(tree.0, 0)
  assert_eq(base.0, 0)
  assert_eq(head.0, 0)
  assert_eq(git(root, ["remote", "add", "origin", remote]).0, 0)
  let goal_id = @control.GoalId("publication-goal-" + label)
  let goal_ref = @workflow.goal_execution_ref(goal_id)
  assert_eq(git(root, ["update-ref", goal_ref.0, head_oid]).0, 0)
  let canonical_root = @sys.realpath_native(root).unwrap()
  let repository_id = @workflow.repository_id(canonical_root)
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest: publication_digest("goal-contract-" + label),
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let integrated = publication_integrated_part(
    goal,
    @control.GitOid(base_oid),
    @control.GitOid(tree_oid),
    @control.GitOid(head_oid),
  )
  let assuring : @workflow.GoalExecutionRecord = {
    goal,
    repository_id,
    selection_decision_digest: publication_digest("selection-" + label),
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid(base_oid),
    base_tree_oid: @control.GitOid(tree_oid),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise Goal publication",
      body: "Exercises native Goal publication.",
      draft: false,
    }),
    migration_production_admission: None,
    goal_ref,
    branch_initialization: publication_initialized_branch(
      goal_id,
      repository_id,
      goal_ref,
      @control.GitOid(base_oid),
    ),
    source_claims: [
      @workflow.receipted_goal_source_claim(
        goal_id,
        integrated.part.id,
        publication_digest("source-revision-" + label),
        publication_digest("source-content-" + label),
        1L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [@workflow.initial_goal_policy_revision(goal_id, 1)],
    part_workflow_ids: [integrated.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    work_order_id: None,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
  }
  let planned = match
    @workflow.initialize_goal_assurance(
      assuring,
      [integrated],
      @control.GitOid(head_oid),
      @control.GitOid(tree_oid),
      integrated.task_contract.verification_specs,
      publication_assurance_identities(goal_id, @control.GitOid(head_oid)),
    ) {
    Ok(value) => value
    Err(error) => fail(label + ": " + error.message())
  }
  let assured = {
    ..assuring,
    state: @workflow.GoalExecutionState::GoalExecutionAssured,
  }
  let assurance = publication_audited_assurance(
    planned,
    @control.GitOid(head_oid),
    @control.GitOid(tree_oid),
  )
  assert_true(@sys.create_dir_all(root + "/.choir/state/control/artifacts"))
  let repository = @goal_host.native_goal_repository(root)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(label + ": " + error.message())
  }
  match
    @workflow.persist_goal_execution_record(repository, adapters, {
      record: assured,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(label + ": " + error.message())
  }
  match
    @workflow.persist_goal_assurance_record(repository, adapters, {
      record: assurance,
      expected_store_version: None,
      goal_precondition: @workflow.goal_execution_state_precondition(assured),
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(label + ": " + error.message())
  }
  match
    @goal_host.advance_native_goal_publication(root, goal_id, fault=Some(fault)) {
    Err(_) => ()
    Ok(_) => fail(label + ": injected publication fault did not interrupt")
  }
  let interrupted = match
    @workflow.load_goal_publication_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) => fail(label + ": interrupted publication record is absent")
    Err(error) =>
      fail(label + ": interrupted publication record: " + error.message())
  }
  assert_eq(interrupted.intent.state, expected_state)
  let observed = git(root, ["ls-remote", "--refs", "origin", goal_ref.0])
  assert_eq(observed.0, 0)
  if remote_updated {
    assert_true(observed.1.has_prefix(head_oid))
  } else {
    assert_eq(observed.1.trim(), "")
  }
  let recovered = match
    @goal_host.advance_native_goal_publication(root, goal_id) {
    Ok(value) => value
    Err(error) => fail(label + ": recovery: " + error.message())
  }
  assert_eq(
    recovered,
    @workflow.GoalPublicationTickOutcome::GoalPublicationComplete,
  )
  let completed = @workflow.load_goal_publication_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  assert_eq(
    completed.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  assert_true(completed.receipt is Some(_))
  let replay_complete = @goal_host.advance_native_goal_publication(
      root, goal_id,
    ).unwrap() ==
    @workflow.GoalPublicationTickOutcome::GoalPublicationComplete
  let replay_stable = @workflow.load_goal_publication_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record ==
    completed
  assert_true(replay_complete)
  assert_true(replay_stable)
  assert_eq(
    @workflow.load_goal_execution_record(repository, adapters, goal_id)
    .unwrap()
    .unwrap().record.state,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  )
  (
    root,
    remote,
    goal_id,
    {
      fault,
      interrupted_state: interrupted.intent.state,
      remote_updated,
      recovered: recovered ==
      @workflow.GoalPublicationTickOutcome::GoalPublicationComplete,
      replay_stable,
    },
  )
}

///|
pub async fn run_native_publication_fault_conformance() -> NativePublicationFaultConformanceReport {
  let cleanup = fn(
    fixture : (
      String,
      String,
      @control.GoalId,
      NativePublicationFaultObservation,
    ),
  ) {
    ignore(@sys.rm_rf(fixture.0))
    ignore(@sys.rm_rf(fixture.1))
  }
  let observations : Array[NativePublicationFaultObservation] = []
  let cases : Array[
    (
      String,
      @workflow.GoalPublicationFaultPoint,
      @workflow.BranchPublicationState,
      Bool,
    ),
  ] = [
    (
      "after-intent",
      @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
      @workflow.BranchPublicationState::BranchPublicationPlanned,
      false,
    ),
    (
      "after-authorization",
      @workflow.GoalPublicationFaultPoint::PublicationAfterAuthorizedBeforeRemoteUpdate,
      @workflow.BranchPublicationState::BranchPublicationAuthorized,
      false,
    ),
    (
      "after-update",
      @workflow.GoalPublicationFaultPoint::PublicationAfterRemoteUpdateBeforeResponse,
      @workflow.BranchPublicationState::BranchPublicationAuthorized,
      true,
    ),
    (
      "after-response",
      @workflow.GoalPublicationFaultPoint::PublicationAfterResponseBeforeReceipt,
      @workflow.BranchPublicationState::BranchPublicationAuthorized,
      true,
    ),
    (
      "during-receipt",
      @workflow.GoalPublicationFaultPoint::PublicationDuringReceiptTransaction,
      @workflow.BranchPublicationState::BranchPublicationReceipted,
      true,
    ),
  ]
  for config in cases {
    let fixture = prove_publication_fault_recovery(
      config.0,
      config.1,
      config.2,
      config.3,
    )
    observations.push(fixture.3)
    cleanup(fixture)
  }
  {
    observations,
    passed: observations.length() == cases.length() &&
    observations.all(fn(observation) {
      observation.recovered && observation.replay_stable
    }),
  }
}

///|
async test "real exec integration: Goal publication recovers across every external-effect boundary" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let report = run_native_publication_fault_conformance()
  assert_true(report.passed)
  assert_eq(report.observations.length(), 5)
}
