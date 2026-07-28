///|
fn goal_executor_storage_running(
  label : String,
) -> @workflow.GoalExecutionRecord raise {
  let queued = archive_native_queued_record(label~)
  archive_native_initialized({
    ..queued,
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
  })
}

///|
/// The durable portfolio record, against the real SQLite compare-and-set
/// adapter. Pure scheduler tests prove the decision; this pins the storage
/// boundary that makes its held-set decision authoritative.
test "Goal executor leases persist, replay, release, and fence on restart" {
  let root = "/tmp/choir-goal-executor-store-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let first = goal_executor_storage_running("executor-first")
  let second = goal_executor_storage_running("executor-second")
  archive_native_persist(repository, adapters, first)
  archive_native_persist(repository, adapters, second)
  let epoch = @control.FencingEpoch(20L)
  let planned = @workflow.acquire_goal_executor_dispatches(
    repository, adapters, 1, 1_000L, epoch,
  ).unwrap()
  assert_eq(planned.leases.length(), 1)
  let held = planned.leases[0]
  assert_true(
    @workflow.goal_executor_lease_is_authorized(repository, adapters, held).unwrap(),
  )
  // A second planner in the same generation observes the exact held set and
  // cannot dispatch the same Goal or oversubscribe the one configured slot.
  let replay = @workflow.acquire_goal_executor_dispatches(
    repository, adapters, 1, 1_000L, epoch,
  ).unwrap()
  assert_eq(replay.leases, [])
  assert_eq(replay.record, planned.record)
  let completed = @workflow.persist_goal_executor_completion(
    repository,
    adapters,
    held,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
      Some(first.durable_version),
      [],
    ),
    1_000L,
  ).unwrap()
  assert_eq(completed.lease, None)
  let next = @workflow.acquire_goal_executor_dispatches(
    repository, adapters, 1, 1_000L, epoch,
  ).unwrap()
  assert_eq(next.leases.length(), 1)
  assert_true(next.leases[0].goal_id != held.goal_id)
  // A replacement worker adopts the open lease under its newer fence. The old
  // identity is no longer authorized, and exactly one replacement dispatch is.
  let replacement_epoch = @control.FencingEpoch(21L)
  let adopted = @workflow.acquire_goal_executor_dispatches(
    repository, adapters, 1, 1_001L, replacement_epoch,
  ).unwrap()
  assert_eq(adopted.leases.length(), 1)
  assert_eq(adopted.leases[0].fencing_epoch, replacement_epoch)
  assert_false(
    @workflow.goal_executor_lease_is_authorized(
      repository,
      adapters,
      next.leases[0],
    ).unwrap(),
  )
  assert_true(
    @workflow.goal_executor_lease_is_authorized(
      repository,
      adapters,
      adopted.leases[0],
    ).unwrap(),
  )
  ignore(@sys.rm_rf(root))
}
