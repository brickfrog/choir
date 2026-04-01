///|

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
fn default_agent_type(role : @types.Role) -> @types.AgentType {
  match role {
    @types.Role::Root => @types.AgentType::Claude
    @types.Role::TL => @types.AgentType::Claude
    @types.Role::Dev => @types.AgentType::Gemini
    @types.Role::Worker => @types.AgentType::Gemini
  }
}

///|
fn is_local_target_alive(
  target : @types.LocalTarget?,
  session : String,
  zellij_live : @runtime.ZellijLiveTargets,
) -> Bool {
  match target {
    Some({ kind: @types.TargetKind::ZellijTab, session: s, name }) =>
      s == session && zellij_live.tabs.contains(name)
    Some({ kind: @types.TargetKind::ZellijPane, session: s, name }) =>
      s == session && zellij_live.panes.contains(name)
    None => false
  }
}

///|
fn recover_agent_from_local_config(
  project_dir : String,
  rel_workspace : String,
  fallback_slug : String,
  session : String,
  zellij_live : @runtime.ZellijLiveTargets,
) -> @types.Agent? {
  let config_path = project_dir +
    "/" +
    rel_workspace +
    "/.choir/config.local.toml"
  let content = @sys.read_file(config_path)
  if content == "" {
    return None
  }
  let local_cfg = match @config.parse_local_config(content) {
    Ok(cfg) => cfg
    Err(_) => return None
  }
  let role = local_cfg.role.unwrap_or(@types.Role::TL)
  let agent_id = local_cfg.agent_id.unwrap_or(fallback_slug)
  let branch = local_cfg.branch.unwrap_or(agent_id)
  let workspace = local_cfg.workspace.unwrap_or(rel_workspace)
  let alive = is_local_target_alive(
    local_cfg.terminal_target,
    session,
    zellij_live,
  )
  Some({
    agent_id: @types.AgentId(agent_id),
    role,
    agent_type: local_cfg.agent_type.unwrap_or(default_agent_type(role)),
    state: if alive {
      @types.AgentState::Active
    } else {
      @types.AgentState::Done
    },
    parent: local_cfg.parent_id,
    terminal_target: if alive {
      local_cfg.terminal_target
    } else {
      None
    },
    host: @types.Host::Local,
    workspace,
    branch,
    spawn_depth: local_cfg.spawn_depth.unwrap_or(0),
  })
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
async fn recover_local_agents(
  state : ServerState,
  session : String,
  zellij_live : @runtime.ZellijLiveTargets,
  dir_name : String,
) -> Unit {
  let project_dir = state.config.project_dir
  let output = capture_stdout(
    "sh",
    ["-c", "ls .choir/" + dir_name + "/ 2>/dev/null"],
    cwd=Some(project_dir),
  )
  for slug in split_lines(output) {
    let rel_workspace = ".choir/" + dir_name + "/" + slug
    match
      recover_agent_from_local_config(
        project_dir, rel_workspace, slug, session, zellij_live,
      ) {
      Some(agent) => {
        let alive = is_local_target_alive(
          agent.terminal_target,
          session,
          zellij_live,
        )
        match state.register_agent(agent) {
          Ok(_) =>
            if !alive {
              ignore(
                state.registry.set_alive(agent.agent_id.to_string(), false),
              )
              finalize_recovered_offline_agent(
                state,
                agent.agent_id.to_string(),
              )
            }
          Err(_) => ()
        }
      }
      None => ()
    }
  }
}

///|
fn inferred_next_round_from_lifecycle(lifecycle : @phase.DevLifecycle) -> Int {
  match lifecycle {
    @phase.DevLifecycle::ReviewOwned(
      state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
      ..
    ) => round + 1
    @phase.DevLifecycle::ChangesRequested(next_round~, ..) => next_round
    @phase.DevLifecycle::ExitRequestedDeferred(
      state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
      ..
    ) => round + 1
    _ => 1
  }
}

///|
fn recover_dev_lifecycle_for_pr(
  current : @phase.DevLifecycle,
  pr_number : Int,
  pr_url : String,
  review : @poller.ReviewState,
) -> @phase.DevLifecycle {
  let preserve_exit = match current {
    @phase.DevLifecycle::ExitRequestedDeferred(..) => true
    _ => false
  }
  match review {
    @poller.ReviewState::Approved =>
      if preserve_exit {
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        )
      } else {
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        )
      }
    @poller.ReviewState::ChangesRequested =>
      @phase.DevLifecycle::ChangesRequested(
        pr_number~,
        next_round=inferred_next_round_from_lifecycle(current),
      )
    @poller.ReviewState::Commented =>
      match current {
        @phase.DevLifecycle::ReviewOwned(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ExitRequestedDeferred(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(..) =>
          @phase.DevLifecycle::ExitRequestedDeferred(
            pr_number~,
            state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
          )
        _ =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
          )
      }
    @poller.ReviewState::None_ =>
      match current {
        @phase.DevLifecycle::ReviewOwned(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(
          pr_number=n,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
        ) if n == pr_number =>
          @phase.DevLifecycle::ExitRequestedDeferred(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~),
          )
        @phase.DevLifecycle::ExitRequestedDeferred(pr_number=n, ..) =>
          if n == pr_number {
            @phase.DevLifecycle::ExitRequestedDeferred(
              pr_number~,
              state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
            )
          } else {
            @phase.DevLifecycle::ReviewOwned(
              pr_number~,
              state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
            )
          }
        _ =>
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::OpenUnreviewed(url=pr_url),
          )
      }
  }
}

///|
fn sync_recovered_pr_lifecycle(
  state : ServerState,
  agent : @types.Agent,
  pr : @runtime.OpenPR,
  review : @poller.ReviewState,
) -> Unit {
  let lifecycle = state.current_lifecycle(agent.agent_id.to_string())
  let workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) =>
      @phase.WorkflowState::Dev(
        recover_dev_lifecycle_for_pr(dev, pr.pr_number, pr.url, review),
      )
    other => other
  }
  let recovered = {
    ..lifecycle,
    workflow,
    process: if agent.terminal_target is Some(_) {
      @phase.ProcessState::Connected
    } else {
      lifecycle.process
    },
  }
  ignore(state.persist_lifecycle(recovered))
  state.sync_parent_child_lifecycle(agent.agent_id.to_string(), recovered)
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
fn find_registered_agent_for_branch(
  state : ServerState,
  branch : String,
  preferred_agent_id? : String? = None,
) -> @types.Agent? {
  match preferred_agent_id {
    Some(agent_id) =>
      match state.registry.get(agent_id) {
        Ok(agent) => return Some(agent)
        Err(_) => ()
      }
    None => ()
  }
  match state.registry.get(branch) {
    Ok(agent) => Some(agent)
    Err(_) => {
      for agent in state.registry.list() {
        if agent.branch == branch {
          return Some(agent)
        }
      }
      None
    }
  }
}

///|
async fn recover_open_pr_tracking_with(
  state : ServerState,
  open_prs : Array[@runtime.OpenPR],
  persisted : Array[@poller.TrackedPR],
  recovered_at : Int64,
  snapshot : async (Int) -> (
    Bool,
    @poller.ReviewState,
    String,
    Bool,
    String,
    Bool,
  ),
) -> Unit {
  for pr in open_prs {
    let restored = find_persisted_tracked_pr(persisted, pr.pr_number, pr.branch)
    match
      find_registered_agent_for_branch(
        state,
        pr.branch,
        preferred_agent_id=restored.map(fn(tracked) { tracked.agent_id }),
      ) {
      Some(agent) =>
        match restored {
          Some(existing) => {
            state.poller.restore({
              ..existing,
              agent_id: agent.agent_id.to_string(),
              branch: pr.branch,
              parent_branch: pr.base,
              pr_url: pr.url,
            })
            sync_recovered_pr_lifecycle(
              state,
              agent,
              pr,
              existing.last_review_state,
            )
          }
          None => {
            let (_, review, sha, ci_failed, review_bodies, _) = snapshot(
              pr.pr_number,
            )
            state.poller.track_recovered(
              pr.pr_number,
              agent.agent_id.to_string(),
              pr.branch,
              pr.base,
              pr.url,
              match pr.created_sec {
                Some(created_sec) => created_sec
                None => recovered_at
              },
              review,
              review_bodies,
              sha,
              ci_failed,
            )
            sync_recovered_pr_lifecycle(state, agent, pr, review)
          }
        }
      None => ()
    }
  }
}

///|
pub async fn discover_recovery_snapshot(
  project_dir : String,
  session : String,
) -> @runtime.RecoverySnapshot {
  let zellij_live = @runtime.parse_zellij_live_targets(
    capture_stdout(
      "zellij",
      ["--session", session, "action", "list-panes", "--json", "-a", "-t", "-s"],
      cwd=Some(project_dir),
    ),
  )
  let open_pr_output = capture_stdout(
    "sh",
    [
      "-c", "gh pr list --json number,headRefName,baseRefName,url,createdAt --state open 2>/dev/null",
    ],
    cwd=Some(project_dir),
  )
  let open_prs = @runtime.parse_open_prs(open_pr_output)
  { zellij_live, open_prs, recovered_at: @poller.now_sec() }
}

///|
pub async fn recover_state(
  state : ServerState,
  session : String,
  snapshot : @runtime.RecoverySnapshot,
) -> Unit {
  let project_dir = state.config.project_dir
  recover_local_agents(state, session, snapshot.zellij_live, "worktrees")
  recover_local_agents(state, session, snapshot.zellij_live, "agents")
  recover_local_agents(state, session, snapshot.zellij_live, "inline")

  recover_open_pr_tracking_with(
    state,
    snapshot.open_prs,
    @poller.read_state_file(project_dir),
    snapshot.recovered_at,
    @poller.gh_poll_pr,
  )
  ignore(state.poller.write_state_file(project_dir))
}

///|

///|
test "recover_agent_from_local_config preserves pi agent type" {
  let root = "/tmp/choir-recovery-pi-" + @sys.get_pid().to_string()
  let workspace = "agent"
  ignore(@sys.system("rm -rf \"" + root + "\""))
  ignore(@sys.system("mkdir -p \"" + root + "/" + workspace + "/.choir\""))
  let content =
    #|role = "dev"
    #|agent_id = "main.pi-leaf"
    #|parent_id = "root"
    #|branch = "main.pi-leaf"
    #|parent_branch = "main"
    #|workspace = "/tmp/workspace"
    #|terminal_target = "zellij-tab:choir:pi-leaf"
    #|agent_type = "pi"
  ignore(
    @sys.write_file_sync(
      root + "/" + workspace + "/.choir/config.local.toml",
      content,
    ),
  )
  let agent = recover_agent_from_local_config(
    root,
    workspace,
    "fallback",
    "choir",
    { tabs: [], panes: [] },
  )
  ignore(@sys.system("rm -rf \"" + root + "\""))
  match agent {
    Some(recovered) => {
      assert_eq(recovered.agent_id.to_string(), "main.pi-leaf")
      assert_eq(recovered.agent_type, @types.AgentType::Pi)
      assert_eq(recovered.state, @types.AgentState::Done)
    }
    None => fail("expected recovered agent")
  }
}

///|
test "recover_agent_from_local_config supports inline metadata directories" {
  let root = "/tmp/choir-recovery-inline-" + @sys.get_pid().to_string()
  let rel_workspace = ".choir/inline/feature_x.worker"
  ignore(@sys.system("rm -rf \"" + root + "\""))
  ignore(@sys.system("mkdir -p \"" + root + "/" + rel_workspace + "/.choir\""))
  let content =
    #|role = "worker"
    #|agent_id = "feature/x.worker"
    #|parent_id = "root"
    #|branch = "feature/x.worker"
    #|parent_branch = "feature/x"
    #|workspace = "/repo"
    #|terminal_target = "zellij-pane:choir:worker"
    #|agent_type = "pi"
  ignore(
    @sys.write_file_sync(
      root + "/" + rel_workspace + "/.choir/config.local.toml",
      content,
    ),
  )
  let agent = recover_agent_from_local_config(
    root,
    rel_workspace,
    "fallback",
    "choir",
    { tabs: [], panes: [] },
  )
  ignore(@sys.system("rm -rf \"" + root + "\""))
  match agent {
    Some(recovered) => {
      assert_eq(recovered.agent_id.to_string(), "feature/x.worker")
      assert_eq(recovered.role, @types.Role::Worker)
      assert_eq(recovered.parent, Some("root"))
      assert_eq(recovered.branch, "feature/x.worker")
    }
    None => fail("expected recovered inline agent")
  }
}

///|
async test "recover_open_pr_tracking_with restores ownership using persisted agent id" {
  let project_dir = "/tmp/choir-recovery-pr-owner-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  ignore(@sys.system("mkdir -p \"" + project_dir + "/.choir/kv\""))
  let state = ServerState::new({
    ..@types.Config::default(),
    project_dir,
    terminal_session: "choir",
  })
  ignore(
    state.register_agent({
      agent_id: @types.AgentId("main.topic-v1"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Pi,
      parent: Some("root"),
      workspace: project_dir + "/.choir/worktrees/topic-leaf",
      branch: "main.topic-leaf",
      terminal_target: @types.LocalTarget::parse("zellij-tab:choir:topic-leaf"),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let persisted = [
    @poller.TrackedPR::{
      pr_number: 55,
      agent_id: "main.topic-v1",
      branch: "main.topic-leaf",
      parent_branch: "main",
      pr_url: "https://example.test/pr/55",
      first_seen: 100L,
      consecutive_failures: 0,
      backoff_until: 0L,
      last_review_state: @poller.ReviewState::Commented,
      last_review_bodies: "needs follow-up",
      last_sha: "abc",
      notified_parent: false,
      last_ci_failed: false,
      last_timeout_at: 0L,
    },
  ]
  recover_open_pr_tracking_with(
    state,
    [
      {
        pr_number: 55,
        branch: "main.topic-leaf",
        base: "main",
        url: "https://example.test/pr/55",
        created_sec: Some(100L),
      },
    ],
    persisted,
    200L,
    async fn(_pr_number) {
      @async.sleep(0)
      (true, @poller.ReviewState::None_, "", false, "", true)
    },
  )
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  match state.poller.get(55) {
    Some(tracked) => {
      assert_eq(tracked.agent_id, "main.topic-v1")
      assert_eq(tracked.branch, "main.topic-leaf")
    }
    None => fail("expected recovered tracked PR")
  }
}

///|
async test "recover_open_pr_tracking_with preserves fixes awaiting review and parent summary" {
  let project_dir = "/tmp/choir-recovery-review-owned-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  ignore(@sys.system("mkdir -p \"" + project_dir + "/.choir/kv\""))
  let state = ServerState::new({
    ..@types.Config::default(),
    project_dir,
    terminal_session: "choir",
  })
  let parent_id = "main.pi-tl"
  let child_id = "main.pi-review-leaf"
  let branch = "main.pi-review-leaf"
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch,
    agent_type: "pi",
    summary: @phase.ChildLifecycleSummary::Working,
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
          pr_number=61,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round=2),
        ),
      ),
    }),
  )
  ignore(
    state.register_agent({
      agent_id: @types.AgentId(child_id),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Pi,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/pi-review-leaf",
      branch,
      terminal_target: @types.LocalTarget::parse(
        "zellij-tab:choir:pi-review-leaf",
      ),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let persisted = [
    @poller.TrackedPR::{
      pr_number: 61,
      agent_id: child_id,
      branch,
      parent_branch: "main",
      pr_url: "https://example.test/pr/61",
      first_seen: 100L,
      consecutive_failures: 0,
      backoff_until: 0L,
      last_review_state: @poller.ReviewState::Commented,
      last_review_bodies: "follow up comments",
      last_sha: "def",
      notified_parent: false,
      last_ci_failed: false,
      last_timeout_at: 0L,
    },
  ]
  recover_open_pr_tracking_with(
    state,
    [
      {
        pr_number: 61,
        branch,
        base: "main",
        url: "https://example.test/pr/61",
        created_sec: Some(100L),
      },
    ],
    persisted,
    200L,
    async fn(_pr_number) {
      @async.sleep(0)
      (true, @poller.ReviewState::None_, "", false, "", true)
    },
  )
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) => {
      assert_eq(lifecycle.process, @phase.ProcessState::Connected)
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
          )
        ) => {
          assert_eq(pr_number, 61)
          assert_eq(round, 2)
        }
        other =>
          fail(
            "expected recovered review-owned lifecycle with pending fixes, got: " +
            other.to_string(),
          )
      }
    }
    None => fail("expected recovered child lifecycle")
  }
  match @phase.read_lifecycle(project_dir, parent_id) {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, ..)
        ) => {
          assert_eq(children.length(), 1)
          match children[0].summary {
            @phase.ChildLifecycleSummary::ReviewOwned(
              pr_number~,
              state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
            ) => {
              assert_eq(pr_number, 61)
              assert_eq(round, 2)
            }
            other =>
              fail(
                "expected parent to see recovered review-owned child summary, got: " +
                other.to_string(),
              )
          }
        }
        other =>
          fail(
            "expected supervising parent lifecycle, got: " + other.to_string(),
          )
      }
    None => fail("expected recovered parent lifecycle")
  }
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
}

///|
async test "recover_local_agents keeps offline review-owned agent mergeable but not active" {
  let project_dir = "/tmp/choir-recovery-offline-review-owned-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let rel_workspace = ".choir/worktrees/pi-review-leaf"
  let parent_id = "main.pi-tl"
  let child_id = "main.pi-review-leaf"
  let branch = "main.pi-review-leaf"
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
  ignore(
    @sys.system(
      "mkdir -p \"" +
      project_dir +
      "/.choir/kv\" \"" +
      project_dir +
      "/" +
      rel_workspace +
      "/.choir\"",
    ),
  )
  let content =
    #|role = "dev"
    #|agent_id = "main.pi-review-leaf"
    #|parent_id = "main.pi-tl"
    #|branch = "main.pi-review-leaf"
    #|parent_branch = "main"
    #|workspace = "/tmp/repo/.choir/worktrees/pi-review-leaf"
    #|terminal_target = "zellij-tab:choir:pi-review-leaf"
    #|agent_type = "pi"
  ignore(
    @sys.write_file_sync(
      project_dir + "/" + rel_workspace + "/.choir/config.local.toml",
      content,
    ),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch,
    agent_type: "pi",
    summary: @phase.ChildLifecycleSummary::Working,
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
          pr_number=72,
          state=@phase.ReviewOwnership::FixesAwaitingReview(round=3),
        ),
      ),
    }),
  )
  let state = ServerState::new({
    ..@types.Config::default(),
    project_dir,
    terminal_session: "choir",
  })
  recover_local_agents(state, "choir", { tabs: [], panes: [] }, "worktrees")
  match state.registry.get(child_id) {
    Ok(agent) => assert_eq(agent.state, @types.AgentState::Done)
    Err(e) => fail("expected recovered agent in registry: " + e.message())
  }
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) => {
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::RecoveredDone,
        ),
      )
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(
            pr_number~,
            state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
          )
        ) => {
          assert_eq(pr_number, 72)
          assert_eq(round, 3)
        }
        other =>
          fail(
            "expected offline recovered child to preserve review-owned workflow, got: " +
            other.to_string(),
          )
      }
    }
    None => fail("expected offline recovered child lifecycle")
  }
  match @phase.read_lifecycle(project_dir, parent_id) {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, ..)
        ) => {
          assert_eq(children.length(), 1)
          match children[0].summary {
            @phase.ChildLifecycleSummary::ReviewOwned(
              pr_number~,
              state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
            ) => {
              assert_eq(pr_number, 72)
              assert_eq(round, 3)
            }
            other =>
              fail(
                "expected parent to retain offline review-owned child summary, got: " +
                other.to_string(),
              )
          }
        }
        other =>
          fail(
            "expected supervising parent lifecycle, got: " + other.to_string(),
          )
      }
    None => fail("expected offline recovered parent lifecycle")
  }
  ignore(@sys.system("rm -rf \"" + project_dir + "\""))
}
