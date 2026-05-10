///|
fn auto_rescue_review_owned(pr_number : Int) -> @phase.WorkflowState {
  @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::OpenUnreviewed(
        url="https://github.com/o/r/pull/" + pr_number.to_string(),
      ),
    ),
  )
}

///|
test "should_auto_rescue all-clear returns Some" {
  let workflow = auto_rescue_review_owned(42)
  let got = should_auto_rescue(workflow, 0, 3, false, false)
  match got {
    Some(decision) => {
      assert_eq(decision.pr_number, 42)
      assert_eq(decision.unresolved_count, 3)
    }
    None => fail("expected Some(decision) for all-clear case")
  }
}

///|
test "should_auto_rescue rejects non-Dev workflow (Supervisor)" {
  let workflow = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::Planning,
  )
  assert_true(should_auto_rescue(workflow, 0, 5, false, false) is None)
}

///|
test "should_auto_rescue rejects Dev workflow that is not ReviewOwned" {
  let workflow = @phase.WorkflowState::Dev(@phase.DevLifecycle::Working)
  assert_true(should_auto_rescue(workflow, 0, 5, false, false) is None)
}

///|
test "should_auto_rescue rejects ChangesRequested (PR is not in ReviewOwned state)" {
  let workflow = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ChangesRequested(pr_number=7, next_round=2),
  )
  assert_true(should_auto_rescue(workflow, 0, 5, false, false) is None)
}

///|
test "should_auto_rescue rejects non-zero exit code (real crash, not premature exit)" {
  let workflow = auto_rescue_review_owned(11)
  assert_true(should_auto_rescue(workflow, 1, 3, false, false) is None)
  assert_true(should_auto_rescue(workflow, 137, 3, false, false) is None)
}

///|
test "should_auto_rescue rejects zero unresolved threads (codex was right to exit)" {
  let workflow = auto_rescue_review_owned(99)
  assert_true(should_auto_rescue(workflow, 0, 0, false, false) is None)
}

///|
test "should_auto_rescue rejects negative unresolved-count fence-post" {
  let workflow = auto_rescue_review_owned(99)
  assert_true(should_auto_rescue(workflow, 0, -1, false, false) is None)
}

///|
test "should_auto_rescue rejects when PR already merged" {
  let workflow = auto_rescue_review_owned(123)
  assert_true(should_auto_rescue(workflow, 0, 4, true, false) is None)
}

///|
test "should_auto_rescue rejects when parent issued shutdown" {
  let workflow = auto_rescue_review_owned(123)
  assert_true(should_auto_rescue(workflow, 0, 4, false, true) is None)
}

///|
test "should_auto_rescue accepts all ReviewOwnership sub-states (FixesAwaitingReview)" {
  let workflow = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=55,
      state=@phase.ReviewOwnership::FixesAwaitingReview(round=2),
    ),
  )
  match should_auto_rescue(workflow, 0, 1, false, false) {
    Some(d) => assert_eq(d.pr_number, 55)
    None =>
      fail(
        "FixesAwaitingReview must be eligible — fixes pushed but unreviewed",
      )
  }
}

///|
test "should_auto_rescue accepts ApprovedAwaitingMerge sub-state" {
  let workflow = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=77,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  )
  match should_auto_rescue(workflow, 0, 2, false, false) {
    Some(d) => {
      assert_eq(d.pr_number, 77)
      assert_eq(d.unresolved_count, 2)
    }
    None =>
      fail(
        "ApprovedAwaitingMerge with unresolved threads is still rescue-eligible",
      )
  }
}

///|
test "auto_rescue_task_body inlines pr_number, branch, and count" {
  let decision = AutoRescueDecision::{ pr_number: 42, unresolved_count: 3 }
  let body = auto_rescue_task_body(decision, "feature/auto-rescue.leaf-0")
  assert_true(body.contains("3 remaining unresolved review threads"))
  assert_true(body.contains("PR #42"))
  assert_true(body.contains("feature/auto-rescue.leaf-0"))
  assert_true(body.contains("resolveReviewThread"))
  assert_true(body.contains("Do not exit"))
}

///|
test "auto_rescue_parent_message uses [AUTO-RESCUE TRIGGERED] marker" {
  let decision = AutoRescueDecision::{ pr_number: 9, unresolved_count: 1 }
  let msg = auto_rescue_parent_message("main.codex-leaf", decision)
  assert_true(msg.has_prefix("[AUTO-RESCUE TRIGGERED] "))
  assert_true(msg.contains("main.codex-leaf"))
  assert_true(msg.contains("PR #9"))
  assert_true(msg.contains("1 unresolved"))
}

///|
test "auto_rescue_slug yields unique alphanumeric-dash slug per timestamp" {
  let s1 = auto_rescue_slug(1700000000L)
  let s2 = auto_rescue_slug(1700000001L)
  assert_true(s1 != s2)
  assert_true(s1.has_prefix("auto-rescue-"))
  for c in s1 {
    let ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
    assert_true(ok)
  }
}
