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
        stage="ApprovedAwaitingMerge",
        round=0,
        url=""
      )
    ) =>
      p = ExitRequestedDeferred(
        pr_number=123,
        stage="ApprovedAwaitingMerge",
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
      stage="ApprovedAwaitingMerge",
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
