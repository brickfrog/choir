///|
test "transfer_owner reassigns all tracked PRs to replacement leaf" {
  let ps = @poller.PollerState::new()
  let now = @poller.now_sec()
  ps.track(7, "main.leaf-a", "main.leaf-a", "main", "https://ex/pr/7", now)
  ps.track(8, "main.leaf-a", "main.leaf-a", "main", "https://ex/pr/8", now)
  let transferred = ps.transfer_owner(
    "main.leaf-a", "main.leaf-b", "main.leaf-a", "main",
  )
  assert_eq(transferred, 2)
  match ps.get(7) {
    Some(t) => {
      assert_eq(t.agent_id, "main.leaf-b")
      assert_eq(t.branch, "main.leaf-a")
      assert_eq(t.parent_branch, "main")
    }
    None => fail("expected PR 7 after transfer")
  }
  match ps.get(8) {
    Some(t) => assert_eq(t.agent_id, "main.leaf-b")
    None => fail("expected PR 8 after transfer")
  }
}

///|
test "transfer_owner keeps prior branch metadata when new branch fields empty" {
  let ps = @poller.PollerState::new()
  let now = 42L
  ps.track(3, "main.from", "main.feat", "main", "u", now)
  let transferred = ps.transfer_owner("main.from", "main.to", "", "")
  assert_eq(transferred, 1)
  match ps.get(3) {
    Some(t) => {
      assert_eq(t.agent_id, "main.to")
      assert_eq(t.branch, "main.feat")
      assert_eq(t.parent_branch, "main")
    }
    None => fail("expected PR 3")
  }
}

///|
test "transfer_owner overwrites branch when replacement publishes new head name" {
  let ps = @poller.PollerState::new()
  let now = 1L
  ps.track(5, "main.v0", "main.v0", "main", "u", now)
  ignore(
    ps.transfer_owner("main.v0", "main.v1", "main.shared-topic", "develop"),
  )
  match ps.get(5) {
    Some(t) => {
      assert_eq(t.agent_id, "main.v1")
      assert_eq(t.branch, "main.shared-topic")
      assert_eq(t.parent_branch, "develop")
    }
    None => fail("expected PR 5")
  }
}
