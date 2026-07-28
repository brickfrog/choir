///|
fn native_planning_repository(
  root : String,
) -> @workflow.PartWorkflowRepository {
  {
    state_store: { path: root + "/state.db" },
    artifact_store: { root: root + "/artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
}

///|
fn native_planning_goal_draft() -> @workflow.ConductorGoalDraft {
  @workflow.decode_conductor_goal_draft(
    (
      #|{"proposal_id":"proposal-native-planning","goal_id":"goal-native-planning",
      #|"pull_request":{"title":"feat: deliver native planning","body":"Delivers the bounded planned change."},
      #|"maximum_parallel_parts":1,
      #|"parts":[{"part_id":"choir-native-next","commit_title":"feat: deliver native planning",
      #|"instruction":"Implement the bounded native planned change.","provider":"codex",
      #|"exact_paths":["src/native_next.mbt"],"moon_args":["test","--target","native"]}]}
    ),
  ).unwrap()
}

///|
fn native_planning_proposal() -> @workflow.WorkOrderPlanningProposal {
  {
    findings: [
      {
        summary: "One bounded Bead is eligible.",
        evidence: "The captured tracker graph has no open blocker.",
        related_bead_ids: [@control.PartId("choir-native-next")],
      },
    ],
    eligible_work_observed: true,
    bead_mutations: { mutations: [] },
    primary_target_ids: [@control.PartId("choir-native-next")],
    prerequisite_closure_ids: [],
    finite_goal: Some(native_planning_goal_draft()),
  }
}

///|
fn native_planning_work_order() -> @workflow.WorkOrderRecord {
  let digest = @storage.artifact_digest(@utf8.encode("native-planning"))
  {
    id: @workflow.WorkOrderId("work-order-native-planning"),
    repository_id: @workflow.RepositoryId("repository-native-planning"),
    objective: "Plan the next bounded Goal.",
    selection_policy: @workflow.WorkOrderSelectionPolicy::WorkOrderExactBeadClosure,
    planner: {
      primary_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      failover_surfaces: [],
    },
    initial_primary_target_ids: [@control.PartId("choir-initial")],
    initial_prerequisite_closure_ids: [],
    max_active_child_goals: 1,
    budget: @workflow.accept_work_order_budget(
      @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(20),
      @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
      100L,
    ).unwrap(),
    child_goals: [
      {
        goal_id: @control.GoalId("goal-native-initial"),
        selection_decision_digest: digest,
        primary_target_ids: [@control.PartId("choir-initial")],
        prerequisite_closure_ids: [],
        outcome: @workflow.WorkOrderChildOutcome::WorkOrderChildSucceeded,
      },
    ],
    planning_rounds: [],
    lifecycle: @workflow.WorkOrderLifecycle::WorkOrderActive,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
async test "native planning reconciles provider and Bead effects by durable phase" {
  let root = "/tmp/choir-native-planning-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create native planning root")
  }
  let repository = native_planning_repository(root)
  let repository_adapters = local_part_workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, repository_adapters).unwrap()
  let owner = native_planning_work_order()
  ignore(
    @workflow.persist_work_order_record(repository, repository_adapters, {
      record: owner,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let digest = @storage.artifact_digest(@utf8.encode("native-planning"))
  let proposal = native_planning_proposal()
  let content = @workflow.work_order_planning_proposal_bytes(proposal)
  let executions = @ref.new(0)
  let deliveries : Array[@workflow.WorkOrderPlanningRoundId] = []
  let adapters : NativeWorkOrderPlanningAdapters = {
    capture_snapshot: () => {
      Ok({ repository_digest: digest, bead_digest: digest, beads: [] })
    },
    execute_planner: (_, _) => {
      executions.val = executions.val + 1
      Ok(content)
    },
    recover_planner: (_, _) => Ok(NativeWorkOrderPlannerRecovered(content)),
    authorize_planner: (_, _) => Ok(NativeWorkOrderPlannerAdmitted),
    release_planner: (_, _) => Ok(()),
    deliver_beads: (round_id, batch) => {
      deliveries.push(round_id)
      Ok({
        batch_digest: @command.bead_batch_digest(batch),
        bead_snapshot_digest: digest,
      })
    },
    now: () => 101L,
  }
  // Intent, dispatch, artifact receipt, delivery intent, and delivery receipt
  // are five independent commits. Reloading inside every call is the restart
  // path, not an in-memory shortcut.
  for index = 0; index < 5; index = index + 1 {
    match
      run_native_work_order_planning_tick(
        repository,
        repository_adapters,
        owner.id,
        adapters,
      ) {
      Ok(NativeWorkOrderPlanningAdvanced(_)) => ()
      Ok(NativeWorkOrderPlanningIdle) =>
        fail("planning became idle before Bead delivery")
      Err(error) => fail(error.message())
    }
  }
  let stored = @workflow.load_work_order_record(
      repository,
      repository_adapters,
      owner.id,
    )
    .unwrap()
    .unwrap()
  assert_eq(
    stored.record.planning_rounds[0].phase,
    @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered,
  )
  assert_eq(executions.val, 0)
  assert_eq(deliveries, [stored.record.planning_rounds[0].id])
  assert_true(
    run_native_work_order_planning_tick(
      repository,
      repository_adapters,
      owner.id,
      adapters,
    ).unwrap()
    is NativeWorkOrderPlanningIdle,
  )
  ignore(@sys.rm_rf(root))
}

///|
async test "a crashed Bead delivery reuses the exact round and batch" {
  let root = "/tmp/choir-native-planning-delivery-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create native delivery root")
  }
  let repository = native_planning_repository(root)
  let repository_adapters = local_part_workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, repository_adapters).unwrap()
  let owner = native_planning_work_order()
  ignore(
    @workflow.persist_work_order_record(repository, repository_adapters, {
      record: owner,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let digest = @storage.artifact_digest(@utf8.encode("native-planning"))
  let proposal = native_planning_proposal()
  let content = @workflow.work_order_planning_proposal_bytes(proposal)
  let attempts : Array[@workflow.WorkOrderPlanningRoundId] = []
  let adapters : NativeWorkOrderPlanningAdapters = {
    capture_snapshot: () => {
      Ok({ repository_digest: digest, bead_digest: digest, beads: [] })
    },
    execute_planner: (_, _) => Ok(content),
    recover_planner: (_, _) => Ok(NativeWorkOrderPlannerExactRetryAuthorized),
    authorize_planner: (_, _) => Ok(NativeWorkOrderPlannerAdmitted),
    release_planner: (_, _) => Ok(()),
    deliver_beads: (round_id, batch) => {
      attempts.push(round_id)
      if attempts.length() == 1 {
        Err(@types.ChoirError::validation_error("simulated tracker crash"))
      } else {
        Ok({
          batch_digest: @command.bead_batch_digest(batch),
          bead_snapshot_digest: digest,
        })
      }
    },
    now: () => 101L,
  }
  // Reach the persisted BeadsDelivering phase.
  for index = 0; index < 4; index = index + 1 {
    ignore(
      run_native_work_order_planning_tick(
        repository,
        repository_adapters,
        owner.id,
        adapters,
      ).unwrap(),
    )
  }
  assert_true(
    run_native_work_order_planning_tick(
      repository,
      repository_adapters,
      owner.id,
      adapters,
    )
    is Err(_),
  )
  ignore(
    run_native_work_order_planning_tick(
      repository,
      repository_adapters,
      owner.id,
      adapters,
    ).unwrap(),
  )
  assert_eq(attempts.length(), 2)
  assert_eq(attempts[0], attempts[1])
  ignore(@sys.rm_rf(root))
}
