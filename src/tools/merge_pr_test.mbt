///|
test "interpret_track_pr returns poller unavailable without poller_state" {
  let args : TrackPrArgs = {
    pr_number: 42,
    agent_id: "main.leaf",
    branch: "main.topic",
    parent_branch: "main",
    pr_url: "https://example.test/pr/42",
  }
  let got = interpret_track_pr(args, "/tmp", None, 0L)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "poller unavailable")
    _ => fail("expected err")
  }
}

///|
test "interpret_track_pr ensure_tracked writes state and returns tracked envelope" {
  let project_dir = "/tmp/choir-track-pr-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : TrackPrArgs = {
    pr_number: 99,
    agent_id: "main.agent",
    branch: "feat-x",
    parent_branch: "develop",
    pr_url: "https://gh/pr/99",
  }
  let ps = @poller.PollerState::new()
  let got = interpret_track_pr(args, project_dir, Some(ps), 12345L)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("tracked")))
      @debug.assert_eq(map.get("branch"), Some(String::to_json("feat-x")))
      @debug.assert_eq(
        map.get("parent_branch"),
        Some(String::to_json("develop")),
      )
      @debug.assert_eq(
        map.get("pr_url"),
        Some(String::to_json("https://gh/pr/99")),
      )
    }
    _ => fail("expected ok")
  }
  match ps.get(99) {
    Some(t) => {
      assert_eq(t.agent_id, "main.agent")
      assert_eq(t.branch, "feat-x")
      assert_eq(t.parent_branch, "develop")
      assert_eq(t.pr_url, "https://gh/pr/99")
      assert_eq(t.first_seen, 12345L)
    }
    None => fail("expected tracked PR in poller state")
  }
}

///|
fn merge_pr_test_tracked(
  review : @poller.ReviewState,
  branch : String,
) -> @poller.TrackedPR {
  {
    pr_number: 9,
    agent_id: "main.leaf",
    branch,
    parent_branch: "main",
    pr_url: "https://example.test/pr/9",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: review,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
}

///|
fn merge_pr_test_write_verify_contract(
  project_dir : String,
  verify : Array[String],
) -> String {
  let worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.create_dir_all(worktree + "/.choir"))
  let target : @types.LocalTarget = {
    kind: ZellijTab,
    session: "choir",
    name: "leaf",
  }
  let spec : @types.SpawnSpec = {
    slug: "leaf",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "merge verified work",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "merge verified work",
      verify,
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main.tl",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  ignore(
    @sys.write_file_sync(
      worktree + "/.choir/config.local.toml",
      @workspace.config_local_content(spec, worktree, target),
    ),
  )
  worktree
}

///|
fn merge_pr_test_registry(worktree : String) -> @registry.AgentRegistry {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/repo",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some("main.tl"),
      workspace: worktree,
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  reg
}

///|
fn merge_pr_test_enable_force_override(project_dir : String) -> Unit {
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  ignore(
    @sys.write_file_atomic(
      project_dir + "/.choir/kv/tl-parent-override--main.tl",
      "1\n",
    ),
  )
}

///|
fn merge_pr_test_write_beads_contract(
  project_dir : String,
  parent_branch : String,
  slug : String,
  issue_id : String?,
) -> String {
  let worktree = project_dir + "/.choir/worktrees/" + slug
  ignore(@sys.create_dir_all(worktree + "/.choir"))
  let target : @types.LocalTarget = {
    kind: ZellijTab,
    session: "choir",
    name: slug,
  }
  let spec : @types.SpawnSpec = {
    slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "assigned leaf",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "assigned leaf",
      beads_issue_id: issue_id,
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main.tl",
    parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: Some("wv-feature"),
  }
  ignore(
    @sys.write_file_sync(
      worktree + "/.choir/config.local.toml",
      @workspace.config_local_content(spec, worktree, target),
    ),
  )
  worktree
}

///|
fn merge_pr_test_registry_for_feature(
  project_dir : String,
  feature_branch : String,
  leaves : Array[(String, String)],
) -> @registry.AgentRegistry {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Codex,
      parent: None,
      workspace: project_dir,
      branch: feature_branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  for leaf in leaves {
    let (slug, worktree) = leaf
    let branch = feature_branch + "." + slug
    ignore(
      reg.upsert({
        agent_id: @types.AgentId(branch),
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Codex,
        parent: Some("main.tl"),
        workspace: worktree,
        branch,
        terminal_target: None,
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
  }
  reg
}

///|
async fn merge_pr_test_runner_record_ok(
  cmds : Array[@workspace.Command],
  seen : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for cmd in cmds {
    seen.push(cmd)
    statuses.push(0)
  }
  statuses
}

///|
test "merge_pr_preflight_host_steps is poller snapshot then thread fetch" {
  let steps = merge_pr_preflight_host_steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], MergePrPreflightHostStep::PollerSnapshot)
  assert_eq(steps[1], MergePrPreflightHostStep::FetchUnresolvedReviewThreads)
}

///|
test "parse_github_owner_repo_from_url accepts pr and git remotes" {
  @debug.assert_eq(
    parse_github_owner_repo_from_url("https://github.com/o/r/pull/7"),
    Some(("o", "r")),
  )
  @debug.assert_eq(
    parse_github_owner_repo_from_url("git@github.com:o/r.git\n"),
    Some(("o", "r")),
  )
}

///|
test "merge_pr_review_gate_block_message allows empty reviews" {
  match merge_pr_review_gate_block_message(4, "[]") {
    Ok(None) => ()
    Ok(Some(msg)) => fail("expected empty reviews to pass: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
test "merge_pr_review_gate_block_message allows commented reviews" {
  match
    merge_pr_review_gate_block_message(
      4, "[{\"state\":\"COMMENTED\",\"user\":{\"login\":\"copilot\"},\"submitted_at\":\"2026-01-01T00:00:00Z\"}]",
    ) {
    Ok(None) => ()
    Ok(Some(msg)) => fail("expected commented reviews to pass: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
test "merge_pr_review_gate_block_message blocks changes requested" {
  match
    merge_pr_review_gate_block_message(
      4,
      (
        #|[{"state":"APPROVED","user":{"login":"a"},"submitted_at":"2026-01-01T00:00:00Z"},{"state":"CHANGES_REQUESTED","user":{"login":"b"},"submitted_at":"2026-01-02T00:00:00Z"}]
      ),
    ) {
    Ok(Some(msg)) => assert_true(msg.contains("requesting changes"))
    _ => fail("expected changes requested block")
  }
}

///|
test "merge_pr_review_gate_block_message ignores stale changes requested after same reviewer approves" {
  let reviews =
    #|[
    #|  {"state":"CHANGES_REQUESTED","user":{"login":"reviewer"},"submitted_at":"2026-01-01T00:00:00Z"},
    #|  {"state":"APPROVED","user":{"login":"reviewer"},"submitted_at":"2026-01-02T00:00:00Z"}
    #|]
  match merge_pr_review_gate_block_message(4, reviews) {
    Ok(None) => ()
    Ok(Some(msg)) => fail("expected stale changes requested to clear: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
test "merge_pr_review_gate_block_message uses submitted_at over array order" {
  let reviews =
    #|[
    #|  {"state":"APPROVED","user":{"login":"reviewer"},"submitted_at":"2026-01-02T00:00:00Z"},
    #|  {"state":"CHANGES_REQUESTED","user":{"login":"reviewer"},"submitted_at":"2026-01-01T00:00:00Z"}
    #|]
  match merge_pr_review_gate_block_message(4, reviews) {
    Ok(None) => ()
    Ok(Some(msg)) =>
      fail("expected older changes requested to be ignored: " + msg)
    Err(e) => fail(e.message())
  }
}

///|
/// When both `submitted_at` values fail to parse, fall back to array order
/// (last-in-response wins) so the gate stays operational against format
/// regressions instead of silently preferring the first entry.
test "merge_pr_review_gate_block_message falls back to array order on unparseable submitted_at" {
  let reviews =
    #|[
    #|  {"state":"APPROVED","user":{"login":"reviewer"},"submitted_at":"not-a-date"},
    #|  {"state":"CHANGES_REQUESTED","user":{"login":"reviewer"},"submitted_at":"also-not-a-date"}
    #|]
  match merge_pr_review_gate_block_message(4, reviews) {
    Ok(Some(_)) => ()
    Ok(None) =>
      fail("expected later CHANGES_REQUESTED to win via array-order fallback")
    Err(e) => fail(e.message())
  }
}

///|
async fn mock_preflight_capture_approved_no_graphql(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    fail("force=true should skip review thread GraphQL fetch")
  }
  (0, "")
}

///|
async fn mock_preflight_capture_changes_requested_reviews(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"CHANGES_REQUESTED\"}]")
  }
  (0, "")
}

///|
async fn mock_preflight_capture_empty_reviews(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[]")
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight review gate force true still blocks changes requested" {
  let got = interpret_merge_pr_preflight(
    true,
    42,
    None,
    "/tmp",
    "main.tl",
    mock_preflight_capture_changes_requested_reviews,
    None,
    override_check=fn(_project_dir, _caller_id) { true },
  )
  match got {
    Err(e) => assert_true(e.message().contains("requesting changes"))
    Ok(_) => fail("expected Err: force=true must not bypass GitHub review gate")
  }
}

///|
async test "interpret_merge_pr_preflight review gate passes without approval" {
  let got = interpret_merge_pr_preflight(
    false,
    42,
    None,
    "/tmp",
    "main.tl",
    mock_preflight_capture_empty_reviews,
    None,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
}

///|
async test "interpret_merge_pr_preflight force bypass skips poller and thread checks when override ON" {
  let got = interpret_merge_pr_preflight(
    true,
    1,
    None,
    "/tmp",
    "main.tl",
    mock_preflight_capture_approved_no_graphql,
    None,
    override_check=fn(_project_dir, _caller_id) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
}

///|
async test "interpret_merge_pr_preflight force rejected when tl-parent-override off" {
  let got = interpret_merge_pr_preflight(
    true,
    1,
    None,
    "/tmp",
    "main.tl",
    mock_preflight_capture_approved_no_graphql,
    None,
    override_check=fn(_project_dir, _caller_id) { false },
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("force=true"))
      assert_true(msg.contains("choir tl-parent-override on"))
      assert_true(msg.contains("main.tl"))
    }
    Ok(_) => fail("expected Err: force=true without override must be rejected")
  }
}

///|
async test "interpret_merge_pr_preflight force honored when tl-parent-override on (parity)" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    9,
    "main.leaf",
    "main.topic",
    "main",
    "https://github.com/o/r/pull/9",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let got = interpret_merge_pr_preflight(
    true,
    9,
    Some(ps),
    "/tmp",
    "main.tl",
    mock_preflight_capture_approved_no_graphql,
    None,
    override_check=fn(_project_dir, _caller_id) { true },
  )
  match got {
    Ok(_) => ()
    Err(e) =>
      fail(
        "expected Ok: force=true with override ON must bypass poller and thread checks, got " +
        e.message(),
      )
  }
}

///|
async fn mock_preflight_capture_no_unresolved_threads(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight ok when no poller block and no threads" {
  let project_dir = "/tmp/choir-mpf-ok-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr_preflight(
    false,
    7,
    None,
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    None,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight accepts required verify evidence" {
  let project_dir = "/tmp/choir-mpf-verify-evidence-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let worktree = merge_pr_test_write_verify_contract(project_dir, [
    "moon test --target native",
  ])
  let reg = merge_pr_test_registry(worktree)
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("exit: 0"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_ci_rollup: @poller.CiRollupStatus::Success,
  })
  let got = interpret_merge_pr_preflight(
    false,
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    Some(reg),
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected verify evidence to satisfy policy: " + e.message())
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight rejects stale verify evidence" {
  let project_dir = "/tmp/choir-mpf-stale-verify-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let worktree = merge_pr_test_write_verify_contract(project_dir, [
    "moon test --target native",
  ])
  let reg = merge_pr_test_registry(worktree)
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("cwd: /wt\nexit: 0\nhead: old-sha"),
      ),
    ),
  )
  let ps = @poller.PollerState::new()
  ps.tracked.set(7, {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    pr_number: 7,
    last_sha: "new-sha",
    last_ci_rollup: @poller.CiRollupStatus::Success,
  })
  let got = interpret_merge_pr_preflight(
    false,
    7,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    Some(reg),
  )
  match got {
    Err(e) => assert_true(e.message().contains("local verify not observed"))
    Ok(_) => fail("expected stale verify evidence to block")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async fn mock_preflight_capture_one_unresolved_thread(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    let body =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_abc","isResolved":false,"path":"src/x.mbt","comments":{"nodes":[{"body":"fix it"}]}}]}}}}}
    return (0, body)
  }
  (0, "")
}

///|
async test "interpret_merge_pr_preflight err when review threads unresolved" {
  let project_dir = "/tmp/choir-mpf-threads-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr_preflight(
    false,
    3,
    None,
    project_dir,
    "main.tl",
    mock_preflight_capture_one_unresolved_thread,
    None,
  )
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("PR #3"))
      assert_true(msg.contains("unresolved review thread"))
      assert_true(msg.contains("fix it"))
    }
    Ok(_) => fail("expected Err")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr_preflight err when poller ChangesRequested" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    9,
    "main.leaf",
    "main.topic",
    "main",
    "https://github.com/o/r/pull/9",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let project_dir = "/tmp/choir-mpf-cr-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr_preflight(
    false,
    9,
    Some(ps),
    project_dir,
    "main.tl",
    mock_preflight_capture_no_unresolved_threads,
    None,
  )
  match got {
    Err(e) => assert_true(e.message().contains("ChangesRequested"))
    Ok(_) => fail("expected Err from poller gate")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_preflight_block_message prefers ChangesRequested over thread gate" {
  let t = merge_pr_test_tracked(
    @poller.ReviewState::ChangesRequested,
    "main.leaf",
  )
  match merge_pr_preflight_block_message(9, Some(t), 2, "threads", None) {
    Some(msg) => {
      assert_true(msg.contains("ChangesRequested"))
      assert_false(msg.contains("unresolved review thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message blocks on unresolved threads" {
  match merge_pr_preflight_block_message(3, None, 1, "body", None) {
    Some(msg) => {
      assert_true(msg.contains("PR #3"))
      assert_true(msg.contains("1 unresolved review thread"))
      assert_true(msg.contains("body"))
      assert_true(msg.contains("resolve_review_thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message gh thread fetch failed marker" {
  match
    merge_pr_preflight_block_message(
      5,
      None,
      1,
      review_thread_fetch_failed_marker,
      None,
    ) {
    Some(msg) => {
      assert_true(msg.contains("merge blocked: gh unavailable"))
      assert_true(msg.contains("could not fetch review thread state"))
      assert_true(msg.contains("manually advance lifecycle"))
      assert_false(msg.contains("resolve_review_thread"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message allows Approved with no threads" {
  let t = merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf")
  @debug.assert_eq(
    merge_pr_preflight_block_message(9, Some(t), 0, "", None),
    None,
  )
}

///|
test "merge_pr_preflight_block_message policy Blocked" {
  let policy_decision = Some(
    @policy.MergeDecision::Blocked(reason="insufficient evidence"),
  )
  match merge_pr_preflight_block_message(9, None, 0, "", policy_decision) {
    Some(msg) => {
      assert_true(msg.contains("policy blocked: insufficient evidence"))
      assert_true(msg.contains("pass force=true to override"))
    }
    None => fail("expected block")
  }
}

///|
test "merge_pr_preflight_block_message policy Wait" {
  let policy_decision = Some(@policy.MergeDecision::Wait(reason="pending CI"))
  match merge_pr_preflight_block_message(9, None, 0, "", policy_decision) {
    Some(msg) => {
      assert_true(msg.contains("policy wait: pending CI"))
      assert_true(msg.contains("pass force=true to override"))
    }
    None => fail("expected wait")
  }
}

///|
test "merge_pr_preflight_block_message policy NeedsHuman" {
  let policy_decision = Some(
    @policy.MergeDecision::NeedsHuman(reason="manual check"),
  )
  match merge_pr_preflight_block_message(9, None, 0, "", policy_decision) {
    Some(msg) => {
      assert_true(msg.contains("policy requires human check: manual check"))
      assert_true(msg.contains("pass force=true to override"))
    }
    None => fail("expected needs human")
  }
}

///|
test "format_tl_pr_recheck_summary ready snapshot when approved success zero threads" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("no tracked blockers"))
  assert_true(s.contains("Does not merge"))
  assert_true(s.contains("success"))
  assert_true(s.contains("GitHub Copilot issue comment (REST): not seen"))
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
}

///|
test "format_tl_pr_recheck_summary lists blockers for changes requested" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::ChangesRequested, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("GitHub review requests changes"))
  assert_false(s.contains("no tracked blockers"))
  assert_true(s.contains("Advisory evaluation verdict: blocked"))
  assert_true(s.contains("Merge policy decision: blocked"))
}

///|
test "format_tl_pr_recheck_summary does not claim ready when thread count not fetched" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", None)
  assert_true(s.contains("not fetched"))
  assert_false(s.contains("no tracked blockers"))
  assert_true(s.contains("Advisory evaluation verdict: needs_human"))
  assert_true(s.contains("Merge policy decision: needs_human"))
}

///|
test "format_tl_pr_recheck_summary notes Copilot issue comment when seen on merge-ready snapshot" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
    copilot_issue_comment_seen: true,
  }
  let s = format_tl_pr_recheck_summary(t, "/repo", Some(0))
  assert_true(s.contains("GitHub Copilot issue comment (REST): seen"))
  assert_true(s.contains("Copilot issue comment observed"))
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
}

///|
test "format_tl_pr_recheck_summary policy needs human when required verify is missing" {
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
  }
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
  let s = format_tl_pr_recheck_summary(
    t,
    "/repo",
    Some(0),
    task_contract=Some(contract),
  )
  assert_true(s.contains("Advisory evaluation verdict: needs_human"))
  assert_true(s.contains("Merge policy decision: needs_human"))
  assert_true(s.contains("local verify not observed"))
}

///|
test "format_tl_pr_recheck_summary reads verify evidence from ledger" {
  let project_dir = "/tmp/choir-recheck-verify-evidence-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let t : @poller.TrackedPR = {
    ..merge_pr_test_tracked(@poller.ReviewState::Approved, "main.leaf"),
    last_ci_rollup: @poller.CiRollupStatus::Success,
  }
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
  ignore(
    @evidence.append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      1L,
      @evidence.EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("exit: 0"),
      ),
    ),
  )
  let s = format_tl_pr_recheck_summary(
    t,
    project_dir,
    Some(0),
    task_contract=Some(contract),
  )
  assert_true(s.contains("Advisory evaluation verdict: ready"))
  assert_true(s.contains("Merge policy decision: merge_now"))
  assert_true(s.contains("local verify passed"))
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_merge_failure_message classifies conflict output" {
  assert_eq(
    merge_pr_merge_failure_message(7, "Merge conflict: foo"),
    "merge conflict on PR #7: Merge conflict: foo",
  )
}

///|
test "merge_pr_merge_failure_message classifies not mergeable" {
  assert_eq(
    merge_pr_merge_failure_message(2, "NOT MERGEABLE because"),
    "merge conflict on PR #2: NOT MERGEABLE because",
  )
}

///|
test "merge_pr_merge_failure_message uses generic when non-empty" {
  assert_eq(
    merge_pr_merge_failure_message(4, "permission denied"),
    "merge failed for PR #4: permission denied",
  )
}

///|
test "merge_pr_merge_failure_message empty stderr" {
  assert_eq(merge_pr_merge_failure_message(5, ""), "merge failed for PR #5")
}

///|
test "merge_pr_pr_merged_event_url_slug uses extract_slug from branch" {
  assert_eq(
    merge_pr_pr_merged_event_url_slug(1, Some("main.my-slug")),
    "my-slug",
  )
}

///|
test "merge_pr_pr_merged_event_url_slug fallback without branch" {
  assert_eq(merge_pr_pr_merged_event_url_slug(42, None), "PR-42")
}

///|
test "merge_pr_post_success_plan uses tracked branch slug when poller available" {
  let plan = merge_pr_post_success_plan(5, true, Some("main.leaf-slug"))
  assert_eq(plan.poller_untrack_and_write_state, true)
  assert_eq(plan.tl_event, @phase.TLEvent::PRMerged(number=5, url="leaf-slug"))
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("merged")))
    }
    _ => fail("expected OK merged response")
  }
}

///|
test "merge_pr_post_success_plan untrack intent when poller on but PR not tracked" {
  let plan = merge_pr_post_success_plan(9, true, None)
  assert_eq(plan.poller_untrack_and_write_state, true)
  assert_eq(plan.tl_event, @phase.TLEvent::PRMerged(number=9, url="PR-9"))
}

///|
test "merge_pr_post_success_plan ignores branch when poller unavailable" {
  let plan = merge_pr_post_success_plan(3, false, Some("main.ignored"))
  assert_eq(plan.poller_untrack_and_write_state, false)
  assert_eq(plan.tl_event, @phase.TLEvent::PRMerged(number=3, url="PR-3"))
}

///|
test "merge_pr_mutex_name prefixes branch" {
  assert_eq(merge_pr_mutex_name("main"), "branch:main")
}

///|
test "merge_pr_host_step_sequence is gh merge then git fetch" {
  let steps = merge_pr_host_step_sequence()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], MergePrHostStep::GhPrMerge)
  assert_eq(steps[1], MergePrHostStep::GitFetch)
}

///|
test "merge_pr_serialization_busy_message is stable" {
  assert_eq(
    merge_pr_serialization_busy_message(),
    "merge serialization lock held by another agent, retry shortly",
  )
}

///|
test "merge_pr_serialization_busy_message_with_position annotates only for >= 2" {
  let base = merge_pr_serialization_busy_message()
  assert_eq(merge_pr_serialization_busy_message_with_position(0), base)
  assert_eq(merge_pr_serialization_busy_message_with_position(1), base)
  assert_eq(
    merge_pr_serialization_busy_message_with_position(3),
    base + " (position 3 in queue)",
  )
}

///|
async fn mock_merge_host_runner_ok(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn mock_merge_host_runner_gh_fails(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for i = 0; i < cmds.length(); i = i + 1 {
    statuses.push(if i == 0 { 1 } else { 0 })
  }
  statuses
}

///|
async fn mock_merge_host_capture_for_merge(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["remote", "get-url", "origin"] {
    return (0, "https://github.com/o/r.git\n")
  }
  if cmd.program == "gh" &&
    cmd.args.length() >= 2 &&
    cmd.args[0] == "api" &&
    cmd.args[1].has_suffix("/reviews") {
    return (0, "[{\"state\":\"APPROVED\"}]")
  }
  if cmd.program == "gh" && cmd.args.length() >= 2 && cmd.args[0] == "pr" {
    return (1, "permission denied\n")
  }
  (0, "")
}

///|
async test "interpret_merge_pr_merge_host ok without mutex" {
  let got = interpret_merge_pr_merge_host(
    "main",
    42,
    "main.tl",
    None,
    0L,
    mock_merge_host_runner_ok,
    mock_capture_empty,
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected Ok got " + e.message())
  }
}

///|
async test "interpret_merge_pr_merge_host maps merge failure via merge_pr_command capture" {
  let got = interpret_merge_pr_merge_host(
    "main",
    4,
    "main.tl",
    None,
    0L,
    mock_merge_host_runner_gh_fails,
    mock_merge_host_capture_for_merge,
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
}

///|
async test "interpret_merge_pr_merge_host returns busy when mutex held" {
  let reg = @registry.MutexRegistry::new()
  let name = merge_pr_mutex_name("main")
  let (holder_ok, _) = reg.acquire(
    name, "other-agent", merge_pr_mutex_ttl_sec, 50L,
  )
  assert_true(holder_ok)
  let got = interpret_merge_pr_merge_host(
    "main",
    1,
    "waiter",
    Some(reg),
    50L,
    mock_merge_host_runner_ok,
    mock_capture_empty,
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::validation_error(
          merge_pr_serialization_busy_message(),
        ).message(),
      )
    Ok(_) => fail("expected busy Err")
  }
}

///|
async test "interpret_merge_pr_merge_host holds mutex across failure capture" {
  let reg = @registry.MutexRegistry::new()
  let name = merge_pr_mutex_name("main")
  let events : Array[String] = []
  let capture_count : Ref[Int] = @ref.new(0)
  let failure_capture_saw_holder : Ref[Bool] = @ref.new(false)
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let (holder, _) = reg.status(name)
    @debug.assert_eq(holder, Some("main.tl"))
    events.push("mutex_acquire")
    events.push("merge")
    let statuses = []
    for i = 0; i < cmds.length(); i = i + 1 {
      statuses.push(if i == 0 { 1 } else { 0 })
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" && cmd.args == ["pr", "merge", "4", "--merge"] {
      capture_count.val += 1
      let (holder, _) = reg.status(name)
      @debug.assert_eq(holder, Some("main.tl"))
      if capture_count.val == 1 {
        events.push("strict_failure_capture")
      } else if capture_count.val == 2 {
        failure_capture_saw_holder.val = holder == Some("main.tl")
        events.push("failure_capture")
      } else {
        fail("unexpected extra merge capture")
      }
      return (1, "permission denied\n")
    }
    (0, "")
  }
  let got = interpret_merge_pr_merge_host(
    "main",
    4,
    "main.tl",
    Some(reg),
    50L,
    runner,
    capture,
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    Ok(_) => fail("expected Err")
  }
  let (holder, queue) = reg.status(name)
  @debug.assert_eq(holder, None)
  assert_eq(queue.length(), 0)
  events.push("mutex_release")
  assert_eq(capture_count.val, 2)
  assert_true(failure_capture_saw_holder.val)
  assert_eq(events.length(), 5)
  assert_eq(events[0], "mutex_acquire")
  assert_eq(events[1], "merge")
  assert_eq(events[2], "strict_failure_capture")
  assert_eq(events[3], "failure_capture")
  assert_eq(events[4], "mutex_release")
}

///|
async test "interpret_merge_pr_merge_host returns busy for overlapping failure-capture merge" {
  let reg = @registry.MutexRegistry::new()
  let name = merge_pr_mutex_name("main")
  let capture_count : Ref[Int] = @ref.new(0)
  let second_runner_calls : Ref[Int] = @ref.new(0)
  let second_message : Ref[String] = @ref.new("")
  let second_runner = async fn(
    _cmds : Array[@workspace.Command],
  ) -> Array[Int] {
    @async.sleep(0)
    second_runner_calls.val += 1
    fail(
      "second merge should not run while the first merge is inspecting failure",
    )
    []
  }
  let second_capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (0, "")
  }
  let first_runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses = []
    for i = 0; i < cmds.length(); i = i + 1 {
      statuses.push(if i == 0 { 1 } else { 0 })
    }
    statuses
  }
  let first_capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" && cmd.args == ["pr", "merge", "4", "--merge"] {
      capture_count.val += 1
      if capture_count.val == 2 {
        let second = interpret_merge_pr_merge_host(
          "main",
          5,
          "second",
          Some(reg),
          50L,
          second_runner,
          second_capture,
        )
        match second {
          Err(e) => second_message.val = e.message()
          Ok(_) => fail("expected second merge to be busy")
        }
      }
      return (1, "permission denied\n")
    }
    (0, "")
  }
  let first = interpret_merge_pr_merge_host(
    "main",
    4,
    "first",
    Some(reg),
    50L,
    first_runner,
    first_capture,
  )
  match first {
    Err(e) =>
      assert_eq(
        e.message(),
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    Ok(_) => fail("expected first merge Err")
  }
  assert_eq(
    second_message.val,
    @types.ChoirError::validation_error(
      merge_pr_serialization_busy_message_with_position(1),
    ).message(),
  )
  assert_eq(second_runner_calls.val, 0)
  let (holder, queue) = reg.status(name)
  @debug.assert_eq(holder, None)
  assert_eq(queue.length(), 0)
}

///|
async fn mock_runner_merge_pr_must_not_run(
  _cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  fail("merge host should not run after preflight Err")
  []
}

///|
async test "interpret_merge_pr returns preflight err without merge host" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    9,
    "main.leaf",
    "main.topic",
    "main",
    "https://github.com/o/r/pull/9",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let args : MergePrArgs = {
    pr_number: 9,
    parent_branch: "main",
    caller_id: "main.tl",
    force: false,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let project_dir = "/tmp/choir-mpr-preflight-" + @sys.get_pid().to_string()
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    None,
    mock_runner_merge_pr_must_not_run,
    mock_preflight_capture_no_unresolved_threads,
    @sys.append_file_sync,
    @sys.path_entry_exists,
  )
  match got {
    @types.Response::Err(msg) => assert_true(msg.contains("ChangesRequested"))
    _ => fail("expected preflight Err")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr returns merge host err after force preflight" {
  let args : MergePrArgs = {
    pr_number: 4,
    parent_branch: "main",
    caller_id: "main.tl",
    force: true,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let project_dir = "/tmp/choir-mpr-host-err-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  assert_true(
    @sys.write_file_atomic(
      project_dir + "/.choir/kv/tl-parent-override--main.tl",
      "1\n",
    ),
  )
  let got = interpret_merge_pr(
    args,
    project_dir,
    None,
    None,
    None,
    mock_merge_host_runner_gh_fails,
    mock_merge_host_capture_for_merge,
    @sys.append_file_sync,
    @sys.path_entry_exists,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(
        msg,
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(4, "permission denied"),
        ).message(),
      )
    _ => fail("expected merge host Err")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr ok response matches merged envelope" {
  let project_dir = "/tmp/choir-mpr-interpret-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  assert_true(
    @sys.write_file_atomic(
      project_dir + "/.choir/kv/tl-parent-override--main.tl",
      "1\n",
    ),
  )
  let args : MergePrArgs = {
    pr_number: 77,
    parent_branch: "main",
    caller_id: "main.tl",
    force: true,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    None,
    None,
    None,
    mock_merge_host_runner_ok,
    mock_preflight_capture_approved_no_graphql,
    @sys.append_file_sync,
    @sys.path_entry_exists,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("merged")))
    }
    _ => fail("expected ok merged")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_closes_issue_ids_from_body matches literal closes regex" {
  let ids = merge_pr_closes_issue_ids_from_body(
    "prefix Closes choir-a.1\ncloses\tchoir-b-2\nCLOSES choir-nope\nCloses not-choir\n",
  )
  assert_eq(ids.length(), 2)
  assert_true(ids.contains("choir-a.1"))
  assert_true(ids.contains("choir-b-2"))
}

///|
test "merge_pr_closes_issue_ids_from_body captures all ids on a comma- or space-separated Closes line" {
  // PR descriptions often list multiple beads after a single `Closes` keyword.
  // The previous parser stopped after the first id, leaving the rest open.
  let ids = merge_pr_closes_issue_ids_from_body(
    "Closes choir-aaa, choir-bbb,choir-ccc choir-ddd\nThen prose continues choir-not-counted\n",
  )
  assert_eq(ids.length(), 4)
  assert_true(ids.contains("choir-aaa"))
  assert_true(ids.contains("choir-bbb"))
  assert_true(ids.contains("choir-ccc"))
  assert_true(ids.contains("choir-ddd"))
  assert_false(ids.contains("choir-not-counted"))
}

///|
test "merge_pr_beads_show_status_and_open_children detects epic children" {
  let show =
    #|[{"id":"choir-parent","status":"open","epic_closeable":false,"dependents":[{"id":"choir-child","status":"open"}]}]
  match merge_pr_beads_show_status_and_open_children(show) {
    Ok((status, has_open_children)) => {
      assert_eq(status, "open")
      assert_true(has_open_children)
    }
    Err(e) => fail(e.message())
  }
}

///|
async test "interpret_merge_pr feature main closes wave and body beads then deletes feature branch" {
  let project_dir = "/tmp/choir-mpr-feature-beads-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  merge_pr_test_enable_force_override(project_dir)
  let feature_branch = "feature/demo"
  let leaf_a = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    Some("choir-a"),
  )
  let leaf_b = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-b",
    Some("choir-b"),
  )
  match
    save_wave_index(
      project_dir,
      WaveIndex::new("wv-feature", feature_branch, 1L, [
        feature_branch + ".leaf-a",
        feature_branch + ".leaf-b",
      ]),
    ) {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf_a),
    ("leaf-b", leaf_b),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "main.tl",
    feature_branch,
    "main",
    "https://github.com/o/r/pull/77",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let closed : Array[String] = []
  let audited : Array[String] = []
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "timeout" &&
      cmd.args == ["30s", "gh", "pr", "view", "77", "--json", "body"] {
      return (0, "{\"body\":\"Closes choir-body\\ncloses choir-a\\n\"}")
    }
    if cmd.program == "bd" &&
      cmd.args.length() == 4 &&
      cmd.args[0] == "--readonly" &&
      cmd.args[1] == "show" {
      let id = cmd.args[2]
      return (
        0,
        "[{\"id\":\"" + id + "\",\"title\":\"t\",\"status\":\"open\"}]",
      )
    }
    if cmd.program == "bd" && cmd.args.length() == 4 && cmd.args[0] == "close" {
      closed.push(cmd.args[1])
      assert_eq(cmd.args[2], "--reason")
      assert_eq(cmd.args[3], "completed via PR #77")
      return (0, "")
    }
    if cmd.program == "bd" &&
      cmd.args.length() >= 10 &&
      cmd.args[0] == "audit" &&
      cmd.args[1] == "record" {
      assert_true(cmd.args.contains("--tool-name"))
      assert_true(cmd.args.contains("merge_pr"))
      assert_true(cmd.args.contains("--response"))
      assert_true(cmd.args.contains("closed via PR #77"))
      assert_true(cmd.args.contains("--issue-id"))
      let mut issue_index = -1
      for i = 0; i < cmd.args.length(); i = i + 1 {
        if cmd.args[i] == "--issue-id" {
          issue_index = i
        }
      }
      assert_true(issue_index >= 0 && issue_index + 1 < cmd.args.length())
      audited.push(cmd.args[issue_index + 1])
      return (0, "")
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let logs : Array[String] = []
  let append_file = fn(_path : String, content : String) -> Bool {
    logs.push(content)
    true
  }
  let args : MergePrArgs = {
    pr_number: 77,
    parent_branch: "main",
    caller_id: "main.tl",
    force: true,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    append_file,
    fn(_path) { false },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_eq(closed.length(), 3)
  assert_true(closed.contains("choir-a"))
  assert_true(closed.contains("choir-b"))
  assert_true(closed.contains("choir-body"))
  assert_eq(audited.length(), 3)
  assert_true(audited.contains("choir-a"))
  assert_true(audited.contains("choir-b"))
  assert_true(audited.contains("choir-body"))
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["checkout", "main"] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", feature_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  assert_true(logs.length() > 0)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr feature main with no issue ids does not call bd close" {
  let project_dir = "/tmp/choir-mpr-feature-no-beads-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  merge_pr_test_enable_force_override(project_dir)
  let feature_branch = "feature/no-beads"
  let leaf = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    None,
  )
  match
    save_wave_index(
      project_dir,
      WaveIndex::new("wv-feature", feature_branch, 1L, [
        feature_branch + ".leaf-a",
      ]),
    ) {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    78,
    "main.tl",
    feature_branch,
    "main",
    "https://github.com/o/r/pull/78",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let closed : Array[String] = []
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "gh" && cmd.args == ["pr", "view", "78", "--json", "body"] {
      return (0, "{\"body\":\"No closing lines here.\"}")
    }
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "close" {
      closed.push(cmd.args[1])
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let args : MergePrArgs = {
    pr_number: 78,
    parent_branch: "main",
    caller_id: "main.tl",
    force: true,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, _content) { true },
    fn(_path) { false },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_eq(closed.length(), 0)
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", feature_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf merge removes worktree and deletes local branch" {
  let project_dir = "/tmp/choir-mpr-leaf-cleanup-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  merge_pr_test_enable_force_override(project_dir)
  let feature_branch = "feature/demo"
  let leaf_branch = feature_branch + ".leaf-a"
  let leaf = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    Some("choir-a"),
  )
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    79,
    leaf_branch,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/79",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "close" {
      fail("leaf PR merge must not close beads")
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let args : MergePrArgs = {
    pr_number: 79,
    parent_branch: feature_branch,
    caller_id: "main.tl",
    force: true,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, _content) { true },
    fn(path) { path == leaf },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["worktree", "remove", "--force", leaf]
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", leaf_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "dispatch merge_pr routes injected append_file and path_exists" {
  let project_dir = "/tmp/choir-mpr-dispatch-inject-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  merge_pr_test_enable_force_override(project_dir)
  let feature_branch = "feature/dispatch-cleanup"
  let leaf_branch = feature_branch + ".leaf-a"
  let leaf = merge_pr_test_write_beads_contract(
    project_dir,
    feature_branch,
    "leaf-a",
    Some("choir-a"),
  )
  let reg = merge_pr_test_registry_for_feature(project_dir, feature_branch, [
    ("leaf-a", leaf),
  ])
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    81,
    leaf_branch,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/81",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let logs : Array[String] = []
  let path_checks : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    (0, "")
  }
  let resp = dispatch(
    ToolRequest::MergePr({
      pr_number: 81,
      parent_branch: feature_branch,
      caller_id: "main.tl",
      force: true,
      review_mode: Some(@types.ReviewMode::SinglePass),
    }),
    project_dir~,
    poller_state=Some(ps),
    registry=Some(reg),
    runner=mock_merge_host_runner_ok,
    capture~,
    append_file=fn(_path, content) {
      logs.push(content)
      true
    },
    path_exists=fn(path) {
      path_checks.push(path)
      path == leaf
    },
  )
  match resp {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected dispatch merge success: " + msg)
  }
  assert_true(path_checks.contains(leaf))
  assert_true(logs.length() > 0)
  assert_true(logs.iter().any(fn(line) { line.contains("merge_pr cleanup") }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf merge skips missing worktree and still deletes branch" {
  let project_dir = "/tmp/choir-mpr-leaf-no-worktree-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  merge_pr_test_enable_force_override(project_dir)
  let feature_branch = "feature/no-worktree"
  let leaf_branch = feature_branch + ".leaf-a"
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    80,
    leaf_branch,
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/80",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let args : MergePrArgs = {
    pr_number: 80,
    parent_branch: feature_branch,
    caller_id: "main.tl",
    force: true,
    review_mode: Some(@types.ReviewMode::SinglePass),
  }
  let got = interpret_merge_pr(
    args,
    project_dir,
    Some(ps),
    None,
    None,
    runner,
    capture,
    fn(_path, _content) { true },
    fn(_path) { false },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_false(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "worktree" &&
      cmd.args[1] == "remove"
    }),
  )
  assert_true(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args == ["branch", "-D", leaf_branch] &&
      cmd.workdir == Some(project_dir)
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_merge_pr leaf cleanup refuses supervisor tracked agent" {
  let project_dir = "/tmp/choir-mpr-supervisor-cleanup-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  merge_pr_test_enable_force_override(project_dir)
  let feature_branch = "feature/supervisor-cleanup"
  let leaf_branch = feature_branch + ".root"
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("root"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: feature_branch,
      terminal_target: Some({
        kind: @types.TargetKind::ZellijTab,
        session: "s",
        name: "TL",
      }),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    82,
    "root",
    leaf_branch,
    feature_branch,
    "https://github.com/o/r/pull/82",
    0L,
    @poller.ReviewState::Approved,
    "",
    "",
    @poller.CiRollupStatus::Success,
    true,
  )
  let ran : Array[@workspace.Command] = []
  let logs : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    merge_pr_test_runner_record_ok(cmds, ran)
  }
  let got = interpret_merge_pr(
    {
      pr_number: 82,
      parent_branch: feature_branch,
      caller_id: "main.tl",
      force: true,
      review_mode: Some(@types.ReviewMode::SinglePass),
    },
    project_dir,
    Some(ps),
    None,
    Some(reg),
    runner,
    capture,
    fn(_path, content) {
      logs.push(content)
      true
    },
    fn(path) { path == project_dir },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail(msg)
  }
  assert_false(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "worktree" &&
      cmd.args[1] == "remove"
    }),
  )
  assert_false(
    ran
    .iter()
    .any(fn(cmd) {
      cmd.program == "git" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "branch" &&
      cmd.args[1] == "-D"
    }),
  )
  assert_true(
    logs.iter().any(fn(line) { line.contains("outcome=supervisor_agent") }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
test "merge_pr_tracked_branch_for_post_success is None without poller" {
  @debug.assert_eq(merge_pr_tracked_branch_for_post_success(None, 1), None)
}

///|
test "merge_pr_tracked_branch_for_post_success is None when PR not tracked" {
  let ps = @poller.PollerState::new()
  @debug.assert_eq(merge_pr_tracked_branch_for_post_success(Some(ps), 7), None)
}

///|
test "merge_pr_tracked_branch_for_post_success returns branch when tracked" {
  let ps = @poller.PollerState::new()
  ps.track(4, "main.leaf", "main.topic", "main", "https://ex/4", 0L)
  @debug.assert_eq(
    merge_pr_tracked_branch_for_post_success(Some(ps), 4),
    Some("main.topic"),
  )
}

///|
test "resolve_review_thread_gh_command matches graphql argv and workdir" {
  let cmd = resolve_review_thread_gh_command("/repo/root", "PRRT_kwDOabc")
  assert_eq(cmd.program, "gh")
  @debug.assert_eq(cmd.workdir, Some("/repo/root"))
  assert_eq(cmd.args, [
    "api",
    "graphql",
    "-f",
    "query=" + resolve_review_thread_graphql_mutation(),
    "-F",
    "threadId=PRRT_kwDOabc",
  ])
}

///|
test "interpret_resolve_review_thread_result maps non-zero exit with stderr" {
  let r = interpret_resolve_review_thread_result(1, "permission denied\n", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: permission denied")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result maps non-zero exit without output" {
  let r = interpret_resolve_review_thread_result(2, "   \n", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed (exit 2)")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result empty body on success exit" {
  let r = interpret_resolve_review_thread_result(0, "", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: empty response from gh")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result invalid json" {
  let r = interpret_resolve_review_thread_result(0, "not json", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread: invalid JSON in gh response")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result unexpected top-level shape" {
  let r = interpret_resolve_review_thread_result(0, "[]", "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread: unexpected response shape")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result graphql errors array first message" {
  let body = "{\"errors\":[{\"message\":\"Thread not found\"}],\"data\":null}"
  let r = interpret_resolve_review_thread_result(0, body, "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: Thread not found")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result graphql error without message field" {
  let body = "{\"errors\":[{}]}"
  let r = interpret_resolve_review_thread_result(0, body, "T1")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(msg, "resolve_review_thread failed: GraphQL error")
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result not resolved path" {
  let body = "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":false}}}}"
  let r = interpret_resolve_review_thread_result(0, body, "PRRT_x")
  match r {
    @types.Response::Err(msg) =>
      assert_eq(
        msg, "resolve_review_thread: thread was not marked resolved (check permissions)",
      )
    _ => fail("expected Err")
  }
}

///|
test "interpret_resolve_review_thread_result success envelope" {
  let body = "{\"data\":{\"resolveReviewThread\":{\"thread\":{\"isResolved\":true}}}}"
  let r = interpret_resolve_review_thread_result(0, body, "PRRT_ok")
  match r {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("ok")))
      @debug.assert_eq(map.get("thread_id"), Some(String::to_json("PRRT_ok")))
      @debug.assert_eq(map.get("resolved"), Some(Bool::to_json(true)))
    }
    _ => fail("expected Ok")
  }
}

///|
