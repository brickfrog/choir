///|
fn contract_with_verify() -> @types.TaskContract {
  {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
}

///|
fn bundle_with_signals(
  task_contract : @types.TaskContract?,
  signals : Array[@types.EvaluationSignal],
) -> @types.EvaluationBundle {
  { task_contract, signals }
}

///|
fn approved_ready_signals() -> Array[@types.EvaluationSignal] {
  [
    @types.EvaluationSignal::Review(
      state=@types.EvaluationReviewState::Approved,
      body="looks good",
    ),
    @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
    @types.EvaluationSignal::ThreadsObserved(count=0),
    @types.EvaluationSignal::Verify(result={
      name: "moon test --target native",
      status: @types.VerifyStatus::Passed,
      details: "ok",
    }),
  ]
}

///|
test "decide_merge returns merge_now when review CI threads and verify all pass" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), approved_ready_signals()),
  )
  assert_eq(decision.label(), "merge_now")
  assert_true(decision.reason().contains("ready"))
}

///|
test "decide_merge blocks on changes requested" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::ChangesRequested,
        body="please fix",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "ok",
      }),
    ]),
  )
  assert_eq(decision.label(), "blocked")
  assert_true(decision.reason().contains("changes requested"))
}

///|
test "decide_merge waits while ci is still in progress" {
  let decision = decide_merge(
    None,
    bundle_with_signals(
      Some({ ..@types.TaskContract::empty(), goal: "ship feature" }),
      [
        @types.EvaluationSignal::Review(
          state=@types.EvaluationReviewState::Approved,
          body="looks good",
        ),
        @types.EvaluationSignal::Ci(
          status=@types.EvaluationCiRollup::InProgress,
        ),
        @types.EvaluationSignal::ThreadsObserved(count=0),
      ],
    ),
  )
  assert_eq(decision.label(), "wait")
  assert_true(decision.reason().contains("CI"))
}

///|
test "decide_merge needs human when review threads were not fetched" {
  let decision = decide_merge(
    None,
    bundle_with_signals(
      Some({ ..@types.TaskContract::empty(), goal: "ship feature" }),
      [
        @types.EvaluationSignal::Review(
          state=@types.EvaluationReviewState::Approved,
          body="looks good",
        ),
        @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
        @types.EvaluationSignal::ThreadsUnobserved,
      ],
    ),
  )
  assert_eq(decision.label(), "needs_human")
  assert_true(decision.reason().contains("threads not fetched"))
}

///|
test "decide_merge needs human when verify commands exist but were not observed" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="looks good",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
    ]),
  )
  assert_eq(decision.label(), "needs_human")
  assert_true(decision.reason().contains("local verify not observed"))
}

///|
test "decide_merge blocks on failed verify" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="looks good",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Failed,
        details: "tests failed",
      }),
    ]),
  )
  assert_eq(decision.label(), "blocked")
  assert_true(decision.reason().contains("local verify failed"))
}
