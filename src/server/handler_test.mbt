///|
test "poll_events_delivery_summary escapes newlines and truncates long events" {
  let tail = "b".repeat(220)
  let ev = @poller.PollEvent::ReviewReceived(3, "alpha\nbeta\n" + tail)
  let s = poll_events_delivery_summary([ev])
  assert_false(s.contains("\n"))
  assert_true(s.contains("\\n"))
  assert_eq(s.length(), 203)
}

///|
test "merge_execution_mode_for_request distinguishes manual automerge and force" {
  let manual_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::new({ "pr_number": "5" }),
  }
  assert_eq(
    merge_execution_mode_for_request(manual_req),
    @evidence.MergeExecutionMode::Manual,
  )
  let automerge_args : Map[String, Json] = {
    "pr_number": Int::to_json(5),
    "automerge": Bool::to_json(true),
  }
  let automerge_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(automerge_args),
  }
  assert_eq(
    merge_execution_mode_for_request(automerge_req),
    @evidence.MergeExecutionMode::ServerAutomerge,
  )
  let force_args : Map[String, Json] = {
    "pr_number": Int::to_json(5),
    "automerge": Bool::to_json(true),
    "force": Bool::to_json(true),
  }
  let force_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::from_values(force_args),
  }
  assert_eq(
    merge_execution_mode_for_request(force_req),
    @evidence.MergeExecutionMode::ForceOverride,
  )
}

///|
test "should_fetch_unresolved_threads_for_pending_event widens for automerge" {
  assert_false(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::MergeReady(7),
      false,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::MergeReady(7),
      true,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::CILatestHeadRollupSucceeded(7),
      false,
    ),
  )
  assert_true(
    should_fetch_unresolved_threads_for_pending_event(
      @poller.PollEvent::FixesPushed(7),
      false,
    ),
  )
}

///|
test "poll_event_beads_note_and_state maps review and ci events" {
  match poll_event_beads_note_and_state(@poller.PollEvent::CIFailed(12)) {
    Some((note, dimension, value)) => {
      assert_true(note.contains("PR #12"))
      assert_eq(dimension, "ci")
      assert_eq(value, "failing")
    }
    None => fail("expected ci state")
  }
  match poll_event_beads_note_and_state(@poller.PollEvent::PRReady(13)) {
    Some((note, dimension, value)) => {
      assert_true(note.contains("review gate ready"))
      assert_eq(dimension, "review")
      assert_eq(value, "ready")
    }
    None => fail("expected review state")
  }
  match
    poll_event_beads_note_and_state(
      @poller.PollEvent::PRMerged({
        pr_number: 14,
        agent_id: "main.leaf",
        branch: "main.leaf",
        parent_branch: "main",
        pr_url: "https://example.test/pr/14",
        first_seen: 0L,
        consecutive_failures: 0,
        backoff_until: 0L,
        last_review_state: @poller.ReviewState::Approved,
        last_review_bodies: "",
        last_sha: "sha",
        notified_parent: false,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        last_timeout_at: 0L,
        copilot_issue_comment_seen: false,
        orphan_notified: false,
        orphan_reconciling: false,
        changes_requested_since: 0L,
        stall_notified: false,
        fixes_pushed_at: 0L,
      }),
    ) {
    Some((note, dimension, value)) => {
      assert_true(note.contains("merged externally"))
      assert_eq(dimension, "merge")
      assert_eq(value, "merged")
    }
    None => fail("expected merge state")
  }
}

///|
test "automerge_enabled_for_agent respects local override" {
  let global_true = { ..@types.Config::default(), automerge: true }
  assert_true(automerge_enabled_for_agent(global_true, None))
  assert_false(
    automerge_enabled_for_agent(
      global_true,
      Some({ ..@types.LocalConfig::default(), automerge: Some(false) }),
    ),
  )
  assert_true(
    automerge_enabled_for_agent(
      { ..@types.Config::default(), automerge: false },
      Some({ ..@types.LocalConfig::default(), automerge: Some(true) }),
    ),
  )
}

///|
test "review_mode_for_agent respects local override" {
  let global_iterative = {
    ..@types.Config::default(),
    review_mode: @types.ReviewMode::Iterative,
  }
  assert_eq(
    review_mode_for_agent(global_iterative, None),
    @types.ReviewMode::Iterative,
  )
  assert_eq(
    review_mode_for_agent(
      global_iterative,
      Some({
        ..@types.LocalConfig::default(),
        review_mode: Some(@types.ReviewMode::SinglePass),
      }),
    ),
    @types.ReviewMode::SinglePass,
  )
}

///|
async test "maybe_trigger_automerge_for_pending_event reuses merge_pr path" {
  let project_dir = "/tmp/choir-automerge-handler-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
  }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let child_id = "main.auto-leaf"
  let pr_number = 90
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/auto-leaf",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch: child_id,
    agent_type: @types.AgentType::MoonPilot,
    summary: @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: parent_id,
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[parent_child], wave=1),
      ),
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: child_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number, child_id, child_id, "main", "https://github.com/brickfrog/choir/pull/90",
    100L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
      })
    None => fail("expected tracked PR")
  }
  let tracked = match state.poller.get(pr_number) {
    Some(value) => value
    None => fail("expected tracked PR")
  }
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    (0, "")
  }
  let merged = maybe_trigger_automerge_for_pending_event(
    state,
    @poller.PollEvent::ReviewThreadsResolved(pr_number),
    tracked,
    Some(0),
    runner,
    capture~,
  )
  assert_true(merged)
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) =>
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
    None => fail("expected merged child lifecycle")
  }
}

///|
async test "maybe_trigger_automerge_for_pending_event fires on iterative fixes pushed when policy is merge_now" {
  let project_dir = "/tmp/choir-automerge-fixes-pushed-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
    review_mode: @types.ReviewMode::Iterative,
  }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let child_id = "main.auto-leaf"
  let pr_number = 91
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/auto-leaf",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch: child_id,
    agent_type: @types.AgentType::MoonPilot,
    summary: @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: parent_id,
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[parent_child], wave=1),
      ),
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: child_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number, child_id, child_id, "main", "https://github.com/brickfrog/choir/pull/91",
    100L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Commented,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        last_sha: "old-sha",
        copilot_issue_comment_seen: true,
      })
    None => fail("expected tracked PR")
  }
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      return (0, "[{\"state\":\"APPROVED\"}]")
    }
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    (0, "")
  }
  let blocked_tracked = match state.poller.get(pr_number) {
    Some(value) => value
    None => fail("expected tracked PR")
  }
  let blocked_decision = @poller.merge_policy_decision_for_tracked_pr(
    blocked_tracked,
    Some(1),
    review_mode=@types.ReviewMode::Iterative,
  )
  assert_eq(blocked_decision.label(), "blocked")
  let blocked = maybe_trigger_automerge_for_pending_event(
    state,
    @poller.PollEvent::MergeReady(pr_number),
    blocked_tracked,
    Some(1),
    runner,
    capture~,
    review_mode=@types.ReviewMode::Iterative,
  )
  assert_false(blocked)
  assert_false(merge_seen)
  state.poller.restore({ ..blocked_tracked, last_sha: "fix-sha" })
  let fixed_tracked = match state.poller.get(pr_number) {
    Some(value) => value
    None => fail("expected tracked PR")
  }
  let fixed_decision = @poller.merge_policy_decision_for_tracked_pr(
    fixed_tracked,
    Some(0),
    review_mode=@types.ReviewMode::Iterative,
  )
  assert_eq(fixed_decision.label(), "merge_now")
  let merged = maybe_trigger_automerge_for_pending_event(
    state,
    @poller.PollEvent::FixesPushed(pr_number),
    fixed_tracked,
    Some(0),
    runner,
    capture~,
    review_mode=@types.ReviewMode::Iterative,
  )
  assert_true(merged)
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) =>
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
    None => fail("expected merged child lifecycle")
  }
}

///|
fn blocked_gh_automerge_fixture(
  label : String,
  pr_number : Int,
  review_mode? : @types.ReviewMode = @types.ReviewMode::SinglePass,
) -> (ServerState, String, String) raise {
  let project_dir = "/tmp/choir-blocked-gh-automerge-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session,
    automerge: true,
    review_mode,
  }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl-" + label
  let child_id = "main.blocked-gh-" + label
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(
        @workspace.local_target_for(
          terminal_session,
          "TL",
          @types.IsolationMode::Worktree,
        ),
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/" + label,
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch: child_id,
    agent_type: @types.AgentType::Codex,
    summary: @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: parent_id,
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[parent_child], wave=1),
      ),
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: child_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://github.com/brickfrog/choir/pull/" + pr_number.to_string(),
    100L,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        last_sha: "sha-" + label,
        copilot_issue_comment_seen: true,
      })
    None => fail("expected tracked PR")
  }
  match state.poller.get(pr_number) {
    Some(_) => {
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::ReviewObserved(
            state=@evidence.EvidenceReviewState::Approved,
            body=Some("looks good"),
          ),
        ),
      )
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::CiObserved(
            status=@evidence.EvidenceCiStatus::Success,
            head_sha=Some("sha-" + label),
          ),
        ),
      )
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::ThreadsObserved(count=0),
        ),
      )
      ignore(
        @evidence.append_agent_evidence_event(
          @sys.append_file_sync,
          project_dir,
          child_id,
          @poller.now_sec(),
          @evidence.EvidenceEvent::CopilotIssueCommentObserved,
        ),
      )
    }
    None => fail("expected tracked PR")
  }
  (state, child_id, project_dir)
}

///|
fn blocked_gh_notify_request(
  caller_id : String,
  message : String,
) -> @types.Request {
  let args : Map[String, Json] = {
    "caller_id": caller_id.to_json(),
    "message": message.to_json(),
    "status": "failure".to_json(),
  }
  {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "notify_parent",
    args: @types.RequestArgs::from_values(args),
  }
}

///|
async test "blocked gh notify auto-merges when latest poller snapshot is clear" {
  let pr_number = 92
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "fires",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      let reviews_json =
        #|[{"state":"APPROVED","user":{"login":"copilot-pull-request-reviewer[bot]"},"submitted_at":"2026-05-10T00:00:00Z"}]
      return (0, reviews_json)
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] bounded GraphQL review-thread check timed out (exit 124). I cannot confirm zero unresolved review threads, so I am not reporting review-complete.",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "blocked gh notify honors single-pass review mode for fixes pushed" {
  let pr_number = 94
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "singlepass",
    pr_number,
    review_mode=@types.ReviewMode::SinglePass,
  )
  match state.poller.get(pr_number) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::ChangesRequested,
        last_sha: "fix-sha-singlepass",
        changes_requested_since: 0L,
        fixes_pushed_at: 999L,
      })
    None => fail("expected tracked PR")
  }
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1].has_suffix("/reviews") {
      let reviews_json =
        #|[{"state":"APPROVED","user":{"login":"copilot-pull-request-reviewer[bot]"},"submitted_at":"2026-05-10T00:00:00Z"}]
      return (0, reviews_json)
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] bounded GraphQL review-thread check timed out (exit 124). I cannot confirm zero unresolved review threads, so I am not reporting review-complete.",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_true(merge_seen)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "blocked gh notify does not auto-merge unrelated blocked reasons" {
  let pr_number = 93
  let (state, child_id, _) = blocked_gh_automerge_fixture(
    "nofire",
    pr_number,
    review_mode=@types.ReviewMode::Iterative,
  )
  let mut merge_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "gh" &&
        cmd.args.length() >= 3 &&
        cmd.args[0] == "pr" &&
        cmd.args[1] == "merge" {
        merge_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    let repo_view_json =
      #|{"owner":{"login":"brickfrog"},"name":"choir"}
    let review_threads_json =
      #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, repo_view_json)
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (0, review_threads_json)
    }
    (0, "")
  }
  let resp = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] compile error in src/server/handler_test.mbt",
    ),
    runner~,
    capture~,
  )
  assert_true(resp.is_ok())
  assert_false(merge_seen)
  match state.poller.get(pr_number) {
    Some(_) => ()
    None => fail("unrelated BLOCKED reason must not untrack or merge the PR")
  }
  // Adversarial reason: hits three of the four matcher gates but is missing
  // the `bounded` discipline keyword — it's a real CI/network failure, not a
  // bounded-gh-discipline timeout. Must not auto-merge.
  let resp_partial = state.handle_with_runner_and_capture(
    blocked_gh_notify_request(
      child_id, "[BLOCKED] github action runner timed out fetching a sibling review thread; see actions log",
    ),
    runner~,
    capture~,
  )
  assert_true(resp_partial.is_ok())
  assert_false(merge_seen)
  match state.poller.get(pr_number) {
    Some(_) => ()
    None =>
      fail(
        "BLOCKED reason missing the `bounded` discipline keyword must not auto-merge",
      )
  }
}

///|
fn kill_agent_reconciliation_fixture(
  label : String,
  pr_number : Int,
) -> (ServerState, String, String) {
  let project_dir = "/tmp/choir-kill-reconcile-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.parent"
  let child_id = "main.child"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => panic()
  }
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some(parent_id),
      workspace: project_dir + "/child",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.poller.track(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://example.test/pr/" + pr_number.to_string(),
    100L,
  )
  (state, parent_id, child_id)
}

///|
async test "kill_agent auto-closes tracked stale PR and untracks it" {
  let pr_number = 208
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "ok", pr_number,
  )
  let mut close_seen = false
  let mut stale_closed_delivered = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[STALE PR CLOSED]") &&
          text.contains("PR #" + pr_number.to_string()) {
          stale_closed_delivered = true
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      close_seen = true
      return (0, "closed")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({
      "agent_id": child_id,
      "caller_id": _parent_id,
    }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_true(close_seen)
  assert_true(stale_closed_delivered)
  assert_true(state.poller.get(pr_number) == None)
}

///|
async test "kill_agent close failure sends one explicit stale PR failure and suppresses generic orphan notification" {
  let pr_number = 209
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "fail", pr_number,
  )
  let mut stale_failed_delivered = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[STALE PR CLOSE FAILED]") &&
          text.contains("PR #" + pr_number.to_string()) {
          stale_failed_delivered = true
        }
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      return (1, "permission denied")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({
      "agent_id": child_id,
      "caller_id": _parent_id,
    }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_true(stale_failed_delivered)
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_true(tracked.orphan_notified)
      assert_false(tracked.orphan_reconciling)
      assert_eq(@poller.detect_orphaned_prs([(tracked, false)]).length(), 0)
    }
    None => fail("expected tracked PR to remain after close failure")
  }
}

///|
/// Regression: an empty caller_id used to reach
/// `reconcile_killed_agent_tracked_prs`, where the branch guard
/// short-circuited on an empty caller_branch and auto-closed every
/// tracked PR. The boundary in `handler.mbt` now rejects empty
/// caller_id before dispatching reconciliation.
async test "kill_agent with empty caller_id does not auto-close tracked PRs" {
  let pr_number = 312
  let (state, _parent_id, child_id) = kill_agent_reconciliation_fixture(
    "empty-caller", pr_number,
  )
  let mut close_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args.length() >= 3 &&
      cmd.args[0] == "pr" &&
      cmd.args[1] == "close" &&
      cmd.args[2] == pr_number.to_string() {
      close_seen = true
      return (0, "closed")
    }
    (0, "")
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "kill_agent",
    args: @types.RequestArgs::new({ "agent_id": child_id, "caller_id": "" }),
  }
  let resp = state.handle_with_runner_and_capture(req, runner~, capture~)
  assert_true(resp.is_ok())
  assert_false(close_seen)
  assert_true(state.poller.get(pr_number) is Some(_))
}

///|
fn parent_poll_test_ready_tracked(pr_number : Int) -> @poller.TrackedPR {
  {
    pr_number,
    agent_id: "main.dev-ready",
    branch: "work/ready",
    parent_branch: "main",
    pr_url: "https://ex/pr/" + pr_number.to_string(),
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
}

///|
fn assert_next_action_line(
  message : String,
  action : @poller.NextAction,
) -> Unit raise {
  assert_true(message.contains("next_action: " + action.to_wire_string()))
}

///|
test "parent_poll_event_message PR READY stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 7,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/7",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
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
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRReady(7),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("[PR READY]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("merge_mode: manual"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("[PR MERGED]"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on Copilot review"))
    }
    None => fail("expected PRReady message")
  }
}

///|
test "parent_poll_event_message PR READY shows merge gate when snapshot allows" {
  let tracked : @poller.TrackedPR = {
    pr_number: 70,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/70",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRReady(70),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected merge-gate-open PRReady message")
  }
}

///|
test "parent_poll_event_message MergeReady is actionable in manual mode" {
  let tracked : @poller.TrackedPR = {
    pr_number: 71,
    agent_id: "main.dev-manual",
    branch: "work/manual",
    parent_branch: "main",
    pr_url: "https://ex/pr/71",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(71),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Manual,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Success)
      assert_true(message.contains("[MERGE READY]"))
      assert_true(message.contains("merge_mode: manual"))
      assert_true(message.contains("Merge policy decision: merge_now"))
      assert_true(message.contains("merge_pr("))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected manual MergeReady message")
  }
}

///|
test "parent_poll_event_message MergeReady is informational in automerge mode" {
  let tracked : @poller.TrackedPR = {
    pr_number: 72,
    agent_id: "main.dev-auto",
    branch: "work/auto",
    parent_branch: "main",
    pr_url: "https://ex/pr/72",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(72),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Automerge,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("merge_mode: automerge"))
      assert_true(message.contains("server will attempt merge automatically"))
      assert_true(message.contains("AUTO-MERGE READY"))
      assert_false(message.contains("`merge_pr("))
    }
    None => fail("expected automerge MergeReady message")
  }
}

///|
test "parent PR-state notifications emit typed next_action" {
  let tracked = parent_poll_test_ready_tracked(73)
  let events = [
    @poller.PollEvent::PRReady(73),
    @poller.PollEvent::FixesPushed(73),
    @poller.PollEvent::CILatestHeadRollupSucceeded(73),
    @poller.PollEvent::CopilotIssueCommentSeen(73),
    @poller.PollEvent::MergeReady(73),
  ]
  for event in events {
    match
      parent_poll_event_message(
        tracked,
        "/repo",
        event,
        Some(0),
        merge_mode=@poller.MergeOperatorMode::Manual,
      ) {
      Some((message, _)) =>
        assert_next_action_line(message, @poller.NextAction::MergeNow)
      None => fail("expected parent PR-state notification")
    }
  }
  let merged = merged_pr_parent_message(
    73,
    "main.dev-ready",
    "work/ready",
    "main",
    "https://ex/pr/73",
    MergedDeliverySource::MergePrTool,
    merge_execution_mode=Some(@evidence.MergeExecutionMode::Manual),
  )
  assert_true(merged.contains("[PR MERGED]"))
  assert_next_action_line(merged, @poller.NextAction::Wait)
}

///|
test "parent PR-state notifications also emit next_action for ReviewTimeout / ReviewReceived / CIFailed / ReviewThreadsResolved" {
  let tracked = parent_poll_test_ready_tracked(75)
  let events = [
    @poller.PollEvent::ReviewTimeout(75),
    @poller.PollEvent::ReviewReceived(75, ""),
    @poller.PollEvent::ReviewReceived(75, "looks fine"),
    @poller.PollEvent::CIFailed(75),
    @poller.PollEvent::ReviewThreadsResolved(75),
  ]
  for event in events {
    match
      parent_poll_event_message(
        tracked,
        "/repo",
        event,
        Some(0),
        merge_mode=@poller.MergeOperatorMode::Manual,
      ) {
      Some((message, _)) => assert_true(message.contains("\nnext_action: "))
      None => fail("expected parent PR-state notification for event")
    }
  }
}

///|
test "parent_poll_event_message MergeReady never says auto ready when policy is blocked" {
  let tracked = parent_poll_test_ready_tracked(74)
  let modes = [
    @poller.MergeOperatorMode::Manual,
    @poller.MergeOperatorMode::Automerge,
    @poller.MergeOperatorMode::Mixed,
  ]
  for mode in modes {
    match
      parent_poll_event_message(
        tracked,
        "/repo",
        @poller.PollEvent::MergeReady(74),
        Some(2),
        merge_mode=mode,
      ) {
      Some((message, _)) => {
        assert_true(message.contains("[MERGE READY]"))
        assert_true(
          message.contains(
            "Merge policy decision: blocked (2 unresolved inline review thread(s))",
          ),
        )
        assert_next_action_line(message, @poller.NextAction::AddressThreads)
        assert_false(message.contains("AUTO-MERGE READY"))
        assert_false(message.contains("MERGE NOW:"))
      }
      None => fail("expected MergeReady message")
    }
  }
}

///|
test "parent_poll_event_message MergeReady on Mixed mode says MERGE READY (not MERGE NOW) and emits cross_check_merge_mode" {
  let tracked = parent_poll_test_ready_tracked(76)
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::MergeReady(76),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Mixed,
    ) {
    Some((message, _)) => {
      assert_true(message.contains("[MERGE READY]"))
      // Mixed must NOT collapse to a Manual-style 'MERGE NOW: Run merge_pr.'
      assert_false(message.contains("MERGE NOW: reviewed"))
      assert_true(message.contains("MERGE READY: reviewed"))
      assert_true(message.contains("Check per-leaf merge mode"))
      assert_next_action_line(message, @poller.NextAction::CrossCheckMergeMode)
    }
    None => fail("expected MergeReady message for Mixed mode")
  }
}

///|
test "parent_poll_event_message ReviewTimeout emits EscalateReview next_action with reviewer-add detail" {
  let tracked = parent_poll_test_ready_tracked(77)
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewTimeout(77),
      Some(0),
      merge_mode=@poller.MergeOperatorMode::Manual,
    ) {
    Some((message, _)) => {
      assert_next_action_line(message, @poller.NextAction::EscalateReview)
      assert_true(message.contains("gh pr edit --add-reviewer @copilot"))
    }
    None => fail("expected ReviewTimeout message")
  }
}

///|
test "parent_poll_event_message FixesPushed stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 8,
    agent_id: "main.dev-b",
    branch: "work/b",
    parent_branch: "main",
    pr_url: "",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
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
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::FixesPushed(8),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[FIXES PUSHED]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Unresolved inline review threads"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("FIXES PUSHED: Copilot does not re-review"))
      assert_false(message.contains("Waiting on review or CI"))
    }
    None => fail("expected FixesPushed message")
  }
}

///|
test "parent_poll_event_message FixesPushed single_pass avoids re-review wording" {
  let tracked : @poller.TrackedPR = {
    pr_number: 9,
    agent_id: "main.dev-c",
    branch: "work/c",
    parent_branch: "main",
    pr_url: "",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 1L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::FixesPushed(9),
      Some(0),
      review_mode=@types.ReviewMode::SinglePass,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(
        message.contains("Unresolved inline review threads (GraphQL): 0"),
      )
      assert_true(message.contains("resolving threads and checking gates"))
      assert_true(message.contains("MERGE NOW"))
      assert_false(message.contains("awaiting re-review"))
    }
    None => fail("expected FixesPushed message")
  }
  match
    pr_comment_body(
      @poller.PollEvent::FixesPushed(9),
      "main.dev-c",
      review_mode=@types.ReviewMode::SinglePass,
    ) {
    Some((_, body)) => {
      assert_true(body.contains("resolving threads and checking gates"))
      assert_false(body.contains("awaiting re-review"))
    }
    None => fail("expected FixesPushed comment")
  }
}

///|
test "parent_poll_event_message CIFailureCleared stresses re-check not merge" {
  let tracked : @poller.TrackedPR = {
    pr_number: 10,
    agent_id: "main.dev-x",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/10",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc",
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
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CIFailureCleared(10),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[CI FAILURE CLEARED]"))
      assert_true(message.contains("not a merge/review verdict"))
      assert_true(message.contains("pending"))
      assert_true(message.contains("re-check"))
      assert_false(message.contains("CI PASSED"))
      assert_false(message.to_lower().contains("green"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("changes_requested"))
      assert_true(message.contains("GitHub review requests changes"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("BLOCKED: review requested changes"))
    }
    None => fail("expected CIFailureCleared message")
  }
}

///|
test "leaf_poll_review_injection_message CIFailureCleared is honest about scope" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CIFailureCleared(44),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("no longer reports failure"))
      assert_true(message.contains("GitHub"))
      assert_true(message.contains("not merge"))
      assert_false(message.to_lower().contains("green"))
    }
    None => fail("expected leaf CIFailureCleared injection")
  }
}

///|
test "pr_comment_body CIFailureCleared contains pending caveat and no merge signal" {
  match pr_comment_body(@poller.PollEvent::CIFailureCleared(55), "main.dev-x") {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 55)
      assert_true(body.contains("pending"))
      assert_true(body.contains("not a merge signal"))
      assert_false(body.to_lower().contains("passed"))
      assert_false(body.to_lower().contains("green"))
    }
    None => fail("expected pr_comment_body for CIFailureCleared")
  }
}

///|
test "parent_poll_event_message CILatestHeadRollupSucceeded stresses not merge or approval" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("[CI LATEST HEAD]"))
      assert_true(message.contains("not merge approval"))
      assert_true(message.contains("re-check"))
      assert_false(message.to_lower().contains("mergeable"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("approved"))
      assert_true(message.contains("success"))
      assert_true(message.contains("no tracked blockers"))
      assert_true(message.contains("Does not merge"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("MERGE NOW"))
    }
    None => fail("expected CILatestHeadRollupSucceeded message")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded is scoped" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("all checks successful"))
      assert_true(message.contains("not merge"))
    }
    None => fail("expected leaf CILatestHeadRollupSucceeded injection")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded escalates when review timed out with no snapshot review" {
  let tracked : @poller.TrackedPR = {
    pr_number: 178,
    agent_id: "main.dev-leaf",
    branch: "work/leaf",
    parent_branch: "main",
    pr_url: "https://ex/pr/178",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 100L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(178),
      Some(tracked),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("no review"))
      assert_true(message.contains("add-reviewer"))
      assert_false(message.contains("re-check review thread and policy"))
    }
    None => fail("expected leaf CI escalation injection")
  }
}

///|
test "pr_comment_body CILatestHeadRollupSucceeded avoids approval language" {
  match
    pr_comment_body(
      @poller.PollEvent::CILatestHeadRollupSucceeded(60),
      "main.dev-z",
    ) {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 60)
      assert_true(body.contains("successful"))
      assert_true(body.contains("not an approval"))
      assert_false(body.to_lower().contains("approved"))
    }
    None => fail("expected pr_comment_body for CILatestHeadRollupSucceeded")
  }
}

///|
test "parent_poll_event_message suppresses non-blocking review comments" {
  let tracked : @poller.TrackedPR = {
    pr_number: 9,
    agent_id: "main.dev-c",
    branch: "work/c",
    parent_branch: "main",
    pr_url: "https://ex/pr/9",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Commented,
    last_review_bodies: "note",
    last_sha: "abc",
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
  @debug.assert_eq(
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewCommented(9, "minor suggestion"),
      None,
    ),
    None,
  )
}

///|
test "clamp_review_summary_for_pane leaves short text unchanged" {
  let s = "fix the typo in handler"
  assert_eq(clamp_review_summary_for_pane(s), s)
}

///|
test "clamp_review_summary_for_pane truncates long Copilot-style bodies" {
  let long = "x".repeat(review_summary_pane_max_chars + 500)
  let out = clamp_review_summary_for_pane(long)
  assert_true(out.contains("[truncated"))
  assert_true(out.length() < long.length())
}

///|
test "disconnect PR recovery only applies to branch-owning dev agents" {
  let mk = fn(role : @types.Role, branch : String) {
    @types.Agent::{
      agent_id: "agent",
      role,
      agent_type: @types.AgentType::Claude,
      parent: Some("root"),
      workspace: "/proj",
      branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }
  }
  assert_true(
    disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "main.leaf")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "")))
  assert_false(
    disconnect_pr_recovery_candidate(mk(@types.Role::Worker, "main.worker")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::TL, "main")))
}

///|
test "disconnect auto-rescue decision fires for review-owned unresolved threads" {
  let agent_id = "main.leaf"
  let agent : @types.Agent = {
    agent_id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: Some("main.tl"),
    workspace: "/tmp/proj/.choir/worktrees/leaf",
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=77,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://github.com/o/r/pull/77",
        ),
      ),
    ),
  }
  let tracked : @poller.TrackedPR = {
    pr_number: 77,
    agent_id,
    branch: agent_id,
    parent_branch: "main",
    pr_url: "https://github.com/o/r/pull/77",
    first_seen: 1000L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "fix this",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 1001L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    disconnect_auto_rescue_decision(agent, lifecycle, Some(tracked), 2, 2000L) {
    Rescue(plan~) => {
      assert_eq(plan.pr_number, 77)
      assert_eq(plan.new_slug, "auto-rescue-pr-77")
      assert_eq(plan.agent_type, @types.AgentType::Codex)
      assert_eq(
        plan.task,
        "PR 77: address Copilot review threads then notify_parent",
      )
    }
    NoRescue => fail("expected auto-rescue decision")
  }
}

///|
test "disconnect auto-rescue decision fires while Copilot review is pending" {
  let agent_id = "main.leaf"
  let agent : @types.Agent = {
    agent_id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: Some("main.tl"),
    workspace: "/tmp/proj/.choir/worktrees/leaf",
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=77,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://github.com/o/r/pull/77",
        ),
      ),
    ),
  }
  let tracked : @poller.TrackedPR = {
    pr_number: 77,
    agent_id,
    branch: agent_id,
    parent_branch: "main",
    pr_url: "https://github.com/o/r/pull/77",
    first_seen: 1000L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Commented,
    last_review_bodies: "human comment before copilot",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    disconnect_auto_rescue_decision(agent, lifecycle, Some(tracked), 0, 1100L) {
    Rescue(plan~) => {
      assert_eq(plan.pr_number, 77)
      assert_eq(
        plan.task,
        "PR 77: address Copilot review threads then notify_parent",
      )
    }
    NoRescue => fail("expected auto-rescue decision")
  }
}

///|
test "disconnect auto-rescue decision is one-shot for auto-rescue leaves" {
  let agent_id = "main.auto-rescue-pr-77"
  let agent : @types.Agent = {
    agent_id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: Some("main.tl"),
    workspace: "/tmp/proj/.choir/worktrees/leaf",
    branch: "main.leaf",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=77,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://github.com/o/r/pull/77",
        ),
      ),
    ),
  }
  let tracked : @poller.TrackedPR = {
    pr_number: 77,
    agent_id,
    branch: "main.leaf",
    parent_branch: "main",
    pr_url: "https://github.com/o/r/pull/77",
    first_seen: 1000L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "fix this",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 1001L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    disconnect_auto_rescue_decision(agent, lifecycle, Some(tracked), 2, 2000L) {
    NoRescue => ()
    Rescue(_) => fail("auto-rescue leaf must not auto-rescue again")
  }
}

///|
async test "disconnect auto-rescue skips thread fetch during Copilot grace window" {
  let project_dir = "/tmp/choir-auto-rescue-grace-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let old_id = "main.leaf"
  let pr_number = 79
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: old_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/leaf",
      branch: old_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: old_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::OpenUnreviewed(
            url="https://github.com/o/r/pull/79",
          ),
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number,
    old_id,
    old_id,
    "main",
    "https://github.com/o/r/pull/79",
    @poller.now_sec(),
  )

  let task = "PR 79: address Copilot review threads then notify_parent"
  let mut spawn_seen = false
  let mut gh_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "zellij" && cmd.args.join(" ").contains(task) {
        spawn_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" {
      gh_seen = true
    }
    (1, "")
  }

  state.handle_disconnect_with_runner(old_id, runner~, capture~)

  assert_true(spawn_seen)
  assert_false(gh_seen)
  match state.poller.get(pr_number) {
    Some(tracked) => assert_eq(tracked.agent_id, "main.auto-rescue-pr-79")
    None => fail("expected tracked PR to transfer to rescue leaf")
  }
}

///|
async test "disconnect auto-rescue spawns replacement for unresolved threads" {
  let project_dir = "/tmp/choir-auto-rescue-disconnect-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let old_id = "main.leaf"
  let pr_number = 78
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: old_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/leaf",
      branch: old_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: old_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::OpenUnreviewed(
            url="https://github.com/o/r/pull/78",
          ),
        ),
      ),
    }),
  )
  state.poller.track(
    pr_number, old_id, old_id, "main", "https://github.com/o/r/pull/78", 1000L,
  )

  let task = "PR 78: address Copilot review threads then notify_parent"
  let mut spawn_seen = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "zellij" && cmd.args.join(" ").contains(task) {
        spawn_seen = true
      }
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "gh" &&
      cmd.args == ["repo", "view", "--json", "owner,name"] {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.program == "gh" &&
      cmd.args.length() >= 2 &&
      cmd.args[0] == "api" &&
      cmd.args[1] == "graphql" {
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"T1\",\"isResolved\":false,\"isOutdated\":false,\"path\":\"src/server/handler_disconnect.mbt\",\"comments\":{\"nodes\":[{\"body\":\"fix\"}]}}]}}}}}",
      )
    }
    (1, "")
  }

  state.handle_disconnect_with_runner(old_id, runner~, capture~)

  assert_true(spawn_seen)
  match state.poller.get(pr_number) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "main.auto-rescue-pr-78")
      assert_eq(tracked.branch, old_id)
    }
    None => fail("expected tracked PR to transfer to rescue leaf")
  }
  match @phase.read_lifecycle(project_dir, old_id) {
    Some(lifecycle) =>
      match lifecycle.process {
        @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::RescuedByReplacement
        ) => ()
        other => fail("expected rescued finalization, got " + other.to_string())
      }
    None => fail("expected old lifecycle to remain as rescued")
  }
  match @phase.read_lifecycle(project_dir, "main.auto-rescue-pr-78") {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(pr_number=78, ..)
        ) => ()
        other =>
          fail(
            "expected review-owned rescue lifecycle, got " + other.to_string(),
          )
      }
    None => fail("expected rescue lifecycle")
  }
}

///|
async test "fail_agent_with_runner injects failure to parent terminal" {
  let project_dir = "/tmp/choir-watchdog-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main.parent"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => fail("expected parseable local target")
  }

  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: parent_id,
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  ignore(
    @phase.write_lifecycle(
      project_dir,
      @phase.lifecycle_for_role(caller_id, @types.Role::Dev),
    ),
  )

  @async.sleep(0)

  let mut injected_failure_msg = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[from: " + caller_id + "]") &&
          text.contains("watchdog timeout") {
          injected_failure_msg = true
        }
      }
    }
    [0]
  }

  state.fail_agent_with_runner(
    caller_id,
    @phase.FailureReason::WatchdogTimeout,
    "watchdog timeout",
    @types.ExitReason::Shutdown,
    runner,
  )

  assert_true(injected_failure_msg)
}

///|
test "parent_poll_event_message REVIEW TIMEOUT uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 61,
    agent_id: "main.dev-timeout",
    branch: "work/timeout",
    parent_branch: "main",
    pr_url: "https://ex/pr/61",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::ReviewTimeout(61),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Failure)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("ACTION REQUIRED: no review"))
      assert_true(message.contains("add-reviewer"))
      assert_true(message.contains("add-reviewer"))
      assert_false(message.contains("15min"))
    }
    None => fail("expected ReviewTimeout message")
  }
}

///|
test "parent_poll_event_message CI LATEST HEAD adds escalation when review timeout already fired" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 999L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Info)
      assert_true(message.contains("Review timeout already fired"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("ACTION REQUIRED: no review"))
    }
    None => fail("expected CILatestHeadRollupSucceeded escalation message")
  }
}

///|
test "parent_poll_event_message CI FAILED uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 62,
    agent_id: "main.dev-ci",
    branch: "work/ci",
    parent_branch: "main",
    pr_url: "https://ex/pr/62",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Failure,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  match
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::CIFailed(62),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, @types.Status::Failure)
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("BLOCKED: CI failing"))
    }
    None => fail("expected CIFailed message")
  }
}

///|
test "parent_poll_event_message PRMerged is handled by canonical teardown delivery" {
  let tracked : @poller.TrackedPR = {
    pr_number: 63,
    agent_id: "main.dev-merged",
    branch: "work/merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/63",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  @debug.assert_eq(
    parent_poll_event_message(
      tracked,
      "/repo",
      @poller.PollEvent::PRMerged(tracked),
      Some(0),
    ),
    None,
  )
}

///|
test "evidence_events_for_poll_snapshot emits normalized snapshot events" {
  let tracked : @poller.TrackedPR = {
    pr_number: 64,
    agent_id: "main.dev-evidence",
    branch: "work/evidence",
    parent_branch: "main",
    pr_url: "https://ex/pr/64",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "looks good",
    last_sha: "sha64",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::CILatestHeadRollupSucceeded(64),
    Some(0),
  )
  assert_eq(events.length(), 4)
  match events[0] {
    @evidence.EvidenceEvent::ReviewObserved(state~, body~) => {
      assert_eq(state, @evidence.EvidenceReviewState::Approved)
      @debug.assert_eq(body, Some("looks good"))
    }
    _ => fail("expected review evidence")
  }
  match events[1] {
    @evidence.EvidenceEvent::CiObserved(status~, head_sha~) => {
      assert_eq(status, @evidence.EvidenceCiStatus::Success)
      @debug.assert_eq(head_sha, Some("sha64"))
    }
    _ => fail("expected ci evidence")
  }
  match events[2] {
    @evidence.EvidenceEvent::ThreadsObserved(count~) => assert_eq(count, 0)
    _ => fail("expected threads evidence")
  }
  match events[3] {
    @evidence.EvidenceEvent::CopilotIssueCommentObserved => ()
    _ => fail("expected copilot evidence")
  }
}

///|
test "evidence_events_for_poll_snapshot includes merge observed on PRMerged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 65,
    agent_id: "main.dev-evidence-merged",
    branch: "work/evidence-merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/65",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha65",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let events = evidence_events_for_poll_snapshot(
    tracked,
    @poller.PollEvent::PRMerged(tracked),
    None,
  )
  assert_eq(events.length(), 5)
  match events[4] {
    @evidence.EvidenceEvent::MergeObserved(pr_number~, pr_url~) => {
      assert_eq(pr_number, 65)
      @debug.assert_eq(pr_url, Some("https://ex/pr/65"))
    }
    _ => fail("expected merge evidence")
  }
}

///|
async test "deliver_orphaned_pr_notification_for skips finalized merged lifecycle" {
  let project_dir = "/tmp/choir-handler-orphan-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let agent_id = "main.dev-finalized"
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::Merged,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    }),
  )
  let pr : @poller.TrackedPR = {
    pr_number: 88,
    agent_id,
    branch: "feat/finalized",
    parent_branch: "main",
    pr_url: "https://gh.test/88",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let mut runner_calls = 0
  deliver_orphaned_pr_notification_for(state, pr, async fn(cmds) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    []
  })
  assert_eq(runner_calls, 0)
}

///|
async test "deliver_poller_stall_notification_for skips finalized merged lifecycle" {
  let project_dir = "/tmp/choir-handler-stall-skip-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let agent_id = "main.dev-finalized"
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::Merged,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
      ),
    }),
  )
  let pr : @poller.TrackedPR = {
    pr_number: 89,
    agent_id,
    branch: "feat/finalized",
    parent_branch: "main",
    pr_url: "https://gh.test/89",
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 1L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
  let mut runner_calls = 0
  deliver_poller_stall_notification_for(state, pr, 1000L, async fn(cmds) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    []
  })
  assert_eq(runner_calls, 0)
}

///|
async fn handler_with_moontrace_capture(
  captured : Array[@moontrace.Event],
  f : async () -> Unit,
) -> Unit {
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  f() catch {
    err => {
      @moontrace.clear_subscriber()
      raise err
    }
  }
  @moontrace.clear_subscriber()
}

///|
fn handler_auto_close_test_state(label : String) -> ServerState {
  let project_dir = "/tmp/choir-handler-auto-close-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  ServerState::new(config, make_recovery_provider())
}

///|
fn handler_auto_close_target(label : String) -> @types.LocalTarget {
  { kind: @types.TargetKind::ZellijPane, session: "test-session", name: label }
}

///|
fn handler_close_terminal_warn_count(events : Array[@moontrace.Event]) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "CloseTerminal failed" {
      count = count + 1
    }
  }
  count
}

///|
async test "test_close_terminal_warns_on_nonzero_exit" {
  let state = handler_auto_close_test_state("close-warn")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [1])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
async test "test_close_terminal_no_warn_on_zero_exit" {
  let state = handler_auto_close_test_state("close-ok")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [0])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 0)
}

///|
/// Post-merge teardown may close a zellij tab that already self-closed; the
/// close helper exits 0 idempotently, so the runner reports success and no WARN.
async test "test_close_terminal_no_warn_idempotent_absent_zellij_tab" {
  let state = handler_auto_close_test_state("close-tab-idempotent")
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "test-session",
    name: "already-closed-tab",
  }
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => [0])
  })
  assert_eq(handler_close_terminal_warn_count(captured), 0)
}

///|
async test "test_close_terminal_warns_on_error" {
  let state = handler_auto_close_test_state("close-error")
  let target = handler_auto_close_target("leaf-pane")
  let captured : Array[@moontrace.Event] = []
  handler_with_moontrace_capture(captured, async fn() {
    state.interpret_teardown_effects([CloseTerminal(target)], _cmds => {
      raise @types.ChoirError::agent_not_found("test error")
    })
  })
  assert_eq(handler_close_terminal_warn_count(captured), 1)
}

///|
fn handler_auto_close_agent(
  agent_id : String,
  state : @types.AgentState,
  target : @types.LocalTarget?,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some("main.parent"),
    workspace: "/tmp/choir-handler-auto-close-workspace",
    branch: agent_id,
    terminal_target: target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state,
  }
}

///|
async test "test_disconnect_done_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-done")
  let agent_id = "main.done-leaf"
  let target = handler_auto_close_target("done-pane")
  ignore(
    state.register_agent(handler_auto_close_agent(agent_id, Done, Some(target))),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_failed_agent_closes_pane" {
  let state = handler_auto_close_test_state("disconnect-failed")
  let agent_id = "main.failed-leaf"
  let target = handler_auto_close_target("failed-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Failed, Some(target)),
    ),
  )
  let expected = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], expected)
}

///|
async test "test_disconnect_done_agent_no_target_no_call" {
  let state = handler_auto_close_test_state("disconnect-done-no-target")
  let agent_id = "main.done-leaf-no-target"
  ignore(state.register_agent(handler_auto_close_agent(agent_id, Done, None)))
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(calls.length(), 0)
}

///|
async test "test_disconnect_completing_agent_no_close" {
  let state = handler_auto_close_test_state("disconnect-completing")
  let agent_id = "main.completing-leaf"
  let target = handler_auto_close_target("completing-pane")
  ignore(
    state.register_agent(
      handler_auto_close_agent(agent_id, Completing, Some(target)),
    ),
  )
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })

  // Completing agents finalize state (PersistLifecycle) then transition to Done.
  // finalize_agent_with_runner is called with close_target=false and remove_worktree=false,
  // so plan_finalize emits no CloseTerminal or RemoveWorktree effects — the only effects
  // that invoke the runner. The assertion confirms no premature pane close occurs.
  assert_true(calls.is_empty())

  let agent = state.registry.get(agent_id) catch {
    _ => fail("agent not found")
  }
  assert_eq(agent.state, Done)
}

///|
fn disconnect_confirmation_provider(
  live_tabs : Array[String],
  live_panes : Array[String],
) -> @runtime.RecoveryProvider {
  {
    ..make_recovery_provider(),
    zellij_live: async fn(_, _) {
      @async.sleep(0)
      { tabs: live_tabs, panes: live_panes }
    },
    find_prs_by_head: async fn(_, _) {
      @async.sleep(0)
      []
    },
  }
}

///|
fn disconnect_confirmation_test_state(
  label : String,
  live_tabs : Array[String],
  live_panes : Array[String],
) -> ServerState {
  let project_dir = "/tmp/choir-disconnect-confirm-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  ServerState::new(
    config,
    disconnect_confirmation_provider(live_tabs, live_panes),
  )
}

///|
fn disconnect_confirmation_parent(parent_id : String) -> @types.Agent {
  {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: "/tmp/choir-disconnect-confirm-parent",
    branch: "main",
    terminal_target: Some(handler_auto_close_target("parent-pane")),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
fn disconnect_confirmation_leaf(
  agent_id : String,
  parent_id : String,
  target_name : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: Some(parent_id),
    workspace: "/tmp/choir-disconnect-confirm-leaf",
    branch: agent_id,
    terminal_target: Some(handler_auto_close_target(target_name)),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
fn texts_contain(texts : Array[String], needle : String) -> Bool {
  for text in texts {
    if text.contains(needle) {
      return true
    }
  }
  false
}

///|
async test "disconnect confirmation keeps single registry-timeout signal soft" {
  let parent_id = "main.confirm-parent"
  let agent_id = "main.confirm-leaf"
  let state = disconnect_confirmation_test_state("single-signal", [], [
    "leaf-pane",
  ])
  ignore(state.register_agent(disconnect_confirmation_parent(parent_id)))
  ignore(
    state.register_agent(
      disconnect_confirmation_leaf(agent_id, parent_id, "leaf-pane"),
    ),
  )
  state.schedule_disconnect(agent_id, 0L)
  let delivered : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        delivered.push(cmd.args[cmd.args.length() - 1])
      }
    }
    [0]
  }
  let capture = async fn(_ : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (1, "")
  }

  state.process_pending_disconnects_with_runner(61L, 60L, runner~, capture~)
  state.process_pending_disconnects_with_runner(91L, 60L, runner~, capture~)

  assert_true(
    texts_contain(delivered, "[POSSIBLY DISCONNECTED: " + agent_id + "]"),
  )
  assert_false(texts_contain(delivered, "[FAILED: " + agent_id + "]"))
  assert_eq(delivered.length(), 1)
  let agent = state.registry.get(agent_id) catch {
    _ => fail("expected active agent to remain in registry")
  }
  assert_eq(agent.state, @types.AgentState::Active)
  assert_true(state.pending_disconnects.contains(agent_id))
  assert_true(state.pending_disconnect_soft_notified.contains(agent_id))

  state.clear_pending_disconnect(agent_id)
  assert_false(state.pending_disconnects.contains(agent_id))
  assert_false(state.pending_disconnect_soft_notified.contains(agent_id))
}

///|
async test "disconnect confirmation hard-fails after registry-timeout and closed-pane signals" {
  let parent_id = "main.confirm-parent"
  let agent_id = "main.confirm-leaf"
  let state = disconnect_confirmation_test_state("two-signal", [], [])
  ignore(state.register_agent(disconnect_confirmation_parent(parent_id)))
  ignore(
    state.register_agent(
      disconnect_confirmation_leaf(agent_id, parent_id, "leaf-pane"),
    ),
  )
  state.schedule_disconnect(agent_id, 0L)
  let delivered : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        delivered.push(cmd.args[cmd.args.length() - 1])
      }
    }
    [0]
  }
  let capture = async fn(_ : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (1, "")
  }

  state.process_pending_disconnects_with_runner(61L, 60L, runner~, capture~)

  assert_true(
    texts_contain(
      delivered,
      "[FAILED: " +
      agent_id +
      "] disconnected unexpectedly - agent may have crashed or run out of context",
    ),
  )
  assert_false(
    texts_contain(delivered, "[POSSIBLY DISCONNECTED: " + agent_id + "]"),
  )
  let agent = state.registry.get(agent_id) catch {
    _ => fail("expected failed agent to remain in registry")
  }
  assert_eq(agent.state, @types.AgentState::Failed)
  assert_false(state.pending_disconnects.contains(agent_id))
}

///|
async test "direct disconnect wrapper buffers awaiting-confirmation result" {
  let parent_id = "main.confirm-parent"
  let agent_id = "main.confirm-leaf"
  let state = disconnect_confirmation_test_state("direct-wrapper", [], [
    "leaf-pane",
  ])
  ignore(state.register_agent(disconnect_confirmation_parent(parent_id)))
  ignore(
    state.register_agent(
      disconnect_confirmation_leaf(agent_id, parent_id, "leaf-pane"),
    ),
  )
  let delivered : Array[String] = []
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        delivered.push(cmd.args[cmd.args.length() - 1])
      }
    }
    [0]
  }
  let capture = async fn(_ : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (1, "")
  }

  state.handle_disconnect_with_runner(agent_id, runner~, capture~)

  assert_true(
    texts_contain(delivered, "[POSSIBLY DISCONNECTED: " + agent_id + "]"),
  )
  assert_false(texts_contain(delivered, "[FAILED: " + agent_id + "]"))
  assert_true(state.pending_disconnects.contains(agent_id))
  assert_true(state.pending_disconnect_soft_notified.contains(agent_id))
  let agent = state.registry.get(agent_id) catch {
    _ => fail("expected active agent to remain in registry")
  }
  assert_eq(agent.state, @types.AgentState::Active)
}
