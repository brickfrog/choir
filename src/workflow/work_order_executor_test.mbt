///|
fn executor_owner(value : String) -> @workflow.WorkOrderId {
  @workflow.WorkOrderId("work-order-executor-" + value)
}

///|
test "WorkOrder executor leases independent campaigns concurrently" {
  let epoch = @control.FencingEpoch(1L)
  let initial = @workflow.empty_work_order_executor_schedule_record(epoch)
  let planned = @workflow.plan_work_order_executor_dispatches(
    initial,
    [executor_owner("b"), executor_owner("a"), executor_owner("c")],
    2,
    100L,
    epoch,
  ).unwrap()
  assert_eq(planned.leases.length(), 2)
  assert_eq(planned.leases.map(fn(lease) { lease.work_order_id }), [
    executor_owner("a"),
    executor_owner("b"),
  ])
  assert_eq(planned.leases.map(fn(lease) { lease.slot }), [0, 1])
  let completed = @workflow.complete_work_order_executor_dispatch(
    planned.record,
    planned.leases[0].id,
    @workflow.WorkOrderExecutionJobTickOutcome::WorkOrderExecutionJobTickSucceeded(
      Some(2),
      [],
    ),
    101L,
  ).unwrap()
  let next = @workflow.plan_work_order_executor_dispatches(
    completed,
    [executor_owner("a"), executor_owner("b"), executor_owner("c")],
    2,
    101L,
    epoch,
  ).unwrap()
  assert_eq(next.leases.length(), 1)
  assert_eq(next.leases[0].work_order_id, executor_owner("c"))
  assert_eq(next.leases[0].slot, 0)
}

///|
test "a newer WorkOrder generation reclaims orphaned executor leases" {
  let first_epoch = @control.FencingEpoch(1L)
  let held = @workflow.plan_work_order_executor_dispatches(
    @workflow.empty_work_order_executor_schedule_record(first_epoch),
    [executor_owner("slow")],
    1,
    100L,
    first_epoch,
  ).unwrap()
  let next_epoch = @control.FencingEpoch(2L)
  let adopted = @workflow.plan_work_order_executor_dispatches(
    held.record,
    [executor_owner("slow")],
    1,
    101L,
    next_epoch,
  ).unwrap()
  assert_eq(adopted.leases.length(), 1)
  assert_eq(adopted.leases[0].fencing_epoch, next_epoch)
  assert_false(
    @workflow.work_order_executor_lease_is_held(adopted.record, held.leases[0]),
  )
}

///|
test "WorkOrder executor completion replay is exact and failures are local" {
  let epoch = @control.FencingEpoch(1L)
  let planned = @workflow.plan_work_order_executor_dispatches(
    @workflow.empty_work_order_executor_schedule_record(epoch),
    [executor_owner("a"), executor_owner("b")],
    2,
    100L,
    epoch,
  ).unwrap()
  let failure = @storage.artifact_digest(@utf8.encode("planner failed"))
  let failed = @workflow.complete_work_order_executor_dispatch(
    planned.record,
    planned.leases[0].id,
    @workflow.WorkOrderExecutionJobTickOutcome::WorkOrderExecutionJobTickFailed(
      failure,
      [],
    ),
    101L,
  ).unwrap()
  assert_eq(
    @workflow.complete_work_order_executor_dispatch(
      failed,
      planned.leases[0].id,
      @workflow.WorkOrderExecutionJobTickOutcome::WorkOrderExecutionJobTickFailed(
        failure,
        [],
      ),
      101L,
    ).unwrap(),
    failed,
  )
  let a = @workflow.work_order_execution_job_for_work_order(
    failed,
    executor_owner("a"),
  ).unwrap()
  let b = @workflow.work_order_execution_job_for_work_order(
    failed,
    executor_owner("b"),
  ).unwrap()
  assert_eq(a.consecutive_failures, 1)
  assert_eq(a.last_failure_digest, Some(failure))
  assert_eq(b.consecutive_failures, 0)
  assert_true(b.lease is Some(_))
}
