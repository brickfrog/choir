///|
async test "native Conductor submission captures Beads and persists once" {
  let root = "/tmp/choir-conductor-submit-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Conductor submission root")
  }
  let base_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let base_tree = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let capture = async fn(command : @exec.Command) -> (Int, String) {
    match (command.program, command.args) {
      ("git", ["symbolic-ref", "--quiet", "HEAD"]) => (0, "refs/heads/main\n")
      ("git", ["rev-parse", "--show-toplevel"]) => (0, root + "\n")
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
      ("bd", ["show", "choir-a", "--json", "--readonly"]) =>
        (
          0,
          (
            #|[{"id":"choir-a","title":"Change A","description":"Update the answer","acceptance_criteria":"The focused test passes","status":"open","priority":2,"issue_type":"task","dependency_count":0,"updated_at":"2026-07-20T00:00:00Z"}]
          ),
        )
      _ => (-1, "unexpected capture")
    }
  }
  let draft =
    #|{
    #|  "proposal_id": "proposal-native-submit",
    #|  "goal_id": "goal-native-submit",
    #|  "maximum_parallel_parts": 1,
    #|  "parts": [
    #|    {
    #|      "part_id": "choir-a",
    #|      "instruction": "Change only src/a.mbt so answer_a returns 2.",
    #|      "provider": "codex",
    #|      "exact_paths": ["src/a.mbt"],
    #|      "moon_args": ["test", "--target", "native", "src/a.mbt"]
    #|    }
    #|  ]
    #|}
  let first = match submit_native_conductor_goal_draft(root, draft, capture) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(first.accepted)
  assert_false(first.replayed)
  assert_eq(first.accepted_part_ids, [@control.PartId("choir-a")])
  assert_eq(first.initialized_part_count, 1)
  assert_true(first.execution_registered)
  assert_eq(first.rejections, [])
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/.choir/state/control/workflow.db" },
    artifact_store: { root: root + "/.choir/state/control/artifacts" },
    max_snapshot_bytes: 4 * 1024 * 1024,
  }
  let stored = match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      native_goal_part_workflow_id(
        @control.GoalId("goal-native-submit"),
        @control.PartId("choir-a"),
      ),
    ) {
    Ok(Some(value)) => value.snapshot
    Ok(None) => fail("initialized Part snapshot is absent")
    Err(error) => fail(error.message())
  }
  assert_eq(stored.goal.id, @control.GoalId("goal-native-submit"))
  assert_eq(stored.part.id, @control.PartId("choir-a"))
  assert_eq(
    stored.identities.implementation_session.surface,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  assert_eq(stored.task_contract.base_commit_oid, @control.GitOid(base_commit))
  let process_content = match
    (local_part_workflow_repository_adapters().artifacts.read)(
      repository.artifact_store,
      {
        digest: stored.task_contract.verification_specs[0].process_spec_digest,
        max_bytes: 65536,
      },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let process_json = @json.parse(@utf8.decode_lossy(process_content)) catch {
    _ => fail("verification process is not JSON")
  }
  let process : @sandbox.SandboxProcessSpec = @json.from_json(process_json) catch {
    _ => fail("verification process schema is invalid")
  }
  guard process.authority
    is @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      authority_take_id,
      _,
      _
    ) else {
    fail("verification process authority is wrong")
  }
  assert_eq(authority_take_id, stored.verification_take.id)
  assert_true(
    process.environment.contains({
      key: "MOON_HOME",
      value: "/scratch/home/.moon",
    }),
  )
  let execution = match
    @workflow.load_goal_execution_record(
      repository,
      local_part_workflow_repository_adapters(),
      @control.GoalId("goal-native-submit"),
    ) {
    Ok(Some(value)) => value.record
    Ok(None) => fail("runnable Goal record is absent")
    Err(error) => fail(error.message())
  }
  assert_eq(execution.state, @workflow.GoalExecutionState::GoalExecutionQueued)
  assert_eq(execution.base_ref, @workflow.GitRefName("refs/heads/main"))
  assert_eq(
    execution.integration_target_ref,
    @workflow.GitRefName("refs/heads/main"),
  )
  assert_eq(execution.maximum_parallel_parts, 1)
  assert_eq(execution.part_workflow_ids, [
    native_goal_part_workflow_id(
      @control.GoalId("goal-native-submit"),
      @control.PartId("choir-a"),
    ),
  ])
  match
    @workflow.list_goal_execution_records(
      repository,
      local_part_workflow_repository_adapters(),
    ) {
    Ok([listed]) => assert_eq(listed.record, execution)
    Ok(_) => fail("runnable Goal discovery cardinality is wrong")
    Err(error) => fail(error.message())
  }
  let execution_called = @ref.new(false)
  let tick = match
    @workflow.run_next_goal_execution_tick(
      repository,
      local_part_workflow_repository_adapters(),
      {
        initialize: async fn(_) { Ok(true) },
        execute: async fn(record, snapshots) {
          execution_called.val = true
          assert_eq(record.goal.id, @control.GoalId("goal-native-submit"))
          assert_eq(snapshots.length(), 1)
          Ok(())
        },
        assure: async fn(_, _) { fail("unintegrated Goal entered assurance") },
        finalize: async fn(_, _) { fail("unassured Goal entered finalization") },
        cancel: async fn(_, _) { Ok(false) },
      },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(execution_called.val)
  guard tick
    is @workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(advanced) else {
    fail("queued Goal was not advanced")
  }
  assert_eq(advanced.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  assert_eq(
    advanced.goal.lifecycle,
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRecoveryUncertain,
    ),
  )
  assert_eq(advanced.durable_version, 3)
  let status = match
    inspect_native_goal(root, @control.GoalId("goal-native-submit")) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(status.goal_id, @control.GoalId("goal-native-submit"))
  assert_eq(status.state, @workflow.GoalExecutionState::GoalExecutionPaused)
  assert_eq(status.durable_version, 3)
  assert_eq(status.maximum_parallel_parts, 1)
  assert_eq(status.parts.length(), 1)
  assert_eq(status.parts[0].part_id, @control.PartId("choir-a"))
  assert_eq(
    status.parts[0].provider_surface,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  assert_eq(status.parts[0].stage, @workflow.PartWorkflowStage::PartAccepted)
  assert_eq(
    status.parts[0].lifecycle,
    @control.PartLifecycle::PartExecuting(
      stored.identities.implementation_take.id,
    ),
  )
  assert_eq(status.parts[0].verification_receipt_count, 0)
  assert_false(status.parts[0].audit_receipt_present)
  assert_false(status.parts[0].integration_receipt_present)
  match
    @workflow.run_next_goal_execution_tick(
      repository,
      local_part_workflow_repository_adapters(),
      {
        initialize: async fn(_) { fail("paused Goal initialized again") },
        execute: async fn(_, _) { fail("paused Goal executed again") },
        assure: async fn(_, _) { fail("paused Goal entered assurance") },
        finalize: async fn(_, _) { fail("paused Goal entered finalization") },
        cancel: async fn(_, _) { fail("paused Goal was canceled") },
      },
    ) {
    Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickIdle) => ()
    Ok(_) => fail("paused Goal remained runnable")
    Err(error) => fail(error.message())
  }
  let current = match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      stored.workflow_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => fail("Part disappeared before replay")
    Err(error) => fail(error.message())
  }
  let intent = match @workflow.plan_next_part_effect(current.snapshot) {
    Ok(Some(value)) => value
    Ok(None) => fail("Part had no next effect")
    Err(error) => fail(error.message())
  }
  let progressed = match
    @workflow.persist_planned_part_effect(current.snapshot, intent) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  match
    @workflow.persist_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      {
        snapshot: progressed,
        expected_store_version: Some(current.state_record.version),
        fault_point: None,
      },
    ) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  let replay = match submit_native_conductor_goal_draft(root, draft, capture) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(replay.accepted)
  assert_true(replay.replayed)
  assert_eq(replay.initialized_part_count, 1)
  assert_true(replay.execution_registered)
  assert_eq(replay.selection_decision_digest, first.selection_decision_digest)
  match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      stored.workflow_id,
    ) {
    Ok(Some(value)) => assert_eq(value.snapshot, progressed)
    Ok(None) => fail("replay removed Part progress")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
async test "native Conductor submission rejects a detached checkout" {
  let root = "/tmp/choir-conductor-detached-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create detached submission root")
  }
  let capture = async fn(command : @exec.Command) -> (Int, String) {
    match (command.program, command.args) {
      ("git", ["symbolic-ref", "--quiet", "HEAD"]) => (1, "")
      _ => (-1, "unexpected capture")
    }
  }
  let draft =
    #|{"proposal_id":"proposal-detached","goal_id":"goal-detached","maximum_parallel_parts":1,"parts":[{"part_id":"choir-a","instruction":"Change src/a.mbt.","provider":"codex","exact_paths":["src/a.mbt"],"moon_args":["test","--target","native"]}]}
  match submit_native_conductor_goal_draft(root, draft, capture) {
    Err(error) =>
      assert_true(
        error.message().contains("current checkout must be on a named branch"),
      )
    Ok(_) => fail("detached checkout was accepted")
  }
  ignore(@sys.rm_rf(root))
}

///|
async test "durable Goal cancellation survives replay and starts no provider" {
  let root = "/tmp/choir-goal-cancel-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal cancellation root")
  }
  let base_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let base_tree = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let capture = async fn(command : @exec.Command) -> (Int, String) {
    match (command.program, command.args) {
      ("git", ["symbolic-ref", "--quiet", "HEAD"]) => (0, "refs/heads/main\n")
      ("git", ["rev-parse", "--show-toplevel"]) => (0, root + "\n")
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
      ("bd", ["show", "choir-cancel", "--json", "--readonly"]) =>
        (
          0,
          (
            #|[{"id":"choir-cancel","title":"Cancel proof","description":"No provider should start","acceptance_criteria":"Cancellation is durable","status":"open","priority":2,"issue_type":"task","dependency_count":0,"updated_at":"2026-07-20T00:00:00Z"}]
          ),
        )
      _ => (-1, "unexpected capture")
    }
  }
  let draft =
    #|{
    #|  "proposal_id": "proposal-cancel-proof",
    #|  "goal_id": "goal-cancel-proof",
    #|  "maximum_parallel_parts": 1,
    #|  "parts": [{
    #|    "part_id": "choir-cancel",
    #|    "instruction": "Change only src/cancel.mbt.",
    #|    "provider": "codex",
    #|    "exact_paths": ["src/cancel.mbt"],
    #|    "moon_args": ["test", "--target", "native", "src/cancel.mbt"]
    #|  }]
    #|}
  match submit_native_conductor_goal_draft(root, draft, capture) {
    Ok(report) => assert_true(report.accepted)
    Err(error) => fail(error.message())
  }
  let goal_id = @control.GoalId("goal-cancel-proof")
  let first = match cancel_native_goal(root, goal_id, 1000L) {
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(
        record
      )
    ) => record
    Ok(_) => fail("first cancellation was not persisted")
    Err(error) => fail(error.message())
  }
  assert_eq(first.state, @workflow.GoalExecutionState::GoalExecutionCanceling)
  assert_eq(first.durable_version, 2)
  match cancel_native_goal(root, goal_id, 2000L) {
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationReplayed(
        replayed
      )
    ) => assert_eq(replayed, first)
    Ok(_) => fail("cancellation replay changed durable state")
    Err(error) => fail(error.message())
  }
  ignore(
    run_native_goal_execution_tick_with_forge(
      root,
      native_pull_request_forge_adapters(),
      beads_capture=capture,
    ).unwrap(),
  )
  ignore(
    run_native_goal_execution_tick_with_forge(
      root,
      native_pull_request_forge_adapters(),
      beads_capture=capture,
    ).unwrap(),
  )
  let tick = match
    run_native_goal_execution_tick_with_forge(
      root,
      native_pull_request_forge_adapters(),
      beads_capture=capture,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard tick
    is @workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(canceled) else {
    fail("canceling Goal did not reconcile")
  }
  assert_eq(canceled.state, @workflow.GoalExecutionState::GoalExecutionCanceled)
  assert_eq(canceled.durable_version, 5)
  let status = match inspect_native_goal(root, goal_id) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(status.state, @workflow.GoalExecutionState::GoalExecutionCanceled)
  assert_eq(status.parts.length(), 1)
  assert_eq(status.parts[0].stage, @workflow.PartWorkflowStage::PartCanceled)
  assert_eq(
    status.parts[0].lifecycle,
    @control.PartLifecycle::PartCanceledNotRun,
  )
  assert_eq(status.parts[0].harness_session_count, 0)
  assert_eq(status.parts[0].effect_receipt_count, 0)
  match cancel_native_goal(root, goal_id, 3000L) {
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationTerminal(
        state
      )
    ) => assert_eq(state, @workflow.GoalExecutionState::GoalExecutionCanceled)
    Ok(_) => fail("terminal cancellation was not reported")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
async test "rejected Conductor submission initializes no Part workflow" {
  let root = "/tmp/choir-conductor-reject-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create rejected submission root")
  }
  let base_commit = "cccccccccccccccccccccccccccccccccccccccc"
  let base_tree = "dddddddddddddddddddddddddddddddddddddddd"
  let capture = async fn(command : @exec.Command) -> (Int, String) {
    match (command.program, command.args) {
      ("git", ["symbolic-ref", "--quiet", "HEAD"]) => (0, "refs/heads/main\n")
      ("git", ["rev-parse", "--show-toplevel"]) => (0, root + "\n")
      ("git", ["rev-parse", "--verify", "refs/heads/main^{commit}"]) =>
        (0, base_commit + "\n")
      (
        "git",
        [
          "show",
          "-s",
          "--format=%T",
          "--no-show-signature",
          "cccccccccccccccccccccccccccccccccccccccc",
        ],
      ) => (0, base_tree + "\n")
      ("bd", ["show", "choir-closed", "--json", "--readonly"]) =>
        (
          0,
          (
            #|[{"id":"choir-closed","title":"Closed","status":"closed","priority":2,"issue_type":"task","dependency_count":0,"updated_at":"2026-07-20T00:00:00Z"}]
          ),
        )
      _ => (-1, "unexpected capture")
    }
  }
  let draft =
    #|{"proposal_id":"proposal-native-reject","goal_id":"goal-native-reject","maximum_parallel_parts":1,"parts":[{"part_id":"choir-closed","instruction":"Do not run.","provider":"claude","repository_wide":true,"moon_args":["test","--target","native"]}]}
  let report = match submit_native_conductor_goal_draft(root, draft, capture) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_false(report.accepted)
  assert_eq(report.initialized_part_count, 0)
  assert_false(report.execution_registered)
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/.choir/state/control/workflow.db" },
    artifact_store: { root: root + "/.choir/state/control/artifacts" },
    max_snapshot_bytes: 4 * 1024 * 1024,
  }
  match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      native_goal_part_workflow_id(
        @control.GoalId("goal-native-reject"),
        @control.PartId("choir-closed"),
      ),
    ) {
    Ok(None) => ()
    Ok(Some(_)) => fail("rejected Part was initialized")
    Err(error) => fail(error.message())
  }
  match
    @workflow.load_goal_execution_record(
      repository,
      local_part_workflow_repository_adapters(),
      @control.GoalId("goal-native-reject"),
    ) {
    Ok(None) => ()
    Ok(Some(_)) => fail("rejected Goal became runnable")
    Err(error) => fail(error.message())
  }
  match inspect_native_goal(root, @control.GoalId("goal-native-reject")) {
    Err(error) => assert_true(error.message().contains("not registered"))
    Ok(_) => fail("rejected Goal became inspectable")
  }
  ignore(@sys.rm_rf(root))
}

///|
async test "Goal runtime purge is a no-op without durable state" {
  let root = "/tmp/choir-goal-purge-empty-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(root))
  assert_eq(purge_native_goal_resources(root).unwrap(), {
    runtime_roots_removed: 0,
    git_refs_removed: 0,
  })
  ignore(@sys.rm_rf(root))
}
