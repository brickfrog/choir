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
test "decide_merge returns merge_now for comment-only review when CI threads and verify all pass" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::CopilotIssueCommentObserved,
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "ok",
      }),
    ]),
  )
  assert_eq(decision.label(), "merge_now")
  assert_true(decision.reason().contains("ready"))
}

///|
test "decide_merge waits for comment-only review until Copilot comments are observed" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::CopilotIssueCommentUnobserved,
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "ok",
      }),
    ]),
  )
  assert_eq(decision.label(), "wait")
  assert_true(decision.reason().contains("Copilot comments"))
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

///|
test "classify_tl_parent_branch_paths returns doc only for markdown and docs paths" {
  let class = classify_tl_parent_branch_paths([
    "README.md", ".choir/context/tl.md", "docs/design/overview.txt",
  ])
  assert_true(class == TLParentBranchChangeClass::DocOnly)
}

///|
test "classify_tl_parent_branch_paths returns non doc for source files" {
  let class = classify_tl_parent_branch_paths([
    "README.md", "src/server/handler.mbt",
  ])
  assert_true(class == TLParentBranchChangeClass::NonDoc)
}

///|
test "decide_tl_parent_branch_write blocks non doc changes during live wave" {
  let decision = decide_tl_parent_branch_write(
    true,
    Some(3),
    ["src/tools/dispatch.mbt"],
    false,
  )
  assert_true(decision.is_blocked())
  assert_true(decision.reason().contains("wave 3"))
}

///|
test "decide_tl_parent_branch_write allows doc only changes during live wave" {
  let decision = decide_tl_parent_branch_write(
    true,
    Some(1),
    ["README.md", ".choir/context/common.md"],
    false,
  )
  assert_false(decision.is_blocked())
  assert_true(decision.reason().contains("doc-only"))
}

///|
test "decide_tl_parent_branch_write allows explicit override" {
  let decision = decide_tl_parent_branch_write(
    true,
    Some(1),
    ["src/server/handler.mbt"],
    true,
  )
  assert_false(decision.is_blocked())
  assert_true(decision.reason().contains("override"))
}

///|
test "decide_tl_parent_branch_write allows non doc changes when no live wave exists" {
  let decision = decide_tl_parent_branch_write(
    false,
    Some(4),
    ["src/server/handler.mbt"],
    false,
  )
  assert_false(decision.is_blocked())
  assert_true(decision.reason().contains("no live wave"))
}
