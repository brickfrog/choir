///|
pub fn make_recovery_provider() -> @runtime.RecoveryProvider {
  {
    zellij_live: async fn(project_dir, session) {
      @runtime.parse_zellij_live_targets(
        capture_stdout(
          "zellij",
          [
            "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
          ],
          cwd=Some(project_dir),
        ),
      )
    },
    open_prs: async fn(project_dir) {
      let open_pr_output = capture_stdout(
        "sh",
        [
          "-c", "gh pr list --json number,headRefName,baseRefName,url,createdAt --state open 2>/dev/null",
        ],
        cwd=Some(project_dir),
      )
      @runtime.parse_open_prs(open_pr_output)
    },
    list_local_agents: async fn(project_dir, dir_name) {
      let output = capture_stdout(
        "sh",
        ["-c", "ls .choir/" + dir_name + "/ 2>/dev/null"],
        cwd=Some(project_dir),
      )
      split_lines(output)
    },
    read_local_config: async fn(project_dir, dir_name, slug) {
      capture_stdout(
        "sh",
        [
          "-c",
          "cat .choir/" +
          dir_name +
          "/" +
          slug +
          "/.choir/config.local.toml 2>/dev/null",
        ],
        cwd=Some(project_dir),
      )
    },
  }
}

///|
/// Query GitHub for an open PR whose head branch matches `branch`.
/// Returns (pr_number, pr_url) if found, None otherwise.
/// Used by the disconnect handler to recover agents that bypassed file_pr.
async fn find_pr_for_branch(
  branch : String,
  project_dir : String,
) -> (Int, String)? {
  if branch.trim() == "" {
    return None
  }
  let output = capture_stdout(
    "gh",
    [
      "pr", "list", "--head", branch, "--state", "open", "--json", "number,headRefName,baseRefName,url,createdAt",
    ],
    cwd=Some(project_dir),
  )
  let prs = @runtime.parse_open_prs(output)
  if prs.length() > 0 {
    Some((prs[0].pr_number, prs[0].url))
  } else {
    None
  }
}

///|
/// Scan lifecycle files for an agent whose DevLifecycle is ReviewOwned for
/// the given PR number. Used as a fallback when the poller doesn't track
/// the PR (e.g. after server restart).
fn find_agent_for_pr(project_dir : String, pr_number : Int) -> String? {
  let tmp = "/tmp/choir-find-pr-" + @sys.get_pid().to_string() + ".tmp"
  let cmd = "ls " +
    project_dir +
    "/.choir/kv/lifecycle--* 2>/dev/null > " +
    tmp +
    " 2>/dev/null"
  ignore(@sys.system(cmd))
  let output = @sys.read_file(tmp)
  ignore(@sys.delete_file_sync(tmp))
  let needle = "\"pr_number\":" + pr_number.to_string()
  for line in output.split("\n") {
    let path = line.trim().to_string()
    if path == "" {
      continue
    }
    let content = @sys.read_file(path)
    if content == "" || !content.contains(needle) {
      continue
    }
    let json = @json.parse(content) catch { _ => continue }
    let obj = match json {
      Object(m) => m
      _ => continue
    }
    match obj.get("agent_id") {
      Some(String(id)) => return Some(id)
      _ => ()
    }
  }
  None
}

///|
async fn capture_stdout(
  program : String,
  args : Array[String],
  cwd? : String? = None,
) -> String {
  let tmp = "/tmp/choir-recovery-" +
    @env.now().reinterpret_as_int64().to_string() +
    ".tmp"
  let shell_args = StringBuilder::new()
  shell_args.write_string(program)
  for arg in args {
    shell_args.write_string(" '")
    shell_args.write_string(arg)
    shell_args.write_string("'")
  }
  shell_args.write_string(" > '")
  shell_args.write_string(tmp)
  shell_args.write_string("' 2>/dev/null")
  let shell_cmd = shell_args.to_string()
  ignore(
    match cwd {
      Some(dir) =>
        @process.run("sh", ["-c", shell_cmd], cwd=dir) catch {
          _ => -1
        }
      None => @process.run("sh", ["-c", shell_cmd]) catch { _ => -1 }
    },
  )
  let result = @sys.read_file(tmp)
  ignore(@process.run("rm", ["-f", tmp]) catch { _ => -1 })
  result
}

///|
fn split_lines(output : String) -> Array[String] {
  let lines = []
  for raw in output.split("\n") {
    let line = raw.to_string().trim().to_string()
    if line != "" {
      lines.push(line)
    }
  }
  lines
}

///|
pub async fn discover_recovery_snapshot(
  provider : @runtime.RecoveryProvider,
  project_dir : String,
  session : String,
) -> @runtime.RecoverySnapshot {
  let zellij_live = (provider.zellij_live)(project_dir, session)
  let open_prs = (provider.open_prs)(project_dir)
  let local_agents = []
  for dir_name in ["worktrees", "agents", "inline"] {
    let slugs = (provider.list_local_agents)(project_dir, dir_name)
    for slug in slugs {
      let content = (provider.read_local_config)(project_dir, dir_name, slug)
      let agent = @runtime.parse_agent_from_config(
        content,
        ".choir/" + dir_name + "/" + slug,
        slug,
      )
      local_agents.push(@runtime.LocalAgentSnapshot::{ slug, dir_name, agent })
    }
  }
  { zellij_live, open_prs, local_agents, recovered_at: @poller.now_sec() }
}

///|
fn find_persisted_tracked_pr(
  persisted : Array[@poller.TrackedPR],
  pr_number : Int,
  branch : String,
) -> @poller.TrackedPR? {
  for tracked in persisted {
    if tracked.pr_number == pr_number && tracked.branch == branch {
      return Some(tracked)
    }
  }
  None
}

///|
fn find_registered_agent_for_branch_in_list(
  agents : Array[@types.Agent],
  branch : String,
  preferred_agent_id? : String? = None,
) -> @types.Agent? {
  match preferred_agent_id {
    Some(agent_id) =>
      for agent in agents {
        if agent.agent_id.to_string() == agent_id {
          return Some(agent)
        }
      }
    None => ()
  }
  for agent in agents {
    if agent.branch == branch || agent.agent_id.to_string() == branch {
      return Some(agent)
    }
  }
  None
}

///|
pub async fn plan_recovery(
  session : String,
  snapshot : @runtime.RecoverySnapshot,
  persisted_tracked_prs : Array[@poller.TrackedPR],
  gh_poll : async (Int) -> (
    Bool,
    @poller.ReviewState,
    String,
    Bool,
    String,
    Bool,
  ),
) -> @runtime.RecoveryPlan {
  let actions = []
  let recovered_agents = []

  // 1. Local agents
  for local_agent in snapshot.local_agents {
    match local_agent.agent {
      Some(agent) => {
        let alive = @runtime.is_local_target_alive(
          agent.terminal_target,
          session,
          snapshot.zellij_live,
        )
        let recovered = if alive {
          agent
        } else {
          { ..agent, state: @types.AgentState::Done, terminal_target: None }
        }
        recovered_agents.push(recovered)
        actions.push(@runtime.RecoveryAction::RegisterAgent(recovered, alive))
        if !alive {
          actions.push(
            @runtime.RecoveryAction::FinalizeOfflineAgent(
              agent_id=agent.agent_id.to_string(),
            ),
          )
        }
      }
      None => ()
    }
  }

  // 2. Open PRs
  for pr in snapshot.open_prs {
    let restored = find_persisted_tracked_pr(
      persisted_tracked_prs,
      pr.pr_number,
      pr.branch,
    )
    match
      find_registered_agent_for_branch_in_list(
        recovered_agents,
        pr.branch,
        preferred_agent_id=restored.map(fn(tracked) { tracked.agent_id }),
      ) {
      Some(agent) =>
        match restored {
          Some(existing) => {
            actions.push(
              @runtime.RecoveryAction::RestorePRTracking({
                ..existing,
                agent_id: agent.agent_id.to_string(),
                branch: pr.branch,
                parent_branch: pr.base,
                pr_url: pr.url,
              }),
            )
            actions.push(
              @runtime.RecoveryAction::SyncLifecycle(
                agent_id=agent.agent_id.to_string(),
                pr~,
                review=existing.last_review_state,
              ),
            )
          }
          None => {
            let (_, review, sha, ci_failed, review_bodies, _) = gh_poll(
              pr.pr_number,
            )
            actions.push(
              @runtime.RecoveryAction::TrackNewPR(
                pr_number=pr.pr_number,
                agent_id=agent.agent_id.to_string(),
                branch=pr.branch,
                parent_branch=pr.base,
                pr_url=pr.url,
                review~,
                review_bodies~,
                sha~,
                ci_failed~,
                created_at=match pr.created_sec {
                  Some(created_sec) => created_sec
                  None => snapshot.recovered_at
                },
              ),
            )
            actions.push(
              @runtime.RecoveryAction::SyncLifecycle(
                agent_id=agent.agent_id.to_string(),
                pr~,
                review~,
              ),
            )
          }
        }
      None => ()
    }
  }

  { actions, }
}

///|
fn finalize_recovered_offline_agent(
  state : ServerState,
  agent_id : String,
) -> Unit {
  let lifecycle = state.current_lifecycle(agent_id)
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => ()
    _ => {
      let finalized = {
        ..lifecycle,
        process: @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::RecoveredDone,
        ),
      }
      ignore(state.persist_lifecycle(finalized))
      state.sync_parent_child_lifecycle(agent_id, finalized)
    }
  }
}

///|
fn sync_recovered_pr_lifecycle(
  state : ServerState,
  agent_id : String,
  pr : @runtime.OpenPR,
  review : @poller.ReviewState,
) -> Unit {
  let agent_opt = state.registry.get(agent_id).to_option()
  let lifecycle = state.current_lifecycle(agent_id)
  let workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) =>
      @phase.WorkflowState::Dev(
        @runtime.recover_dev_lifecycle_for_pr(dev, pr.pr_number, pr.url, review),
      )
    other => other
  }
  let recovered = {
    ..lifecycle,
    workflow,
    process: match agent_opt {
      Some(agent) if agent.terminal_target is Some(_) =>
        @phase.ProcessState::Connected
      _ => lifecycle.process
    },
  }
  ignore(state.persist_lifecycle(recovered))
  state.sync_parent_child_lifecycle(agent_id, recovered)
}

///|
pub async fn recover_state(
  state : ServerState,
  session : String,
  snapshot : @runtime.RecoverySnapshot,
) -> Unit {
  let project_dir = state.config.project_dir
  let plan = plan_recovery(
    session,
    snapshot,
    @poller.read_state_file(project_dir),
    @poller.gh_poll_pr,
  )

  for action in plan.actions {
    match action {
      RegisterAgent(agent, alive) =>
        match state.register_agent(agent) {
          Ok(_) =>
            if !alive {
              ignore(
                state.registry.set_alive(agent.agent_id.to_string(), false),
              )
            }
          Err(_) => ()
        }
      RestorePRTracking(tracked) => state.poller.restore(tracked)
      TrackNewPR(
        pr_number~,
        agent_id~,
        branch~,
        parent_branch~,
        pr_url~,
        review~,
        review_bodies~,
        sha~,
        ci_failed~,
        created_at~
      ) =>
        state.poller.track_recovered(
          pr_number, agent_id, branch, parent_branch, pr_url, created_at, review,
          review_bodies, sha, ci_failed,
        )
      SyncLifecycle(agent_id~, pr~, review~) =>
        sync_recovered_pr_lifecycle(state, agent_id, pr, review)
      FinalizeOfflineAgent(agent_id~) =>
        finalize_recovered_offline_agent(state, agent_id)
    }
  }

  ignore(state.poller.write_state_file(project_dir))
}

///|

///|
async test "discover_recovery_snapshot with mock provider" {
  let mock_provider : @runtime.RecoveryProvider = {
    zellij_live: async fn(_dir, _session) {
      @async.sleep(0)
      @runtime.ZellijLiveTargets::{ tabs: ["tab1"], panes: ["pane1"] }
    },
    open_prs: async fn(_dir) {
      @async.sleep(0)
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
    list_local_agents: async fn(_dir, dir_name) {
      @async.sleep(0)
      if dir_name == "worktrees" {
        ["slug1"]
      } else {
        []
      }
    },
    read_local_config: async fn(_dir, _dir_name, _slug) {
      @async.sleep(0)
      let content =
        #|role = "dev"
        #|agent_id = "slug1"
        #|branch = "feat/x"
      content
    },
  }
  let snapshot = discover_recovery_snapshot(mock_provider, "/tmp", "session")
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
    recovered_at: 2000L,
  }

  let plan = plan_recovery("session", snapshot, [], async fn(_pr_number) {
    @async.sleep(0)
    (true, @poller.ReviewState::Approved, "sha1", false, "", true)
  })

  // Expect:
  // 1. RegisterAgent(slug1, alive=true)
  // 2. TrackNewPR(123, slug1, ...)
  // 3. SyncLifecycle(slug1, ...)

  let actions = plan.actions
  assert_eq(actions.length(), 3)

  match actions[0] {
    RegisterAgent(agent, alive) => {
      assert_eq(agent.agent_id.to_string(), "slug1")
      assert_true(alive)
      assert_eq(agent.state, @types.AgentState::Active)
    }
    _ => fail("expected RegisterAgent")
  }

  match actions[1] {
    TrackNewPR(pr_number~, agent_id~, ..) => {
      assert_eq(pr_number, 123)
      assert_eq(agent_id, "slug1")
    }
    _ => fail("expected TrackNewPR")
  }

  match actions[2] {
    SyncLifecycle(agent_id~, ..) => assert_eq(agent_id, "slug1")
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
    recovered_at: 4000L,
  }

  let persisted = [
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
      last_ci_failed: false,
      last_timeout_at: 0L,
    },
  ]

  let plan = plan_recovery("session", snapshot, persisted, async fn(
    _pr_number,
  ) {
    @async.sleep(0)
    (true, @poller.ReviewState::None_, "", false, "", true)
  })

  // Expect:
  // 1. RegisterAgent(slug-off, alive=false)
  // 2. FinalizeOfflineAgent(slug-off)
  // 3. RestorePRTracking(456, slug-off, ...)
  // 4. SyncLifecycle(slug-off, ...)

  let actions = plan.actions
  assert_eq(actions.length(), 4)

  match actions[0] {
    RegisterAgent(agent, alive) => {
      assert_eq(agent.agent_id.to_string(), "slug-off")
      assert_false(alive)
      assert_eq(agent.state, @types.AgentState::Done)
    }
    _ => fail("expected RegisterAgent")
  }

  match actions[1] {
    FinalizeOfflineAgent(agent_id~) => assert_eq(agent_id, "slug-off")
    _ => fail("expected FinalizeOfflineAgent")
  }

  match actions[2] {
    RestorePRTracking(tracked) => {
      assert_eq(tracked.pr_number, 456)
      assert_eq(tracked.agent_id, "slug-off")
    }
    _ => fail("expected RestorePRTracking")
  }

  match actions[3] {
    SyncLifecycle(agent_id~, pr~, ..) => {
      assert_eq(agent_id, "slug-off")
      assert_eq(pr.pr_number, 456)
    }
    _ => fail("expected SyncLifecycle")
  }
}
