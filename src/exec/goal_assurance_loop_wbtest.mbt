///| The Goal assurance loop's provider bound, driven through the loop.
///
/// `goal_assurance_lease_storage_test.mbt` calls `native_goal_assurance_effect_admission`
/// and `finish_native_goal_assurance_leases` directly. That pins what those two
/// decide, but not that anything reaches them: delete the gate call out of
/// `advance_native_goal_assurance_attempt`, or hand its teardown an empty hold
/// list, and every test in that file still passes while the Goal audit runs
/// unbounded and leaks a slot per tick. These two tests enter at
/// `advance_native_goal_assurance` instead, so they fail when the loop stops
/// calling either one.
///
/// Whitebox because `advance_native_goal_assurance` is private and should stay
/// private — the daemon reaches it through the execution tick's `assure`
/// adapter, not from outside this package.
///
/// Real-exec because the attempt discovers the Git repository before it reads
/// its durable record. The fixture is one temporary repository under `/tmp`
/// with a single commit and its own control store, removed on the way out; no
/// provider, no BoxLite server, and nothing outside that directory is touched.

///|
/// A temporary repository, its control store, and the two durable records one
/// assurance tick reads.
priv struct NativeAssuranceLoopFixture {
  root : String
  repository : @workflow.PartWorkflowRepository
  adapters : @workflow.PartWorkflowRepositoryAdapters
  execution : @workflow.GoalExecutionRecord
  /// Stage `GoalAuditPending` with no audit evidence yet, so the next assurance
  /// effect is the audit sandbox — the first thing the audit session needs and
  /// the first thing that reaches a provider surface.
  assurance : @workflow.GoalAssuranceRecord
}

///|
/// A Goal mid-assurance, exactly as the durable store would hold it.
///
/// Both records are built here rather than driven through the workflow because
/// what is under test is one decision inside the loop; the decoders on the way
/// back in are what keep the fixture honest about the shape.
async fn real_exec_integration_assurance_loop_fixture(
  label : String,
  surface : @control.ProviderSurfaceId,
) -> NativeAssuranceLoopFixture {
  let root = "/tmp/choir-assurance-loop-" +
    label +
    "-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root + "/.choir/state/control") {
    fail("create Goal assurance loop root")
  }
  let git = async fn(
    arguments : Array[String],
  ) -> @git_integration.NativeGitCapture {
    match capture_native_goal_git(root, arguments) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
  }
  if git(["init", "-q"]).exit_code != 0 {
    fail("initialize Goal assurance loop repository")
  }
  let tree = git(["hash-object", "-w", "-t", "tree", "/dev/null"])
  if tree.exit_code != 0 {
    fail("create Goal assurance loop tree")
  }
  let tree_oid = @control.GitOid(tree.output.trim().to_owned())
  let author = [
    "-c", "user.name=Choir Test", "-c", "user.email=choir@example.invalid",
  ]
  let base = git([..author, "commit-tree", tree_oid.0, "-m", "base"])
  if base.exit_code != 0 {
    fail("create Goal assurance loop base commit")
  }
  let base_oid = @control.GitOid(base.output.trim().to_owned())
  let head = git(
    [..author, "commit-tree", tree_oid.0, "-p", base_oid.0, "-m", "goal"],
  )
  if head.exit_code != 0 {
    fail("create Goal assurance loop head commit")
  }
  let head_oid = @control.GitOid(head.output.trim().to_owned())
  // The identity `discover_native_goal_repository` will derive, derived the
  // same way: a fixture that guessed it would fail before it reached the gate.
  let toplevel = match
    native_goal_git_value(root, ["rev-parse", "--show-toplevel"]) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let canonical = match @sys.realpath_native(toplevel) {
    Some(value) => value
    None => fail("canonicalize Goal assurance loop root")
  }
  let repository_id = @workflow.repository_id(canonical)
  let repository = native_goal_repository(root)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  let goal_id = @control.GoalId("goal-assurance-loop-" + label)
  let part_id = @control.PartId("part-assurance-loop-" + label)
  let goal_ref = @workflow.goal_execution_ref(goal_id)
  if git(["update-ref", goal_ref.0, head_oid.0]).exit_code != 0 {
    fail("create Goal assurance loop Goal ref")
  }
  let identity_digest = native_goal_submission_digest(
    "choir.assurance-loop-fixture.v1",
    label.to_json(),
  )
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest: identity_digest,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let initialization = @workflow.initial_goal_branch_initialization(
    goal_id, repository_id, goal_ref, base_oid,
  )
  let execution : @workflow.GoalExecutionRecord = {
    goal,
    repository_id,
    selection_decision_digest: identity_digest,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: base_oid,
    base_tree_oid: tree_oid,
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise the Goal assurance loop",
      body: "Exercises the Goal assurance provider bound.",
      draft: false,
    }),
    migration_production_admission: None,
    goal_ref,
    branch_initialization: {
      ..initialization,
      lifecycle: @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
      receipt: Some({
        intent_id: initialization.intent_id,
        idempotency_key: initialization.idempotency_key,
        repository_id,
        goal_ref,
        initialized_oid: base_oid,
        initialization_witness_ref: initialization.initialization_witness_ref,
        observed_at: 1L,
      }),
    },
    source_claims: [
      @workflow.receipted_goal_source_claim(
        goal_id, part_id, identity_digest, identity_digest, 1L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [@workflow.initial_goal_policy_revision(goal_id, 1)],
    part_workflow_ids: [@control.WorkflowId("workflow-assurance-loop-" + label)],
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    work_order_id: None,
    durable_version: 1,
    fencing_epoch: current_native_goal_fencing_epoch(),
  }
  match
    @workflow.persist_goal_execution_record(repository, adapters, {
      record: execution,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  let verification_take = native_goal_submission_take(
    "take-assurance-loop-" + label + "-goal-verification-1",
    goal_id,
    @control.TakePurpose::GoalVerification(
      goal_id,
      head_oid,
      goal.contract_digest,
    ),
  )
  let audit_take = native_goal_submission_take(
    "take-assurance-loop-" + label + "-goal-audit-1",
    goal_id,
    @control.TakePurpose::GoalAudit(goal_id, goal.contract_digest),
  )
  let audit_sandbox = native_goal_submission_sandbox(
    "sandbox-assurance-loop-" + label + "-goal-audit-1",
    "generation-assurance-loop-" + label + "-goal-audit-1",
    audit_take,
    native_goal_submission_profile_digest(surface, "goal-audit"),
  )
  let identities : @workflow.GoalAssuranceIdentityPlan = {
    verification_take,
    verification_sandbox: native_goal_submission_sandbox(
      "sandbox-assurance-loop-" + label + "-goal-verification-1",
      "generation-assurance-loop-" + label + "-goal-verification-1",
      verification_take,
      native_goal_submission_profile_digest(surface, "goal-verification"),
    ),
    audit_take,
    audit_sandbox,
    audit_session: native_goal_submission_session(
      "session-assurance-loop-" + label + "-goal-audit-1",
      audit_take,
      audit_sandbox,
      surface,
    ),
  }
  let receipts : Array[@control.IntegrationReceipt] = [
    {
      id: @control.IntegrationReceiptId("integration-receipt-" + label),
      intent_id: @control.IntegrationIntentId("integration-intent-" + label),
      goal_id,
      part_id,
      candidate_id: @control.CandidateId("candidate-" + label),
      candidate_commit_oid: head_oid,
      candidate_tree_oid: tree_oid,
      from_head_oid: base_oid,
      promotion_commit_oid: head_oid,
      promotion_tree_oid: tree_oid,
      witness_ref: "refs/choir/witness/assurance-loop-" + label,
      integrated_at: 1L,
    },
  ]
  let receipt_set_digest = native_goal_submission_digest(
    "choir.goal-integration-receipt-set.v1",
    receipts.to_json(),
  )
  let specs : Array[@control.VerificationSpec] = [
    {
      id: @control.VerificationSpecId("goal-verify-assurance-loop-" + label),
      version: 1,
      digest: identity_digest,
      process_spec_digest: identity_digest,
    },
  ]
  let policy_digest = native_goal_submission_digest(
    "choir.goal-assurance-policy.v1",
    [goal.contract_digest.to_json(), specs.to_json(), identities.to_json()].to_json(),
  )
  let policy_revision = @control.RevisionId(
    "goal-assurance-" + @storage.digest_text(policy_digest),
  )
  let seal_intent : @control.GoalBranchSealIntent = {
    id: @control.GoalBranchSealIntentId("seal-intent-assurance-loop-" + label),
    goal_id,
    expected_head_oid: head_oid,
    expected_tree_oid: tree_oid,
    integration_receipt_set_digest: receipt_set_digest,
    assurance_policy_revision: policy_revision,
    assurance_policy_digest: policy_digest,
    seal_witness_ref: "refs/choir/witness/assurance-loop-seal-" + label,
    idempotency_key: "seal-assurance-loop-" + label,
    lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
  }
  let unsealed : @control.GoalBranchSeal = {
    id: @control.GoalBranchSealId("seal-assurance-loop-" + label),
    intent_id: seal_intent.id,
    goal_id,
    seal_epoch: execution.fencing_epoch,
    goal_ref: goal_ref.0,
    seal_witness_ref: seal_intent.seal_witness_ref,
    head_oid,
    tree_oid,
    goal_contract_digest: goal.contract_digest,
    assurance_policy_revision: policy_revision,
    assurance_policy_digest: policy_digest,
    integration_receipt_set_digest: receipt_set_digest,
    sealed_at: 1L,
    seal_digest: identity_digest,
  }
  let assurance : @workflow.GoalAssuranceRecord = {
    goal_id,
    repository_id,
    goal_ref,
    goal_contract_digest: goal.contract_digest,
    base_commit_oid: base_oid,
    integration_receipts: receipts,
    integration_receipt_set_digest: receipt_set_digest,
    assurance_policy_revision: policy_revision,
    assurance_policy_digest: policy_digest,
    verification_specs: specs,
    identities,
    verification_take,
    audit_take,
    seal_intent,
    seal_witnessed_at: Some(1L),
    seal: Some({
      ..unsealed,
      seal_digest: @workflow.goal_branch_seal_digest(unsealed),
    }),
    sandbox_leases: [],
    harness_sessions: [],
    harness_events: [],
    verification_subject: None,
    verification_slots: [],
    verification_receipts: [],
    verification_authorization: None,
    audit_subject: None,
    audit_result: None,
    audit_receipt: None,
    pending_effect: None,
    effect_receipts: [],
    stage: @workflow.GoalAssuranceStage::GoalAuditPending,
    blocked_reason: None,
    durable_version: 1,
    fencing_epoch: execution.fencing_epoch,
  }
  { root, repository, adapters, execution, assurance }
}

///|
fn persist_assurance_loop_record(
  fixture : NativeAssuranceLoopFixture,
  record : @workflow.GoalAssuranceRecord,
) -> Unit raise {
  match
    @workflow.persist_goal_assurance_record(
      fixture.repository,
      fixture.adapters,
      {
        record,
        expected_store_version: None,
        goal_precondition: @workflow.goal_execution_state_precondition(
          fixture.execution,
        ),
        fault_point: None,
      },
    ) {
    Ok(
      {
        outcome: @workflow.GoalAssurancePersistenceOutcome::GoalAssurancePersistenceCompleted(
          _
        ),
        ..,
      }
    ) => ()
    Ok(_) => fail("Goal assurance seed lost its Goal precondition")
    Err(error) => fail(error.message())
  }
  // The decoder is what makes the seed a real record rather than a shape the
  // loop happens to tolerate.
  match
    @workflow.load_goal_assurance_record(
      fixture.repository,
      fixture.adapters,
      fixture.execution.goal.id,
    ) {
    Ok(Some(stored)) => assert_eq(stored.record, record)
    Ok(None) => fail("Goal assurance seed disappeared")
    Err(error) => fail(error.message())
  }
}

///|
/// One Claude slot for the whole portfolio, so a single held lease is the whole
/// of that surface.
fn assurance_loop_capacity() -> @types.ProviderCapacityPolicy {
  {
    claude_subscription_cli: 1,
    codex_subscription_cli: 4,
    global_execution_ceiling: None,
  }
}

///|
fn assurance_loop_held(
  fixture : NativeAssuranceLoopFixture,
  surface : @control.ProviderSurfaceId,
) -> Array[@workflow.ProviderLeaseId] raise {
  match
    @workflow.load_provider_surface_lease_record(
      fixture.repository,
      fixture.adapters,
      surface,
    ) {
    Ok(Some(stored)) => stored.record.held.map(fn(lease) { lease.id })
    Ok(None) => []
    Err(error) => fail(error.message())
  }
}

///|
/// THE LOOP ASKS. A Goal audit is refused when the surface its audit session
/// runs on is full, and it is refused before the audit box is prepared.
///
/// The refusal has to come from inside `advance_native_goal_assurance`: the
/// portfolio bound is only a bound if the code path that dispatches the audit
/// is the one that consults it. Take the gate call out and this attempt walks
/// straight on to authorize the sandbox effect and create a box on a surface
/// that is already serving everything it can.
async test "real exec integration: a full surface refuses the Goal assurance loop" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let surface = @control.ProviderSurfaceId::ClaudeSubscriptionCli
  let fixture = real_exec_integration_assurance_loop_fixture("refused", surface)
  persist_assurance_loop_record(fixture, fixture.assurance)
  let epoch = current_native_goal_fencing_epoch()
  // A Part of some other Goal holds the one configured slot.
  let holder = @workflow.provider_lease_id(
    @control.GoalId("goal-assurance-loop-holder"),
    @control.PartId("part-assurance-loop-holder"),
    surface,
  )
  match
    @workflow.acquire_provider_lease(
      fixture.repository,
      fixture.adapters,
      surface,
      {
        lease_id: holder,
        take_id: @control.TakeId("take-assurance-loop-holder"),
        goal_id: @control.GoalId("goal-assurance-loop-holder"),
        fencing_epoch: epoch,
      },
      assurance_loop_capacity(),
      1_000L,
    ) {
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseGranted(_, _)) => ()
    Ok(_) => fail("the holding Part was refused its own slot")
    Err(error) => fail(error.message())
  }
  assert_eq(assurance_loop_held(fixture, surface), [holder])
  let observed : Array[@workflow.ProviderSurfaceTickReport] = []
  let outcome = advance_native_goal_assurance(
    fixture.root,
    fixture.repository,
    fixture.adapters,
    fixture.execution,
    [],
    assurance_loop_capacity(),
    observe=fn(report) { observed.push(report) },
  )
  let instant = match outcome {
    Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceDeferredUntil(value)) =>
      value
    Ok(_) => fail("the assurance loop was not refused")
    Err(error) => fail(error.message())
  }
  // The refusal the daemon schedules against is the one this gate reported,
  // on the surface it judged.
  assert_eq(observed, [
    {
      surface,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        instant,
      ),
    },
  ])
  // A refused attempt took nothing, so the holder's slot is still the only one.
  assert_eq(assurance_loop_held(fixture, surface), [holder])
  // And it stopped exactly at the authorize boundary: the audit sandbox effect
  // is planned and unauthorized, which is what the next tick resumes from.
  match
    @workflow.load_goal_assurance_record(
      fixture.repository,
      fixture.adapters,
      fixture.execution.goal.id,
    ) {
    Ok(Some(stored)) =>
      assert_eq(
        stored.record.pending_effect.map(fn(intent) {
          (intent.kind, intent.lifecycle)
        }),
        Some(
          (
            @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(
              fixture.assurance.identities.audit_sandbox,
            ),
            @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectPlanned,
          ),
        ),
      )
    Ok(None) => fail("the Goal assurance record disappeared")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(fixture.root))
}

///|
/// THE LOOP GIVES IT BACK. An assurance tick that took a slot and then failed
/// returns it, so the surface is not one slot poorer for the rest of the
/// generation.
///
/// The failure is the real one that guard exists for: `choird` recorded a
/// cancellation while this tick was in flight, so the tick's durable write is
/// refused by the Goal precondition it was planned against and the attempt
/// cannot finish. There is no expiry on a provider lease — it comes back when
/// the tick returns it or when the generation dies — so a tick that returned
/// through this path without releasing would strand the slot until the daemon
/// restarted.
async test "real exec integration: a displaced assurance tick returns its slot" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let surface = @control.ProviderSurfaceId::ClaudeSubscriptionCli
  let fixture = real_exec_integration_assurance_loop_fixture(
    "displaced", surface,
  )
  // The audit sandbox effect is already planned, so this tick's first act is to
  // ask for the slot that authorizing it needs.
  let planned = match
    @workflow.plan_next_goal_assurance_effect(fixture.assurance) {
    Ok(Some(value)) => value
    Ok(None) => fail("the seeded Goal assurance has no next effect")
    Err(error) => fail(error.message())
  }
  persist_assurance_loop_record(fixture, {
    ..fixture.assurance,
    pending_effect: Some(planned),
  })
  assert_eq(assurance_loop_held(fixture, surface), [])
  // choird cancels the Goal. The tick still holds the record it loaded.
  match
    @workflow.persist_goal_cancellation_request(
      fixture.repository,
      fixture.adapters,
      fixture.execution.goal.id,
      1_000L,
    ) {
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(_)
    ) => ()
    Ok(_) => fail("the Goal cancellation did not displace the tick")
    Err(error) => fail(error.message())
  }
  let observed : Array[@workflow.ProviderSurfaceTickReport] = []
  let outcome = advance_native_goal_assurance(
    fixture.root,
    fixture.repository,
    fixture.adapters,
    fixture.execution,
    [],
    assurance_loop_capacity(),
    observe=fn(report) { observed.push(report) },
  )
  assert_true(outcome is Err(_))
  // The slot was really taken — otherwise the release below proves nothing.
  assert_eq(observed, [
    {
      surface,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
  ])
  // And really given back.
  assert_eq(assurance_loop_held(fixture, surface), [])
  // The tick wrote nothing on its way out: the displaced attempt left the
  // planned effect exactly where it found it, which is the state whose write
  // being refused is what failed the tick.
  match
    @workflow.load_goal_assurance_record(
      fixture.repository,
      fixture.adapters,
      fixture.execution.goal.id,
    ) {
    Ok(Some(stored)) => {
      assert_eq(stored.record.pending_effect, Some(planned))
      assert_eq(stored.record.durable_version, 1)
    }
    Ok(None) => fail("the Goal assurance record disappeared")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(fixture.root))
}
