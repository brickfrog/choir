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
  assert_eq(
    @workflow.goal_input_policy_disposition(
      Some(@workflow.WorkOrderId("work-order-test")),
    ),
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
  // An unbudgeted Goal admits work exactly as before.
  assert_eq(
    @workflow.work_order_admits_new_agentic_work(None, 5_000L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestRelativeSeconds(100L),
    @workflow.WorkOrderCutoffPolicy::WorkOrderInstallCancellationCutoff,
    100L,
  ).unwrap()
  assert_eq(
    @workflow.work_order_admits_new_agentic_work(Some(budget), 150L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  assert_eq(
    @workflow.work_order_admits_new_agentic_work(Some(budget), 250L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
  let stopped = @workflow.record_work_order_stop(budget, 250L)
  assert_eq(
    stopped.stopped,
    Some(@workflow.WorkOrderStopReason::WorkOrderDeadlineReached),
  )
  // Restart cannot resurrect it: an earlier clock reading is still refused,
  // and latching again is a no-op rather than a second version bump.
  assert_eq(
    @workflow.work_order_admits_new_agentic_work(Some(stopped), 150L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderDeadlineReached,
    ),
  )
  assert_eq(@workflow.record_work_order_stop(stopped, 250L), stopped)
  assert_eq(
    stopped.cutoff_policy,
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
    #|"work_order":{"objective":"Deliver the selected Beads.","planner":{"provider":"codex"},"initial_primary_targets":["choir-a"],"cutoff":"cancel","stop":{"kind":"any_of","any_of":[
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
  let budget = @workflow.accept_work_order_budget(
    @workflow.WorkOrderStopRequest::WorkOrderRequestSafetyCeiling(started),
    @workflow.WorkOrderCutoffPolicy::WorkOrderDrainToSafeBoundary,
    100L,
  ).unwrap()
  assert_eq(
    @workflow.work_order_admits_new_agentic_work(Some(budget), 101L),
    @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork,
  )
  let counted = @workflow.refresh_work_order_counters(budget, [
    drive_to_verified(),
  ])
  assert_eq(counted.counters.agentic_takes_started, started)
  // The ceiling is now reached, so no further agentic Take is authorized.
  assert_eq(
    @workflow.work_order_admits_new_agentic_work(Some(counted), 101L),
    @workflow.WorkOrderAdmission::WorkOrderExhausted(
      @workflow.WorkOrderStopReason::WorkOrderSafetyCeilingReached,
    ),
  )
  // A tick that started nothing new writes nothing.
  assert_eq(
    @workflow.refresh_work_order_counters(counted, [drive_to_verified()]),
    counted,
  )
}

///|
fn planning_work_order() -> @workflow.WorkOrderRecord {
  let digest = @storage.artifact_digest(@utf8.encode("planning-snapshot"))
  {
    id: @workflow.WorkOrderId("work-order-planning-test"),
    repository_id: @workflow.RepositoryId("repository-planning-test"),
    objective: "Select the next bounded Goal.",
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
      100L,
    ).unwrap(),
    child_goals: [
      {
        goal_id: @control.GoalId("goal-initial"),
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
fn planning_goal_draft() -> @workflow.ConductorGoalDraft {
  @workflow.decode_conductor_goal_draft(
    (
      #|{"proposal_id":"proposal-planning-next","goal_id":"goal-planning-next",
      #|"pull_request":{"title":"feat: deliver planned work","body":"Delivers the bounded planned change."},
      #|"maximum_parallel_parts":1,
      #|"parts":[{"part_id":"choir-next","commit_title":"feat: deliver planned work",
      #|"instruction":"Implement the bounded next change.","provider":"codex",
      #|"exact_paths":["src/next.mbt"],"moon_args":["test","--target","native"]}]}
    ),
  ).unwrap()
}

///|
test "planning rounds bind snapshots and bound provider or empty failures" {
  let digest = @storage.artifact_digest(@utf8.encode("planning-snapshot"))
  let planned = @workflow.plan_work_order_round(
    planning_work_order(),
    digest,
    digest,
  ).unwrap()
  assert_eq(planned.planning_rounds[0].sequence, 1)
  assert_eq(
    planned.planning_rounds[0].phase,
    @workflow.WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded,
  )
  let dispatched = @workflow.dispatch_work_order_planning_round(planned, 101L).unwrap()
  assert_eq(dispatched.budget.counters.agentic_takes_started, 1)
  let failed = @workflow.record_work_order_planner_failure(
    dispatched,
    @storage.artifact_digest(@utf8.encode("provider failed")),
  ).unwrap()
  assert_eq(
    failed.planning_rounds[0].planner_surface,
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  let mut current = failed
  for index = 0; index < 3; index = index + 1 {
    current = @workflow.dispatch_work_order_planning_round(current, 101L).unwrap()
    current = @workflow.record_empty_work_order_planner_response(current).unwrap()
  }
  assert_true(
    current.planning_rounds[0].outcome
    is @workflow.WorkOrderPlanningOutcome::WorkOrderPlanningQuarantined(
      @workflow.WorkOrderPlanningFailure::WorkOrderPlannerRepeatedEmptyProposal
    ),
  )
}

///|
test "a planning proposal is validated before replayable Bead delivery" {
  let digest = @storage.artifact_digest(@utf8.encode("planning-snapshot"))
  let planned = @workflow.plan_work_order_round(
    planning_work_order(),
    digest,
    digest,
  ).unwrap()
  let dispatched = @workflow.dispatch_work_order_planning_round(planned, 101L).unwrap()
  let proposal : @workflow.WorkOrderPlanningProposal = {
    findings: [
      {
        summary: "A bounded next Bead is eligible.",
        evidence: "The captured graph has no open blocker.",
        related_bead_ids: [@control.PartId("choir-next")],
      },
    ],
    eligible_work_observed: true,
    bead_mutations: { mutations: [] },
    primary_target_ids: [@control.PartId("choir-next")],
    prerequisite_closure_ids: [],
    finite_goal: Some(planning_goal_draft()),
  }
  let content = @workflow.work_order_planning_proposal_bytes(proposal)
  let artifact : @control.ArtifactReference = {
    artifact_id: "planning-proposal-1",
    digest: @storage.artifact_digest(content),
  }
  let received = @workflow.record_work_order_planning_proposal(
    dispatched,
    artifact,
    content,
    digest,
    digest,
    [],
    101L,
  ).unwrap()
  assert_eq(
    received.planning_rounds[0].outcome,
    @workflow.WorkOrderPlanningOutcome::WorkOrderPlanningProposalAccepted,
  )
  let delivering = @workflow.begin_work_order_bead_delivery(received).unwrap()
  assert_true(
    @workflow.complete_work_order_bead_delivery(
      delivering,
      @storage.artifact_digest(@utf8.encode("wrong")),
      digest,
    )
    is Err(_),
  )
  let delivered = @workflow.complete_work_order_bead_delivery(
    delivering,
    @command.bead_batch_digest(proposal.bead_mutations),
    digest,
  ).unwrap()
  assert_eq(
    delivered.planning_rounds[0].phase,
    @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered,
  )
}

///|
test "planning proposal snapshot drift is a typed terminal outcome" {
  let digest = @storage.artifact_digest(@utf8.encode("planning-snapshot"))
  let drift = @storage.artifact_digest(@utf8.encode("planning-drift"))
  let dispatched = @workflow.dispatch_work_order_planning_round(
    @workflow.plan_work_order_round(planning_work_order(), digest, digest).unwrap(),
    101L,
  ).unwrap()
  let proposal : @workflow.WorkOrderPlanningProposal = {
    findings: [],
    eligible_work_observed: false,
    bead_mutations: { mutations: [] },
    primary_target_ids: [],
    prerequisite_closure_ids: [],
    finite_goal: None,
  }
  let content = @workflow.work_order_planning_proposal_bytes(proposal)
  let stopped = @workflow.record_work_order_planning_proposal(
    dispatched,
    {
      artifact_id: "planning-proposal-drift",
      digest: @storage.artifact_digest(content),
    },
    content,
    drift,
    digest,
    [],
    101L,
  ).unwrap()
  assert_true(
    stopped.planning_rounds[0].outcome
    is @workflow.WorkOrderPlanningOutcome::WorkOrderPlanningFailed(
      @workflow.WorkOrderPlanningFailure::WorkOrderPlannerRepositorySnapshotDrift
    ),
  )
}
