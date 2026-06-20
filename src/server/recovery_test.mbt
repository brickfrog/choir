///|
async test "discover_recovery_input with mock provider" {
  let mock_provider : @runtime.RecoveryProvider = {
    zellij_live: fn(_dir, _session) {
      @runtime.ZellijLiveTargets::{ tabs: ["tab1"], panes: ["pane1"] }
    },
    agent_process_alive: fn(_dir, _workspace) { false },
    open_prs: fn(_dir) {
      [
        @runtime.OpenPR::{
          pr_number: 123,
          branch: "feat/x",
          base: "main",
          url: "https://gh.test/123",
          created_sec: Some(1000L),
        },
      ]
    },
    find_prs_by_head: fn(_dir, _branch) {
      [
        @runtime.OpenPR::{
          pr_number: 123,
          branch: "feat/x",
          base: "main",
          url: "https://gh.test/123",
          created_sec: Some(1000L),
        },
      ]
    },
    find_prs_by_head_any: fn(_dir, _branch) { [] },
    find_pr_by_number: fn(_dir, _pr_number) { None },
    list_agent_containers: fn(_dir) { ["worktrees"] },
    list_agents_in_container: fn(_dir, container) {
      if container == "worktrees" {
        ["slug1"]
      } else {
        []
      }
    },
    read_agent_config: fn(_dir, _container, _slug) {
      let content =
        #|role = "dev"
        #|agent_id = "slug1"
        #|branch = "feat/x"
      content
    },
    get_agent_relative_workspace: fn(container, slug) {
      ".choir/" + container + "/" + slug
    },
    list_lifecycle_ids: fn(_dir) { [] },
    read_lifecycle_content: fn(_dir, _id) { "" },
    read_poller_state: fn(_dir) { [] },
    write_poller_state: fn(_dir, _tracked) { () },
    gh_poll_pr: fn(_num, _skip) {
      (
        true,
        @poller.ReviewState::Approved,
        "sha1",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
  }
  let input = @runtime.discover_recovery_input(mock_provider, "/tmp", "session")
  @debug.assert_eq(input.panes.live.tabs, ["tab1"])
  @debug.assert_eq(input.panes.live.panes, ["pane1"])
  assert_eq(input.prs.open_prs.length(), 1)
  assert_eq(input.prs.open_prs[0].pr_number, 123)
  assert_eq(input.files.local_agents.length(), 1)
  assert_eq(input.files.local_agents[0].slug, "slug1")
  match input.prs.polls.get(123) {
    Some(row) => {
      assert_eq(row.review, @poller.ReviewState::Approved)
      assert_eq(row.sha, "sha1")
    }
    None => fail("expected PR poll row for open PR without persisted tracking")
  }
  match input.prebuilt_agent_phase {
    Some(_) => ()
    None => fail("discover_recovery_input should include prebuilt agent phase")
  }
}

///|
async test "discover_recovery_input keeps process-live agent alive without zellij target" {
  let project_dir = "/tmp/choir-recovery-process-live"
  let mock_provider : @runtime.RecoveryProvider = {
    ..make_hermetic_recovery_provider(),
    list_agent_containers: fn(_dir) { ["worktrees"] },
    list_agents_in_container: fn(_dir, container) {
      if container == "worktrees" {
        ["slug1"]
      } else {
        []
      }
    },
    read_agent_config: fn(_dir, _container, _slug) {
      (
        #|role = "dev"
        #|agent_id = "slug1"
        #|branch = "feat/x"
        #|workspace = "/tmp/choir-recovery-process-live/.choir/worktrees/slug1"
        #|terminal_target = "zellij-tab:session:missing-tab"
      )
    },
    get_agent_relative_workspace: fn(container, slug) {
      ".choir/" + container + "/" + slug
    },
    // Owned-handle liveness is keyed by agent id (pidfile name), not by
    // workspace path.
    agent_process_alive: fn(_dir, candidate) { candidate == "slug1" },
  }

  let input = @runtime.discover_recovery_input(
    mock_provider, project_dir, "session",
  )

  assert_eq(input.files.local_agents.length(), 1)
  assert_true(input.files.local_agents[0].process_alive)
  match input.prebuilt_agent_phase {
    Some(phase) => {
      assert_eq(phase.agent_stage_actions.length(), 1)
      match phase.agent_stage_actions[0] {
        @runtime.RecoveryAction::RegisterAgent(agent, alive) => {
          assert_true(alive)
          assert_eq(agent.state, @types.AgentState::Active)
          @debug.assert_eq(
            agent.terminal_target.map(fn(t) { t.to_string() }),
            Some("zellij-tab:session:missing-tab"),
          )
        }
        _ => fail("expected only RegisterAgent for process-live agent")
      }
    }
    None => fail("expected prebuilt phase")
  }
}

///|
async test "recover_state ReapStaleLifecycle deletes the on-disk lifecycle" {
  // Narrowed from a prior "no parent-registry warn" framing: the reap
  // branch does not call sync_parent_child_lifecycle at all, so asserting
  // that warn is absent here was vacuous. The contract worth pinning is
  // the file-deletion side effect plus the debug log; the wider boot-path
  // "stale entry never triggers a warn" property is exercised end-to-end
  // by `plan_stale_lifecycle_reaps` planner tests + the phase-side
  // downgrade test in src/phase/phase_test.mbt.
  let project_dir = "/tmp/choir-recovery-reap-stale-lifecycle-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
  let agent_id = "feature/x.stale-leaf"
  let lifecycle = {
    ..@phase.lifecycle_for_role(agent_id, @types.Role::Dev),
    process: @phase.ProcessState::Finalized(
      reason=@phase.FinalizeReason::Merged,
    ),
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
    ),
  }
  assert_true(@phase.write_lifecycle(project_dir, lifecycle))
  let pid_path = @workspace.agent_pid_file_path(project_dir, agent_id)
  ignore(@sys.create_dir_all(project_dir + "/.choir/pids"))
  assert_true(@sys.write_file_sync(pid_path, "5151\n"))
  let killed : Array[Int] = []
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  try
    recover_state(
      state,
      terminal_session,
      {
        panes: { live: { tabs: [], panes: [] } },
        prs: { open_prs: [], polls: Map([], capacity=0), resolved_prs: [] },
        files: { local_agents: [], persisted_tracked_prs: [] },
        recovered_at: 200L,
        prebuilt_agent_phase: Some({
          recovered_agents: [],
          agent_stage_actions: [
            @runtime.RecoveryAction::ReapStaleLifecycle(agent_id~),
          ],
        }),
      },
      runner=async fn(_cmds) {
        @async.sleep(0)
        []
      },
      kill_pgid=fn(pgid) { killed.push(pgid) },
    )
  catch {
    e => {
      @moontrace.clear_subscriber()
      raise e
    }
  } noraise {
    _ => ()
  }
  @moontrace.clear_subscriber()
  assert_true(@phase.read_lifecycle(project_dir, agent_id) is None)
  @debug.assert_eq(killed, [5151])
  assert_false(@sys.path_entry_exists(pid_path))
  let mut saw_reap_debug = false
  for event in captured {
    if event.level == @moontrace.Level::Debug &&
      event.message == "reaped stale lifecycle" {
      saw_reap_debug = true
    }
  }
  assert_true(saw_reap_debug)
}

///|
async test "recover_state ReapStaleLifecycle warns when delete_lifecycle returns false" {
  // Pins the warn-branch contract: when delete_file_sync fails (file already
  // gone, ENOENT, permission, etc.), the dispatch arm must emit a warn so
  // operators do not see a "reaped" line while the on-disk KV remains.
  let project_dir = "/tmp/choir-recovery-reap-stale-lifecycle-fail-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_hermetic_recovery_provider())
  let agent_id = "feature/x.never-written-leaf"
  // Intentionally do NOT write the lifecycle. delete_file_sync returns false
  // for a missing file -> the reap branch must take the warn arm.
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  try
    recover_state(state, terminal_session, {
      panes: { live: { tabs: [], panes: [] } },
      prs: { open_prs: [], polls: Map([], capacity=0), resolved_prs: [] },
      files: { local_agents: [], persisted_tracked_prs: [] },
      recovered_at: 200L,
      prebuilt_agent_phase: Some({
        recovered_agents: [],
        agent_stage_actions: [
          @runtime.RecoveryAction::ReapStaleLifecycle(agent_id~),
        ],
      }),
    })
  catch {
    e => {
      @moontrace.clear_subscriber()
      raise e
    }
  } noraise {
    _ => ()
  }
  @moontrace.clear_subscriber()
  let mut saw_reap_debug = false
  let mut saw_reap_failed_warn = false
  for event in captured {
    if event.message == "reaped stale lifecycle" {
      saw_reap_debug = true
    }
    if event.level == @moontrace.Level::Warn &&
      event.message ==
      "reap stale lifecycle failed: delete_lifecycle returned false" {
      saw_reap_failed_warn = true
    }
  }
  assert_false(saw_reap_debug)
  assert_true(saw_reap_failed_warn)
}

///|
test "plan_recovery reconciles local agents and open PRs" {
  let polls : Map[Int, @runtime.RecoveryPrPollRow] = Map([], capacity=0)
  polls.set(123, {
    review: @poller.ReviewState::Approved,
    sha: "sha1",
    ci_rollup: @poller.CiRollupStatus::Success,
    review_bodies: "",
    copilot_issue_comment_seen: false,
  })
  let input : @runtime.RecoveryReconcileInput = {
    panes: { live: { tabs: ["tab1"], panes: [] } },
    prs: {
      open_prs: [
        {
          pr_number: 123,
          branch: "feat/x",
          base: "main",
          url: "https://gh.test/123",
          created_sec: Some(1000L),
        },
      ],
      polls,
      resolved_prs: [],
    },
    files: {
      local_agents: [
        {
          slug: "slug1",
          dir_name: "worktrees",
          agent: Some({
            agent_id: @types.AgentId("slug1"),
            role: @types.Role::Dev,
            agent_type: @types.AgentType::Claude,
            parent: None,
            workspace: "/tmp/w",
            branch: "feat/x",
            terminal_target: Some({
              kind: @types.TargetKind::ZellijTab,
              session: "session",
              name: "tab1",
            }),
            host: @types.Host::Local,
            spawn_depth: 0,
            state: @types.AgentState::Active,
          }),
          process_alive: false,
        },
      ],
      persisted_tracked_prs: [],
    },
    recovered_at: 2000L,
    prebuilt_agent_phase: None,
  }

  let plan = @runtime.plan_recovery("session", input)

  // Expect:
  // 1. RegisterAgent(slug1, alive=true)
  // 2. TrackNewPR(123, slug1, ...)
  // 3. SyncLifecycle(slug1, ...)

  let actions = plan.actions
  assert_eq(actions.length(), 3)

  match actions[0] {
    @runtime.RecoveryAction::RegisterAgent(agent, alive) => {
      assert_eq(agent.agent_id.to_string(), "slug1")
      assert_true(alive)
      assert_eq(agent.state, @types.AgentState::Active)
    }
    _ => fail("expected RegisterAgent")
  }

  match actions[1] {
    @runtime.RecoveryAction::TrackNewPR(pr_number~, agent_id~, ..) => {
      assert_eq(pr_number, 123)
      assert_eq(agent_id, "slug1")
    }
    _ => fail("expected TrackNewPR")
  }

  match actions[2] {
    @runtime.RecoveryAction::SyncLifecycle(agent_id~, ..) =>
      assert_eq(agent_id, "slug1")
    _ => fail("expected SyncLifecycle")
  }
}

///|
test "plan_recovery uses fallback poll row when TrackNewPR snapshot map has no entry" {
  let input : @runtime.RecoveryReconcileInput = {
    panes: { live: { tabs: ["tab1"], panes: [] } },
    prs: {
      open_prs: [
        {
          pr_number: 123,
          branch: "feat/x",
          base: "main",
          url: "https://gh.test/123",
          created_sec: Some(1000L),
        },
      ],
      polls: Map([], capacity=0),
      resolved_prs: [],
    },
    files: {
      local_agents: [
        {
          slug: "slug1",
          dir_name: "worktrees",
          agent: Some({
            agent_id: @types.AgentId("slug1"),
            role: @types.Role::Dev,
            agent_type: @types.AgentType::Claude,
            parent: None,
            workspace: "/tmp/w",
            branch: "feat/x",
            terminal_target: Some({
              kind: @types.TargetKind::ZellijTab,
              session: "session",
              name: "tab1",
            }),
            host: @types.Host::Local,
            spawn_depth: 0,
            state: @types.AgentState::Active,
          }),
          process_alive: false,
        },
      ],
      persisted_tracked_prs: [],
    },
    recovered_at: 2000L,
    prebuilt_agent_phase: None,
  }
  let plan = @runtime.plan_recovery("session", input)
  assert_eq(plan.actions.length(), 3)
  match plan.actions[1] {
    @runtime.RecoveryAction::TrackNewPR(
      pr_number~,
      review~,
      sha~,
      ci_rollup~,
      ..
    ) => {
      assert_eq(pr_number, 123)
      assert_eq(review, @poller.ReviewState::None_)
      assert_eq(sha, "")
      assert_eq(ci_rollup, @poller.CiRollupStatus::Unknown)
    }
    _ => fail("expected TrackNewPR with fallback poll row")
  }
}

///|
test "plan_recovery handles offline agent and persisted PR" {
  let input : @runtime.RecoveryReconcileInput = {
    panes: { live: { tabs: [], panes: [] } },
    prs: {
      open_prs: [
        {
          pr_number: 456,
          branch: "feat/offline",
          base: "main",
          url: "https://gh.test/456",
          created_sec: Some(3000L),
        },
      ],
      polls: Map([], capacity=0),
      resolved_prs: [],
    },
    files: {
      local_agents: [
        {
          slug: "slug-off",
          dir_name: "worktrees",
          agent: Some({
            agent_id: @types.AgentId("slug-off"),
            role: @types.Role::Dev,
            agent_type: @types.AgentType::Claude,
            parent: None,
            workspace: "/tmp/w-off",
            branch: "feat/offline",
            terminal_target: Some({
              kind: @types.TargetKind::ZellijTab,
              session: "session",
              name: "tab-off",
            }),
            host: @types.Host::Local,
            spawn_depth: 0,
            state: @types.AgentState::Active,
          }),
          process_alive: false,
        },
      ],
      persisted_tracked_prs: [
        @poller.TrackedPR::{
          pr_number: 456,
          agent_id: "slug-off",
          branch: "feat/offline",
          parent_branch: "main",
          pr_url: "https://gh.test/456",
          first_seen: 3000L,
          consecutive_failures: 0,
          backoff_until: 0L,
          last_review_state: @poller.ReviewState::Commented,
          last_review_bodies: "some comments",
          last_sha: "sha-off",
          last_automerge_attempt_sha: "",
          notified_parent: false,
          last_ci_rollup: @poller.CiRollupStatus::Unknown,
          mergeable: @poller.Mergeable::Unknown,
          merge_state_status: @poller.MergeStateStatus::Unknown,
          merged_at_unix: None,
          last_timeout_at: 0L,
          copilot_issue_comment_seen: false,
          orphan_notified: false,
          orphan_reconciling: false,
          changes_requested_since: 0L,
          stall_notified: false,
          fixes_pushed_at: 0L,
          review_mode: @types.ReviewMode::Iterative,
          unresolved_thread_ids: [],
          unresolved_thread_ids_fetched: false,
          auto_resolve_outdated_pending: false,
        },
      ],
    },
    recovered_at: 4000L,
    prebuilt_agent_phase: None,
  }

  let plan = @runtime.plan_recovery("session", input)

  // Expect:
  // 1. RegisterAgent(slug-off, alive=false)
  // 2. FinalizeOfflineAgent(slug-off)
  // 3. RestorePRTracking(456, slug-off, ...)
  // 4. SyncLifecycle(slug-off, ...)

  let actions = plan.actions
  assert_eq(actions.length(), 4)

  match actions[0] {
    @runtime.RecoveryAction::RegisterAgent(agent, alive) => {
      assert_eq(agent.agent_id.to_string(), "slug-off")
      assert_false(alive)
      assert_eq(agent.state, @types.AgentState::Done)
    }
    _ => fail("expected RegisterAgent")
  }

  match actions[1] {
    @runtime.RecoveryAction::FinalizeOfflineAgent(agent_id~) =>
      assert_eq(agent_id, "slug-off")
    _ => fail("expected FinalizeOfflineAgent")
  }

  match actions[2] {
    @runtime.RecoveryAction::RestorePRTracking(tracked) => {
      assert_eq(tracked.pr_number, 456)
      assert_eq(tracked.agent_id, "slug-off")
    }
    _ => fail("expected RestorePRTracking")
  }

  match actions[3] {
    @runtime.RecoveryAction::SyncLifecycle(agent_id~, pr~, ..) => {
      assert_eq(agent_id, "slug-off")
      assert_eq(pr.pr_number, 456)
    }
    _ => fail("expected SyncLifecycle")
  }
}

///|
test "plan_recovery finalizes merged tracked PR after restart" {
  let input : @runtime.RecoveryReconcileInput = {
    panes: { live: { tabs: [], panes: [] } },
    prs: {
      open_prs: [],
      polls: Map([], capacity=0),
      resolved_prs: [
        @runtime.KnownPR::{
          pr_number: 777,
          branch: "feat/merged",
          base: "main",
          url: "https://gh.test/777",
          created_sec: Some(5000L),
          state: @runtime.KnownPRState::Merged,
        },
      ],
    },
    files: {
      local_agents: [],
      persisted_tracked_prs: [
        @poller.TrackedPR::{
          pr_number: 777,
          agent_id: "main.leaf-merged",
          branch: "feat/merged",
          parent_branch: "main",
          pr_url: "https://gh.test/777",
          first_seen: 4000L,
          consecutive_failures: 0,
          backoff_until: 0L,
          last_review_state: @poller.ReviewState::Approved,
          last_review_bodies: "",
          last_sha: "sha-merged",
          last_automerge_attempt_sha: "",
          notified_parent: true,
          last_ci_rollup: @poller.CiRollupStatus::Success,
          mergeable: @poller.Mergeable::Unknown,
          merge_state_status: @poller.MergeStateStatus::Unknown,
          merged_at_unix: None,
          last_timeout_at: 0L,
          copilot_issue_comment_seen: false,
          orphan_notified: false,
          orphan_reconciling: false,
          changes_requested_since: 0L,
          stall_notified: false,
          fixes_pushed_at: 0L,
          review_mode: @types.ReviewMode::Iterative,
          unresolved_thread_ids: [],
          unresolved_thread_ids_fetched: false,
          auto_resolve_outdated_pending: false,
        },
      ],
    },
    recovered_at: 6000L,
    prebuilt_agent_phase: None,
  }

  let plan = @runtime.plan_recovery("session", input)
  assert_eq(plan.actions.length(), 1)
  match plan.actions[0] {
    @runtime.RecoveryAction::FinalizeMergedAgent(
      agent_id~,
      pr_number~,
      branch~,
      parent_branch~,
      pr_url~
    ) => {
      assert_eq(agent_id, "main.leaf-merged")
      assert_eq(pr_number, 777)
      assert_eq(branch, "feat/merged")
      assert_eq(parent_branch, "main")
      assert_eq(pr_url, "https://gh.test/777")
    }
    _ => fail("expected FinalizeMergedAgent")
  }
}
