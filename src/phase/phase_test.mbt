///|
fn phase_test_lifecycle_for_workflow(
  workflow : WorkflowState,
) -> AgentLifecycle {
  let role = match workflow {
    Supervisor(_) => @types.Role::TL
    Dev(_) => @types.Role::Dev
    Worker(_) => @types.Role::Worker
  }
  {
    agent_id: "phase.test",
    role,
    process: Connected,
    workflow,
    last_updated_unix_sec: 0L,
  }
}

///|
fn phase_test_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn phase_test_failed_warn_event(
  events : Array[@moontrace.Event],
) -> @moontrace.Event? {
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "agent lifecycle transitioned to failed" {
      return Some(event)
    }
  }
  None
}

///|
fn phase_test_agent(
  agent_id : String,
  parent : String?,
  state? : @types.AgentState = @types.AgentState::Active,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent,
    workspace: "/tmp/choir-phase-test/.choir/worktrees/leaf",
    branch: "feature/x.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
fn phase_test_event_count(
  events : Array[@moontrace.Event],
  level : @moontrace.Level,
  message : String,
) -> Int {
  let mut count = 0
  for event in events {
    if event.level == level && event.message == message {
      count = count + 1
    }
  }
  count
}

///|
fn phase_test_warning_count(
  events : Array[@moontrace.Event],
  message : String,
) -> Int {
  phase_test_event_count(events, @moontrace.Level::Warn, message)
}

///|
/// Drive `body` with `@moontrace.set_subscriber` installed, then
/// unconditionally clear it. Without this any assertion failure inside the
/// body would leave a stale subscriber installed for the rest of the
/// process — causing spurious cross-test event noise.
fn phase_test_with_capture(
  captured : Array[@moontrace.Event],
  body : () -> Unit raise,
) -> Unit raise {
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  let result = try body() catch {
    e => {
      @moontrace.clear_subscriber()
      raise e
    }
  } noraise {
    _ => ()
  }
  @moontrace.clear_subscriber()
  result
}

///|
fn phase_test_tmp_project_dir(label : String) -> String {
  let dir = "/tmp/choir-phase-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(dir))
  dir
}

///|
test "sync_parent_child_lifecycle keeps warn for live child missing parent" {
  let project_dir = phase_test_tmp_project_dir("live-missing-parent")
  let registry = @registry.AgentRegistry::new()
  let agent_id = "feature/x.live-leaf"
  ignore(registry.upsert(phase_test_agent(agent_id, Some("feature/x.parent"))))
  let lifecycle = {
    ..lifecycle_for_role(agent_id, @types.Role::Dev),
    process: ProcessState::Connected,
    workflow: WorkflowState::Dev(DevLifecycle::Working),
  }
  let captured : Array[@moontrace.Event] = []
  let msg = "sync_parent_child_lifecycle: parent not in registry"
  phase_test_with_capture(captured, fn() raise {
    sync_parent_child_lifecycle(
      project_dir, "session", registry, agent_id, lifecycle,
    )
    // Assertions inside the closure so phase_test_with_capture's catch-and-
    // clear arm actually fires if either side of the contract drifts.
    assert_eq(phase_test_warning_count(captured, msg), 1)
    // Pins the live-mid-run side of the contract: the warn must fire and
    // the debug must NOT — accidentally double-emitting at the warn site
    // would silently break the prior-session-zombie downgrade pair.
    assert_eq(phase_test_event_count(captured, @moontrace.Level::Debug, msg), 0)
  })
}

///|
test "sync_parent_child_lifecycle downgrades missing parent for terminal child" {
  let project_dir = phase_test_tmp_project_dir("terminal-missing-parent")
  let registry = @registry.AgentRegistry::new()
  let agent_id = "feature/x.done-leaf"
  ignore(registry.upsert(phase_test_agent(agent_id, Some("feature/x.parent"))))
  let lifecycle = {
    ..lifecycle_for_role(agent_id, @types.Role::Dev),
    process: ProcessState::Finalized(reason=FinalizeReason::Merged),
    workflow: WorkflowState::Dev(
      DevLifecycle::Done(reason=FinalizeReason::Merged),
    ),
  }
  let captured : Array[@moontrace.Event] = []
  let msg = "sync_parent_child_lifecycle: parent not in registry"
  phase_test_with_capture(captured, fn() raise {
    sync_parent_child_lifecycle(
      project_dir, "session", registry, agent_id, lifecycle,
    )
    assert_eq(phase_test_warning_count(captured, msg), 0)
    // Pins the downgrade contract: silencing the warn must not also drop
    // the signal entirely — the debug entry has to fire so prior-session
    // zombies remain greppable in operator-trace.
    assert_eq(phase_test_event_count(captured, @moontrace.Level::Debug, msg), 1)
  })
}

///|
test "is_active_to_failed_transition matches non-failed workflow to failed workflow" {
  assert_true(
    is_active_to_failed_transition(
      phase_test_lifecycle_for_workflow(Supervisor(Planning)),
      phase_test_lifecycle_for_workflow(
        Supervisor(Failed(reason=UnexpectedDisconnect)),
      ),
    ),
  )
  assert_true(
    is_active_to_failed_transition(
      phase_test_lifecycle_for_workflow(Supervisor(Dispatching)),
      phase_test_lifecycle_for_workflow(
        Supervisor(Failed(reason=ParentFailureNotification)),
      ),
    ),
  )
  assert_true(
    is_active_to_failed_transition(
      phase_test_lifecycle_for_workflow(Dev(Working)),
      phase_test_lifecycle_for_workflow(
        Dev(Failed(reason=UnexpectedDisconnect)),
      ),
    ),
  )
  assert_true(
    is_active_to_failed_transition(
      phase_test_lifecycle_for_workflow(
        Dev(ReviewOwned(pr_number=1, state=ApprovedAwaitingMerge)),
      ),
      phase_test_lifecycle_for_workflow(Dev(Failed(reason=BlockedByReview))),
    ),
  )
  assert_true(
    is_active_to_failed_transition(
      phase_test_lifecycle_for_workflow(Worker(Working)),
      phase_test_lifecycle_for_workflow(Worker(Failed(reason=WatchdogTimeout))),
    ),
  )
  assert_true(
    is_active_to_failed_transition(
      phase_test_lifecycle_for_workflow(Worker(Exitable)),
      phase_test_lifecycle_for_workflow(Worker(Failed(reason=ParentKilled))),
    ),
  )
}

///|
test "is_active_to_failed_transition suppresses non-failed and repeated failed transitions" {
  let working = phase_test_lifecycle_for_workflow(Dev(Working))
  let review_owned = phase_test_lifecycle_for_workflow(
    Dev(ReviewOwned(pr_number=1, state=ApprovedAwaitingMerge)),
  )
  assert_false(is_active_to_failed_transition(working, review_owned))
  let failed = phase_test_lifecycle_for_workflow(
    Dev(Failed(reason=UnexpectedDisconnect)),
  )
  assert_false(is_active_to_failed_transition(failed, failed))
}

///|
test "append_lifecycle_event warns when lifecycle enters Failed" {
  let project_dir = "/tmp/choir-lifecycle-failed-warn-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let from_lc = phase_test_lifecycle_for_workflow(Dev(Working))
  let to_lc = {
    ..phase_test_lifecycle_for_workflow(Dev(Failed(reason=WatchdogTimeout))),
    agent_id: from_lc.agent_id,
  }
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  let ok = append_lifecycle_event(
    project_dir,
    from_lc.agent_id,
    from_lc,
    to_lc,
    @types.LifecycleTrigger::ExitShutdown,
  )
  @moontrace.clear_subscriber()
  assert_true(ok)
  let warn_event = match phase_test_failed_warn_event(captured) {
    Some(event) => event
    None => fail("expected failed lifecycle warning")
  }
  match phase_test_field_value(warn_event.fields, "agent_id") {
    Some(String(value)) => assert_eq(value, from_lc.agent_id)
    _ => fail("agent_id field")
  }
  match phase_test_field_value(warn_event.fields, "trigger") {
    Some(String(value)) => assert_eq(value, "ExitShutdown")
    _ => fail("trigger field")
  }
  match phase_test_field_value(warn_event.fields, "reason") {
    Some(String(value)) => assert_eq(value, "watchdog_timeout")
    _ => fail("reason field")
  }
  match phase_test_field_value(warn_event.fields, "from_state") {
    Some(String(value)) => assert_true(value.contains("\"workflow\""))
    _ => fail("from_state field")
  }
  match phase_test_field_value(warn_event.fields, "to_state") {
    Some(String(value)) => assert_true(value.contains("WatchdogTimeout"))
    _ => fail("to_state field")
  }
  ignore(@sys.rm_rf(project_dir))
}

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
  // `Supervisor` is not exempt here; `check_idle_agents` skips TL by role first.
  assert_false(lifecycle_idle_watchdog_exempt(tl))

  // WaitingForRedGate must be exempt (leaf is following TDD protocol; spec says wait).
  let dev_red_gate = {
    ..lifecycle_for_role("d2", @types.Role::Dev),
    workflow: Dev(WaitingForRedGate),
  }
  assert_true(lifecycle_idle_watchdog_exempt(dev_red_gate))
}

///|
test "lifecycle_thread_owning_dev covers the three thread-owning Dev states by name" {
  // The progress backstop and dead-leaf reaper (choir-3rp5, F1) must cover
  // exactly the watchdog-exempt Dev states that own a PR's contested review
  // threads — the states `lifecycle_idle_watchdog_exempt` skips that carry a
  // `pr_number`: ReviewOwned, ChangesRequested, and ExitRequestedDeferred.
  assert_true(
    lifecycle_thread_owning_dev(
      Dev(ReviewOwned(pr_number=7, state=OpenUnreviewed(url="u"))),
    ),
  )
  assert_true(
    lifecycle_thread_owning_dev(
      Dev(ReviewOwned(pr_number=7, state=ApprovedAwaitingMerge)),
    ),
  )
  assert_true(
    lifecycle_thread_owning_dev(Dev(ChangesRequested(pr_number=7, next_round=2))),
  )
  // ExitRequestedDeferred owns a PR (carries pr_number + review state) and is
  // idle-watchdog-exempt + non-terminal — an alive-wedged one orphans unless the
  // backstop covers it (choir-3rp5.4 residual F1 gap).
  assert_true(
    lifecycle_thread_owning_dev(
      Dev(ExitRequestedDeferred(pr_number=7, state=ApprovedAwaitingMerge)),
    ),
  )
}

///|
test "lifecycle_thread_owning_dev excludes non-thread-owning and non-Dev states" {
  assert_false(lifecycle_thread_owning_dev(Dev(Working)))
  // WaitingForRedGate is a pre-PR TDD wait: it owns no review threads and
  // carries no pr_number, so the backstop/reaper exclude it (spec Q1/Leaf 2).
  assert_false(lifecycle_thread_owning_dev(Dev(WaitingForRedGate)))
  assert_false(lifecycle_thread_owning_dev(Dev(Exitable)))
  assert_false(lifecycle_thread_owning_dev(Dev(Done(reason=Merged))))
  assert_false(
    lifecycle_thread_owning_dev(Dev(Failed(reason=UnexpectedDisconnect))),
  )
  assert_false(lifecycle_thread_owning_dev(Worker(Working)))
  assert_false(lifecycle_thread_owning_dev(Supervisor(Planning)))
}

///|
/// Canonical structural shape of a `DevLifecycle`, collapsing unbounded numeric
/// payloads (`pr_number`, `next_round`) so the BFS over `dev_lifecycle_transition`
/// terminates while still distinguishing every variant that matters to the
/// invariant. TOTAL match: a new `DevLifecycle` variant fails to compile here,
/// forcing a maintainer to classify it before the invariant test can drift.
fn dev_state_invariant_shape(state : DevLifecycle) -> String {
  match state {
    Working => "Working"
    WaitingForRedGate => "WaitingForRedGate"
    ReviewOwned(state~, ..) =>
      "ReviewOwned:" + review_ownership_invariant_shape(state)
    ChangesRequested(..) => "ChangesRequested"
    ExitRequestedDeferred(state~, ..) =>
      "ExitRequestedDeferred:" + review_ownership_invariant_shape(state)
    Exitable => "Exitable"
    Done(..) => "Done"
    Failed(..) => "Failed"
  }
}

///|
fn review_ownership_invariant_shape(state : ReviewOwnership) -> String {
  match state {
    OpenUnreviewed(..) => "OpenUnreviewed"
    FixesAwaitingReview(..) => "FixesAwaitingReview"
    ApprovedAwaitingMerge => "ApprovedAwaitingMerge"
  }
}

///|
/// A `DevLifecycle` that corresponds to a terminal `ProcessState`: the leaf has
/// finished (`Done`) or failed (`Failed`) and is finalized, so the single-writer
/// gate's `is_terminal` axis has already released its threads to the TL. TOTAL
/// match (anti-drift): a new variant must be explicitly classified.
fn dev_state_process_terminal(state : DevLifecycle) -> Bool {
  match state {
    Done(..) | Failed(..) => true
    Working
    | WaitingForRedGate
    | ReviewOwned(..)
    | ChangesRequested(..)
    | ExitRequestedDeferred(..)
    | Exitable => false
  }
}

///|
/// One representative of every `DevLifecycleEvent` variant, targeting `pr`. The
/// witness match below is the compile-time guard that keeps this alphabet in
/// sync with the event enum, so the BFS can never silently omit a transition.
fn dev_invariant_events(pr : Int) -> Array[DevLifecycleEvent] {
  [
    PRCreated(pr_number=pr, url="u"),
    ReviewReceived(pr_number=pr, body="b"),
    ReviewApproved(pr_number=pr),
    FixesPushed(pr_number=pr, sha="s"),
    ExitRequested,
    MergeObserved(pr_number=pr),
    PrClosedUnmerged(pr_number=pr),
  ]
}

///|
fn dev_event_invariant_witness(event : DevLifecycleEvent) -> Unit {
  match event {
    PRCreated(..)
    | ReviewReceived(..)
    | ReviewApproved(..)
    | FixesPushed(..)
    | ExitRequested
    | MergeObserved(..)
    | PrClosedUnmerged(..) => ()
  }
}

///|
/// DEFENSIVE INVARIANT (choir-3rp5.5): the single-writer gate
/// (`src/tools/dispatch.mbt`) blocks the TL for ANY non-terminal owner via
/// `ProcessState::is_terminal`, but the liveness drivers (progress-backstop +
/// dead-leaf reaper) only cover `lifecycle_thread_owning_dev`. Those two sets
/// coincide today ONLY because the `DevLifecycle` transition table never routes a
/// tracked-PR owner into a non-terminal, non-thread-owning state — nothing
/// enforces it. This test PINS that coincidence: starting from the FSM's own
/// entry into PR ownership and following the REAL `dev_lifecycle_transition`
/// (both review modes), every reachable state must be either
/// `ProcessState`-terminal OR in `lifecycle_thread_owning_dev`. A future
/// transition that violates this — e.g. parking a PR-owner in `Exitable` while it
/// still owns the tracked PR — would be reached by the BFS and fail here, before
/// it can silently deadlock the TL gate (non-terminal owner, no driver to reap).
test "every PR-owning-reachable DevLifecycle state is terminal or thread-owning (choir-3rp5.5 gate==driver invariant)" {
  // Keep the event-alphabet exhaustiveness guard live.
  for event in dev_invariant_events(1) {
    dev_event_invariant_witness(event)
  }
  // Entry: the FSM's own transition into PR ownership, not a hand-written state.
  let entry = match
    dev_lifecycle_transition(Working, PRCreated(pr_number=1, url="u")) {
    Transitioned(state) => state
    InvalidTransition(msg) => {
      fail("PRCreated must enter PR ownership: " + msg)
      return
    }
  }
  // BFS over the real transition function, both review modes, deduped by shape.
  let visited : Map[String, DevLifecycle] = {}
  let worklist : Array[DevLifecycle] = [entry]
  visited.set(dev_state_invariant_shape(entry), entry)
  let modes = [@types.ReviewMode::Iterative, @types.ReviewMode::SinglePass]
  let mut i = 0
  while i < worklist.length() {
    let state = worklist[i]
    i = i + 1
    for mode in modes {
      for event in dev_invariant_events(1) {
        match dev_lifecycle_transition(state, event, review_mode=mode) {
          Transitioned(next) => {
            let key = dev_state_invariant_shape(next)
            match visited.get(key) {
              None => {
                visited.set(key, next)
                worklist.push(next)
              }
              Some(_) => ()
            }
          }
          InvalidTransition(_) => ()
        }
      }
    }
  }
  // The invariant: every reachable state is terminal or driver-covered.
  for shape, state in visited {
    let covered = dev_state_process_terminal(state) ||
      lifecycle_thread_owning_dev(Dev(state))
    if !covered {
      fail(
        "DevLifecycle state reachable while owning a tracked PR is neither ProcessState-terminal nor in lifecycle_thread_owning_dev: " +
        shape +
        " — a future transition would silently deadlock the TL single-writer gate (choir-3rp5.5).",
      )
    }
  }
  // Guard against a vacuous pass if the FSM entry ever stops reaching the
  // PR-owning states (the three thread-owning states + the Done terminal).
  assert_true(visited.length() >= 4)
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
test "dev_lifecycle_transition exits deferred open PR when merge observed" {
  let lifecycle : DevLifecycle = ExitRequestedDeferred(
    pr_number=346,
    state=OpenUnreviewed(url="https://example.test/pr/346"),
  )
  match
    dev_lifecycle_transition(
      lifecycle,
      DevLifecycleEvent::MergeObserved(pr_number=346),
    ) {
    Transitioned(Done(reason=Merged)) => ()
    _ => fail("expected deferred exit to complete after merge observed")
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
    last_updated_unix_sec: 0L,
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
    last_updated_unix_sec: 0L,
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
    last_updated_unix_sec: 1234L,
  }
  let json = lifecycle_to_json(lifecycle)
  assert_true(json.contains("\"last_updated_unix_sec\""))
  assert_true(json.contains("\"1234\""))
  match lifecycle_from_json(json) {
    Some(restored) => assert_eq(restored, lifecycle)
    None => fail("expected lifecycle round-trip")
  }
}

///|
test "lifecycle json read defaults missing last_updated_unix_sec" {
  let legacy_json =
    #|{"agent_id":"main","role":["TL"],"process":["Connected"],"workflow":["Supervisor",["Planning"]]}
  match lifecycle_from_json(legacy_json) {
    Some(restored) => assert_eq(restored.last_updated_unix_sec, 0L)
    None => fail("expected legacy lifecycle read")
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
test "supervisor full-id child update reaches WaveComplete from spawned row" {
  let lifecycle : AgentLifecycle = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: Connected,
    workflow: Supervisor(Planning),
    last_updated_unix_sec: 0L,
  }
  let effects = plan_tl_lifecycle_effects(
    lifecycle,
    TLEvent::ChildSpawned(
      child_id="main.leaf-x",
      agent_type=@types.AgentType::Codex,
    ),
  )
  let supervisor = match effects[0] {
    PersistLifecycle(lifecycle=lc) =>
      match lc.workflow {
        Supervisor(next) => next
        _ => {
          fail("expected supervisor lifecycle")
          Planning
        }
      }
    _ => {
      fail("expected PersistLifecycle")
      Planning
    }
  }
  match
    supervisor_transition(
      supervisor,
      SupervisorEvent::ChildUpdated(
        child_id="main.leaf-x",
        summary=ChildLifecycleSummary::Done,
        agent_type=Some(@types.AgentType::Codex),
      ),
    ) {
    Transitioned(WaveComplete(wave=1, children~)) => {
      assert_eq(children.length(), 1)
      assert_eq(children[0].child_id, "main.leaf-x")
      assert_eq(children[0].summary, ChildLifecycleSummary::Done)
    }
    Transitioned(_) => fail("expected WaveComplete after full-id update")
    InvalidTransition(reason) =>
      fail("expected WaveComplete after full-id update, got invalid: " + reason)
  }
}

///|
test "supervisor ChildSpawned heals legacy slug-only phantom row" {
  let phantom : ChildLifecycle = {
    child_id: "leaf-x",
    slug: "leaf-x",
    branch: "leaf-x",
    agent_type: @types.AgentType::Unknown,
    summary: ChildLifecycleSummary::Working,
  }
  let real : ChildLifecycle = {
    child_id: "main.leaf-x",
    slug: "leaf-x",
    branch: "main.leaf-x",
    agent_type: @types.AgentType::Codex,
    summary: ChildLifecycleSummary::Working,
  }
  match
    supervisor_transition(
      SupervisorLifecycle::Supervising(children=[phantom], wave=1),
      SupervisorEvent::ChildSpawned(child=real),
    ) {
    Transitioned(Supervising(children~, wave=1)) => {
      assert_eq(children.length(), 1)
      assert_eq(children[0].child_id, "main.leaf-x")
      assert_eq(children[0].slug, "leaf-x")
      assert_eq(children[0].branch, "main.leaf-x")
      assert_eq(children[0].agent_type, @types.AgentType::Codex)
      assert_eq(children[0].summary, ChildLifecycleSummary::Working)
    }
    Transitioned(_) => fail("expected healed Supervising row")
    InvalidTransition(reason) =>
      fail("expected healed Supervising row, got invalid: " + reason)
  }
}

///|
test "supervisor ChildSpawned after WaveComplete starts next wave with only new child" {
  let prior_done : ChildLifecycle = {
    child_id: "main.leaf-x",
    slug: "leaf-x",
    branch: "main.leaf-x",
    agent_type: @types.AgentType::Codex,
    summary: ChildLifecycleSummary::Done,
  }
  let prior_failed : ChildLifecycle = {
    child_id: "main.leaf-y",
    slug: "leaf-y",
    branch: "main.leaf-y",
    agent_type: @types.AgentType::Codex,
    summary: ChildLifecycleSummary::Failed(reason=RecoveredFailed),
  }
  let next_child : ChildLifecycle = {
    child_id: "main.leaf-z",
    slug: "leaf-z",
    branch: "main.leaf-z",
    agent_type: @types.AgentType::Codex,
    summary: ChildLifecycleSummary::Working,
  }
  match
    supervisor_transition(
      SupervisorLifecycle::WaveComplete(wave=1, children=[
        prior_done, prior_failed,
      ]),
      SupervisorEvent::ChildSpawned(child=next_child),
    ) {
    Transitioned(Supervising(children~, wave=2)) => {
      assert_eq(children.length(), 1)
      assert_eq(children[0].child_id, next_child.child_id)
      assert_eq(children[0].slug, next_child.slug)
      assert_eq(children[0].branch, next_child.branch)
      assert_eq(children[0].agent_type, next_child.agent_type)
      assert_eq(children[0].summary, next_child.summary)
    }
    Transitioned(_) => fail("expected next wave to contain only new child")
    InvalidTransition(reason) =>
      fail(
        "expected next wave to contain only new child, got invalid: " + reason,
      )
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
  let resolved = try
    resolve_agent_with_fallback(project_dir, session, reg, agent_id)
  catch {
    e => Err(e)
  } noraise {
    agent => Ok(agent)
  }
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let lifecycle = lifecycle_for_role(agent_id, @types.Role::TL)
  ignore(write_lifecycle(project_dir, lifecycle))

  let resolved = try
    resolve_agent_with_fallback(project_dir, session, reg, agent_id)
  catch {
    e => Err(e)
  } noraise {
    agent => Ok(agent)
  }
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

  let resolved = try
    resolve_parent_with_fallback(project_dir, session, reg, caller_id)
  catch {
    e => Err(e)
  } noraise {
    agent => Ok(agent)
  }
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
    last_updated_unix_sec: 0L,
  }
  let effects = plan_tl_lifecycle_effects(
    lifecycle,
    TLEvent::ChildSpawned(
      child_id="main.leaf",
      agent_type=@types.AgentType::Codex,
    ),
  )
  assert_eq(effects.length(), 2)
  match effects[0] {
    PersistLifecycle(lifecycle=lc) =>
      match lc.workflow {
        Supervisor(Supervising(children~, wave=1)) => {
          assert_eq(children.length(), 1)
          assert_eq(children[0].child_id, "main.leaf")
          assert_eq(children[0].slug, "leaf")
          assert_eq(children[0].branch, "main.leaf")
          assert_eq(children[0].agent_type, @types.AgentType::Codex)
          assert_eq(children[0].summary, ChildLifecycleSummary::Working)
        }
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
    last_updated_unix_sec: 0L,
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
    last_updated_unix_sec: 0L,
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
    last_updated_unix_sec: 0L,
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
    Some(lc) => {
      assert_eq(lc.agent_id, to_lc.agent_id)
      assert_eq(lc.role, to_lc.role)
      assert_eq(lc.process, to_lc.process)
      assert_eq(lc.workflow, to_lc.workflow)
      assert_true(lc.last_updated_unix_sec > 0L)
    }
    None => fail("expected persisted lifecycle")
  }
  let ev_path = project_dir +
    "/.choir/state/events/" +
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
  ignore(@sys.write_file_sync(project_dir + "/.choir/state/kv", "not-a-directory"))
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
    "/.choir/state/events/" +
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
test "persist_lifecycle preserves suspended registry overlay for active lifecycle" {
  let project_dir = "/tmp/choir-persist-suspended-overlay-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let reg = @registry.AgentRegistry::new()
  let agent_id = "p.suspended"
  ignore(reg.upsert(phase_test_agent(agent_id, None, state=Suspended)))
  let lifecycle = lifecycle_for_role(agent_id, @types.Role::Dev)
  assert_true(persist_lifecycle(project_dir, reg, lifecycle))
  try reg.get(agent_id) catch {
    _ => fail("expected agent in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Suspended)
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "interpret_lifecycle_effects append ignored when last persist is another agent" {
  let project_dir = "/tmp/choir-interp-pair-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
    "/.choir/state/events/" +
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
    "/.choir/state/events/" +
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

///|
test "dev_lifecycle_transition closes ReviewOwned/ChangesRequested/ExitRequestedDeferred to Done(PrClosedUnmerged) on matching PR (choir-56ax)" {
  // ReviewOwned -> Done(PrClosedUnmerged)
  match
    dev_lifecycle_transition(
      ReviewOwned(pr_number=200, state=OpenUnreviewed(url="u")),
      PrClosedUnmerged(pr_number=200),
    ) {
    Transitioned(Done(reason=PrClosedUnmerged)) => ()
    _ => fail("expected Done(PrClosedUnmerged) from ReviewOwned")
  }
  // ChangesRequested (NET-NEW arm — MergeObserved has none) -> Done(PrClosedUnmerged)
  match
    dev_lifecycle_transition(
      ChangesRequested(pr_number=200, next_round=2),
      PrClosedUnmerged(pr_number=200),
    ) {
    Transitioned(Done(reason=PrClosedUnmerged)) => ()
    _ =>
      fail("expected Done(PrClosedUnmerged) from ChangesRequested")
  }
  // ExitRequestedDeferred -> Done(PrClosedUnmerged)
  match
    dev_lifecycle_transition(
      ExitRequestedDeferred(pr_number=200, state=ApprovedAwaitingMerge),
      PrClosedUnmerged(pr_number=200),
    ) {
    Transitioned(Done(reason=PrClosedUnmerged)) => ()
    _ =>
      fail("expected Done(PrClosedUnmerged) from ExitRequestedDeferred")
  }
  // PER-PR gate: a stale PR closing must NOT finalize a leaf owning a different PR.
  match
    dev_lifecycle_transition(
      ReviewOwned(pr_number=200, state=OpenUnreviewed(url="u")),
      PrClosedUnmerged(pr_number=199),
    ) {
    InvalidTransition(_) => ()
    _ => fail("expected InvalidTransition for stale PR close")
  }
  // Exitable is EXCLUDED (pr-blind, AR-3b).
  match dev_lifecycle_transition(Exitable, PrClosedUnmerged(pr_number=200)) {
    InvalidTransition(_) => ()
    _ => fail("expected InvalidTransition for Exitable close")
  }
}
