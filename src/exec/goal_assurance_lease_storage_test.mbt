///| Portfolio admission for the Goal's own audit session, driven against a real
/// control store.
///
/// These tests call `native_goal_assurance_effect_admission` — the gate
/// `advance_native_goal_assurance` itself calls before it authorizes or runs an
/// assurance effect — and `finish_native_goal_assurance_leases`, which is that
/// tick's teardown. Nothing here is a stand-in: the surface bound is decided
/// against the same durable lease record the Part gate writes, which is what
/// makes a Goal audit and a Part compete for one slot rather than two.

///|
/// The identity plan a Goal assurance attempt is planned against, with its
/// audit session moved onto the surface these tests bound. The shared fixture
/// plans the audit onto Codex; what is under test is one surface's bound, so
/// the audit session and the Part leases have to name the same surface.
fn assurance_lease_identities(
  record : @workflow.GoalExecutionRecord,
) -> @workflow.GoalAssuranceIdentityPlan {
  let base = workflow_store_goal_assurance_identities(
    record.goal,
    @control.GitOid("assurance-head-" + record.goal.id.0),
  )
  {
    ..base,
    audit_session: { ..base.audit_session, surface: provider_lease_surface },
  }
}

///|
fn assurance_lease_audit_take_id(label : String) -> @control.TakeId {
  @control.TakeId("goal-audit-take-" + label)
}

///|
fn assurance_lease_audit_subject(
  goal_id : @control.GoalId,
) -> @control.GoalAuditSubject {
  {
    goal_id,
    goal_branch_seal_id: @control.GoalBranchSealId("seal-" + goal_id.0),
    goal_branch_seal_digest: workflow_store_digest_a,
    goal_head_oid: @control.GitOid("assurance-head-" + goal_id.0),
    goal_tree_oid: @control.GitOid("assurance-tree-" + goal_id.0),
    goal_contract_digest: workflow_store_digest_b,
    assurance_policy_revision: @control.RevisionId("assurance-policy-1"),
    integration_receipt_set_digest: workflow_store_digest_a,
    goal_verification_receipt_set_digest: workflow_store_digest_b,
    goal_verification_evidence_manifest_digest: workflow_store_digest_a,
    subject_digest: workflow_store_digest_b,
  }
}

///|
fn assurance_lease_admit(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
  label : String,
  kind : @workflow.GoalAssuranceEffectKind,
  capacity : @types.ProviderCapacityPolicy,
  epoch : Int64,
  now : Int64,
  holds : Array[NativeProviderLeaseHold],
  observed? : Array[@workflow.ProviderSurfaceTickReport] = [],
) -> @workflow.GoalAssuranceTickOutcome? raise {
  match
    native_goal_assurance_effect_admission(
      repository,
      record.goal.id,
      assurance_lease_audit_take_id(label),
      assurance_lease_identities(record),
      kind,
      capacity,
      @control.FencingEpoch(epoch),
      now,
      holds,
      observe=fn(report) { observed.push(report) },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
/// WHAT THE ASSURANCE LEASE IS KEYED ON. The identity is derived, so its inputs
/// are the whole of its meaning: drop one and two things that must not share a
/// slot start sharing one.
///
/// The Part collision is the sharp one. A Goal's assurance lease and its own
/// Part's lease are written into the same held set, so if the two derivations
/// ever agreed, a Goal audit would silently reuse the Part's slot — admitted
/// while the surface was full, and released twice.
test "a Goal assurance lease is keyed on the Goal, its audit Take, and surface" {
  let goal = @control.GoalId("goal-lease-identity")
  let take = @control.TakeId("goal-audit-take-identity")
  let lease = @workflow.goal_assurance_provider_lease_id(
    goal, take, provider_lease_surface,
  )
  // The same attempt asking again derives the same slot. That is what makes a
  // retried tick idempotent rather than a leak.
  assert_eq(
    lease,
    @workflow.goal_assurance_provider_lease_id(
      goal, take, provider_lease_surface,
    ),
  )
  // A replanned attempt mints a fresh audit Take, and that is a different
  // session: it must not inherit the slot the previous attempt recorded for
  // teardown.
  assert_not_eq(
    lease,
    @workflow.goal_assurance_provider_lease_id(
      goal,
      @control.TakeId("goal-audit-take-identity-replanned"),
      provider_lease_surface,
    ),
  )
  assert_not_eq(
    lease,
    @workflow.goal_assurance_provider_lease_id(
      @control.GoalId("goal-lease-identity-other"),
      take,
      provider_lease_surface,
    ),
  )
  assert_not_eq(
    lease,
    @workflow.goal_assurance_provider_lease_id(
      goal,
      take,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ),
  )
  // A Part of the same Goal, on the same surface, keyed by a Part id that reads
  // like the audit Take: still a different slot.
  assert_not_eq(
    lease,
    @workflow.provider_lease_id(
      goal,
      @control.PartId(take.0),
      provider_lease_surface,
    ),
  )
}

///|
/// GOAL ASSURANCE IS COUNTED. A Goal's own audit session is a provider dispatch
/// like any other, so a surface a Part already filled refuses it and names when
/// to come back. Before this gate existed the dispatch simply ran, and Goal
/// audits were not counted against surface capacity at all.
test "a Goal audit cannot dispatch onto a surface a Part filled" {
  let root = "/tmp/choir-assurance-lease-capacity-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let running = provider_lease_running_record("assurance-part")
  let assuring = provider_lease_running_record("assurance-goal")
  archive_native_persist(repository, adapters, running)
  archive_native_persist(repository, adapters, assuring)
  let capacity = provider_lease_capacity(1)
  // A Part takes the one slot, through the Part gate the daemon runs.
  assert_true(
    provider_lease_authorize(
      repository, running, "assurance-part", capacity, 3L, 1_000L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 1)
  let holds : Array[NativeProviderLeaseHold] = []
  let identities = assurance_lease_identities(assuring)
  let dispatch = @workflow.GoalAssuranceEffectKind::DispatchGoalAudit(
    assurance_lease_audit_take_id("assurance-goal"),
    identities.audit_session.id,
    assurance_lease_audit_subject(assuring.goal.id),
  )
  // The Goal audit asks for a slot on the same surface and is refused with an
  // instant rather than a bare no.
  assert_eq(
    assurance_lease_admit(
      repository, assuring, "assurance-goal", dispatch, capacity, 3L, 2_000L, holds,
    ),
    Some(
      @workflow.GoalAssuranceTickOutcome::GoalAssuranceDeferredUntil(
        2_005L,
        @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
      ),
    ),
  )
  // A refused attempt holds nothing, so the tick's teardown has nothing to give
  // back and the Part's slot is untouched.
  assert_eq(holds, [])
  assert_eq(provider_lease_held(repository), 1)
  // Two configured slots and the same ask is admitted, so the refusal above was
  // the bound rather than anything about a Goal audit.
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "assurance-goal",
      dispatch,
      provider_lease_capacity(2),
      3L,
      2_100L,
      holds,
    ),
    None,
  )
  assert_eq(provider_lease_held(repository), 2)
  // The slot recorded for teardown is the derived assurance identity, not a
  // minted one: teardown re-derives nothing, so a disagreement here would be a
  // slot held until the daemon generation ended.
  assert_eq(holds, [
    {
      surface: provider_lease_surface,
      lease_id: @workflow.goal_assurance_provider_lease_id(
        assuring.goal.id,
        assurance_lease_audit_take_id("assurance-goal"),
        provider_lease_surface,
      ),
    },
  ])
  ignore(@sys.rm_rf(root))
}

///|
/// ONE SLOT PER ATTEMPT, NOT PER ASK. The assurance lease is derived from the
/// Goal and its audit Take, so the sandbox, the harness start, and the dispatch
/// all ask for one slot, and a retried tick asks for the slot it already holds.
/// Deriving it wrong leaks a slot per tick, which is worse than leaving Goal
/// assurance unbounded.
test "a retried assurance tick takes the slot it already holds" {
  let root = "/tmp/choir-assurance-lease-retry-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let assuring = provider_lease_running_record("retry-goal")
  let other = provider_lease_running_record("retry-other")
  archive_native_persist(repository, adapters, assuring)
  archive_native_persist(repository, adapters, other)
  let capacity = provider_lease_capacity(1)
  let identities = assurance_lease_identities(assuring)
  let first : Array[NativeProviderLeaseHold] = []
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "retry-goal",
      @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(
        identities.audit_sandbox,
      ),
      capacity,
      3L,
      1_000L,
      first,
    ),
    None,
  )
  assert_eq(provider_lease_held(repository), 1)
  // A later effect of the same attempt takes no second slot.
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "retry-goal",
      @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(
        identities.audit_session,
      ),
      capacity,
      3L,
      1_100L,
      first,
    ),
    None,
  )
  assert_eq(first.length(), 1)
  assert_eq(provider_lease_held(repository), 1)
  // A whole retried tick, with its own empty accumulator, asks for the same
  // lease and is granted the one it already holds.
  let retried : Array[NativeProviderLeaseHold] = []
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "retry-goal",
      @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(
        identities.audit_sandbox,
      ),
      capacity,
      3L,
      1_200L,
      retried,
    ),
    None,
  )
  assert_eq(retried, first)
  assert_eq(provider_lease_held(repository), 1)
  // The one slot really is taken: another Goal asking now is refused. Without
  // this the count above would also be satisfied by a gate that took nothing.
  assert_true(
    assurance_lease_admit(
      repository,
      other,
      "retry-other",
      @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(
        identities.audit_sandbox,
      ),
      capacity,
      3L,
      1_300L,
      [],
    )
    is Some(
      @workflow.GoalAssuranceTickOutcome::GoalAssuranceDeferredUntil(_, _)
    ),
  )
  ignore(@sys.rm_rf(root))
}

///|
/// THE SLOT COMES BACK, FAILURE INCLUDED. An assurance attempt that failed
/// while holding a provider seat and did not return it would starve the surface
/// until the daemon generation ended.
test "a failed assurance attempt returns its provider slot" {
  let root = "/tmp/choir-assurance-lease-teardown-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let assuring = provider_lease_running_record("teardown-goal")
  let next = provider_lease_running_record("teardown-next")
  archive_native_persist(repository, adapters, assuring)
  archive_native_persist(repository, adapters, next)
  let capacity = provider_lease_capacity(1)
  let identities = assurance_lease_identities(assuring)
  let holds : Array[NativeProviderLeaseHold] = []
  let observed : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "teardown-goal",
      @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(
        identities.audit_session,
      ),
      capacity,
      3L,
      1_000L,
      holds,
      observed~,
    ),
    None,
  )
  assert_eq(provider_lease_held(repository), 1)
  // The attempt failed. Its error is what the tick reports, and the slot is
  // returned on the way out anyway.
  assert_true(
    finish_native_goal_assurance_leases(
      repository,
      holds,
      Err(@types.ChoirError::validation_error("assurance dispatch failed")),
      @control.FencingEpoch(3L),
    )
    is Err(_),
  )
  assert_eq(provider_lease_held(repository), 0)
  // The freed slot is real: the next Goal takes it at capacity one.
  assert_eq(
    assurance_lease_admit(
      repository,
      next,
      "teardown-next",
      @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(
        identities.audit_session,
      ),
      capacity,
      3L,
      1_100L,
      [],
      observed~,
    ),
    None,
  )
  assert_eq(provider_lease_held(repository), 1)
  // Sweeping the same holds again is a no-op rather than a second decrement,
  // and a successful attempt's outcome survives its teardown unchanged.
  assert_true(
    finish_native_goal_assurance_leases(
      repository,
      holds,
      Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending),
      @control.FencingEpoch(3L),
    )
    is Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending),
  )
  // Only the gate reports, and only what it judged: two admissions, and nothing
  // from either teardown. A teardown that reported too would count one refusal
  // twice and park the daemon on an instant no gate named.
  assert_eq(observed, [
    {
      surface: provider_lease_surface,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
    {
      surface: provider_lease_surface,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
  ])
  assert_eq(provider_lease_held(repository), 1)
  ignore(@sys.rm_rf(root))
}

///|
/// A refused Goal audit names its surface and its wake instant.
///
/// The instant is what the daemon sleeps to, and the surface is what decides
/// whether it sleeps at all — a refusal on a spent surface must not hold back a
/// Goal that would run on the other one. Both come from the gate, because the
/// gate is the only place that knows which surface it just judged.
test "a refused Goal audit reports the surface it was refused on" {
  let root = "/tmp/choir-assurance-lease-refused-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let holder = provider_lease_running_record("refused-holder")
  let refused = provider_lease_running_record("refused-goal")
  archive_native_persist(repository, adapters, holder)
  archive_native_persist(repository, adapters, refused)
  let capacity = provider_lease_capacity(1)
  let observed : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_eq(
    assurance_lease_admit(
      repository,
      holder,
      "refused-holder",
      @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(
        assurance_lease_identities(holder).audit_session,
      ),
      capacity,
      3L,
      2_000L,
      [],
      observed~,
    ),
    None,
  )
  assert_eq(provider_lease_held(repository), 1)
  // The one slot is spent, so the second Goal's audit is refused rather than
  // dispatched: a Goal audit competes for the same seat a Part does.
  assert_eq(
    assurance_lease_admit(
      repository,
      refused,
      "refused-goal",
      @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(
        assurance_lease_identities(refused).audit_session,
      ),
      capacity,
      3L,
      2_000L,
      [],
      observed~,
    ),
    Some(
      @workflow.GoalAssuranceTickOutcome::GoalAssuranceDeferredUntil(
        2_005L,
        @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
      ),
    ),
  )
  // The refusal took no slot on its way out.
  assert_eq(provider_lease_held(repository), 1)
  assert_eq(observed, [
    {
      surface: provider_lease_surface,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
    {
      surface: provider_lease_surface,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        2_005L,
      ),
    },
  ])
  ignore(@sys.rm_rf(root))
}

///|
/// Sealing and combined verification reach no provider. Verification runs the
/// Goal's own declared commands in a sandbox, so leasing a subscription slot
/// for it would hold a seat for the length of a test suite and would let a busy
/// surface stop a Goal from running its own checks.
test "Goal verification takes no provider slot" {
  let root = "/tmp/choir-assurance-lease-verify-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let assuring = provider_lease_running_record("verify-goal")
  archive_native_persist(repository, adapters, assuring)
  let identities = assurance_lease_identities(assuring)
  let holds : Array[NativeProviderLeaseHold] = []
  // Capacity zero refuses anything that asks, so admission here means the
  // verification effects did not ask.
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "verify-goal",
      @workflow.GoalAssuranceEffectKind::PrepareGoalVerificationSandbox(
        identities.verification_sandbox,
      ),
      provider_lease_capacity(0),
      3L,
      1_000L,
      holds,
    ),
    None,
  )
  assert_eq(
    assurance_lease_admit(
      repository,
      assuring,
      "verify-goal",
      @workflow.GoalAssuranceEffectKind::DispatchGoalVerification(
        identities.verification_take.id,
        {
          goal_id: assuring.goal.id,
          goal_branch_seal_id: @control.GoalBranchSealId("seal-verify"),
          goal_branch_seal_digest: workflow_store_digest_a,
          goal_head_oid: @control.GitOid("assurance-head-verify"),
          goal_tree_oid: @control.GitOid("assurance-tree-verify"),
          goal_contract_digest: workflow_store_digest_b,
          assurance_policy_revision: @control.RevisionId("assurance-policy-1"),
          integration_receipt_set_digest: workflow_store_digest_a,
          subject_digest: workflow_store_digest_a,
        },
      ),
      provider_lease_capacity(0),
      3L,
      1_100L,
      holds,
    ),
    None,
  )
  assert_eq(holds, [])
  assert_eq(provider_lease_held(repository), 0)
  ignore(@sys.rm_rf(root))
}

///|
/// A CAPACITY REFUSAL IS NOT A VERDICT. The execution tick must leave a Goal
/// whose audit was refused exactly where it was — assuring, with its durable
/// record untouched — so the next tick resumes at the same effect. Mapping the
/// refusal onto any other state would turn a busy provider surface into a
/// blocked or advanced Goal, permanently.
async test "an assurance tick refused by capacity leaves the Goal assuring" {
  let repository = workflow_repository("assurance-capacity-deferral")
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
          id: @control.IntegrationLeaseId("assurance-deferral-lease"),
          goal_id: current.goal.id,
          fencing_epoch: current.fencing_epoch,
          holder: "choird-test",
        },
        intent_id: @control.IntegrationIntentId("assurance-deferral-intent"),
        expected_goal_head_oid: selection.expected_goal_head_oid,
        promotion_metadata_digest: workflow_store_digest_a,
        git_witness_ref: "refs/choir/witness/assurance-deferral-intent",
      })
    },
    plan_conflict_repair: fn(_) {
      Ok(@workflow.PartConflictRepairDecision::PartConflictRepairLimitReached)
    },
    plan_audit_repair: fn(_) {
      Ok(@workflow.PartAuditRepairDecision::PartAuditRepairLimitReached)
    },
    plan_verification_repair: fn(_) {
      Ok(
        @workflow.PartVerificationRepairDecision::PartVerificationRepairLimitReached,
      )
    },
    plan_recovery_retry: fn(_) {
      Err(@types.ChoirError::validation_error("recovery is not expected"))
    },
    read_goal_head: () => Ok(@control.GitOid("goal-head-store")),
    release_provider_lease: fn(_) { Ok(()) },
  }
  assert_eq(
    @workflow.run_goal_parts(
      [scheduling_record],
      1,
      @exec.goal_part_workflow_adapters(config),
    ).unwrap().outcome,
    @workflow.GoalRunOutcome::GoalRunSucceeded,
  )
  let integrated = @workflow.load_part_snapshot(
      repository,
      adapters,
      snapshot.workflow_id,
    )
    .unwrap()
    .unwrap().snapshot
  let repository_id = @workflow.RepositoryId("repository-assurance-deferral")
  let execution : @workflow.GoalExecutionRecord = {
    goal: integrated.goal,
    repository_id,
    selection_decision_digest: workflow_store_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("goal-head-store"),
    base_tree_oid: @control.GitOid("goal-tree-store"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise a refused Goal assurance tick",
      body: "Exercises the capacity deferral outcome.",
      draft: false,
    }),
    migration_production_admission: None,
    goal_ref: @workflow.goal_execution_ref(integrated.goal.id),
    branch_initialization: workflow_store_initialized_branch(
      integrated.goal.id,
      repository_id,
      @workflow.goal_execution_ref(integrated.goal.id),
      @control.GitOid("goal-head-store"),
    ),
    source_claims: [
      @workflow.receipted_goal_source_claim(
        integrated.goal.id,
        integrated.part.id,
        workflow_store_digest_a,
        workflow_store_digest_a,
        1L,
      ),
    ],
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
    work_order_budget: None,
    durable_version: 1,
    fencing_epoch: integrated.fencing_epoch,
  }
  ignore(
    @workflow.persist_goal_execution_record(repository, adapters, {
      record: execution,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let assuring = match
    @workflow.run_next_goal_execution_tick(repository, adapters, {
      initialize: _ => Ok(true),
      execute: (_, _) => fail("integrated Goal dispatched another Part"),
      assure: (_, _) => fail("assurance ran before its durable transition"),
      finalize: (_, _) => fail("finalization ran before assurance"),
      cancel: (_, _) => fail("running Goal entered cancellation"),
    }) {
    Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced)) =>
      advanced
    Ok(_) => fail("integrated Goal did not enter assurance")
    Err(error) => fail(error.message())
  }
  assert_eq(assuring.state, @workflow.GoalExecutionState::GoalExecutionAssuring)
  let refused = match
    @workflow.run_next_goal_execution_tick(repository, adapters, {
      initialize: _ => Ok(true),
      execute: (_, _) => fail("assuring Goal dispatched a Part"),
      assure: (_, _) => {
        Ok(
          @workflow.GoalAssuranceTickOutcome::GoalAssuranceDeferredUntil(
            9_000L,
            @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
          ),
        )
      },
      finalize: (_, _) => fail("a refused Goal entered finalization"),
      cancel: (_, _) => fail("a refused Goal entered cancellation"),
    }) {
    Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced)) =>
      advanced
    Ok(_) => fail("the refused tick reported idle")
    Err(error) => fail(error.message())
  }
  // Nothing moved: the same state, the same durable version, no cancellation.
  assert_eq(refused, assuring)
  match
    @workflow.load_goal_execution_record(repository, adapters, assuring.goal.id) {
    Ok(Some(stored)) => assert_eq(stored.record, assuring)
    Ok(None) => fail("the refused Goal record disappeared")
    Err(error) => fail(error.message())
  }
  clean_workflow_repository(repository)
}
