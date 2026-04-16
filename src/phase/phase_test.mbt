///|
test "lifecycle_idle_watchdog_exempt logic" {
  let dev_working = lifecycle_for_role("d1", @types.Role::Dev)
  assert_false(lifecycle_idle_watchdog_exempt(dev_working))

  let dev_review = {
    ..dev_working,
    workflow: Dev(ReviewOwned(pr_number=1, state=ApprovedAwaitingMerge)),
  }
  assert_true(lifecycle_idle_watchdog_exempt(dev_review))

  let dev_done = { ..dev_working, workflow: Dev(Done(reason=Merged)) }
  assert_true(lifecycle_idle_watchdog_exempt(dev_done))

  let dev_failed = {
    ..dev_working,
    workflow: Dev(Failed(reason=UnexpectedDisconnect)),
  }
  assert_true(lifecycle_idle_watchdog_exempt(dev_failed))

  let dev_exit_deferred = {
    ..dev_working,
    workflow: Dev(
      ExitRequestedDeferred(pr_number=1, state=ApprovedAwaitingMerge),
    ),
  }
  assert_true(lifecycle_idle_watchdog_exempt(dev_exit_deferred))

  let dev_changes_requested = {
    ..dev_working,
    workflow: Dev(ChangesRequested(pr_number=1, next_round=2)),
  }
  assert_true(lifecycle_idle_watchdog_exempt(dev_changes_requested))

  let worker_working = lifecycle_for_role("w1", @types.Role::Worker)
  assert_false(lifecycle_idle_watchdog_exempt(worker_working))

  let worker_exitable = { ..worker_working, workflow: Worker(Exitable) }
  assert_false(lifecycle_idle_watchdog_exempt(worker_exitable))

  let worker_done = {
    ..worker_working,
    workflow: Worker(Done(reason=Shutdown)),
  }
  assert_true(lifecycle_idle_watchdog_exempt(worker_done))

  let worker_failed = {
    ..worker_working,
    workflow: Worker(Failed(reason=UnexpectedDisconnect)),
  }
  assert_true(lifecycle_idle_watchdog_exempt(worker_failed))

  let tl = lifecycle_for_role("tl", @types.Role::TL)
  // `Supervisor` is not exempt here; `check_idle_agents` skips TL/Root by role first.
  assert_false(lifecycle_idle_watchdog_exempt(tl))

  // WaitingForRedGate must be exempt (leaf is following TDD protocol; spec says wait).
  let dev_red_gate = {
    ..lifecycle_for_role("d2", @types.Role::Dev),
    workflow: Dev(WaitingForRedGate),
  }
  assert_true(lifecycle_idle_watchdog_exempt(dev_red_gate))
}

///|
test "WaitingForRedGate transitions identically to Working" {
  // PRCreated from WaitingForRedGate should work like from Working.
  match
    dev_lifecycle_transition(
      WaitingForRedGate,
      DevLifecycleEvent::PRCreated(pr_number=1, url="https://ex/pr/1"),
    ) {
    Transitioned(ReviewOwned(pr_number=1, state=OpenUnreviewed(_))) => ()
    _ => fail("expected ReviewOwned from WaitingForRedGate + PRCreated")
  }
  // ExitRequested from WaitingForRedGate should become Exitable.
  match
    dev_lifecycle_transition(
      WaitingForRedGate,
      DevLifecycleEvent::ExitRequested,
    ) {
    Transitioned(Exitable) => ()
    _ => fail("expected Exitable from WaitingForRedGate + ExitRequested")
  }
}

///|
test "WaitingForRedGate is disconnect-preserve, not fail" {
  assert_eq(
    lifecycle_dev_disconnect_policy(WaitingForRedGate),
    LifecycleDisconnectPolicy::Preserve,
  )
}

///|
test "supervisor_transition rejects OwnPRFiled from Planning and Dispatching" {
  let ev = SupervisorEvent::OwnPRFiled(number=1, url="https://ex/pr/1")
  match supervisor_transition(SupervisorLifecycle::Planning, ev) {
    InvalidTransition(_) => ()
    _ => fail("expected InvalidTransition from Planning + OwnPRFiled")
  }
  match supervisor_transition(SupervisorLifecycle::Dispatching, ev) {
    InvalidTransition(_) => ()
    _ => fail("expected InvalidTransition from Dispatching + OwnPRFiled")
  }
}

///|
test "classify_failure does not misclassify incidental review phrases" {
  // "no changes requested yet" contains "changes requested" but should NOT
  // classify as BlockedByReview — it does not start with the keyword.
  match classify_failure("no changes requested yet, still waiting") {
    ChildFailure(_) => ()
    _ =>
      fail(
        "expected ChildFailure for message containing review phrase mid-sentence",
      )
  }
  // A message that STARTS with "changes requested:" should classify correctly.
  match classify_failure("changes requested: please add tests") {
    BlockedByReview => ()
    _ =>
      fail(
        "expected BlockedByReview for first-line prefix 'changes requested:'",
      )
  }
  // Bare "blocked by review" prefix still works.
  match classify_failure("blocked by review at round 2") {
    BlockedByReview => ()
    _ =>
      fail("expected BlockedByReview for first-line prefix 'blocked by review'")
  }
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
test "dev_lifecycle_transition single_pass skips fixes awaiting review" {
  let lifecycle : DevLifecycle = ChangesRequested(pr_number=123, next_round=2)
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::FixesPushed(pr_number=123, sha="abc123"),
      review_mode=@types.ReviewMode::SinglePass,
    ) {
    Transitioned(ReviewOwned(pr_number=123, state=ApprovedAwaitingMerge)) => ()
    _ => fail("expected single-pass fixes to move to merge gate ownership")
  }
}

///|
test "dev_lifecycle_transition iterative keeps fixes awaiting review" {
  let lifecycle : DevLifecycle = ChangesRequested(pr_number=123, next_round=2)
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::FixesPushed(pr_number=123, sha="abc123"),
      review_mode=@types.ReviewMode::Iterative,
    ) {
    Transitioned(ReviewOwned(pr_number=123, state=FixesAwaitingReview(round=2))) =>
      ()
    _ => fail("expected iterative fixes to await re-review")
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
test "lifecycle policy preserves changes-requested on disconnect" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main.leaf-a",
    role: @types.Role::Dev,
    process: Connected,
    workflow: Dev(ChangesRequested(pr_number=99, next_round=1)),
  }
  assert_eq(lifecycle_disconnect_policy(lifecycle), Preserve)
}

///|
test "lifecycle json round-trip covers supervisor children" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main",
    role: @types.Role::TL,
    process: Connected,
    workflow: Supervisor(
      Supervising(
        children=[
          {
            child_id: "main.leaf-a",
            slug: "leaf-a",
            branch: "main.leaf-a",
            agent_type: @types.AgentType::Gemini,
            summary: ReviewOwned(
              pr_number=7,
              state=FixesAwaitingReview(round=2),
            ),
          },
          {
            child_id: "main.leaf-b",
            slug: "leaf-b",
            branch: "main.leaf-b",
            agent_type: @types.AgentType::Gemini,
            summary: Failed(reason=ChildFailure(message="ci failed")),
          },
        ],
        wave=1,
      ),
    ),
  }
  match lifecycle_from_json(lifecycle_to_json(lifecycle)) {
    Some(restored) => assert_eq(restored, lifecycle)
    None => fail("expected lifecycle round-trip")
  }
}

///|
test "default_workflow_state TL is Supervisor Planning" {
  match default_workflow_state(@types.Role::TL) {
    Supervisor(Planning) => ()
    other => fail("expected Supervisor(Planning), got " + other.to_string())
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
test "state_machine supervisor machine_name and transition" {
  let sm : SupervisorLifecycle = Planning
  assert_eq(StateMachine::machine_name(sm), "supervisor")
  let child : ChildLifecycle = {
    child_id: "c1",
    slug: "leaf-c1",
    branch: "main.leaf-c1",
    agent_type: @types.AgentType::Gemini,
    summary: ChildLifecycleSummary::Working,
  }
  match sm.transition(SupervisorEvent::ChildSpawned(child~)) {
    Transitioned(Supervising(children~, wave=1)) =>
      assert_eq(children.length(), 1)
    _ => fail("expected Supervising after ChildSpawned")
  }
}

///|
test "supervisor ChildUpdated with agent_type replaces placeholder" {
  let sm : SupervisorLifecycle = Planning
  let child : ChildLifecycle = {
    child_id: "c1",
    slug: "leaf",
    branch: "b1",
    agent_type: @types.AgentType::Unknown,
    summary: ChildLifecycleSummary::Working,
  }
  let sm2 = match sm.transition(SupervisorEvent::ChildSpawned(child~)) {
    Transitioned(s) => s
    _ => {
      fail("expected ChildSpawned transition")
      Planning
    }
  }
  match
    sm2.transition(
      SupervisorEvent::ChildUpdated(
        child_id="c1",
        summary=ChildLifecycleSummary::Working,
        agent_type=Some(@types.AgentType::MoonPilot),
      ),
    ) {
    Transitioned(Supervising(children~, ..)) =>
      if children.length() == 1 {
        assert_eq(children[0].agent_type, @types.AgentType::MoonPilot)
      } else {
        fail("expected one child")
      }
    _ => fail("expected Supervising after ChildUpdated")
  }
}

///|
test "resolve_agent_with_fallback - in registry" {
  let project_dir = "test_project"
  let session = "test_session"
  let reg = @registry.AgentRegistry::new()
  let agent_id = "agent1"
  let agent : @types.Agent = {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("parent1"),
    workspace: "ws1",
    branch: "branch1",
    terminal_target: Some({ kind: ZellijTab, session: "s1", name: "n1" }),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  ignore(reg.upsert(agent))
  let resolved = try? resolve_agent_with_fallback(
    project_dir, session, reg, agent_id,
  )
  match resolved {
    Ok(a) => {
      assert_eq(a.agent_id.to_string(), agent_id)
      assert_eq(a.role, @types.Role::Dev)
      assert_eq(a.agent_type, @types.AgentType::Gemini)
    }
    Err(e) => fail("should have resolved from registry: " + e.message())
  }
}

///|
test "resolve_agent_with_fallback - fallback to lifecycle" {
  let project_dir = "/tmp/choir-test-fallback-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let session = "test_session_fallback"
  let reg = @registry.AgentRegistry::new()
  let agent_id = "parent1"

  // Create lifecycle using the store/write_lifecycle
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let lifecycle = lifecycle_for_role(agent_id, @types.Role::TL)
  ignore(write_lifecycle(project_dir, lifecycle))

  let resolved = try? resolve_agent_with_fallback(
    project_dir, session, reg, agent_id,
  )
  match resolved {
    Ok(a) => {
      assert_eq(a.agent_id.to_string(), agent_id)
      assert_eq(a.role, @types.Role::TL)
      assert_eq(a.agent_type, @types.AgentType::Claude)
      assert_eq(a.workspace, project_dir)
      assert_eq(a.branch, agent_id)
      match a.terminal_target {
        Some(target) => {
          assert_eq(target.session, session)
          assert_eq(target.name, "TL")
        }
        None => fail("should have terminal target")
      }
    }
    Err(e) =>
      fail("should have resolved from lifecycle fallback: " + e.message())
  }

  // Cleanup
  ignore(@sys.rm_rf(project_dir))
}

///|
test "resolve_parent_with_fallback - parent in registry" {
  let project_dir = "test_project_parent"
  let session = "test_session_parent"
  let reg = @registry.AgentRegistry::new()
  let caller_id = "agent1"
  let parent_id = "parent1"

  ignore(
    reg.upsert({
      agent_id: @types.AgentId(caller_id),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: "ws1",
      branch: "branch1",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
      spawn_depth: 1,
    }),
  )

  let parent : @types.Agent = {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "ws_parent",
    branch: "branch_parent",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  ignore(reg.upsert(parent))

  let resolved = try? resolve_parent_with_fallback(
    project_dir, session, reg, caller_id,
  )
  match resolved {
    Ok(a) => assert_eq(a.agent_id.to_string(), parent_id)
    Err(e) => fail("should have resolved parent: " + e.message())
  }
}

///|
test "plan_tl_lifecycle_effects ChildSpawned emits persist then append" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: Connected,
    workflow: Supervisor(Planning),
  }
  let effects = plan_tl_lifecycle_effects(
    lifecycle,
    TLEvent::ChildSpawned(child_id="main.leaf"),
  )
  assert_eq(effects.length(), 2)
  match effects[0] {
    PersistLifecycle(lifecycle=lc) =>
      match lc.workflow {
        Supervisor(Supervising(children~, wave=1)) =>
          assert_eq(children.length(), 1)
        _ => fail("expected Supervising wave 1")
      }
    _ => fail("expected PersistLifecycle first")
  }
  match effects[1] {
    AppendLifecycleEvent(agent_id~, trigger~, ..) => {
      assert_eq(agent_id, "main.tl")
      assert_eq(trigger, @types.LifecycleTrigger::ChildSpawned)
    }
    _ => fail("expected AppendLifecycleEvent second")
  }
}

///|
test "plan_tl_lifecycle_effects unsupported event yields no effects" {
  let lifecycle : AgentLifecycle = {
    agent_id: "x",
    role: @types.Role::TL,
    process: Connected,
    workflow: Supervisor(Planning),
  }
  let effects = plan_tl_lifecycle_effects(lifecycle, TLEvent::AllChildrenDone)
  assert_eq(effects.length(), 0)
}

///|
test "plan_dev_event_checked PRCreated emits two lifecycle effects" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main.dev",
    role: @types.Role::Dev,
    process: Connected,
    workflow: Dev(Working),
  }
  match
    plan_dev_event_checked(
      lifecycle,
      DevEvent::PRCreated(pr_number=9, url="https://ex/pr/9", branch="b"),
    ) {
    Ok((phase, effects)) => {
      match phase {
        PROpenUnreviewed(pr_number=9, url~) => assert_eq(url, "https://ex/pr/9")
        _ => fail("expected PROpenUnreviewed phase")
      }
      assert_eq(effects.length(), 2)
      match effects[0] {
        PersistLifecycle(lifecycle=lc) =>
          match lc.workflow {
            Dev(ReviewOwned(pr_number=9, ..)) => ()
            _ => fail("expected ReviewOwned dev workflow")
          }
        _ => fail("expected PersistLifecycle")
      }
      match effects[1] {
        AppendLifecycleEvent(trigger~, ..) =>
          assert_eq(trigger, @types.LifecycleTrigger::PRCreated)
        _ => fail("expected AppendLifecycleEvent")
      }
    }
    Err(msg) => fail("unexpected err: " + msg.message())
  }
}

///|
test "plan_dev_event_checked NotifyParentSuccess has empty effects" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main.dev",
    role: @types.Role::Dev,
    process: Connected,
    workflow: Dev(Working),
  }
  match
    plan_dev_event_checked(
      lifecycle,
      DevEvent::NotifyParentSuccess(message="ok"),
    ) {
    Ok((_, effects)) => assert_eq(effects.length(), 0)
    Err(msg) => fail("unexpected err: " + msg.message())
  }
}

// --- interpret_lifecycle_effects (service.mbt) regression tests ---
// Covers: successful persist + append, failed persist suppresses append,
// registry sync after persist, append requires matching last-persist agent_id,
// latch clears after each Append effect (no stale pairing).

///|
test "interpret_lifecycle_effects no-op on empty effect list" {
  let project_dir = "/tmp/choir-interp-empty-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  interpret_lifecycle_effects(project_dir, [], registry=None)
}

///|
test "interpret_lifecycle_effects writes lifecycle and event log" {
  let project_dir = "/tmp/choir-interp-ok-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let from_lc = lifecycle_for_role("leaf.z", @types.Role::Dev)
  let to_lc = {
    ..from_lc,
    workflow: Dev(
      ReviewOwned(pr_number=3, state=OpenUnreviewed(url="https://ex/3")),
    ),
  }
  let effects : Array[LifecycleEffect] = [
    PersistLifecycle(lifecycle=to_lc),
    AppendLifecycleEvent(
      agent_id=from_lc.agent_id,
      from_lc~,
      to_lc~,
      trigger=@types.LifecycleTrigger::PRCreated,
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  match read_lifecycle(project_dir, "leaf.z") {
    Some(lc) => assert_eq(lc, to_lc)
    None => fail("expected persisted lifecycle")
  }
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("leaf.z") +
    ".jsonl"
  let log = @sys.read_file(ev_path)
  assert_true(log.contains("lifecycle.transition"))
  assert_true(log.contains("PRCreated"))
  ignore(@sys.rm_rf(project_dir))
}

///|
test "interpret_lifecycle_effects skips append when persist fails" {
  let project_dir = "/tmp/choir-interp-badkv-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  ignore(@sys.write_file_sync(project_dir + "/.choir/kv", "not-a-directory"))
  let lc = lifecycle_for_role("u1", @types.Role::Dev)
  let effects : Array[LifecycleEffect] = [
    PersistLifecycle(lifecycle=lc),
    AppendLifecycleEvent(
      agent_id=lc.agent_id,
      from_lc=lc,
      to_lc=lc,
      trigger=@types.LifecycleTrigger::PRCreated,
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("u1") +
    ".jsonl"
  assert_eq(@sys.read_file(ev_path), "")
  ignore(@sys.rm_rf(project_dir))
}

///|
test "interpret_lifecycle_effects updates registry after successful persist" {
  let project_dir = "/tmp/choir-interp-reg-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let reg = @registry.AgentRegistry::new()
  let agent_id = "p.reg"
  ignore(
    reg.upsert({
      agent_id: @types.AgentId(agent_id),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
      spawn_depth: 0,
    }),
  )
  let base = lifecycle_for_role(agent_id, @types.Role::Dev)
  let next = { ..base, process: Finalizing(reason=Shutdown) }
  interpret_lifecycle_effects(
    project_dir,
    [PersistLifecycle(lifecycle=next)],
    registry=Some(reg),
  )
  try reg.get(agent_id) catch {
    _ => fail("expected agent in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Completing)
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "interpret_lifecycle_effects append ignored when last persist is another agent" {
  let project_dir = "/tmp/choir-interp-pair-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let lc_a = lifecycle_for_role("a.only", @types.Role::Dev)
  let lc_b = lifecycle_for_role("b.only", @types.Role::Dev)
  let effects : Array[LifecycleEffect] = [
    PersistLifecycle(lifecycle=lc_a),
    PersistLifecycle(lifecycle=lc_b),
    AppendLifecycleEvent(
      agent_id=lc_a.agent_id,
      from_lc=lc_a,
      to_lc=lc_a,
      trigger=@types.LifecycleTrigger::PRCreated,
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("a.only") +
    ".jsonl"
  assert_eq(@sys.read_file(ev_path), "")
  ignore(@sys.rm_rf(project_dir))
}

///|
test "interpret_lifecycle_effects second append without new persist is ignored" {
  let project_dir = "/tmp/choir-interp-2append-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let from_lc = lifecycle_for_role("leaf.2a", @types.Role::Dev)
  let to_lc = {
    ..from_lc,
    workflow: Dev(
      ReviewOwned(pr_number=2, state=OpenUnreviewed(url="https://ex/2")),
    ),
  }
  let effects : Array[LifecycleEffect] = [
    PersistLifecycle(lifecycle=to_lc),
    AppendLifecycleEvent(
      agent_id=from_lc.agent_id,
      from_lc~,
      to_lc~,
      trigger=@types.LifecycleTrigger::PRCreated,
    ),
    AppendLifecycleEvent(
      agent_id=from_lc.agent_id,
      from_lc~,
      to_lc~,
      trigger=@types.LifecycleTrigger::ExitRequested,
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("leaf.2a") +
    ".jsonl"
  let log = @sys.read_file(ev_path)
  assert_true(log.contains("PRCreated"))
  assert_false(log.contains("ExitRequested"))
  ignore(@sys.rm_rf(project_dir))
}

///|
test "sanitize_branch escapes dots and path separators" {
  assert_eq(sanitize_branch("main.leaf"), "main--leaf")
  assert_eq(sanitize_branch("feature/x.leaf"), "feature_x--leaf")
  assert_eq(sanitize_branch("feature\\x.leaf"), "feature_x--leaf")
}
