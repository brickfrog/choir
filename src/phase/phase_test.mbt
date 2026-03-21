///|
test "tl_transition" {
  let mut p = TLPhase::Planning
  match tl_transition(p, ChildSpawned("c1")) {
    Transitioned(Waiting(1)) => p = Waiting(1)
    _ => fail("expected Waiting(1)")
  }
  match tl_transition(p, ChildSpawned("c2")) {
    Transitioned(Waiting(2)) => p = Waiting(2)
    _ => fail("expected Waiting(2)")
  }
  match tl_transition(p, ChildCompleted("c1")) {
    Transitioned(Waiting(1)) => p = Waiting(1)
    _ => fail("expected Waiting(1)")
  }
  match tl_transition(p, PRMerged(1, "url")) {
    Transitioned(AllMerged) => p = AllMerged
    _ => fail("expected AllMerged")
  }
}

///|
test "dev_transition" {
  let mut p = DevPhase::Spawned
  match dev_transition(p, PRCreated(123, "url", "branch")) {
    Transitioned(PRFiled(123, "url")) => p = PRFiled(123, "url")
    _ => fail("expected PRFiled")
  }
  match dev_transition(p, ReviewReceivedEv(123, "msg")) {
    Transitioned(ChangesRequested(123)) => p = ChangesRequested(123)
    _ => fail("expected ChangesRequested")
  }
  match dev_transition(p, FixesPushedEv(123, "hash")) {
    Transitioned(UnderReview(123, 1)) => p = UnderReview(123, 1)
    _ => fail("expected UnderReview")
  }
  match dev_transition(p, ReviewApprovedEv(123)) {
    Transitioned(Approved(123)) => p = Approved(123)
    _ => fail("expected Approved")
  }
}

///|
test "tl_can_exit" {
  assert_eq(tl_can_exit(Planning), Clean)
  assert_eq(tl_can_exit(Waiting(1)), ShouldNudge("Waiting for 1 children"))
  assert_eq(tl_can_exit(PRFiled(1, "url")), MustBlock("PR filed (1) at url"))
}

///|
test "dev_can_exit" {
  assert_eq(dev_can_exit(ChangesRequested(123)), MustBlock("Changes requested"))
  assert_eq(
    dev_can_exit(UnderReview(123, 1)),
    ShouldNudge("PR 123 under review (round 1)"),
  )
}

///|
test "tl json roundtrip" {
  let p = TLPhase::Waiting(3)
  let j = tl_phase_to_json(p)
  match tl_phase_from_json(j) {
    Some(p2) => assert_eq(p, p2)
    None => fail("failed to parse")
  }
}

///|
test "dev json roundtrip" {
  let p = DevPhase::UnderReview(123, 2)
  let j = dev_phase_to_json(p)
  match dev_phase_from_json(j) {
    Some(p2) => assert_eq(p, p2)
    None => fail("failed to parse")
  }
}
