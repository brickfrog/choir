///|
/// A fake clock: acceptance and every later reading are supplied, never taken
/// from the host, so the deadline is reproducible.
fn work_order_clock(readings : Array[Int64]) -> () -> Int64 {
  let index = @ref.new(0)
  fn() {
    let value = readings[index.val.min(readings.length() - 1)]
    index.val = index.val + 1
    value
  }
}

///|
test "a relative WorkOrder duration resolves once and survives replay" {
  let clock = work_order_clock([1_000L, 1_500L, 9_999L])
  let accepted_at = clock()
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(3_600L),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    accepted_at,
  ).unwrap()
  assert_eq(
    budget.stop_policy,
    @workflow.WorkOrderStopPolicy::WorkOrderStopAtDeadline(4_600L),
  )
  // Replaying the durable record much later yields the identical deadline:
  // the relative duration never survives into durable state.
  let replayed = @workflow.decode_work_order_budget(
    @workflow.work_order_budget_bytes(budget),
  ).unwrap()
  assert_eq(replayed, budget)
  assert_eq(replayed.stop_policy, budget.stop_policy)
  assert_eq(replayed.counters, @workflow.initial_work_order_counters())
}

///|
test "unattended WorkOrders never park on an input request" {
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(60L),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    1_000L,
  ).unwrap()
  assert_eq(
    @workflow.goal_input_policy_disposition(Some(budget)),
    @workflow.GoalInputPolicyDisposition::GoalInputPolicyCancelUnattended,
  )
  assert_eq(
    @workflow.goal_input_policy_disposition(None),
    @workflow.GoalInputPolicyDisposition::GoalInputPolicyRequestInteractiveInput,
  )
}

///|
test "WorkOrder acceptance rejects nonpositive bounds and deadline overflow" {
  let reject = fn(request : @workflow.WorkOrderStopRequest) {
    @workflow.accept_work_order_budget(
      request,
      @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
      1_000L,
    )
    is Err(_)
  }
  assert_true(
    reject(@workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(0L)),
  )
  assert_true(
    reject(
      @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(
        9223372036854775807L,
      ),
    ),
  )
  assert_true(
    reject(
      @workflow.WorkOrderStopRequest::WorkOrderRequestAbsoluteDeadline(1_000L),
    ),
  )
  assert_true(
    reject(
      @workflow.WorkOrderStopRequest::WorkOrderRequestDeliveredQuota(
        @workflow.WorkOrderQuotaBasis::WorkOrderPrimaryTargets,
        0,
      ),
    ),
  )
  assert_true(
    reject(@workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(-1)),
  )
  assert_true(
    reject(@workflow.WorkOrderStopRequest::WorkOrderRequestFirstOf([])),
  )
  // A compound policy is a flat list, so the winning reason is unambiguous.
  assert_true(
    reject(
      @workflow.WorkOrderStopRequest::WorkOrderRequestFirstOf([
        @workflow.WorkOrderStopRequest::WorkOrderRequestFirstOf([
          @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(1),
        ]),
      ]),
    ),
  )
  // An acceptance time is a real clock reading.
  assert_true(
    @workflow.accept_work_order_budget(
      @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(60L),
      @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
      0L,
    )
    is Err(_),
  )
}

///|
test "the deadline stops the next effect between two ready effects" {
  // Acceptance, a reading before the deadline, then a reading after it.
  let clock = work_order_clock([100L, 150L, 250L, 260L])
  let accepted_at = clock()
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(100L),
    @workflow.WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff,
    accepted_at,
  ).unwrap()
  // The first ready effect is inside the budget.
  assert_eq(
    @workflow.work_order_admits_new_work(budget, clock()),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  // The clock crosses the deadline; the second ready effect is not authorized.
  let after = clock()
  assert_eq(
    @workflow.work_order_admits_new_work(budget, after),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
  // Latching survives restart even if a later reading would not reach it.
  let stopped = @workflow.record_work_order_stop(budget, after)
  assert_eq(
    stopped.stopped,
    Some(@workflow.WorkOrderStopReason::WorkOrderDeadlineReached),
  )
  let replayed = @workflow.decode_work_order_budget(
    @workflow.work_order_budget_bytes(stopped),
  ).unwrap()
  assert_eq(
    @workflow.work_order_admits_new_work(replayed, accepted_at),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
}

///|
test "only delivered Beads satisfy a quota, on the recorded count basis" {
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestDeliveredQuota(
      @workflow.WorkOrderQuotaBasis::WorkOrderPrimaryTargets,
      2,
    ),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    10L,
  ).unwrap()
  // Attempts, rounds, and started Takes are not delivery.
  let attempted = @workflow.record_work_order_round(
    @workflow.record_work_order_agentic_take(
      @workflow.record_work_order_agentic_take(budget),
    ),
    true,
    true,
  )
  assert_eq(
    @workflow.work_order_admits_new_work(attempted, 11L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  // One delivered Goal carrying one primary target and three closure Beads.
  let first = @workflow.record_work_order_delivery(attempted, 1, 3).unwrap()
  assert_eq(first.counters.delivered_primary_targets, 1)
  assert_eq(first.counters.delivered_dependency_closure, 3)
  // The closure count is already past the quota number, but the recorded basis
  // is primary targets, so the quota is not satisfied.
  assert_eq(
    @workflow.work_order_admits_new_work(first, 11L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  let second = @workflow.record_work_order_delivery(first, 1, 1).unwrap()
  assert_eq(
    @workflow.work_order_admits_new_work(second, 11L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderQuotaSatisfied(
        @workflow.WorkOrderQuotaBasis::WorkOrderPrimaryTargets,
        2,
      ),
    ),
  )
  // Closure can never be smaller than the primary targets it contains.
  assert_true(@workflow.record_work_order_delivery(second, 2, 1) is Err(_))
  assert_true(@workflow.record_work_order_delivery(second, -1, 0) is Err(_))
}

///|
test "each stop condition reports its own terminal reason" {
  let accept = fn(request : @workflow.WorkOrderStopRequest) {
    @workflow.accept_work_order_budget(
      request,
      @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
      10L,
    ).unwrap()
  }
  let idle = accept(
    @workflow.WorkOrderStopRequest::WorkOrderRequestNoEligibleWork(2),
  )
  let idle_once = @workflow.record_work_order_round(idle, false, false)
  assert_eq(
    @workflow.work_order_admits_new_work(idle_once, 11L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  assert_eq(
    @workflow.work_order_admits_new_work(
      @workflow.record_work_order_round(idle_once, false, false),
      11L,
    ),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderNoEligibleWorkRemains,
    ),
  )
  // A round that found work resets the idle streak.
  assert_eq(
    @workflow.record_work_order_round(idle_once, true, false).counters.consecutive_idle_rounds,
    0,
  )
  let findings = accept(
    @workflow.WorkOrderStopRequest::WorkOrderRequestNoFurtherFindings(1),
  )
  assert_eq(
    @workflow.work_order_admits_new_work(
      @workflow.record_work_order_round(findings, true, false),
      11L,
    ),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderNoFurtherFindingsRemain,
    ),
  )
  let ceiling = accept(
    @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(1),
  )
  assert_eq(
    @workflow.work_order_admits_new_work(
      @workflow.record_work_order_agentic_take(ceiling),
      11L,
    ),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderSafetyCeilingReached,
    ),
  )
  // A fatal integrity stop is not expressible as a budget condition and
  // latches on its own evidence.
  let integrity = @workflow.record_work_order_integrity_stop(
    ceiling,
    @storage.artifact_digest(@utf8.encode("integrity")),
  ).unwrap()
  assert_eq(
    @workflow.work_order_admits_new_work(integrity, 11L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderFatalIntegrityStop(
        @storage.artifact_digest(@utf8.encode("integrity")),
      ),
    ),
  )
  assert_true(
    @workflow.record_work_order_integrity_stop(
      ceiling,
      @control.Digest("not-a-digest"),
    )
    is Err(_),
  )
}

///|
test "an exhausted WorkOrder budget stops the Goal admitting new agentic work" {
  let record = workflow_execution_for_attach(workflow_fixture())
  // An unbudgeted Goal admits work exactly as before.
  assert_eq(
    @workflow.goal_execution_admits_new_agentic_work(record, 5_000L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  assert_eq(@workflow.record_goal_work_order_stop(record, 5_000L), record)
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(100L),
    @workflow.WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff,
    100L,
  ).unwrap()
  let budgeted = { ..record, work_order_budget: Some(budget) }
  assert_eq(
    @workflow.goal_execution_admits_new_agentic_work(budgeted, 150L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  assert_eq(
    @workflow.goal_execution_admits_new_agentic_work(budgeted, 250L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
  // The latch is durable on the Goal record and bumps its version once.
  let stopped = @workflow.record_goal_work_order_stop(budgeted, 250L)
  assert_eq(stopped.durable_version, budgeted.durable_version + 1)
  assert_eq(
    stopped.work_order_budget.unwrap().stopped,
    Some(@workflow.WorkOrderStopReason::WorkOrderDeadlineReached),
  )
  // Restart cannot resurrect it: an earlier clock reading is still refused,
  // and latching again is a no-op rather than a second version bump.
  assert_eq(
    @workflow.goal_execution_admits_new_agentic_work(stopped, 150L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
  assert_eq(@workflow.record_goal_work_order_stop(stopped, 250L), stopped)
  assert_eq(
    stopped.work_order_budget.unwrap().cutoff_policy,
    @workflow.WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff,
  )
}

///|
test "a compound WorkOrder policy stops on its first satisfied condition" {
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestFirstOf([
      @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(100L),
      @workflow.WorkOrderStopRequest::WorkOrderRequestDeliveredQuota(
        @workflow.WorkOrderQuotaBasis::WorkOrderDependencyClosure,
        2,
      ),
    ]),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    10L,
  ).unwrap()
  // The quota is reached first, well inside the deadline.
  let delivered = @workflow.record_work_order_delivery(budget, 1, 2).unwrap()
  assert_eq(
    @workflow.work_order_admits_new_work(delivered, 20L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderQuotaSatisfied(
        @workflow.WorkOrderQuotaBasis::WorkOrderDependencyClosure,
        2,
      ),
    ),
  )
  // With no delivery, the deadline wins instead, and it is listed first.
  assert_eq(
    @workflow.work_order_admits_new_work(budget, 110L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
}

///|
test "a Conductor draft carries a WorkOrder request without resolving it" {
  let draft =
    #|{"proposal_id":"proposal-wo","goal_id":"goal-wo","maximum_parallel_parts":1,
    #|"pull_request":{"title":"feat: work order","body":"Body.","draft":false},
    #|"work_order":{"cutoff":"cancel","stop":{"kind":"any_of","any_of":[
    #|{"kind":"duration","seconds":3600},
    #|{"kind":"delivered","basis":"closure","count":5}]}},
    #|"parts":[{"part_id":"choir-a","commit_title":"feat: a","instruction":"Do the work.","repository_wide":true,"moon_args":["test"]}]}
  let decoded = match @workflow.decode_conductor_goal_draft(draft) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard decoded.work_order is Some(work_order) else {
    fail("draft dropped its WorkOrder")
  }
  assert_eq(
    work_order.cutoff,
    @workflow.WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff,
  )
  // The duration is still relative in the draft: only acceptance may resolve it.
  assert_eq(
    work_order.stop,
    @workflow.WorkOrderStopRequest::WorkOrderRequestFirstOf([
      @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(3600L),
      @workflow.WorkOrderStopRequest::WorkOrderRequestDeliveredQuota(
        @workflow.WorkOrderQuotaBasis::WorkOrderDependencyClosure,
        5,
      ),
    ]),
  )
  let accepted = @workflow.accept_work_order_budget(
    work_order.stop,
    work_order.cutoff,
    1_000L,
  ).unwrap()
  assert_eq(
    accepted.stop_policy,
    @workflow.WorkOrderStopPolicy::WorkOrderStopAtFirstOf([
      @workflow.WorkOrderStopPolicy::WorkOrderStopAtDeadline(4_600L),
      @workflow.WorkOrderStopPolicy::WorkOrderStopAtDeliveredQuota(
        @workflow.WorkOrderQuotaBasis::WorkOrderDependencyClosure,
        5,
      ),
    ]),
  )
}

///|
test "a malformed WorkOrder request is rejected at draft decode" {
  let draft = fn(work_order : String) {
    @workflow.decode_conductor_goal_draft(
      "{\"proposal_id\":\"p\",\"goal_id\":\"g\",\"maximum_parallel_parts\":1," +
      "\"pull_request\":{\"title\":\"feat: a\",\"body\":\"B.\",\"draft\":false}," +
      work_order +
      "\"parts\":[{\"part_id\":\"choir-a\",\"commit_title\":\"feat: a\",\"instruction\":\"Do the work.\",\"repository_wide\":true,\"moon_args\":[\"test\"]}]}",
    )
  }
  // A Goal with no WorkOrder is unbudgeted and still admitted.
  match draft("") {
    Ok(value) => assert_true(value.work_order is None)
    Err(error) => fail(error.message())
  }
  assert_true(
    draft("\"work_order\":{\"stop\":{\"kind\":\"whenever\"}},") is Err(_),
  )
  assert_true(draft("\"work_order\":{\"cutoff\":\"cancel\"},") is Err(_))
  assert_true(
    draft(
      "\"work_order\":{\"stop\":{\"kind\":\"duration\",\"seconds\":60},\"cutoff\":\"maybe\"},",
    )
    is Err(_),
  )
  assert_true(
    draft("\"work_order\":{\"stop\":{\"kind\":\"delivered\"}},") is Err(_),
  )
  // Compound policies stay flat so the winning stop reason is unambiguous.
  assert_true(
    draft(
      "\"work_order\":{\"stop\":{\"kind\":\"any_of\",\"any_of\":[{\"kind\":\"any_of\",\"any_of\":[]}]}},",
    )
    is Err(_),
  )
}

///|
test "the safety ceiling counts Takes that actually started" {
  let planned = workflow_fixture()
  let baseline = @workflow.goal_agentic_takes_started([planned])
  let started = @workflow.goal_agentic_takes_started([drive_to_verified()])
  // Driving a Part to verified starts Takes the untouched fixture has not.
  assert_true(started > baseline)
  // Two Parts count independently.
  assert_eq(
    @workflow.goal_agentic_takes_started([
      drive_to_verified(),
      drive_to_verified(),
    ]),
    started * 2,
  )
  let record = workflow_execution_for_attach(planned)
  // An unbudgeted Goal keeps no counters.
  assert_eq(
    @workflow.refresh_goal_work_order_counters(record, [drive_to_verified()]),
    record,
  )
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(started),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    100L,
  ).unwrap()
  let budgeted = { ..record, work_order_budget: Some(budget) }
  assert_eq(
    @workflow.goal_execution_admits_new_agentic_work(budgeted, 101L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  let counted = @workflow.refresh_goal_work_order_counters(budgeted, [
    drive_to_verified(),
  ])
  assert_eq(
    counted.work_order_budget.unwrap().counters.agentic_takes_started,
    started,
  )
  assert_eq(counted.durable_version, budgeted.durable_version + 1)
  // The ceiling is now reached, so no further agentic Take is authorized.
  assert_eq(
    @workflow.goal_execution_admits_new_agentic_work(counted, 101L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderSafetyCeilingReached,
    ),
  )
  // A tick that started nothing new writes nothing.
  assert_eq(
    @workflow.refresh_goal_work_order_counters(counted, [drive_to_verified()]),
    counted,
  )
}
