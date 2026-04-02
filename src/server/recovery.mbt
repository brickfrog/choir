///|
pub fn make_recovery_provider() -> @runtime.RecoveryProvider {
  @runtime.make_shell_recovery_provider(@exec.capture_stdout_with_cwd)
}

///|
pub async fn recover_state(
  state : ServerState,
  session : String,
  snapshot : @runtime.RecoverySnapshot,
) -> Unit {
  let plan = @runtime.plan_recovery(
    session,
    snapshot,
    state.recovery_provider.gh_poll_pr,
  )

  for action in plan.actions {
    match action {
      @runtime.RecoveryAction::RegisterAgent(agent, alive) =>
        state.apply_recovered_agent(agent, alive)
      @runtime.RecoveryAction::RestorePRTracking(tracked) =>
        state.restore_recovered_pr_tracking(tracked)
      @runtime.RecoveryAction::TrackNewPR(
        pr_number~,
        agent_id~,
        branch~,
        parent_branch~,
        pr_url~,
        review~,
        review_bodies~,
        sha~,
        ci_rollup~,
        created_at~
      ) =>
        state.track_recovered_pr(
          pr_number, agent_id, branch, parent_branch, pr_url, created_at, review,
          review_bodies, sha, ci_rollup,
        )
      @runtime.RecoveryAction::SyncLifecycle(agent_id~, pr~, review~) =>
        state.sync_recovered_pr_lifecycle(agent_id, pr, review)
      @runtime.RecoveryAction::FinalizeOfflineAgent(agent_id~) =>
        state.finalize_recovered_offline_agent(agent_id)
    }
  }

  state.persist_recovered_poller_state()
}

///|

///|
async test "discover_recovery_snapshot with mock provider" {
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
    gh_poll_pr: fn(_num) {
      (
        true,
        @poller.ReviewState::Approved,
        "sha1",
        @poller.CiRollupStatus::Success,
        "",
        true,
      )
    },
  }
  let snapshot = @runtime.discover_recovery_snapshot(
    mock_provider, "/tmp", "session",
  )
  assert_eq(snapshot.zellij_live.tabs, ["tab1"])
  assert_eq(snapshot.zellij_live.panes, ["pane1"])
  assert_eq(snapshot.open_prs.length(), 1)
  assert_eq(snapshot.open_prs[0].pr_number, 123)
  assert_eq(snapshot.local_agents.length(), 1)
  assert_eq(snapshot.local_agents[0].slug, "slug1")
}

///|
async test "plan_recovery reconciles local agents and open PRs" {
  let snapshot : @runtime.RecoverySnapshot = {
    zellij_live: { tabs: ["tab1"], panes: [] },
    open_prs: [
      {
        pr_number: 123,
        branch: "feat/x",
        base: "main",
        url: "https://gh.test/123",
        created_sec: Some(1000L),
      },
    ],
    local_agents: [
      {
        slug: "slug1",
        dir_name: "worktrees",
        agent: Some({
          agent_id: @types.AgentId("slug1"),
          role: @types.Role::Dev,
          agent_type: @types.AgentType::Pi,
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
    recovered_at: 2000L,
  }

  let plan = @runtime.plan_recovery("session", snapshot, async fn(_pr_number) {
    @async.sleep(0)
    (
      true,
      @poller.ReviewState::Approved,
      "sha1",
      @poller.CiRollupStatus::Success,
      "",
      true,
    )
  })

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
async test "plan_recovery handles offline agent and persisted PR" {
  let snapshot : @runtime.RecoverySnapshot = {
    zellij_live: { tabs: [], panes: [] },
    open_prs: [
      {
        pr_number: 456,
        branch: "feat/offline",
        base: "main",
        url: "https://gh.test/456",
        created_sec: Some(3000L),
      },
    ],
    local_agents: [
      {
        slug: "slug-off",
        dir_name: "worktrees",
        agent: Some({
          agent_id: @types.AgentId("slug-off"),
          role: @types.Role::Dev,
          agent_type: @types.AgentType::Pi,
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
      },
    ],
    recovered_at: 4000L,
  }

  let plan = @runtime.plan_recovery("session", snapshot, async fn(_pr_number) {
    @async.sleep(0)
    (
      true,
      @poller.ReviewState::None_,
      "",
      @poller.CiRollupStatus::Unknown,
      "",
      true,
    )
  })

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
