///|
fn make_agent(
  id : String,
  role : @types.Role,
  parent : String?,
  agent_type : @types.AgentType,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(id),
    role,
    agent_type,
    parent,
    workspace: "/tmp/ws/" + id,
    branch: id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
}

///|
fn make_dev_lifecycle(
  agent_id : String,
  workflow : @phase.DevLifecycle,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.Connected,
    workflow: @phase.Dev(workflow),
  }
}

///|
fn make_worker_lifecycle(
  agent_id : String,
  workflow : @phase.WorkerLifecycle,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::Worker,
    process: @phase.Connected,
    workflow: @phase.Worker(workflow),
  }
}

///|
fn make_supervisor_lifecycle(
  agent_id : String,
  workflow : @phase.SupervisorLifecycle,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::TL,
    process: @phase.Connected,
    workflow: @phase.Supervisor(workflow),
  }
}

///|
fn lifecycle_map_reader(
  map : Map[String, @phase.AgentLifecycle],
) -> (String) -> @phase.AgentLifecycle? {
  fn(id) { map.get(id) }
}

///|
fn heartbeat_map_reader(map : Map[String, Int64]) -> (String) -> Int64? {
  fn(id) { map.get(id) }
}

///|
fn threads_zero_lookup(_pr : Int) -> (Int?, String?) {
  (Some(0), None)
}

///|
fn no_heartbeat(_agent_id : String) -> Int64? {
  None
}

///|
/// Build a TrackedPR in the state we want for a test branch.
fn tracked_pr_with(
  pr_number : Int,
  agent_id : String,
  review : @poller.ReviewState,
  ci : @poller.CiRollupStatus,
  copilot_comment : Bool,
  fixes_pushed_at : Int64,
  last_sha : String,
) -> @poller.TrackedPR {
  {
    pr_number,
    agent_id,
    branch: agent_id,
    parent_branch: "main",
    pr_url: "https://x/pr/" + pr_number.to_string(),
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: "",
    last_sha,
    notified_parent: false,
    last_ci_rollup: ci,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: copilot_comment,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at,
  }
}

///|
test "plan_wave_state assembles supervisor + dev + worker children" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf-a",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.worker-b",
        @types.Role::Worker,
        Some("tl"),
        @types.AgentType::Claude,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle(
      "tl",
      @phase.SupervisorLifecycle::Supervising(children=[], wave=7),
    ),
  )
  lifecycles.set(
    "tl.leaf-a",
    make_dev_lifecycle(
      "tl.leaf-a",
      @phase.DevLifecycle::ReviewOwned(
        pr_number=42,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="https://x/pr/42"),
      ),
    ),
  )
  lifecycles.set(
    "tl.worker-b",
    make_worker_lifecycle("tl.worker-b", @phase.WorkerLifecycle::Working),
  )
  let ps = @poller.PollerState::new()
  ps.track(42, "tl.leaf-a", "tl.leaf-a", "main", "https://x/pr/42", 0L)
  let hb : Map[String, Int64] = {}
  hb.set("tl.worker-b", 1_700_000_000_000L)
  let snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    threads_zero_lookup,
    heartbeat_map_reader(hb),
    @types.ReviewMode::Iterative,
    9_999_999L,
  ).unwrap()
  assert_eq(snap.taken_at_ms, 9_999_999L)
  assert_eq(snap.supervisor.agent_id, "tl")
  @debug.assert_eq(snap.supervisor.wave, Some(7))
  assert_true(snap.supervisor.own_pr is None)
  assert_eq(snap.children.length(), 2)
  let leaf_row = snap.children
    .iter()
    .find_first(fn(c) { c.agent_id == "tl.leaf-a" })
    .unwrap()
  assert_eq(leaf_row.agent_type, @types.AgentType::Gemini)
  @debug.assert_eq(leaf_row.last_heartbeat_ms, None)
  match leaf_row.pr {
    Some(pr) => {
      assert_eq(pr.pr_number, 42)
      assert_eq(pr.review_state, @poller.ReviewState::None_)
      assert_eq(pr.ci_rollup, @poller.CiRollupStatus::Unknown)
      @debug.assert_eq(pr.unresolved_threads, Some(0))
      @debug.assert_eq(pr.threads_fetch_error, None)
      assert_eq(pr.merge_gate_ready, false)
    }
    None => fail("expected tracked PR for dev leaf")
  }
  let worker_row = snap.children
    .iter()
    .find_first(fn(c) { c.agent_id == "tl.worker-b" })
    .unwrap()
  assert_true(worker_row.pr is None)
  @debug.assert_eq(worker_row.last_heartbeat_ms, Some(1_700_000_000_000L))
  assert_eq(worker_row.agent_type, @types.AgentType::Claude)
  match worker_row.workflow {
    @phase.Worker(@phase.WorkerLifecycle::Working) => ()
    _ => fail("expected worker Working")
  }
}

///|
test "plan_wave_state merge_gate_ready: approved + threads=0 + CI success" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
  )
  lifecycles.set(
    "tl.leaf",
    make_dev_lifecycle(
      "tl.leaf",
      @phase.DevLifecycle::ReviewOwned(
        pr_number=10,
        state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    10,
    tracked_pr_with(
      10,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Success,
      false,
      0L,
      "abc",
    ),
  )
  let snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    threads_zero_lookup,
    no_heartbeat,
    @types.ReviewMode::Iterative,
    0L,
  ).unwrap()
  let pr = snap.children[0].pr.unwrap()
  assert_eq(pr.merge_gate_ready, true)
}

///|
test "plan_wave_state merge_gate_ready SinglePass: ChangesRequested + fixes_pushed" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    20,
    tracked_pr_with(
      20,
      "tl.leaf",
      @poller.ReviewState::ChangesRequested,
      @poller.CiRollupStatus::Success,
      false,
      1_700_000_000L,
      "def",
    ),
  )
  let iter_snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    threads_zero_lookup,
    no_heartbeat,
    @types.ReviewMode::Iterative,
    0L,
  ).unwrap()
  assert_eq(iter_snap.children[0].pr.unwrap().merge_gate_ready, false)
  let single_snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    threads_zero_lookup,
    no_heartbeat,
    @types.ReviewMode::SinglePass,
    0L,
  ).unwrap()
  assert_eq(single_snap.children[0].pr.unwrap().merge_gate_ready, true)
}

///|
test "plan_wave_state merge_gate_ready false when CI is not success" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    30,
    tracked_pr_with(
      30,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Failure,
      false,
      0L,
      "abc",
    ),
  )
  let snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    threads_zero_lookup,
    no_heartbeat,
    @types.ReviewMode::Iterative,
    0L,
  ).unwrap()
  assert_eq(snap.children[0].pr.unwrap().merge_gate_ready, false)
}

///|
test "plan_wave_state merge_gate_ready false when unresolved threads > 0" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    40,
    tracked_pr_with(
      40,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Success,
      false,
      0L,
      "abc",
    ),
  )
  let threads_two = fn(_pr : Int) -> (Int?, String?) { (Some(2), None) }
  let snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    threads_two,
    no_heartbeat,
    @types.ReviewMode::Iterative,
    0L,
  ).unwrap()
  let pr = snap.children[0].pr.unwrap()
  @debug.assert_eq(pr.unresolved_threads, Some(2))
  assert_eq(pr.merge_gate_ready, false)
}

///|
test "plan_wave_state reports threads_fetch_error on fail-loud path" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    50,
    tracked_pr_with(
      50,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Success,
      false,
      0L,
      "abc",
    ),
  )
  let fail_lookup = fn(_pr : Int) -> (Int?, String?) {
    (None, Some("gh unavailable"))
  }
  let snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    Some(ps),
    fail_lookup,
    no_heartbeat,
    @types.ReviewMode::Iterative,
    0L,
  ).unwrap()
  let pr = snap.children[0].pr.unwrap()
  @debug.assert_eq(pr.unresolved_threads, None)
  @debug.assert_eq(pr.threads_fetch_error, Some("gh unavailable"))
  // fail-loud: snapshot is NOT blocked.
  assert_eq(pr.merge_gate_ready, false)
}

///|
test "wave_state registry denies Dev and Worker callers" {
  let tools = @tools.ToolRegistry::new()
  let dev_lookup = try? tools.lookup(@types.Role::Dev, "wave_state")
  assert_true(dev_lookup is Err(_))
  let worker_lookup = try? tools.lookup(@types.Role::Worker, "wave_state")
  assert_true(worker_lookup is Err(_))
  let tl_lookup = try? tools.lookup(@types.Role::TL, "wave_state")
  assert_true(tl_lookup is Ok(_))
  let root_lookup = try? tools.lookup(@types.Role::Root, "wave_state")
  assert_true(root_lookup is Ok(_))
}

///|
test "plan_wave_state worker with stale heartbeat appears in snapshot" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.sarcasmotron",
        @types.Role::Worker,
        Some("tl"),
        @types.AgentType::Claude,
      ),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  lifecycles.set(
    "tl",
    make_supervisor_lifecycle(
      "tl",
      @phase.SupervisorLifecycle::Supervising(children=[], wave=1),
    ),
  )
  lifecycles.set(
    "tl.sarcasmotron",
    make_worker_lifecycle("tl.sarcasmotron", @phase.WorkerLifecycle::Working),
  )
  let hb : Map[String, Int64] = {}
  // Stale heartbeat from 10 minutes in the past (arbitrary old epoch ms).
  hb.set("tl.sarcasmotron", 1_600_000_000_000L)
  let snap = plan_wave_state(
    "tl",
    reg,
    lifecycle_map_reader(lifecycles),
    None,
    threads_zero_lookup,
    heartbeat_map_reader(hb),
    @types.ReviewMode::Iterative,
    1_600_000_600_000L,
  ).unwrap()
  assert_eq(snap.children.length(), 1)
  let row = snap.children[0]
  assert_eq(row.agent_id, "tl.sarcasmotron")
  assert_true(row.pr is None)
  @debug.assert_eq(row.last_heartbeat_ms, Some(1_600_000_000_000L))
  match row.workflow {
    @phase.Worker(@phase.WorkerLifecycle::Working) => ()
    _ => fail("expected Worker(Working) for silent worker")
  }
}

///|
test "plan_wave_state rejects non-supervisor caller with permission_denied" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("leaf", @types.Role::Dev, None, @types.AgentType::Gemini),
    ),
  )
  let lifecycles : Map[String, @phase.AgentLifecycle] = {}
  let result = plan_wave_state(
    "leaf",
    reg,
    lifecycle_map_reader(lifecycles),
    None,
    threads_zero_lookup,
    no_heartbeat,
    @types.ReviewMode::Iterative,
    0L,
  )
  assert_true(result is Err(_))
}

///|
async fn mock_wave_state_capture_threads_none(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  (0, "")
}

///|
async fn mock_wave_state_capture_threads_two(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"T1\",\"isResolved\":false,\"path\":\"f.mbt\",\"comments\":{\"nodes\":[{\"body\":\"fix\"}]}},{\"id\":\"T2\",\"isResolved\":false,\"path\":\"g.mbt\",\"comments\":{\"nodes\":[{\"body\":\"nit\"}]}}]}}}}}",
    )
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  (0, "")
}

///|
async fn mock_wave_state_capture_gh_fails(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (1, "gh error")
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  (0, "")
}

///|
fn wave_state_test_project_dir(label : String) -> String {
  let dir = "/tmp/choir-wave-state-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(dir))
  ignore(@sys.create_dir_all(dir + "/.choir/kv"))
  dir
}

///|
async test "interpret_wave_state unresolved_threads=Some(0) on clean graphql" {
  let project_dir = wave_state_test_project_dir("zero")
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  ignore(
    @phase.write_lifecycle(
      project_dir,
      make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    99,
    tracked_pr_with(
      99,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Success,
      false,
      0L,
      "abc",
    ),
  )
  let resp = interpret_wave_state(
    { caller_id: "tl" },
    project_dir,
    Some(reg),
    Some(ps),
    capture=mock_wave_state_capture_threads_none,
  )
  assert_true(resp.is_ok())
  let body = resp.ok_field("snapshot").unwrap()
  assert_true(body.contains("\"unresolved_threads\":0"))
  assert_true(body.contains("\"merge_gate_ready\":true"))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_wave_state unresolved_threads=Some(N) blocks merge_gate_ready" {
  let project_dir = wave_state_test_project_dir("two")
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  ignore(
    @phase.write_lifecycle(
      project_dir,
      make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    101,
    tracked_pr_with(
      101,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Success,
      false,
      0L,
      "abc",
    ),
  )
  let resp = interpret_wave_state(
    { caller_id: "tl" },
    project_dir,
    Some(reg),
    Some(ps),
    capture=mock_wave_state_capture_threads_two,
  )
  let body = resp.ok_field("snapshot").unwrap()
  assert_true(body.contains("\"unresolved_threads\":2"))
  assert_true(body.contains("\"merge_gate_ready\":false"))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_wave_state fail-loud when gh graphql fails" {
  let project_dir = wave_state_test_project_dir("fail")
  let reg = @registry.AgentRegistry::new()
  ignore(
    try? reg.insert(
      make_agent("tl", @types.Role::TL, None, @types.AgentType::Gemini),
    ),
  )
  ignore(
    try? reg.insert(
      make_agent(
        "tl.leaf",
        @types.Role::Dev,
        Some("tl"),
        @types.AgentType::Gemini,
      ),
    ),
  )
  ignore(
    @phase.write_lifecycle(
      project_dir,
      make_supervisor_lifecycle("tl", @phase.SupervisorLifecycle::Planning),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(
    202,
    tracked_pr_with(
      202,
      "tl.leaf",
      @poller.ReviewState::Approved,
      @poller.CiRollupStatus::Success,
      false,
      0L,
      "abc",
    ),
  )
  let resp = interpret_wave_state(
    { caller_id: "tl" },
    project_dir,
    Some(reg),
    Some(ps),
    capture=mock_wave_state_capture_gh_fails,
  )
  // Snapshot must be emitted despite gh failure (queries don't gate).
  assert_true(resp.is_ok())
  let body = resp.ok_field("snapshot").unwrap()
  // `derive(ToJson)` omits None fields from the object, so a failed fetch
  // surfaces as `threads_fetch_error` present and `unresolved_threads` absent.
  assert_false(body.contains("\"unresolved_threads\":"))
  assert_true(body.contains("\"threads_fetch_error\":"))
  assert_true(body.contains("\"merge_gate_ready\":false"))
  ignore(@sys.rm_rf(project_dir))
}
