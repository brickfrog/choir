///|
test "tl_transition" {
  let mut p = TLPhase::Planning
  match tl_transition(p, ChildSpawned(child_id="c1")) {
    Transitioned(Waiting(count=1)) => p = Waiting(count=1)
    _ => fail("expected Waiting(1)")
  }
  match tl_transition(p, ChildSpawned(child_id="c2")) {
    Transitioned(Waiting(count=2)) => p = Waiting(count=2)
    _ => fail("expected Waiting(2)")
  }
  match tl_transition(p, ChildCompleted(child_id="c1")) {
    Transitioned(Waiting(count=1)) => p = Waiting(count=1)
    _ => fail("expected Waiting(1)")
  }
  match tl_transition(p, PRMerged(number=1, url="url")) {
    Transitioned(AllMerged) => p = AllMerged
    _ => fail("expected AllMerged")
  }
}

///|
test "dev_transition" {
  let mut p = DevPhase::Working
  match
    dev_transition(p, PRCreated(pr_number=123, url="url", branch="branch")) {
    Transitioned(PROpenUnreviewed(pr_number=123, url="url")) =>
      p = PROpenUnreviewed(pr_number=123, url="url")
    _ => fail("expected PROpenUnreviewed")
  }
  match dev_transition(p, ReviewReceivedEv(pr_number=123, body="msg")) {
    Transitioned(ChangesRequested(pr_number=123)) =>
      p = ChangesRequested(pr_number=123)
    _ => fail("expected ChangesRequested")
  }
  match dev_transition(p, FixesPushedEv(pr_number=123, sha="hash")) {
    Transitioned(FixesPushedAwaitingReview(pr_number=123, round=1)) =>
      p = FixesPushedAwaitingReview(pr_number=123, round=1)
    _ => fail("expected FixesPushedAwaitingReview")
  }
  match dev_transition(p, ReviewApprovedEv(pr_number=123)) {
    Transitioned(ApprovedAwaitingMerge(pr_number=123)) =>
      p = ApprovedAwaitingMerge(pr_number=123)
    _ => fail("expected ApprovedAwaitingMerge")
  }
  match dev_transition(p, ExitRequested) {
    Transitioned(
      ExitRequestedDeferred(
        pr_number=123,
        stage=ApprovedAwaitingMerge,
        round=0,
        url=""
      )
    ) =>
      p = ExitRequestedDeferred(
        pr_number=123,
        stage=ApprovedAwaitingMerge,
        round=0,
        url="",
      )
    _ => fail("expected ExitRequestedDeferred")
  }
  match dev_transition(p, MergeObserved(pr_number=123)) {
    Transitioned(Done) => p = Done
    _ => fail("expected Done")
  }
}

///|
test "tl_can_exit" {
  assert_eq(tl_can_exit(Planning), Clean)
  assert_eq(
    tl_can_exit(Waiting(count=1)),
    ShouldNudge("Waiting for 1 children"),
  )
  assert_eq(
    tl_can_exit(PRFiled(number=1, url="url")),
    MustBlock("PR filed (1) at url"),
  )
}

///|
test "dev_can_exit" {
  assert_eq(
    dev_can_exit(ChangesRequested(pr_number=123)),
    MustBlock("Changes requested"),
  )
  assert_eq(
    dev_can_exit(PRUnderReview(pr_number=123, round=1)),
    ShouldNudge("PR 123 under review (round 1)"),
  )
  assert_eq(dev_disconnect_policy(Working), Fail)
  assert_eq(
    dev_disconnect_policy(PROpenUnreviewed(pr_number=123, url="url")),
    Preserve,
  )
  assert_eq(dev_disconnect_policy(Exitable), FinalizeDone)
}

///|
test "lifecycle dev transition carries typed review ownership" {
  let mut lifecycle = DevLifecycle::Working
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::PRCreated(
        pr_number=123,
        url="https://example.test/pr/123",
      ),
    ) {
    Transitioned(ReviewOwned(pr_number=123, state=OpenUnreviewed(url~))) => {
      assert_eq(url, "https://example.test/pr/123")
      lifecycle = ReviewOwned(pr_number=123, state=OpenUnreviewed(url~))
    }
    _ => fail("expected review-owned lifecycle")
  }
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::ReviewReceived(pr_number=123, body="needs tests"),
    ) {
    Transitioned(ChangesRequested(pr_number=123, next_round=1)) =>
      lifecycle = ChangesRequested(pr_number=123, next_round=1)
    _ => fail("expected changes requested")
  }
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::FixesPushed(pr_number=123, sha="abc123"),
    ) {
    Transitioned(ReviewOwned(pr_number=123, state=FixesAwaitingReview(round=1))) =>
      lifecycle = ReviewOwned(pr_number=123, state=FixesAwaitingReview(round=1))
    _ => fail("expected fixes awaiting review")
  }
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::ReviewApproved(pr_number=123),
    ) {
    Transitioned(ReviewOwned(pr_number=123, state=ApprovedAwaitingMerge)) =>
      lifecycle = ReviewOwned(pr_number=123, state=ApprovedAwaitingMerge)
    _ => fail("expected approved awaiting merge")
  }
  match dev_lifecycle_transition(lifecycle, DevLifecycleEvent::ExitRequested) {
    Transitioned(
      ExitRequestedDeferred(pr_number=123, state=ApprovedAwaitingMerge)
    ) =>
      lifecycle = ExitRequestedDeferred(
        pr_number=123,
        state=ApprovedAwaitingMerge,
      )
    _ => fail("expected deferred exit")
  }
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::MergeObserved(pr_number=123),
    ) {
    Transitioned(Done(reason=Merged)) => ()
    _ => fail("expected merge completion")
  }
}

///|
test "lifecycle policy preserves deferred review ownership on disconnect" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main.leaf-a",
    role: @types.Role::Dev,
    process: Connected,
    workflow: Dev(
      ExitRequestedDeferred(pr_number=99, state=FixesAwaitingReview(round=2)),
    ),
  }
  assert_eq(
    lifecycle_exit_policy(lifecycle),
    Deferred(message="PR 99 awaiting re-review (round 2)"),
  )
  assert_eq(lifecycle_disconnect_policy(lifecycle), Preserve)
}

///|
test "lifecycle json round-trip covers supervisor children" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main",
    role: @types.Role::TL,
    process: Connected,
    workflow: Supervisor(
      Supervising(children=[
        {
          child_id: "main.leaf-a",
          slug: "leaf-a",
          branch: "main.leaf-a",
          agent_type: "gemini",
          summary: ReviewOwned(pr_number=7, state=FixesAwaitingReview(round=2)),
        },
        {
          child_id: "main.leaf-b",
          slug: "leaf-b",
          branch: "main.leaf-b",
          agent_type: "gemini",
          summary: Failed(reason=ChildFailure(message="ci failed")),
        },
      ]),
    ),
  }
  match lifecycle_from_json(lifecycle_to_json(lifecycle)) {
    Some(restored) => assert_eq(restored, lifecycle)
    None => fail("expected lifecycle round-trip")
  }
}

///|
test "classify_failure variants" {
  assert_eq(classify_failure("model at capacity"), ModelAtCapacity)
  assert_eq(classify_failure("service at capacity"), ModelAtCapacity)
  assert_eq(classify_failure("Rate limit exceeded"), ModelAtCapacity)
  assert_eq(classify_failure("MCP initialize failure"), McpInitializeFailure)
  assert_eq(classify_failure("mcp connection failed"), McpInitializeFailure)
  assert_eq(
    classify_failure("failed to initialize MCP server"),
    McpInitializeFailure,
  )
  assert_eq(classify_failure("watchdog timeout"), WatchdogTimeout)
  assert_eq(classify_failure("timeout due to idle"), WatchdogTimeout)
  assert_eq(classify_failure("unexpected disconnect"), UnexpectedDisconnect)
  assert_eq(classify_failure("agent crashed"), UnexpectedDisconnect)
  assert_eq(classify_failure("agent killed by parent"), ParentKilled)
  assert_eq(classify_failure("blocked by review"), BlockedByReview)
  assert_eq(classify_failure("changes requested"), BlockedByReview)
  assert_eq(
    classify_failure("generic error"),
    ChildFailure(message="generic error"),
  )
}

///|
test "tl phase json round-trip all variants" {
  let phases : Array[TLPhase] = [
    Planning,
    Dispatching,
    Waiting(count=3),
    Merging(count=2),
    AllMerged,
    PRFiled(number=42, url="https://github.com/org/repo/pull/42"),
    Done,
    Failed(reason="merge conflict"),
  ]
  for phase in phases {
    let json = tl_phase_to_json(phase)
    match tl_phase_from_json(json) {
      Some(restored) => assert_eq(restored, phase)
      None => fail("round-trip failed for: " + json)
    }
  }
}

///|
test "dev phase json round-trip all variants" {
  let phases : Array[DevPhase] = [
    Spawned,
    Working,
    PROpenUnreviewed(pr_number=99, url="https://github.com/org/repo/pull/99"),
    PRUnderReview(pr_number=99, round=3),
    ChangesRequested(pr_number=99),
    FixesPushedAwaitingReview(pr_number=99, round=2),
    ApprovedAwaitingMerge(pr_number=99),
    ExitRequestedDeferred(
      pr_number=99,
      stage=ApprovedAwaitingMerge,
      round=0,
      url="",
    ),
    Exitable,
    Done,
    Failed(reason="lint errors"),
  ]
  for phase in phases {
    let json = dev_phase_to_json(phase)
    match dev_phase_from_json(json) {
      Some(restored) => assert_eq(restored, phase)
      None => fail("round-trip failed for: " + json)
    }
  }
}
