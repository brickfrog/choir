///|
fn planner_attempt_work_order() -> @workflow.WorkOrderRecord {
  {
    id: @workflow.WorkOrderId("work-order-planner-attempt-test"),
    repository_id: @workflow.RepositoryId("repository-planner-attempt-test"),
    objective: "Select one bounded successor.",
    selection_policy: @workflow.WorkOrderSelectionPolicy::WorkOrderExactBeadClosure,
    planner: {
      primary_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      failover_surfaces: [@control.ProviderSurfaceId::ClaudeSubscriptionCli],
    },
    initial_primary_target_ids: [@control.PartId("choir-initial")],
    initial_prerequisite_closure_ids: [],
    max_active_child_goals: 1,
    budget: @workflow.accept_work_order_budget(
      @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(20),
      @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
      1L,
    ).unwrap(),
    child_goals: [],
    planning_rounds: [],
    lifecycle: @workflow.WorkOrderLifecycle::WorkOrderActive,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
test "planner attempt separates safe first issue from ambiguous replay" {
  let work_order = planner_attempt_work_order()
  let planned_order = @workflow.plan_work_order_round(
    work_order,
    @storage.artifact_digest(@utf8.encode("repository")),
    @storage.artifact_digest(@utf8.encode("beads")),
  ).unwrap()
  let dispatched = @workflow.dispatch_work_order_planning_round(
    planned_order, 10L,
  ).unwrap()
  let round = dispatched.planning_rounds.last().unwrap()
  let planned = @workflow.plan_work_order_planner_attempt(
    dispatched,
    round,
    @storage.artifact_digest(@utf8.encode("instruction")),
    @storage.artifact_digest(@utf8.encode("schema")),
  ).unwrap()
  assert_eq(
    planned.lifecycle,
    @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned,
  )
  let issued = @workflow.issue_work_order_planner_attempt(
    { ..planned, durable_version: 1 },
    11L,
  ).unwrap()
  assert_eq(
    issued.lifecycle,
    @workflow.WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptIssued(
      11L,
    ),
  )
  assert_true(@workflow.issue_work_order_planner_attempt(issued, 12L) is Err(_))
}

///|
test "planner failover receives a distinct durable attempt identity" {
  let digest = @storage.artifact_digest(@utf8.encode("attempt-failover"))
  let first_dispatch = @workflow.dispatch_work_order_planning_round(
    @workflow.plan_work_order_round(
      planner_attempt_work_order(),
      digest,
      digest,
    ).unwrap(),
    10L,
  ).unwrap()
  let first_round = first_dispatch.planning_rounds.last().unwrap()
  let first = @workflow.plan_work_order_planner_attempt(
    first_dispatch, first_round, digest, digest,
  ).unwrap()
  let failed = @workflow.record_work_order_planner_failure(
    first_dispatch, digest,
  ).unwrap()
  let second_dispatch = @workflow.dispatch_work_order_planning_round(
    failed, 11L,
  ).unwrap()
  let second_round = second_dispatch.planning_rounds.last().unwrap()
  let second = @workflow.plan_work_order_planner_attempt(
    second_dispatch, second_round, digest, digest,
  ).unwrap()
  assert_true(first.id != second.id)
  assert_true(first.session_id != second.session_id)
  assert_eq(first.attempt_number, 1)
  assert_eq(second.attempt_number, 2)
  assert_true(first.surface != second.surface)
}
