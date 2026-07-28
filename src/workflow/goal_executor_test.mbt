///|
fn executor_candidate(
  label : String,
  lane? : @workflow.GoalExecutionJobLane = @workflow.GoalExecutionJobLane::GoalExecutionProgressLane,
) -> @workflow.GoalExecutionJobCandidate {
  { goal_id: @control.GoalId(label), lane }
}

///|
fn executor_lease_for_goal(
  plan : @workflow.GoalExecutorDispatchPlan,
  goal_id : @control.GoalId,
) -> @workflow.GoalExecutorLease raise {
  for lease in plan.leases {
    if lease.goal_id == goal_id {
      return lease
    }
  }
  fail("Goal executor lease is absent")
}

///|
test "a held slow Goal does not keep another Goal from an executor" {
  let epoch = @control.FencingEpoch(3L)
  let planned = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate("goal-a"), executor_candidate("goal-b")],
    2,
    100L,
    epoch,
  ).unwrap()
  assert_eq(planned.leases.length(), 2)
  assert_eq(planned.leases.map(fn(lease) { lease.goal_id }), [
    @control.GoalId("goal-a"),
    @control.GoalId("goal-b"),
  ])
  assert_eq(planned.leases.map(fn(lease) { lease.slot }), [0, 1])
  // Replanning while both tasks are open dispatches neither a duplicate A nor
  // a duplicate B.
  let held = @workflow.plan_goal_executor_dispatches(
    planned.record,
    [executor_candidate("goal-a"), executor_candidate("goal-b")],
    2,
    101L,
    epoch,
  ).unwrap()
  assert_eq(held.leases, [])
  assert_eq(held.record, planned.record)
}

///|
test "one Goal's persistent error backs off only that Goal" {
  let epoch = @control.FencingEpoch(4L)
  let candidates = [executor_candidate("goal-a"), executor_candidate("goal-b")]
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    candidates,
    1,
    100L,
    epoch,
  ).unwrap()
  let expected_delays = [2L, 4L, 8L, 16L, 30L]
  let mut current = first.record
  let mut lease_a = executor_lease_for_goal(first, @control.GoalId("goal-a"))
  let mut now = 100L
  for failure = 1; failure <= 5; failure = failure + 1 {
    current = @workflow.complete_goal_executor_dispatch(
      current,
      lease_a.id,
      @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickFailed(
        @storage.artifact_digest(
          @utf8.encode("persistent A failure " + failure.to_string()),
        ),
        [],
      ),
      now,
    ).unwrap()
    let job_a = @workflow.goal_execution_job_for_goal(
      current,
      @control.GoalId("goal-a"),
    ).unwrap()
    assert_eq(job_a.consecutive_failures, failure)
    assert_eq(job_a.due_at, now + expected_delays[failure - 1])
    // B takes the released slot on every failure, including after A reaches the
    // persistent threshold. A's retry clock never becomes the portfolio clock.
    let next_b = @workflow.plan_goal_executor_dispatches(
      current, candidates, 1, now, epoch,
    ).unwrap()
    assert_eq(next_b.leases.length(), 1)
    assert_eq(next_b.leases[0].goal_id, @control.GoalId("goal-b"))
    current = @workflow.complete_goal_executor_dispatch(
      next_b.record,
      next_b.leases[0].id,
      @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
        Some(failure),
        [],
      ),
      now,
    ).unwrap()
    if failure < 5 {
      now = job_a.due_at
      let retry_a = @workflow.plan_goal_executor_dispatches(
        current, candidates, 1, now, epoch,
      ).unwrap()
      assert_eq(retry_a.leases.length(), 1)
      assert_eq(retry_a.leases[0].goal_id, @control.GoalId("goal-a"))
      current = retry_a.record
      lease_a = retry_a.leases[0]
    }
  }
  assert_eq(
    @workflow.goal_execution_job_for_goal(current, @control.GoalId("goal-b")).unwrap().last_goal_durable_version,
    Some(5),
  )
}

///|
test "pending cancellation gets bounded priority then yields to progress" {
  let epoch = @control.FencingEpoch(5L)
  let candidates = [
    executor_candidate(
      "goal-cancel",
      lane=@workflow.GoalExecutionJobLane::GoalExecutionCancellationLane,
    ),
    executor_candidate("goal-progress"),
  ]
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    candidates,
    1,
    200L,
    epoch,
  ).unwrap()
  assert_eq(first.leases[0].goal_id, @control.GoalId("goal-cancel"))
  let mut current = first.record
  let mut cancel_lease = first.leases[0]
  let mut now = 200L
  for round = 1; round <= 5; round = round + 1 {
    // The unchanged durable version models cleanup returning pending.
    current = @workflow.complete_goal_executor_dispatch(
      current,
      cancel_lease.id,
      @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
        Some(3),
        [],
      ),
      now,
    ).unwrap()
    let progress = @workflow.plan_goal_executor_dispatches(
      current, candidates, 1, now, epoch,
    ).unwrap()
    assert_eq(progress.leases.length(), 1)
    assert_eq(progress.leases[0].goal_id, @control.GoalId("goal-progress"))
    current = @workflow.complete_goal_executor_dispatch(
      progress.record,
      progress.leases[0].id,
      @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
        Some(round),
        [],
      ),
      now,
    ).unwrap()
    if round < 5 {
      now = now + 1L
      let cancellation = @workflow.plan_goal_executor_dispatches(
        current, candidates, 1, now, epoch,
      ).unwrap()
      assert_eq(cancellation.leases.length(), 1)
      assert_eq(cancellation.leases[0].goal_id, @control.GoalId("goal-cancel"))
      current = cancellation.record
      cancel_lease = cancellation.leases[0]
    }
  }
  assert_eq(
    @workflow.goal_execution_job_for_goal(
      current,
      @control.GoalId("goal-progress"),
    ).unwrap().last_goal_durable_version,
    Some(5),
  )
}

///|
test "new cancellation does not inherit an active attempt's retry state" {
  let epoch = @control.FencingEpoch(51L)
  let goal_id = @control.GoalId("goal-cancel-now")
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate(goal_id.0)],
    1,
    250L,
    epoch,
  ).unwrap()
  let cancellation_candidate = executor_candidate(
    goal_id.0,
    lane=@workflow.GoalExecutionJobLane::GoalExecutionCancellationLane,
  )
  // Cancellation arrives while the progress task is open. The exact task keeps
  // its lease and lane; no duplicate cancellation dispatch escapes yet.
  let observed_cancel = @workflow.plan_goal_executor_dispatches(
    first.record,
    [cancellation_candidate],
    1,
    251L,
    epoch,
  ).unwrap()
  assert_eq(observed_cancel.leases, [])
  assert_eq(observed_cancel.record, first.record)
  // The old attempt then fails with a provider refusal. Its backoff and report
  // describe progress, not cancellation.
  let failed = @workflow.complete_goal_executor_dispatch(
    observed_cancel.record,
    first.leases[0].id,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickFailed(
      @storage.artifact_digest(@utf8.encode("progress failed during cancel")),
      [
        {
          surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
            280L,
          ),
        },
      ],
    ),
    251L,
  ).unwrap()
  let failed_job = @workflow.goal_execution_job_for_goal(failed, goal_id).unwrap()
  assert_eq(failed_job.consecutive_failures, 1)
  assert_eq(failed_job.due_at, 253L)
  let canceling = @workflow.plan_goal_executor_dispatches(
    failed,
    [cancellation_candidate],
    1,
    251L,
    epoch,
  ).unwrap()
  assert_eq(canceling.leases.length(), 1)
  assert_eq(canceling.leases[0].goal_id, goal_id)
  let canceling_job = @workflow.goal_execution_job_for_goal(
    canceling.record,
    goal_id,
  ).unwrap()
  assert_eq(canceling_job.lane, cancellation_candidate.lane)
  assert_eq(canceling_job.consecutive_failures, 0)
  assert_eq(canceling_job.last_failure_digest, None)
  assert_eq(canceling_job.provider_reports, [])
}

///|
test "restart fencing adopts an open job without duplicate same-epoch dispatch" {
  let old_epoch = @control.FencingEpoch(6L)
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(old_epoch),
    [executor_candidate("goal-restart")],
    1,
    300L,
    old_epoch,
  ).unwrap()
  let old_lease = first.leases[0]
  let replay = @workflow.plan_goal_executor_dispatches(
    first.record,
    [executor_candidate("goal-restart")],
    1,
    301L,
    old_epoch,
  ).unwrap()
  assert_eq(replay.leases, [])
  let new_epoch = @control.FencingEpoch(7L)
  let adopted = @workflow.plan_goal_executor_dispatches(
    first.record,
    [executor_candidate("goal-restart")],
    1,
    301L,
    new_epoch,
  ).unwrap()
  assert_eq(adopted.leases.length(), 1)
  assert_eq(adopted.leases[0].fencing_epoch, new_epoch)
  assert_eq(adopted.leases[0].slot, old_lease.slot)
  assert_true(adopted.leases[0].id != old_lease.id)
  assert_false(@workflow.goal_executor_lease_is_held(adopted.record, old_lease))
  assert_true(
    @workflow.goal_executor_lease_is_held(adopted.record, adopted.leases[0]),
  )
}

///|
test "one provider deferral becomes only that Goal's bounded due-at" {
  let epoch = @control.FencingEpoch(8L)
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate("goal-a"), executor_candidate("goal-b")],
    1,
    400L,
    epoch,
  ).unwrap()
  let deferred = @workflow.complete_goal_executor_dispatch(
    first.record,
    first.leases[0].id,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
      Some(4),
      [
        {
          surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
            9_000_000L,
          ),
        },
      ],
    ),
    400L,
  ).unwrap()
  let job_a = @workflow.goal_execution_job_for_goal(
    deferred,
    @control.GoalId("goal-a"),
  ).unwrap()
  assert_eq(job_a.due_at, 430L)
  let next = @workflow.plan_goal_executor_dispatches(
    deferred,
    [executor_candidate("goal-a"), executor_candidate("goal-b")],
    1,
    400L,
    epoch,
  ).unwrap()
  assert_eq(next.leases[0].goal_id, @control.GoalId("goal-b"))
}

///|
test "an admitted provider observation keeps only this Goal on base cadence" {
  let epoch = @control.FencingEpoch(81L)
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate("goal-mixed-provider")],
    1,
    450L,
    epoch,
  ).unwrap()
  let reports : Array[@workflow.ProviderSurfaceTickReport] = []
  let observations : Array[@workflow.ProviderSurfaceTickReport] = [
    {
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        480L,
      ),
    },
    {
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
    // An admission dominates a refusal on its own surface whichever arrives
    // first, while repeated refusals retain their earliest wake.
    {
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        470L,
      ),
    },
    {
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        460L,
      ),
    },
  ]
  for report in observations {
    let merged = @workflow.record_provider_surface_tick_report(reports, report)
    reports.clear()
    for value in merged {
      reports.push(value)
    }
  }
  assert_eq(reports, [
    {
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
        460L,
      ),
    },
    {
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
    },
  ])
  let completed = @workflow.complete_goal_executor_dispatch(
    first.record,
    first.leases[0].id,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
      Some(2),
      reports,
    ),
    450L,
  ).unwrap()
  assert_eq(
    @workflow.goal_execution_job_for_goal(
      completed,
      @control.GoalId("goal-mixed-provider"),
    ).unwrap().due_at,
    451L,
  )
}

///|
test "a merge-waiting tick carries no provider disposition or slot delay" {
  let epoch = @control.FencingEpoch(9L)
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate("goal-merge-wait")],
    1,
    500L,
    epoch,
  ).unwrap()
  let waiting = @workflow.complete_goal_executor_dispatch(
    first.record,
    first.leases[0].id,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
      Some(10),
      [],
    ),
    500L,
  ).unwrap()
  let job = @workflow.goal_execution_job_for_goal(
    waiting,
    @control.GoalId("goal-merge-wait"),
  ).unwrap()
  assert_eq(job.provider_reports, [])
  assert_eq(job.due_at, 501L)
  assert_eq(job.lease, None)
}

///|
test "executor completion replay and durable decode are exact" {
  let epoch = @control.FencingEpoch(10L)
  let plan = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate("goal-round-trip")],
    1,
    600L,
    epoch,
  ).unwrap()
  let outcome = @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
    Some(2),
    [],
  )
  let completed = @workflow.complete_goal_executor_dispatch(
    plan.record,
    plan.leases[0].id,
    outcome,
    600L,
  ).unwrap()
  assert_eq(
    @workflow.complete_goal_executor_dispatch(
      completed,
      plan.leases[0].id,
      outcome,
      601L,
    ).unwrap(),
    completed,
  )
  assert_eq(
    @workflow.decode_goal_executor_schedule_record(
      @workflow.goal_executor_schedule_record_bytes(completed),
    ).unwrap(),
    completed,
  )
  let jobs = plan.record.jobs.copy()
  guard jobs[0].lease is Some(lease) else { fail("planned lease is absent") }
  jobs[0] = {
    ..jobs[0],
    lease: Some({
      ..lease,
      id: @workflow.GoalExecutorLeaseId("fabricated-lease-id"),
    }),
  }
  assert_true(
    @workflow.decode_goal_executor_schedule_record(
      @workflow.goal_executor_schedule_record_bytes({ ..plan.record, jobs, }),
    )
    is Err(_),
  )
}

///|
test "the durable executor schedule manifest names every populated field" {
  let epoch = @control.FencingEpoch(11L)
  let first = @workflow.plan_goal_executor_dispatches(
    @workflow.empty_goal_executor_schedule_record(epoch),
    [executor_candidate("goal-maximal")],
    1,
    700L,
    epoch,
  ).unwrap()
  let succeeded = @workflow.complete_goal_executor_dispatch(
    first.record,
    first.leases[0].id,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickSucceeded(
      Some(7),
      [
        {
          surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
          disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
            701L,
          ),
        },
      ],
    ),
    700L,
  ).unwrap()
  let second = @workflow.plan_goal_executor_dispatches(
    succeeded,
    [executor_candidate("goal-maximal")],
    1,
    701L,
    epoch,
  ).unwrap()
  let failed = @workflow.complete_goal_executor_dispatch(
    second.record,
    second.leases[0].id,
    @workflow.GoalExecutionJobTickOutcome::GoalExecutionJobTickFailed(
      @storage.artifact_digest(@utf8.encode("maximal failure")),
      [
        {
          surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
          disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
            703L,
          ),
        },
      ],
    ),
    701L,
  ).unwrap()
  let maximal = @workflow.plan_goal_executor_dispatches(
      failed,
      [executor_candidate("goal-maximal")],
      1,
      703L,
      epoch,
    ).unwrap().record
  assert_manifest_names_stored_keys(
    "GoalExecutorScheduleRecord",
    @workflow.goal_executor_schedule_record_bytes(maximal),
  )
}
