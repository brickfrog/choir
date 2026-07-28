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
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
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
  assert_eq(provider_lease_held(repository), 1)
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
