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
        outcome: @workflow.WorkOrderChildOutcome::WorkOrderChildQuarantined(
          digest,
        ),
        delivery_evidence: None,
        delivery_accounted: false,
      },
    ],
    planning_rounds: [],
    lifecycle: @workflow.WorkOrderLifecycle::WorkOrderActive,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
async test "delivered round admits one durable successor and replays it" {
  let root = "/tmp/choir-native-successor-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root + "/.choir/state/control") {
    fail("failed to create native successor root")
  }
  let base_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let base_tree = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let bead_json =
    #|[{"id":"choir-native-next","title":"Deliver native planning","description":"Implement the bounded native planned change.","acceptance_criteria":"The native test passes.","status":"open","priority":0,"issue_type":"task","dependency_count":0,"updated_at":"2026-07-28T00:00:00Z"}]
  let capture : async (Command) -> (Int, String) = command => {
    match (command.program, command.args) {
      ("git", ["symbolic-ref", "--quiet", "HEAD"]) => (0, "refs/heads/main\n")
      ("git", ["rev-parse", "--show-toplevel"]) => (0, root + "\n")
      ("git", ["rev-parse", "--verify", "HEAD^{commit}"]) =>
        (0, base_commit + "\n")
      ("git", ["rev-parse", "--verify", "refs/heads/main^{commit}"]) =>
        (0, base_commit + "\n")
      (
        "git",
        [
          "show",
          "-s",
          "--format=%T",
          "--no-show-signature",
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ],
      ) => (0, base_tree + "\n")
      ("git", ["ls-tree", "--name-only", tree, "--", "moon.mod"]) if tree ==
        base_tree => (0, "")
      ("bd", arguments) =>
        if arguments[0] == "list" {
          (0, bead_json)
        } else if arguments[0] == "show" && arguments[1] == "choir-native-next" {
          (0, bead_json)
        } else {
          (-1, "unexpected Beads command")
        }
      _ => (-1, "unexpected capture")
    }
  }
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/.choir/state/control/workflow.db" },
    artifact_store: { root: root + "/.choir/state/control/artifacts" },
    max_snapshot_bytes: 4 * 1024 * 1024,
  }
  let repository_adapters = @storage_host.local_part_workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, repository_adapters).unwrap()
  let successor_epoch = @control.FencingEpoch(37L)
  let beads = @command.bead_records_from_json(@json.parse(bead_json)).unwrap()
  let snapshot : NativeWorkOrderPlanningSnapshot = {
    repository_root: root,
    object_directory: root + "/.git/objects",
    commit_oid: @control.GitOid(base_commit),
    tree_oid: @control.GitOid(base_tree),
    repository_digest: @storage.artifact_digest(
      @utf8.encode(
        "choir.work-order-repository-snapshot.v1\u{00}" +
        @workflow.repository_id(root).0 +
        "\u{00}" +
        base_commit +
        "\u{00}" +
        base_tree,
      ),
    ),
    bead_digest: @command.bead_graph_digest(beads),
    beads,
  }
  let owner = {
    ..native_planning_work_order(),
    repository_id: @workflow.repository_id(root),
  }
  let planned = @workflow.plan_work_order_round(
    owner,
    snapshot.repository_digest,
    snapshot.bead_digest,
  ).unwrap()
  let dispatched = @workflow.dispatch_work_order_planning_round(planned, 101L).unwrap()
  let proposal = native_planning_proposal()
  let content = @workflow.work_order_planning_proposal_bytes(proposal)
  let proposal_digest = @storage.artifact_digest(content)
  let artifact = (repository_adapters.artifacts.adopt)(
    repository.artifact_store,
    {
      content,
      expected_digest: proposal_digest,
      provenance: @storage.ArtifactProvenance::ArtifactWorkOrderRecord,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    },
  ).unwrap()
  let received = @workflow.record_work_order_planning_proposal(
    dispatched,
    { artifact_id: artifact.artifact_id.0, digest: artifact.digest },
    content,
    snapshot.repository_digest,
    snapshot.bead_digest,
    snapshot.beads,
    101L,
  ).unwrap()
  let delivered = @workflow.complete_work_order_bead_delivery(
    @workflow.begin_work_order_bead_delivery(received).unwrap(),
    @command.bead_batch_digest(proposal.bead_mutations),
    snapshot.bead_digest,
  ).unwrap()
  match
    @workflow.persist_work_order_record(repository, repository_adapters, {
      record: { ..delivered, durable_version: 1 },
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  let first = match
    admit_observed_native_work_order_successor(
      root,
      owner.id,
      snapshot,
      capture,
      successor_epoch,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(first.accepted)
  assert_false(first.replayed)
  assert_eq(first.work_order_id, Some(owner.id))
  let replay = match
    admit_observed_native_work_order_successor(
      root,
      owner.id,
      snapshot,
      capture,
      successor_epoch,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(replay.replayed)
  assert_eq(replay.selection_decision_digest, first.selection_decision_digest)
  let stored = @workflow.load_work_order_record(
      repository,
      repository_adapters,
      owner.id,
    )
    .unwrap()
    .unwrap()
  assert_eq(stored.record.child_goals.length(), 2)
  assert_eq(
    stored.record.child_goals
    .filter(fn(child) {
      child.outcome == @workflow.WorkOrderChildOutcome::WorkOrderChildActive
    })
    .length(),
    1,
  )
  assert_eq(
    stored.record.planning_rounds[0].phase,
    @workflow.WorkOrderPlanningPhase::WorkOrderPlanningGoalReady,
  )
  assert_eq(stored.record.fencing_epoch, successor_epoch)
  let part = @workflow.load_part_snapshot(
      repository,
      repository_adapters,
      native_goal_part_workflow_id(
        @control.GoalId("goal-native-planning"),
        @control.PartId("choir-native-next"),
      ),
    )
    .unwrap()
    .unwrap()
  assert_eq(part.snapshot.fencing_epoch, successor_epoch)
  let execution = @workflow.load_goal_execution_record(
      repository,
      repository_adapters,
      @control.GoalId("goal-native-planning"),
    )
    .unwrap()
    .unwrap()
  assert_eq(execution.record.fencing_epoch, successor_epoch)
  ignore(@sys.rm_rf(root))
}

///|
async test "native planning reconciles provider and Bead effects by durable phase" {
  let root = "/tmp/choir-native-planning-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create native planning root")
  }
  let repository = native_planning_repository(root)
  let repository_adapters = @storage_host.local_part_workflow_repository_adapters()
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
      Ok({
        repository_root: "/tmp/repository",
        object_directory: "/tmp/repository/.git/objects",
        commit_oid: @control.GitOid("1111111111111111111111111111111111111111"),
        tree_oid: @control.GitOid("2222222222222222222222222222222222222222"),
        repository_digest: digest,
        bead_digest: digest,
        beads: [],
      })
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
  let repository_adapters = @storage_host.local_part_workflow_repository_adapters()
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
      Ok({
        repository_root: "/tmp/repository",
        object_directory: "/tmp/repository/.git/objects",
        commit_oid: @control.GitOid("1111111111111111111111111111111111111111"),
        tree_oid: @control.GitOid("2222222222222222222222222222222222222222"),
        repository_digest: digest,
        bead_digest: digest,
        beads: [],
      })
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

///|
test "WorkOrder executor leases persist, release fairly, and fence on restart" {
  let root = "/tmp/choir-work-order-executor-store-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create WorkOrder executor store")
  }
  let repository = native_planning_repository(root)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, adapters).unwrap()
  let first = {
    ..native_planning_work_order(),
    id: @workflow.WorkOrderId("work-order-executor-first"),
    child_goals: [],
  }
  let second = {
    ..native_planning_work_order(),
    id: @workflow.WorkOrderId("work-order-executor-second"),
    child_goals: [],
  }
  for record in [first, second] {
    ignore(
      @workflow.persist_work_order_record(repository, adapters, {
        record,
        expected_store_version: None,
        fault_point: None,
      }).unwrap(),
    )
  }
  let epoch = @control.FencingEpoch(20L)
  let planned = @workflow.acquire_work_order_executor_dispatches(
    repository, adapters, 1, 1_000L, epoch,
  ).unwrap()
  assert_eq(planned.leases.length(), 1)
  let held = planned.leases[0]
  assert_true(
    @workflow.work_order_executor_lease_is_authorized(
      repository, adapters, held,
    ).unwrap(),
  )
  let replay = @workflow.acquire_work_order_executor_dispatches(
    repository, adapters, 1, 1_000L, epoch,
  ).unwrap()
  assert_eq(replay.leases, [])
  let completed = @workflow.persist_work_order_executor_completion(
    repository,
    adapters,
    held,
    @workflow.WorkOrderExecutionJobTickOutcome::WorkOrderExecutionJobTickSucceeded(
      Some(first.durable_version),
      [],
    ),
    1_000L,
  ).unwrap()
  assert_eq(completed.lease, None)
  let next = @workflow.acquire_work_order_executor_dispatches(
    repository, adapters, 1, 1_000L, epoch,
  ).unwrap()
  assert_eq(next.leases.length(), 1)
  assert_true(next.leases[0].work_order_id != held.work_order_id)
  let replacement = @workflow.acquire_work_order_executor_dispatches(
    repository,
    adapters,
    1,
    1_001L,
    @control.FencingEpoch(21L),
  ).unwrap()
  assert_eq(replacement.leases.length(), 1)
  assert_false(
    @workflow.work_order_executor_lease_is_authorized(
      repository,
      adapters,
      next.leases[0],
    ).unwrap(),
  )
  assert_true(
    @workflow.work_order_executor_lease_is_authorized(
      repository,
      adapters,
      replacement.leases[0],
    ).unwrap(),
  )
  ignore(@sys.rm_rf(root))
}

///|
test "planner attempt recovery distinguishes planned, issued, and completed" {
  let root = "/tmp/choir-work-order-attempt-store-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create planner attempt store")
  }
  let repository = native_planning_repository(root)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, adapters).unwrap()
  let digest = @storage.artifact_digest(@utf8.encode("attempt"))
  let owner = @workflow.dispatch_work_order_planning_round(
    @workflow.plan_work_order_round(
      native_planning_work_order(),
      digest,
      digest,
    ).unwrap(),
    101L,
  ).unwrap()
  let round = owner.planning_rounds.last().unwrap()
  let planned = @workflow.ensure_work_order_planner_attempt(
    repository, adapters, owner, round, digest, digest,
  ).unwrap()
  assert_true(
    planned.record.lifecycle
    is @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned,
  )
  let adopted = @workflow.ensure_work_order_planner_attempt(
    repository,
    adapters,
    {
      ..owner,
      durable_version: owner.durable_version + 1,
      fencing_epoch: @control.FencingEpoch(2L),
    },
    round,
    digest,
    digest,
  ).unwrap()
  assert_eq(adopted.record.fencing_epoch, @control.FencingEpoch(2L))
  let issued = @workflow.persist_work_order_planner_attempt_transition(
    repository,
    adapters,
    adopted,
    @workflow.issue_work_order_planner_attempt(adopted.record, 102L).unwrap(),
  ).unwrap()
  assert_true(
    issued.record.lifecycle
    is @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptIssued(
      102L
    ),
  )
  let content = @workflow.work_order_planning_proposal_bytes(
    native_planning_proposal(),
  )
  let result_digest = @storage.artifact_digest(content)
  let receipt = (adapters.artifacts.adopt)(repository.artifact_store, {
    content,
    expected_digest: result_digest,
    provenance: @storage.ArtifactProvenance::ArtifactWorkOrderPlannerResult,
    retention: @storage.ArtifactRetention::ArtifactPermanent,
  }).unwrap()
  let completed = @workflow.persist_work_order_planner_attempt_transition(
    repository,
    adapters,
    issued,
    @workflow.complete_work_order_planner_attempt(
      issued.record,
      { artifact_id: receipt.artifact_id.0, digest: receipt.digest },
      103L,
    ).unwrap(),
  ).unwrap()
  assert_true(
    completed.record.lifecycle
    is @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptCompleted(
      _,
      103L
    ),
  )
  assert_eq(
    @workflow.load_work_order_planner_attempt(repository, adapters, round)
    .unwrap()
    .unwrap().record,
    completed.record,
  )
  ignore(@sys.rm_rf(root))
}

///|
async test "a delivered child leaves GoalReady and starts the next round" {
  let root = "/tmp/choir-work-order-next-round-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create next-round store")
  }
  let repository = native_planning_repository(root)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  @workflow.initialize_part_workflow_repository(repository, adapters).unwrap()
  let digest = @storage.artifact_digest(@utf8.encode("next-round"))
  let proposal = native_planning_proposal()
  let content = @workflow.work_order_planning_proposal_bytes(proposal)
  let dispatched = @workflow.dispatch_work_order_planning_round(
    @workflow.plan_work_order_round(
      native_planning_work_order(),
      digest,
      digest,
    ).unwrap(),
    101L,
  ).unwrap()
  let received = @workflow.record_work_order_planning_proposal(
    dispatched,
    {
      artifact_id: "next-round-proposal",
      digest: @storage.artifact_digest(content),
    },
    content,
    digest,
    digest,
    [],
    101L,
  ).unwrap()
  let delivered = @workflow.complete_work_order_bead_delivery(
    @workflow.begin_work_order_bead_delivery(received).unwrap(),
    @command.bead_batch_digest(proposal.bead_mutations),
    digest,
  ).unwrap()
  let rounds = delivered.planning_rounds.copy()
  rounds[0] = {
    ..rounds[0],
    phase: @workflow.WorkOrderPlanningPhase::WorkOrderPlanningGoalReady,
  }
  let ready = { ..delivered, planning_rounds: rounds, durable_version: 1 }
  ignore(
    @workflow.persist_work_order_record(repository, adapters, {
      record: ready,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let snapshot : NativeWorkOrderPlanningSnapshot = {
    repository_root: "/tmp/repository",
    object_directory: "/tmp/repository/.git/objects",
    commit_oid: @control.GitOid("1111111111111111111111111111111111111111"),
    tree_oid: @control.GitOid("2222222222222222222222222222222222222222"),
    repository_digest: digest,
    bead_digest: digest,
    beads: [],
  }
  let planning : NativeWorkOrderPlanningAdapters = {
    capture_snapshot: fn() { Ok(snapshot) },
    execute_planner: (_, _) => Ok(content),
    recover_planner: (_, _) => Ok(NativeWorkOrderPlannerRecovered(content)),
    authorize_planner: (_, _) => Ok(NativeWorkOrderPlannerAdmitted),
    release_planner: (_, _) => Ok(()),
    deliver_beads: (_, _) => {
      Ok({ batch_digest: digest, bead_snapshot_digest: digest })
    },
    now: fn() { 102L },
  }
  let advanced = run_native_work_order_planning_tick(
    repository,
    adapters,
    ready.id,
    planning,
  ).unwrap()
  guard advanced is NativeWorkOrderPlanningAdvanced(record) else {
    fail("GoalReady did not advance")
  }
  assert_eq(record.planning_rounds.length(), 2)
  assert_eq(
    record.planning_rounds[1].phase,
    @workflow.WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded,
  )
  ignore(@sys.rm_rf(root))
}
