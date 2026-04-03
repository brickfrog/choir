///|
async test "discover_recovery_input with mock provider" {
  let mock_provider : @runtime.RecoveryProvider = {
    zellij_live: fn(_dir, _session) {
      @runtime.ZellijLiveTargets::{ tabs: ["tab1"], panes: ["pane1"] }
    },
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
      )
    },
  }
  let input = @runtime.discover_recovery_input(mock_provider, "/tmp", "session")
  assert_eq(input.panes.live.tabs, ["tab1"])
  assert_eq(input.panes.live.panes, ["pane1"])
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
test "plan_recovery reconciles local agents and open PRs" {
  let polls : Map[Int, @runtime.RecoveryPrPollRow] = Map::new()
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
      polls: Map::new(),
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
      polls: Map::new(),
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
          notified_parent: false,
          last_ci_rollup: @poller.CiRollupStatus::Unknown,
          last_timeout_at: 0L,
          copilot_issue_comment_seen: false,
          orphan_notified: false,
          changes_requested_since: 0L,
          stall_notified: false,
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
