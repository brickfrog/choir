///| The admission gate the Goal worker actually runs, driven against a real
/// control store.
///
/// These tests call `native_goal_effect_authorization` — the same function the
/// `goal_authorizes_new_effects` dependency is bound to inside
/// `execute_native_goal_record` — rather than a stand-in predicate. A capacity
/// test at a layer where the gate is injected proves the stand-in, not the
/// daemon.

///|
let provider_lease_surface : @control.ProviderSurfaceId = @control.ProviderSurfaceId::ClaudeSubscriptionCli

///|
fn provider_lease_capacity(
  claude : Int,
  codex? : Int = 4,
  global? : Int? = None,
) -> @types.ProviderCapacityPolicy {
  {
    claude_subscription_cli: claude,
    codex_subscription_cli: codex,
    global_execution_ceiling: global,
  }
}

///|
/// A Goal the admission gate will consider: running, branch initialized, and
/// with the lifecycle its own decoder demands for that state.
fn provider_lease_running_record(
  label : String,
) -> @workflow.GoalExecutionRecord raise {
  let queued = archive_native_queued_record(label~)
  archive_native_initialized({
    ..queued,
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
  })
}

///|
fn provider_lease_authorize(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
  label : String,
  capacity : @types.ProviderCapacityPolicy,
  epoch : Int64,
  now : Int64,
) -> @workflow.PartGoalAuthorization raise {
  match
    native_goal_effect_authorization(
      repository,
      record.goal.id,
      @control.PartId("part-" + label),
      provider_lease_surface,
      @control.TakeId("take-" + label),
      capacity,
      @control.FencingEpoch(epoch),
      now,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn provider_lease_release(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
  label : String,
  epoch : Int64,
) -> @workflow.ProviderLeaseReleaseDecision raise {
  match
    @workflow.release_provider_lease(
      repository,
      local_part_workflow_repository_adapters(),
      provider_lease_surface,
      @workflow.provider_lease_id(
        record.goal.id,
        @control.PartId("part-" + label),
        provider_lease_surface,
      ),
      @control.FencingEpoch(epoch),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn provider_lease_held(
  repository : @workflow.PartWorkflowRepository,
) -> Int raise {
  match
    @workflow.load_provider_surface_lease_record(
      repository,
      local_part_workflow_repository_adapters(),
      provider_lease_surface,
    ) {
    Ok(Some(stored)) => stored.record.held.length()
    Ok(None) => 0
    Err(error) => fail(error.message())
  }
}

///|
/// NO OVERSUBSCRIPTION. Two Goals, one configured slot: the gate admits one and
/// tells the other when to come back. Both are running and within budget, so
/// nothing but the capacity bound separates them.
test "two running Goals cannot both take the last provider slot" {
  let root = "/tmp/choir-provider-lease-capacity-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let first = provider_lease_running_record("lease-first")
  let second = provider_lease_running_record("lease-second")
  archive_native_persist(repository, adapters, first)
  archive_native_persist(repository, adapters, second)
  let capacity = provider_lease_capacity(1)
  let admitted = provider_lease_authorize(
    repository, first, "lease-first", capacity, 3L, 1_000L,
  )
  assert_true(
    admitted is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 1)
  let refused = provider_lease_authorize(
    repository, second, "lease-second", capacity, 3L, 1_000L,
  )
  assert_eq(
    refused,
    @workflow.PartGoalAuthorization::PartGoalDeferredUntil(
      1_005L,
      @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
    ),
  )
  // The refusal took no slot, so nothing leaked on the way out.
  assert_eq(provider_lease_held(repository), 1)
  // The first Goal re-entering the gate keeps the one slot it already holds
  // rather than taking another.
  assert_true(
    provider_lease_authorize(
      repository, first, "lease-first", capacity, 3L, 1_200L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 1)
  // Two configured slots and the second Goal is admitted, so the refusal above
  // was the bound rather than anything about the second Goal.
  assert_true(
    provider_lease_authorize(
      repository,
      second,
      "lease-second",
      provider_lease_capacity(2),
      3L,
      1_300L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 2)
  ignore(@sys.rm_rf(root))
}

///|
/// RESTART RECONCILIATION. A worker that died holding a slot left its lease in
/// the record. The generation that replaces it reclaims that lease on read, and
/// nothing about the same generation reclaims anything.
test "a provider slot held by a dead generation does not block the next one" {
  let root = "/tmp/choir-provider-lease-restart-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let first = provider_lease_running_record("restart-first")
  let second = provider_lease_running_record("restart-second")
  archive_native_persist(repository, adapters, first)
  archive_native_persist(repository, adapters, second)
  let capacity = provider_lease_capacity(1)
  assert_true(
    provider_lease_authorize(
      repository, first, "restart-first", capacity, 3L, 1_000L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  // Same generation: the slot is taken and stays taken.
  assert_eq(
    provider_lease_authorize(
      repository, second, "restart-second", capacity, 3L, 2_000L,
    ),
    @workflow.PartGoalAuthorization::PartGoalDeferredUntil(
      2_005L,
      @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
    ),
  )
  // The daemon restarted and minted a greater epoch. The dead worker's lease is
  // reclaimed on this read, so the slot is free and no separate reconciliation
  // pass ran.
  assert_true(
    provider_lease_authorize(
      repository, second, "restart-second", capacity, 4L, 3_000L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 1)
  match
    @workflow.load_provider_surface_lease_record(
      repository, adapters, provider_lease_surface,
    ) {
    Ok(Some(stored)) => {
      assert_eq(stored.record.held[0].goal_id, second.goal.id)
      assert_eq(stored.record.held[0].fencing_epoch, @control.FencingEpoch(4L))
    }
    Ok(None) => fail("the reclaimed surface record disappeared")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
/// IDEMPOTENT RELEASE. Releasing twice must not free two slots, and releasing
/// something never held must not free one.
test "releasing a provider slot twice frees exactly one slot" {
  let root = "/tmp/choir-provider-lease-release-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let first = provider_lease_running_record("release-first")
  let second = provider_lease_running_record("release-second")
  archive_native_persist(repository, adapters, first)
  archive_native_persist(repository, adapters, second)
  let capacity = provider_lease_capacity(2)
  assert_true(
    provider_lease_authorize(
      repository, first, "release-first", capacity, 3L, 1_000L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_true(
    provider_lease_authorize(
      repository, second, "release-second", capacity, 3L, 1_001L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 2)
  assert_true(
    provider_lease_release(repository, first, "release-first", 3L)
    is @workflow.ProviderLeaseReleaseDecision::ProviderLeaseReleased(_),
  )
  assert_eq(provider_lease_held(repository), 1)
  // The retry: no record is written, so the count cannot move again.
  assert_eq(
    provider_lease_release(repository, first, "release-first", 3L),
    @workflow.ProviderLeaseReleaseDecision::ProviderLeaseAlreadyReleased,
  )
  assert_eq(provider_lease_held(repository), 1)
  // A slot that was never taken releases the same way.
  assert_eq(
    provider_lease_release(repository, first, "release-never-held", 3L),
    @workflow.ProviderLeaseReleaseDecision::ProviderLeaseAlreadyReleased,
  )
  assert_eq(provider_lease_held(repository), 1)
  // The surviving lease is the one that was not released, and the freed slot is
  // available exactly once.
  match
    @workflow.load_provider_surface_lease_record(
      repository, adapters, provider_lease_surface,
    ) {
    Ok(Some(stored)) => assert_eq(stored.record.held[0].goal_id, second.goal.id)
    Ok(None) => fail("the surface record disappeared")
    Err(error) => fail(error.message())
  }
  assert_true(
    provider_lease_authorize(
      repository, first, "release-first", capacity, 3L, 1_002L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 2)
  ignore(@sys.rm_rf(root))
}

///|
/// The tick gives its slots back by re-deriving the lease identity, not by
/// remembering what it took. If that derivation disagreed with the gate's, the
/// slot would stay held until the daemon generation ended and the surface would
/// quietly stop admitting work.
test "the tick releases exactly the slots its gate leased" {
  let root = "/tmp/choir-provider-lease-teardown-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  // The fixture snapshot and the Goal record name the same Goal and Part, which
  // is what makes this a round trip rather than two unrelated identities.
  let snapshot = workflow_store_fixture()
  let record = provider_lease_running_record("store")
  assert_eq(record.goal.id, snapshot.goal.id)
  archive_native_persist(repository, adapters, record)
  let epoch = current_native_goal_fencing_epoch()
  assert_true(
    provider_lease_authorize(
      repository,
      record,
      "store",
      provider_lease_capacity(1),
      epoch.0,
      1_000L,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_eq(provider_lease_held(repository), 1)
  match release_native_goal_provider_leases(repository, [snapshot]) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  assert_eq(provider_lease_held(repository), 0)
  // Running the teardown again is a no-op rather than an error, which is what a
  // tick that failed part way through relies on.
  match release_native_goal_provider_leases(repository, [snapshot]) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  assert_eq(provider_lease_held(repository), 0)
  ignore(@sys.rm_rf(root))
}

///|
/// The instant has to reach the scheduler, or the gate can name a wake time
/// nobody waits for. This drives the Goal Part adapter with a gate that defers,
/// and checks the instant arrives at the observer the execution tick binds.
/// The capacity rule itself is proven against the real gate above; what is
/// under test here is only the path the instant travels.
async test "a deferred Part reports its wake instant to the tick" {
  let repository = workflow_repository("provider-lease-deferral")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize provider-deferral repository")
  }
  let initial = workflow_store_fixture()
  let record : @workflow.GoalPartSchedulingRecord = {
    part: { ..initial.part, lifecycle: @control.PartLifecycle::PartPending },
    task_contract: initial.task_contract,
  }
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let released : Array[@control.PartId] = []
  let config : @exec.GoalPartWorkflowAdapterConfig = {
    bindings: [
      { scheduling_record: record, initial_snapshot: initial, repository },
    ],
    repository_adapters: adapters,
    dependencies: fn(_, _) {
      Ok({
        ..dependencies,
        goal_authorizes_new_effects: fn() {
          Ok(
            @workflow.PartGoalAuthorization::PartGoalDeferredUntil(
              4_242L,
              @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
            ),
          )
        },
      })
    },
    integration_input: fn(_, _) {
      Err(@types.ChoirError::validation_error("integration is not expected"))
    },
    plan_conflict_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    plan_audit_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    plan_verification_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    plan_recovery_retry: fn(_) {
      Err(@types.ChoirError::validation_error("recovery is not expected"))
    },
    read_goal_head: () => Ok(@control.GitOid("goal-head-deferral")),
    observe_provider_deferral: fn(instant) {
      observed_deferral.val = Some(instant)
    },
    release_provider_lease: fn(part_id) {
      released.push(part_id)
      Ok(())
    },
  }
  match (@exec.goal_part_workflow_adapters(config).advance_part)(record) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  assert_eq(observed_deferral.val, Some(4_242L))
  // A refused Part ran no effect: the deferral is the whole outcome.
  assert_eq(execute_count.val, 0)
  // The slot goes back when the pass returns rather than when the Goal tick
  // ends, so a Part that is idle for the rest of the tick is not holding a
  // surface every other Goal is waiting on.
  assert_eq(released, [record.part.id])
  clean_workflow_repository(repository)
}

///|
/// The repair pass has to report its own deferral.
///
/// `advance_bound_part` can forward the instant because the driver hands it a
/// `PartRunGoalDeferredUntil` outcome to read it from. The repair pass cannot:
/// the outcome that routed the Part here describes the recovery, so if this
/// pass drops the instant nothing else carries it and the refusal degrades to
/// polling. This drives the recovery-repair branch with a gate that defers and
/// checks both halves — the instant is reported, and the repair is not written.
async test "a repair refused by a capacity bound still names its wake instant" {
  let repository = workflow_repository("provider-lease-repair-deferral")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize repair-deferral repository")
  }
  let initial = workflow_store_fixture()
  let uncertain = {
    ..initial,
    stage: @workflow.PartWorkflowStage::PartRecoveryUncertain,
    part: {
      ..initial.part,
      lifecycle: @control.PartLifecycle::PartBlocked(
        @control.PartBlockReason::PartRecoveryUncertain,
      ),
    },
    admitted_provider_surfaces: [
      @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      @control.ProviderSurfaceId::CodexSubscriptionCli,
    ],
  }
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: uncertain,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let moved : @workflow.PartProviderFailover = {
    from_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    to_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    cause: @control.ProviderAvailability::ProviderAllowanceExhausted(None),
    retry_ordinal: 1,
    decided_at: 500L,
  }
  let planned = {
    ..uncertain,
    durable_version: uncertain.durable_version + 1,
    stage: @workflow.PartWorkflowStage::PartAccepted,
    identities: {
      ..uncertain.identities,
      implementation_session: {
        ..uncertain.identities.implementation_session,
        surface: moved.to_surface,
      },
      audit_session: {
        ..uncertain.identities.audit_session,
        surface: moved.to_surface,
      },
    },
    provider_failovers: [moved],
  }
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let record : @workflow.GoalPartSchedulingRecord = {
    part: uncertain.part,
    task_contract: uncertain.task_contract,
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let config : @exec.GoalPartWorkflowAdapterConfig = {
    bindings: [
      { scheduling_record: record, initial_snapshot: initial, repository },
    ],
    repository_adapters: adapters,
    dependencies: fn(_, _) {
      Ok({
        ..dependencies,
        goal_authorizes_new_effects: fn() {
          Ok(
            @workflow.PartGoalAuthorization::PartGoalDeferredUntil(
              7_314L,
              @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
            ),
          )
        },
      })
    },
    integration_input: fn(_, _) {
      Err(@types.ChoirError::validation_error("integration is not expected"))
    },
    plan_conflict_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    plan_audit_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    plan_verification_repair: fn(_) {
      Err(@types.ChoirError::validation_error("repair is not expected"))
    },
    plan_recovery_retry: fn(_) {
      Ok(
        @workflow.PartRecoveryRetryDecision::PartRecoveryRetryFailedOver(
          planned, moved,
        ),
      )
    },
    read_goal_head: () => Ok(@control.GitOid("goal-head-repair-deferral")),
    observe_provider_deferral: fn(instant) {
      observed_deferral.val = Some(instant)
    },
    release_provider_lease: fn(_) { Ok(()) },
  }
  match (@exec.goal_part_workflow_adapters(config).advance_part)(record) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  assert_eq(observed_deferral.val, Some(7_314L))
  // The other half: a refused repair is not written. Were it persisted, the
  // Part would have moved surfaces on a pass the gate declined to authorize.
  let stored = @workflow.load_part_snapshot(
      repository,
      adapters,
      initial.workflow_id,
    )
    .unwrap()
    .unwrap().snapshot
  assert_eq(stored.provider_failovers, [])
  assert_eq(
    stored.identities.implementation_session.surface,
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  assert_eq(execute_count.val, 0)
  clean_workflow_repository(repository)
}

///|
/// The cheap gate runs first: a Goal that is no longer running is refused
/// outright, and must not take a provider slot on its way to being refused.
test "a Goal that is not running is refused without taking a slot" {
  let root = "/tmp/choir-provider-lease-state-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let finished = archive_native_succeeded(
    archive_native_queued_record(label="lease-finished"),
  )
  archive_native_persist(repository, adapters, finished)
  assert_eq(
    provider_lease_authorize(
      repository,
      finished,
      "lease-finished",
      provider_lease_capacity(1),
      3L,
      1_000L,
    ),
    @workflow.PartGoalAuthorization::PartGoalNotAuthorized,
  )
  assert_eq(provider_lease_held(repository), 0)
  ignore(@sys.rm_rf(root))
}
