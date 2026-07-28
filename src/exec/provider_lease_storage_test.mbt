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
  surface? : @control.ProviderSurfaceId = provider_lease_surface,
  observed? : Array[@workflow.ProviderSurfaceTickReport] = [],
) -> @workflow.PartGoalAuthorization raise {
  match
    native_goal_effect_authorization(
      repository,
      record.goal.id,
      @control.PartId("part-" + label),
      surface,
      @control.TakeId("take-" + label),
      capacity,
      @control.FencingEpoch(epoch),
      now,
      observe=fn(report) { observed.push(report) },
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
/// The scheduler's sleep is decided from what this gate reports, so the gate
/// has to name the surface it judged and which way it went. A report that named
/// only refusals would park the daemon on an instant while a surface it just
/// admitted work on sat idle.
test "the gate reports the surface it admitted and the surface it refused" {
  let root = "/tmp/choir-provider-lease-report-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let goal = provider_lease_running_record("report-goal")
  archive_native_persist(repository, adapters, goal)
  let claude = @control.ProviderSurfaceId::ClaudeSubscriptionCli
  let codex = @control.ProviderSurfaceId::CodexSubscriptionCli
  // One Claude slot, two Codex slots.
  let capacity = provider_lease_capacity(1, codex=2)
  let observed : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_lease_authorize(
      repository,
      goal,
      "report-claude",
      capacity,
      3L,
      1_000L,
      surface=claude,
      observed~,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  assert_true(
    provider_lease_authorize(
      repository,
      goal,
      "report-codex",
      capacity,
      3L,
      1_000L,
      surface=codex,
      observed~,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  // The Claude bound is spent; Codex still has room.
  assert_true(
    provider_lease_authorize(
      repository,
      goal,
      "report-claude-second",
      capacity,
      3L,
      1_000L,
      surface=claude,
      observed~,
    )
    is @workflow.PartGoalAuthorization::PartGoalDeferredUntil(_, _),
  )
  assert_eq(observed, [
    {
      surface: claude,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
    {
      surface: codex,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
    {
      surface: claude,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        1_005L,
      ),
    },
  ])
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
/// A Part the gate refuses runs nothing and holds nothing.
///
/// The wake instant itself is reported by the gate — see "the gate tells the
/// tick which surface it admitted and which it refused" — so what is under test
/// here is the other half: a refusal must not start an effect, and must not
/// leave the Part sitting on a provider slot every other Goal is waiting for.
async test "a deferred Part runs no effect and gives its slot back" {
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
    release_provider_lease: fn(part_id) {
      released.push(part_id)
      Ok(())
    },
  }
  match (@exec.goal_part_workflow_adapters(config).advance_part)(record) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  // A refused Part ran no effect: the deferral is the whole outcome.
  assert_eq(execute_count.val, 0)
  // The slot goes back when the pass returns rather than when the Goal tick
  // ends, so a Part that is idle for the rest of the tick is not holding a
  // surface every other Goal is waiting on.
  assert_eq(released, [record.part.id])
  clean_workflow_repository(repository)
}

///|
/// A repair the gate refuses is not written.
///
/// The recovery-repair pass re-arms a Part onto another provider surface, and
/// it asks the gate before persisting that. Were the refusal ignored, the Part
/// would have moved surfaces on a pass the gate declined to authorize.
async test "a repair refused by a capacity bound is not persisted" {
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
    release_provider_lease: fn(_) { Ok(()) },
  }
  match (@exec.goal_part_workflow_adapters(config).advance_part)(record) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
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

///|
/// Ask the gate the daemon asks, keeping what it answered.
///
/// `observed` is the array the report below is built from, and the gate is the
/// only thing that writes to it — an instant in the report is therefore one
/// this gate named rather than one the test also wrote. The epoch is this
/// process's current generation, so the reader's reclamation keeps what the
/// gate just took.
fn provider_capacity_authorize(
  repository : @workflow.PartWorkflowRepository,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  capacity : @types.ProviderCapacityPolicy,
  now : Int64,
  observed : Array[@workflow.ProviderSurfaceTickReport],
) -> @workflow.PartGoalAuthorization raise {
  match
    native_goal_effect_authorization(
      repository,
      goal_id,
      part_id,
      provider_lease_surface,
      @control.TakeId("take-" + part_id.0),
      capacity,
      current_native_goal_fencing_epoch(),
      now,
      observe=fn(report) { observed.push(report) },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
/// The report the daemon's observer publishes: the same durable store, the
/// same configured bounds, and what the tick just answered.
///
/// The gate's answers are folded exactly as `observe_native_goal_provider_surface`
/// folds them, because that folded observation is the one the daemon holds —
/// one telemetry path for the scheduler's sleep and for this report rather
/// than a second one built for reporting. Its rule shows here: a surface that
/// admitted anything reports no wake instant, because it did not need one.
fn provider_capacity_report(
  root : String,
  goal_id : @control.GoalId,
  capacity : @types.ProviderCapacityPolicy,
  observed : Array[@workflow.ProviderSurfaceTickReport],
) -> @workflow.GoalStatusReport raise {
  let mut folded : Array[@workflow.ProviderSurfaceTickReport] = []
  for report in observed {
    folded = @workflow.record_provider_surface_tick_report(folded, report)
  }
  match
    inspect_native_goal(
      root,
      goal_id,
      provider_capacity=Some(capacity),
      surface_reports=folded,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn provider_capacity_part_snapshot(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
) -> @workflow.PartWorkflowSnapshot raise {
  let snapshot = workflow_store_fixture()
  match
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(_) => snapshot
    Err(error) => fail(error.message())
  }
}

///|
/// CAPACITY PRESSURE IS VISIBLE. A surface at its bound with a Part waiting on
/// it reports as such, and every figure in that report is read from the
/// durable lease record the gate committed rather than handed to the
/// projection.
///
/// Three moments of one store: the surface full while this Goal's Part waits,
/// the surface free, and the surface full because this Goal's own Part is the
/// one being served. Only the middle renders nothing, and only the first
/// reports a Part as waiting — a projection that counted held slots without
/// asking whose they are cannot tell the first from the third.
test "a full provider surface and the Part waiting on it are read from lease state" {
  let root = "/tmp/choir-provider-capacity-report-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let goal = provider_lease_running_record("store")
  archive_native_persist(repository, adapters, goal)
  let snapshot = provider_capacity_part_snapshot(repository, adapters)
  assert_eq(snapshot.goal.id, goal.goal.id)
  // A second Goal holds the only Claude slot, so this Goal's Part is refused
  // by the capacity bound alone.
  let blocker = provider_lease_running_record("capacity-blocker")
  archive_native_persist(repository, adapters, blocker)
  let capacity = provider_lease_capacity(1)
  // One tick admits the blocking Goal and asks for nothing else.
  let admitting_tick : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_capacity_authorize(
      repository,
      blocker.goal.id,
      @control.PartId("part-capacity-blocker"),
      capacity,
      2_000L,
      admitting_tick,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  let full = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    admitting_tick,
  )
  // Held is the length of the surface's own held set, and it alone is what
  // makes this pressure: this tick refused nothing.
  assert_eq(full.provider_capacity, [
    {
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      held: 1,
      capacity: 1,
      deferred_until: None,
    },
    {
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      held: 0,
      capacity: 4,
      deferred_until: None,
    },
  ])
  assert_eq(full.parts[0].leased_provider_surface, None)
  assert_eq(@workflow.work_order_portfolio(full, 2_000L).provider_deferred, 1)
  let pressured = @workflow.conductor_goal_display(full, 2_000L).unwrap()
  assert_eq(pressured.provider_waiting, 1)
  assert_eq(pressured.capacity_pressure, [
    {
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      held: 1,
      capacity: 1,
      deferred_until: None,
    },
  ])
  // The next tick reaches the gate with this Goal's Part and is refused. The
  // instant the report carries is the instant that refusal named.
  let refusing_tick : Array[@workflow.ProviderSurfaceTickReport] = []
  let refused = provider_capacity_authorize(
    repository,
    goal.goal.id,
    snapshot.part.id,
    capacity,
    2_400L,
    refusing_tick,
  )
  let deferred_until = match refused {
    @workflow.PartGoalAuthorization::PartGoalDeferredUntil(instant, _) =>
      instant
    _ => fail("the gate admitted the Part the surface had no room for")
  }
  let waiting = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    refusing_tick,
  )
  assert_eq(waiting.provider_capacity[0], {
    surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    held: 1,
    capacity: 1,
    deferred_until: Some(deferred_until),
  })
  assert_eq(
    @workflow.work_order_portfolio(waiting, 2_400L).provider_deferred,
    1,
  )
  // The blocking Goal gives the slot back, and the next tick refuses nothing:
  // spare capacity with nothing waiting is not pressure.
  assert_true(
    provider_lease_release(
      repository,
      blocker,
      "capacity-blocker",
      current_native_goal_fencing_epoch().0,
    )
    is @workflow.ProviderLeaseReleaseDecision::ProviderLeaseReleased(_),
  )
  // The tick that follows asks for nothing on Claude, so it reports nothing.
  let quiet_tick : Array[@workflow.ProviderSurfaceTickReport] = []
  let free = provider_capacity_report(root, goal.goal.id, capacity, quiet_tick)
  assert_eq(free.provider_capacity, [
    {
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      held: 0,
      capacity: 1,
      deferred_until: None,
    },
    {
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      held: 0,
      capacity: 4,
      deferred_until: None,
    },
  ])
  assert_eq(@workflow.work_order_portfolio(free, 2_000L).provider_deferred, 0)
  let quiet = @workflow.conductor_goal_display(free, 2_000L).unwrap()
  assert_eq(quiet.capacity_pressure, [])
  assert_eq(quiet.provider_waiting, 0)
  // The same surface, equally full, but the slot is this Goal's Part: it is
  // being served rather than starved, and nothing is waiting.
  assert_true(
    provider_capacity_authorize(
      repository,
      goal.goal.id,
      snapshot.part.id,
      capacity,
      3_000L,
      quiet_tick,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  let serving = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    quiet_tick,
  )
  assert_eq(serving.provider_capacity[0].held, 1)
  assert_eq(
    serving.parts[0].leased_provider_surface,
    Some(@control.ProviderSurfaceId::ClaudeSubscriptionCli),
  )
  assert_eq(
    @workflow.work_order_portfolio(serving, 3_000L).provider_deferred,
    0,
  )
  let served = @workflow.conductor_goal_display(serving, 3_000L).unwrap()
  assert_eq(served.provider_waiting, 0)
  // The surface is still at its bound, so the pressure is still shown.
  assert_eq(served.capacity_pressure.length(), 1)
  // A slot whose worker no longer exists is not pressure. The gate reclaims it
  // on its next read, and a report that counted it would have an operator
  // waiting on a full surface that is in fact empty. Same durable record, read
  // by the generation that replaced the one holding it.
  let reclaimed = match
    @workflow.list_provider_surface_lease_records(repository, adapters) {
    Ok(lease_records) =>
      match
        @workflow.goal_status_report(
          goal,
          [snapshot],
          None,
          None,
          None,
          None,
          provider_capacity=Some({
            lease_records,
            tick_reports: [],
            policy: capacity,
            fencing_epoch: @control.FencingEpoch(
              current_native_goal_fencing_epoch().0 + 1L,
            ),
          }),
        ) {
        Ok(value) => value
        Err(error) => fail(error.message())
      }
    Err(error) => fail(error.message())
  }
  assert_eq(reclaimed.provider_capacity[0].held, 0)
  assert_eq(reclaimed.parts[0].leased_provider_surface, None)
  assert_eq(
    @workflow.conductor_goal_display(reclaimed, 3_000L).unwrap().capacity_pressure,
    [],
  )
  ignore(@sys.rm_rf(root))
}

///|
/// A reader without the configured bounds reports no bound.
///
/// The alternative is a default capacity nobody chose, which reads exactly
/// like a real one: an operator would see "claude 4/4" on a project configured
/// for two and have no way to tell.
test "a report built without a capacity observation claims no capacity" {
  let root = "/tmp/choir-provider-capacity-absent-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let goal = provider_lease_running_record("store")
  archive_native_persist(repository, adapters, goal)
  let snapshot = provider_capacity_part_snapshot(repository, adapters)
  assert_true(
    provider_capacity_authorize(
      repository,
      goal.goal.id,
      snapshot.part.id,
      provider_lease_capacity(1),
      4_000L,
      [],
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  match inspect_native_goal(root, goal.goal.id) {
    Ok(report) => {
      assert_eq(report.provider_capacity, [])
      // The slot is held, and a reader that did not read the bounds does not
      // report it either: one observation rather than two.
      assert_eq(report.parts[0].leased_provider_surface, None)
    }
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
/// PRESSURE REACHES THE READER WHILE IT IS HAPPENING.
///
/// `conductor_broadcast_goal_update` publishes nothing when a report's material
/// fingerprint is unchanged, and a Goal parked at the admission gate has no
/// other change to offer: the refusal is a `PartGoalDeferredUntil`, not a
/// durable observation, so no stage, lifecycle, or diagnostic moves. If the
/// fingerprint ignored capacity, the one condition whose whole point is that
/// nothing is moving would be the one condition that never reached an operator.
///
/// Four moments of one store, and the Goal is untouched across all of them:
/// same Part, same stage, same lifecycles. Every report is the one
/// `conductor_goal_observer` would publish — `inspect_native_goal` reading the
/// records the real admission gate committed — so what is fingerprinted here is
/// the daemon's own projection rather than a shape this test invented.
test "the fingerprint carries capacity pressure but not the wake instant" {
  let root = "/tmp/choir-provider-capacity-delivery-" +
    @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let goal = provider_lease_running_record("store")
  archive_native_persist(repository, adapters, goal)
  let snapshot = provider_capacity_part_snapshot(repository, adapters)
  let blocker = provider_lease_running_record("capacity-blocker")
  archive_native_persist(repository, adapters, blocker)
  let capacity = provider_lease_capacity(1)
  let blocker_part = @control.PartId("part-capacity-blocker")
  // Nothing held anywhere, and the tick that just ran asked for nothing.
  let free = provider_capacity_report(root, goal.goal.id, capacity, [])
  // A second Goal takes the only Claude slot. This Goal did not move.
  let admitting_tick : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_capacity_authorize(
      repository,
      blocker.goal.id,
      blocker_part,
      capacity,
      2_000L,
      admitting_tick,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  let starved = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    admitting_tick,
  )
  assert_eq(starved.parts[0].leased_provider_surface, None)
  assert_true(
    @workflow.goal_report_material_fingerprint(free) !=
    @workflow.goal_report_material_fingerprint(starved),
  )
  // The next two ticks reach the gate with this Goal's Part and are refused at
  // different instants. The gate named both; neither is a change a reader is
  // owed a second delivery for, and a fingerprint that carried them would
  // re-fire for as long as the surface stayed full.
  let first_refusal : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_capacity_authorize(
      repository,
      goal.goal.id,
      snapshot.part.id,
      capacity,
      2_400L,
      first_refusal,
    )
    is @workflow.PartGoalAuthorization::PartGoalDeferredUntil(_, _),
  )
  let second_refusal : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_capacity_authorize(
      repository,
      goal.goal.id,
      snapshot.part.id,
      capacity,
      2_600L,
      second_refusal,
    )
    is @workflow.PartGoalAuthorization::PartGoalDeferredUntil(_, _),
  )
  let deferred_once = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    first_refusal,
  )
  let deferred_again = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    second_refusal,
  )
  assert_true(
    deferred_once.provider_capacity[0].deferred_until !=
    deferred_again.provider_capacity[0].deferred_until,
  )
  assert_eq(
    @workflow.goal_report_material_fingerprint(starved),
    @workflow.goal_report_material_fingerprint(deferred_once),
  )
  assert_eq(
    @workflow.goal_report_material_fingerprint(deferred_once),
    @workflow.goal_report_material_fingerprint(deferred_again),
  )
  // The blocking Goal gives the slot back and this Goal's Part takes it. The
  // surface is exactly as full as it was, so nothing the capacity projection
  // reports about it changed — only whose slot it is, which is the difference
  // between waiting and working and the thing the operator is watching for.
  assert_true(
    provider_lease_release(
      repository,
      blocker,
      "capacity-blocker",
      current_native_goal_fencing_epoch().0,
    )
    is @workflow.ProviderLeaseReleaseDecision::ProviderLeaseReleased(_),
  )
  let serving_tick : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_capacity_authorize(
      repository,
      goal.goal.id,
      snapshot.part.id,
      capacity,
      3_000L,
      serving_tick,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  let served = provider_capacity_report(
    root,
    goal.goal.id,
    capacity,
    serving_tick,
  )
  assert_eq(served.provider_capacity, starved.provider_capacity)
  assert_eq(
    served.parts[0].leased_provider_surface,
    Some(provider_lease_surface),
  )
  assert_true(
    @workflow.goal_report_material_fingerprint(starved) !=
    @workflow.goal_report_material_fingerprint(served),
  )
  // A surface no Part of this Goal runs on is still pressure its reader is
  // shown — `conductor_goal_display` reports every pressured surface, not only
  // the ones this Goal competes for — so it has to reach them too. This Goal's
  // only Part holds its Claude slot throughout, so nothing here parks anything
  // and the parked count cannot be what carries it.
  let bounded = provider_lease_capacity(1, codex=1)
  let codex_free = provider_capacity_report(
    root,
    goal.goal.id,
    bounded,
    serving_tick,
  )
  let codex_tick : Array[@workflow.ProviderSurfaceTickReport] = []
  assert_true(
    provider_lease_authorize(
      repository,
      blocker,
      "capacity-blocker-codex",
      bounded,
      current_native_goal_fencing_epoch().0,
      3_200L,
      surface=@control.ProviderSurfaceId::CodexSubscriptionCli,
      observed=codex_tick,
    )
    is @workflow.PartGoalAuthorization::PartGoalAuthorized(Some(_)),
  )
  let codex_full = provider_capacity_report(
    root,
    goal.goal.id,
    bounded,
    codex_tick,
  )
  assert_eq(codex_free.provider_capacity[1].held, 0)
  assert_eq(codex_full.provider_capacity[1].held, 1)
  let unparked = @workflow.conductor_goal_display(codex_full, 3_200L).unwrap()
  assert_eq(unparked.provider_waiting, 0)
  assert_eq(unparked.capacity_pressure.length(), 2)
  assert_true(
    @workflow.goal_report_material_fingerprint(codex_free) !=
    @workflow.goal_report_material_fingerprint(codex_full),
  )
  ignore(@sys.rm_rf(root))
}
