///|
test "tl_transition" {
  let mut p = TLPhase::Planning
  match tl_transition(p, ChildSpawned(child_id="c1")) {
    Transitioned(Waiting(count=1, wave=1)) => p = Waiting(count=1, wave=1)
    _ => fail("expected Waiting(1)")
  }
  match tl_transition(p, ChildSpawned(child_id="c2")) {
    Transitioned(Waiting(count=2, wave=1)) => p = Waiting(count=2, wave=1)
    _ => fail("expected Waiting(2)")
  }
  match tl_transition(p, ChildCompleted(child_id="c1")) {
    Transitioned(Waiting(count=1, wave=1)) => p = Waiting(count=1, wave=1)
    _ => fail("expected Waiting(1)")
  }
  match tl_transition(p, PRMerged(number=1, url="url")) {
    Transitioned(WaveComplete(wave=1)) => p = WaveComplete(wave=1)
    _ => fail("expected WaveComplete(1)")
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
    tl_can_exit(Waiting(count=1, wave=1)),
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
      Supervising(
        children=[
          {
            child_id: "main.leaf-a",
            slug: "leaf-a",
            branch: "main.leaf-a",
            agent_type: "gemini",
            summary: ReviewOwned(
              pr_number=7,
              state=FixesAwaitingReview(round=2),
            ),
          },
          {
            child_id: "main.leaf-b",
            slug: "leaf-b",
            branch: "main.leaf-b",
            agent_type: "gemini",
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
test "tl phase json round-trip all variants" {
  let phases : Array[TLPhase] = [
    Planning,
    Dispatching,
    Waiting(count=3, wave=1),
    WaveComplete(wave=1),
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
test "state_machine supervisor machine_name and transition" {
  let sm : SupervisorLifecycle = Planning
  assert_eq(StateMachine::machine_name(sm), "supervisor")
  let child : ChildLifecycle = {
    child_id: "c1",
    slug: "leaf-c1",
    branch: "main.leaf-c1",
    agent_type: "gemini",
    summary: ChildLifecycleSummary::Working,
  }
  match sm.transition(SupervisorEvent::ChildSpawned(child~)) {
    Transitioned(Supervising(children~, wave=1)) =>
      assert_eq(children.length(), 1)
    _ => fail("expected Supervising after ChildSpawned")
  }
}

///|
test "state_machine tl machine_name and transition" {
  let sm : TLPhase = Planning
  assert_eq(StateMachine::machine_name(sm), "tl")
  match sm.transition(TLEvent::ChildSpawned(child_id="c1")) {
    Transitioned(Waiting(count=1, wave=1)) => ()
    _ => fail("expected Waiting after ChildSpawned")
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
  let resolved = resolve_agent_with_fallback(
    project_dir, session, reg, agent_id,
  )
  match resolved {
    Ok(a) => {
      assert_eq(a.agent_id.to_string(), agent_id)
      assert_eq(a.role, @types.Role::Dev)
      assert_eq(a.agent_type, @types.AgentType::Gemini)
    }
    Err(e) => fail("should have resolved from registry: " + e.to_string())
  }
}

///|
test "resolve_agent_with_fallback - fallback to lifecycle" {
  let project_dir = "test_project_fallback"
  let session = "test_session_fallback"
  let reg = @registry.AgentRegistry::new()
  let agent_id = "parent1"

  // Create lifecycle using the store/write_lifecycle
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let lifecycle = lifecycle_for_role(agent_id, @types.Role::TL)
  ignore(write_lifecycle(project_dir, lifecycle))

  let resolved = resolve_agent_with_fallback(
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
      fail("should have resolved from lifecycle fallback: " + e.to_string())
  }

  // Cleanup
  ignore(@sys.system("rm -rf " + project_dir))
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

  let resolved = resolve_parent_with_fallback(
    project_dir, session, reg, caller_id,
  )
  match resolved {
    Ok(a) => assert_eq(a.agent_id.to_string(), parent_id)
    Err(e) => fail("should have resolved parent: " + e.to_string())
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
      assert_eq(trigger, "ChildSpawned")
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
        AppendLifecycleEvent(trigger~, ..) => assert_eq(trigger, "PRCreated")
        _ => fail("expected AppendLifecycleEvent")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
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
    Err(msg) => fail("unexpected err: " + msg)
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
      trigger="test",
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
  assert_true(log.contains("test"))
  ignore(@sys.system("rm -rf " + project_dir))
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
      trigger="t",
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("u1") +
    ".jsonl"
  assert_eq(@sys.read_file(ev_path), "")
  ignore(@sys.system("rm -rf " + project_dir))
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
  match reg.get(agent_id) {
    Ok(a) => assert_eq(a.state, @types.AgentState::Completing)
    Err(_) => fail("expected agent in registry")
  }
  ignore(@sys.system("rm -rf " + project_dir))
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
      trigger="orphan-append",
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("a.only") +
    ".jsonl"
  assert_eq(@sys.read_file(ev_path), "")
  ignore(@sys.system("rm -rf " + project_dir))
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
      trigger="first",
    ),
    AppendLifecycleEvent(
      agent_id=from_lc.agent_id,
      from_lc~,
      to_lc~,
      trigger="second",
    ),
  ]
  interpret_lifecycle_effects(project_dir, effects, registry=None)
  let ev_path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id("leaf.2a") +
    ".jsonl"
  let log = @sys.read_file(ev_path)
  assert_true(log.contains("first"))
  assert_false(log.contains("second"))
  ignore(@sys.system("rm -rf " + project_dir))
}
