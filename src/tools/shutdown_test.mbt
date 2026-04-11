///|
test "shutdown_missing_caller_response is best-effort ok" {
  let r = shutdown_missing_caller_response()
  match r {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected ok")
  }
}

///|
test "shutdown_poller_block_message matches dispatch wording" {
  assert_eq(
    shutdown_poller_block_message(42),
    "cannot shutdown: PR #42 has changes requested — push fixes first",
  )
}

///|
test "shutdown_intent_remove_choir_worktree matches choir worktree paths" {
  assert_true(
    shutdown_intent_remove_choir_worktree("/repo/.choir/worktrees/foo"),
  )
  assert_false(shutdown_intent_remove_choir_worktree("/repo"))
}

///|
fn kill_agent_test_agent(
  terminal_target : @types.LocalTarget?,
  workspace : String,
) -> @types.Agent {
  {
    agent_id: @types.AgentId("main.leaf"),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace,
    branch: "main.leaf",
    terminal_target,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
}

///|
test "kill_agent_pane_close_command is none without terminal_target" {
  let a = kill_agent_test_agent(None, "/repo")
  assert_eq(kill_agent_pane_close_command(a), None)
}

///|
test "kill_agent_pane_close_command matches local_close_target" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let a = kill_agent_test_agent(Some(t), "/repo")
  let expected = @workspace.local_close_target(t)
  match kill_agent_pane_close_command(a) {
    Some(cmd) => {
      assert_eq(cmd.program, expected.program)
      assert_eq(cmd.args, expected.args)
    }
    None => fail("expected close command")
  }
}

///|
test "kill_agent_worktree_remove_command follows choir worktree path rule" {
  let a = kill_agent_test_agent(None, "/proj/.choir/worktrees/slug-0")
  match kill_agent_worktree_remove_command(a) {
    Some(cmd) => {
      assert_eq(cmd.program, "git")
      assert_eq(cmd.args, [
        "worktree", "remove", "--force", "/proj/.choir/worktrees/slug-0",
      ])
    }
    None => fail("expected worktree remove")
  }
  let no_wt = kill_agent_test_agent(None, "/proj")
  assert_eq(kill_agent_worktree_remove_command(no_wt), None)
}

///|
test "kill_agent_ok_response matches killed envelope" {
  match kill_agent_ok_response("main.topic") {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("killed")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.topic")))
    }
    _ => fail("expected ok")
  }
}

///|
test "kill_agent_adapter_host_steps is pane close then worktree remove" {
  let steps = kill_agent_adapter_host_steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0], KillAgentAdapterHostStep::PaneClose)
  assert_eq(steps[1], KillAgentAdapterHostStep::WorktreeRemove)
}

///|
async test "interpret_kill_agent err when no registry" {
  let args : KillAgentArgs = { agent_id: "main.x", reason: "r" }
  let got = interpret_kill_agent(args, None, mock_runner_all_ok)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "no agent registry available")
    _ => fail("expected no-registry err")
  }
}

///|
async test "interpret_kill_agent err when agent missing" {
  let reg = @registry.AgentRegistry::new()
  let args : KillAgentArgs = { agent_id: "main.missing", reason: "r" }
  let got = interpret_kill_agent(args, Some(reg), mock_runner_all_ok)
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "agent not found: main.missing")
    _ => fail("expected not-found err")
  }
}

///|
async test "interpret_kill_agent closes pane, removes worktree, marks failed, returns killed" {
  let t = match @types.LocalTarget::parse("zellij-tab:choir:leaf") {
    Some(v) => v
    None => fail("expected parse")
  }
  let reg = @registry.AgentRegistry::new()
  let agent = kill_agent_test_agent(Some(t), "/proj/.choir/worktrees/slug-0")
  ignore(reg.upsert(agent))
  let args : KillAgentArgs = { agent_id: "main.leaf", reason: "cleanup" }
  let got = interpret_kill_agent(args, Some(reg), mock_runner_all_ok)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("killed")))
      assert_eq(map.get("agent_id"), Some(String::to_json("main.leaf")))
    }
    _ => fail("expected ok")
  }
  try reg.get("main.leaf") catch {
    _ => fail("expected agent in registry")
  } noraise {
    a => assert_eq(a.state, @types.AgentState::Failed)
  }
}

///|
async test "chainlink hooks run when local config exposes issue id" {
  let mut claimed_issue : String? = None
  let mut claimed_branch : String? = None
  let mut commented_issue : String? = None
  let mut commented_task : String? = None
  let fork_args : ForkWaveArgs = {
    ..fork_wave_args_base(),
    chainlink_issue_id: Some("5"),
  }
  let fork_plan : ForkWaveSpawnPlan = {
    cmds: [],
    spawned_specs: [
      {
        slug: "wave-0",
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: "shared task",
        task_contract: None,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main.tl",
        parent_branch: "main",
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
        automerge: None,
        review_mode: None,
        chainlink_issue_id: Some("5"),
      },
    ],
    spawned_slugs: [],
    spawned_count: 1,
    skipped_count: 0,
    agent_ids: "main.wave-0",
    skipped_ids: "",
  }
  interpret_fork_wave_post_spawn(
    fork_args,
    fork_plan,
    "/tmp",
    "choir",
    None,
    capture=mock_capture_empty,
    claim_lock=async fn(issue_id : String, branch : String) {
      @async.sleep(0)
      claimed_issue = Some(issue_id)
      claimed_branch = Some(branch)
      true
    },
    create_subissue=async fn(_parent_id : String, _title : String) {
      @async.sleep(0)
      fail("create_subissue should not run for single-leaf wave")
      None
    },
    write_plan_comment=async fn(issue_id : String, text : String) {
      @async.sleep(0)
      commented_issue = Some(issue_id)
      commented_task = Some(text)
    },
  )
  assert_eq(claimed_issue, Some("5"))
  assert_eq(claimed_branch, Some("main.wave-0"))
  assert_eq(commented_issue, Some("5"))
  assert_eq(commented_task, Some("shared task"))

  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let file_pr_args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 21,
    url: "https://example.test/pr/21",
    state: "OPEN",
  }
  let file_pr_plan_value = file_pr_plan(file_pr_args, "main", pr, false)
  let file_pr_effects = file_pr_post_success_effects(
    file_pr_plan_value, false, false,
  )
  let mut wrote_pr = false
  ignore(
    interpret_file_pr_post_success(
      project_dir,
      "choir",
      file_pr_args.branch,
      file_pr_args.tracked_agent_id,
      project_dir,
      pr.number,
      false,
      file_pr_effects,
      None,
      None,
      mock_runner_all_ok,
      read_chainlink_issue_id=mock_read_chainlink_issue_id_present,
      write_back_pr=async fn(
        issue_id : String,
        pr_url : String,
        pr_number : Int,
      ) {
        @async.sleep(0)
        assert_eq(issue_id, "5")
        assert_eq(pr_url, "https://example.test/pr/21")
        assert_eq(pr_number, 21)
        wrote_pr = true
      },
    ),
  )
  assert_true(wrote_pr)

  let poller = @poller.PollerState::new()
  poller.track(
    21, "main.leaf", "main.leaf", "main", "https://example.test/pr/21", 0L,
  )
  let mut wrote_merge = false
  let mut released_after_merge = false
  ignore(
    interpret_merge_pr_post_success(
      project_dir,
      "main.tl",
      21,
      Some(poller),
      None,
      read_chainlink_issue_id=mock_read_chainlink_issue_id_present,
      write_back_merge=async fn(
        issue_id : String,
        pr_number : Int,
        branch : String,
      ) {
        @async.sleep(0)
        assert_eq(issue_id, "5")
        assert_eq(pr_number, 21)
        assert_eq(branch, "main.leaf")
        wrote_merge = true
      },
      release_lock=async fn(issue_id : String) {
        @async.sleep(0)
        assert_eq(issue_id, "5")
        released_after_merge = true
        true
      },
    ),
  )
  assert_true(wrote_merge)
  assert_true(released_after_merge)

  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/proj/.choir/worktrees/leaf",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let mut released_after_kill = false
  ignore(
    interpret_kill_agent(
      { agent_id: "main.leaf", reason: "cleanup" },
      Some(reg),
      mock_runner_all_ok,
      read_chainlink_issue_id=mock_read_chainlink_issue_id_present,
      release_lock=async fn(issue_id : String) {
        @async.sleep(0)
        assert_eq(issue_id, "5")
        released_after_kill = true
        true
      },
    ),
  )
  assert_true(released_after_kill)
}

///|
async test "chainlink hooks are skipped when local config has no issue id" {
  let mut created = false
  let mut commented = false
  let fork_args = fork_wave_args_base()
  let fork_plan : ForkWaveSpawnPlan = {
    cmds: [],
    spawned_specs: [
      {
        slug: "wave-0",
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: "shared task",
        task_contract: None,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main.tl",
        parent_branch: "main",
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
        automerge: None,
        review_mode: None,
        chainlink_issue_id: None,
      },
    ],
    spawned_slugs: [],
    spawned_count: 1,
    skipped_count: 0,
    agent_ids: "main.wave-0",
    skipped_ids: "",
  }
  interpret_fork_wave_post_spawn(
    fork_args,
    fork_plan,
    "/tmp",
    "choir",
    None,
    capture=mock_capture_empty,
    claim_lock=async fn(_issue_id : String, _branch : String) {
      @async.sleep(0)
      fail("claim_lock should not run")
      false
    },
    create_subissue=async fn(_parent_id : String, _title : String) {
      @async.sleep(0)
      created = true
      None
    },
    write_plan_comment=async fn(_issue_id : String, _text : String) {
      @async.sleep(0)
      commented = true
    },
  )
  assert_false(created)
  assert_false(commented)

  let project_dir = file_pr_post_success_test_dir()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let file_pr_args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 22,
    url: "https://example.test/pr/22",
    state: "OPEN",
  }
  let file_pr_plan_value = file_pr_plan(file_pr_args, "main", pr, false)
  let file_pr_effects = file_pr_post_success_effects(
    file_pr_plan_value, false, false,
  )
  match
    interpret_file_pr_post_success(
      project_dir,
      "choir",
      file_pr_args.branch,
      file_pr_args.tracked_agent_id,
      project_dir,
      pr.number,
      false,
      file_pr_effects,
      None,
      None,
      mock_runner_all_ok,
      read_chainlink_issue_id=mock_read_chainlink_issue_id_absent,
      write_back_pr=async fn(
        _issue_id : String,
        _pr_url : String,
        _pr_number : Int,
      ) {
        @async.sleep(0)
        fail("write_back_pr should not run")
      },
    ) {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }

  let poller = @poller.PollerState::new()
  poller.track(
    22, "main.leaf", "main.leaf", "main", "https://example.test/pr/22", 0L,
  )
  match
    interpret_merge_pr_post_success(
      project_dir,
      "main.tl",
      22,
      Some(poller),
      None,
      read_chainlink_issue_id=mock_read_chainlink_issue_id_absent,
      write_back_merge=async fn(
        _issue_id : String,
        _pr_number : Int,
        _branch : String,
      ) {
        @async.sleep(0)
        fail("write_back_merge should not run")
      },
      release_lock=async fn(_issue_id : String) {
        @async.sleep(0)
        fail("release_lock should not run")
        false
      },
    ) {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }

  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/proj/.choir/worktrees/leaf",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  match
    interpret_kill_agent(
      { agent_id: "main.leaf", reason: "cleanup" },
      Some(reg),
      mock_runner_all_ok,
      read_chainlink_issue_id=mock_read_chainlink_issue_id_absent,
      release_lock=async fn(_issue_id : String) {
        @async.sleep(0)
        fail("release_lock should not run")
        false
      },
    ) {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
}

///|
async test "chainlink multi-leaf wave creates subissues and uses them for comment and lock" {
  let created_titles : Array[(String, String)] = []
  let commented : Array[(String, String)] = []
  let claimed : Array[(String, String)] = []
  let written_ids : Array[(String, String, String)] = []
  let long_task = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"
  let fork_plan : ForkWaveSpawnPlan = {
    cmds: [],
    spawned_specs: [
      {
        slug: "wave-0",
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: long_task,
        task_contract: None,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main.tl",
        parent_branch: "main",
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
        automerge: None,
        review_mode: None,
        chainlink_issue_id: Some("5"),
      },
      {
        slug: "wave-1",
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: "second task",
        task_contract: None,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main.tl",
        parent_branch: "main",
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
        automerge: None,
        review_mode: None,
        chainlink_issue_id: Some("5"),
      },
    ],
    spawned_slugs: [],
    spawned_count: 2,
    skipped_count: 0,
    agent_ids: "main.wave-0,main.wave-1",
    skipped_ids: "",
  }
  interpret_fork_wave_post_spawn(
    fork_wave_args_base(),
    fork_plan,
    "/tmp/project",
    "choir",
    None,
    capture=mock_capture_empty,
    create_subissue=async fn(parent_id : String, title : String) {
      @async.sleep(0)
      created_titles.push((parent_id, title))
      Some(if title == "second task" { 12 } else { 11 })
    },
    write_plan_comment=async fn(issue_id : String, text : String) {
      @async.sleep(0)
      commented.push((issue_id, text))
    },
    claim_lock=async fn(issue_id : String, branch : String) {
      @async.sleep(0)
      claimed.push((issue_id, branch))
      true
    },
    write_subissue_id=fn(
      project_dir : String,
      agent_slug : String,
      issue_id : String,
    ) {
      written_ids.push((project_dir, agent_slug, issue_id))
      true
    },
  )
  assert_eq(created_titles.length(), 2)
  assert_eq(created_titles[0], ("5", long_task[:80].to_string()))
  assert_eq(created_titles[1], ("5", "second task"))
  assert_eq(commented, [("11", long_task), ("12", "second task")])
  assert_eq(claimed, [("11", "main.wave-0"), ("12", "main.wave-1")])
  assert_eq(written_ids, [
    ("/tmp/project", "wave-0", "11"),
    ("/tmp/project", "wave-1", "12"),
  ])
}

///|
async test "chainlink multi-leaf wave falls back to parent issue when subissue creation fails" {
  let commented : Array[(String, String)] = []
  let claimed : Array[(String, String)] = []
  let mut wrote_subissue_id = false
  let fork_plan : ForkWaveSpawnPlan = {
    cmds: [],
    spawned_specs: [
      {
        slug: "wave-0",
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: "shared task",
        task_contract: None,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main.tl",
        parent_branch: "main",
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
        automerge: None,
        review_mode: None,
        chainlink_issue_id: Some("5"),
      },
      {
        slug: "wave-1",
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: "other task",
        task_contract: None,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main.tl",
        parent_branch: "main",
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
        automerge: None,
        review_mode: None,
        chainlink_issue_id: Some("5"),
      },
    ],
    spawned_slugs: [],
    spawned_count: 2,
    skipped_count: 0,
    agent_ids: "main.wave-0,main.wave-1",
    skipped_ids: "",
  }
  interpret_fork_wave_post_spawn(
    fork_wave_args_base(),
    fork_plan,
    "/tmp/project",
    "choir",
    None,
    capture=mock_capture_empty,
    create_subissue=async fn(_parent_id : String, _title : String) {
      @async.sleep(0)
      None
    },
    write_plan_comment=async fn(issue_id : String, text : String) {
      @async.sleep(0)
      commented.push((issue_id, text))
    },
    claim_lock=async fn(issue_id : String, branch : String) {
      @async.sleep(0)
      claimed.push((issue_id, branch))
      true
    },
    write_subissue_id=fn(
      _project_dir : String,
      _agent_slug : String,
      _issue_id : String,
    ) {
      wrote_subissue_id = true
      true
    },
  )
  assert_eq(commented, [("5", "shared task"), ("5", "other task")])
  assert_eq(claimed, [("5", "main.wave-0"), ("5", "main.wave-1")])
  assert_false(wrote_subissue_id)
}

///|
test "shutdown_exit_plan blocked dev changes requested" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=3, next_round=1),
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Err(msg) => assert_eq(msg, "Changes requested")
    _ => fail("expected Err")
  }
}

///|
test "shutdown_exit_plan deferred dev applies exit and skips cleanup" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=7,
        state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/7"),
      ),
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_false(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("deferred")))
      assert_eq(
        map.get("warning"),
        Some("PR filed (7) at https://ex/7".to_json()),
      )
    }
    _ => fail("expected deferred ok")
  }
}

///|
test "shutdown_exit_plan allowed dev allows cleanup and exit" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.l",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_true(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_exit_plan allowed tl skips dev exit but may cleanup worktree" {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
  }
  let plan = shutdown_exit_plan(lifecycle)
  assert_false(plan.apply_dev_exit_requested)
  assert_true(plan.attempt_worktree_cleanup)
  match plan.response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
}

///|
test "shutdown_adapter_host_steps lists poller through cleanup" {
  let steps = shutdown_adapter_host_steps()
  assert_eq(steps.length(), 5)
  assert_eq(steps[0], ShutdownAdapterHostStep::PollerCriticalPhaseRead)
  assert_eq(steps[1], ShutdownAdapterHostStep::RegistryRoleLookup)
  assert_eq(steps[2], ShutdownAdapterHostStep::LifecycleRead)
  assert_eq(steps[3], ShutdownAdapterHostStep::DevExitEventApply)
  assert_eq(steps[4], ShutdownAdapterHostStep::WorktreeCleanupAttempt)
}

///|
test "shutdown_poller_block_pr_number is none without poller" {
  assert_eq(shutdown_poller_block_pr_number(None, "main.leaf"), None)
}

///|
test "shutdown_poller_block_pr_number matches critical phase" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "main.leaf",
    "main.topic",
    "main",
    "https://ex/77",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), Some(77))
}

///|
test "shutdown_poller_block_pr_number is none when agent not in critical phase" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    77,
    "other.leaf",
    "main.topic",
    "main",
    "https://ex/77",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  assert_eq(shutdown_poller_block_pr_number(Some(ps), "main.leaf"), None)
}

///|
test "shutdown_registry_role_for_caller falls back to dev" {
  assert_eq(shutdown_registry_role_for_caller(None, "main.x"), @types.Role::Dev)
  let reg = @registry.AgentRegistry::new()
  assert_eq(
    shutdown_registry_role_for_caller(Some(reg), "main.x"),
    @types.Role::Dev,
  )
}

///|
test "shutdown_registry_role_for_caller uses registry role" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_eq(
    shutdown_registry_role_for_caller(Some(reg), "main.leaf"),
    @types.Role::TL,
  )
}

///|
async fn mock_shutdown_runner_record_worktree(
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
async test "interpret_shutdown blocks poller critical phase before plan" {
  let ps = @poller.PollerState::new()
  ps.track_recovered(
    5,
    "main.leaf",
    "b",
    "main",
    "https://ex/5",
    0L,
    @poller.ReviewState::ChangesRequested,
    "",
    "",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    "/tmp",
    Some(ps),
    None,
    mock_shutdown_runner_record_worktree,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, shutdown_poller_block_message(5))
    _ => fail("expected poller block")
  }
}

///|
async test "interpret_shutdown ok when caller missing uses best-effort" {
  let args : ShutdownArgs = { caller_id: None }
  let got = interpret_shutdown(
    args,
    "/tmp",
    None,
    None,
    mock_shutdown_runner_record_worktree,
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected missing-caller ok")
  }
}

///|
test "format_handoff_comment with pr_number Some" {
  let comment = format_handoff_comment(
    "leaf-0",
    @types.Role::Dev,
    "main.leaf-0",
    Some(42),
  )
  inspect(
    comment,
    content=(
      #|[leaf-0] [dev] shutdown
      #|branch: main.leaf-0
      #|pr: #42
    ),
  )
}

///|
test "format_handoff_comment with pr_number None" {
  let comment = format_handoff_comment(
    "worker-1",
    @types.Role::Worker,
    "main.worker-1",
    None,
  )
  inspect(
    comment,
    content=(
      #|[worker-1] [worker] shutdown
      #|branch: main.worker-1
      #|pr: (none)
    ),
  )
}

///|
test "format_handoff_comment with empty branch produces (unknown)" {
  let comment = format_handoff_comment(
    "inline-0",
    @types.Role::Worker,
    "",
    None,
  )
  inspect(
    comment,
    content=(
      #|[inline-0] [worker] shutdown
      #|branch: (unknown)
      #|pr: (none)
    ),
  )
}

///|
test "format_handoff_comment TL role" {
  let comment = format_handoff_comment(
    "tl-0",
    @types.Role::TL,
    "main.tl-0",
    Some(7),
  )
  inspect(
    comment,
    content=(
      #|[tl-0] [tl] shutdown
      #|branch: main.tl-0
      #|pr: #7
    ),
  )
}

///|
test "dev_lifecycle_pr_number extracts from ReviewOwned" {
  let lc = @phase.DevLifecycle::ReviewOwned(
    pr_number=10,
    state=@phase.ReviewOwnership::OpenUnreviewed(url="https://ex/10"),
  )
  assert_eq(dev_lifecycle_pr_number(lc), Some(10))
}

///|
test "dev_lifecycle_pr_number extracts from ChangesRequested" {
  let lc = @phase.DevLifecycle::ChangesRequested(pr_number=5, next_round=2)
  assert_eq(dev_lifecycle_pr_number(lc), Some(5))
}

///|
test "dev_lifecycle_pr_number extracts from ExitRequestedDeferred" {
  let lc = @phase.DevLifecycle::ExitRequestedDeferred(
    pr_number=3,
    state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
  )
  assert_eq(dev_lifecycle_pr_number(lc), Some(3))
}

///|
test "dev_lifecycle_pr_number returns None for Working" {
  assert_eq(dev_lifecycle_pr_number(@phase.DevLifecycle::Working), None)
}

///|
test "dev_lifecycle_pr_number returns None for Exitable" {
  assert_eq(dev_lifecycle_pr_number(@phase.DevLifecycle::Exitable), None)
}

///|
test "workflow_state_pr_number extracts from Dev workflow" {
  let ws = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=15,
      state=@phase.ReviewOwnership::OpenUnreviewed(url=""),
    ),
  )
  assert_eq(workflow_state_pr_number(ws), Some(15))
}

///|
test "workflow_state_pr_number extracts from Supervisor OwnPRFiled" {
  let ws = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::OwnPRFiled(number=22, url="https://ex/22"),
  )
  assert_eq(workflow_state_pr_number(ws), Some(22))
}

///|
test "workflow_state_pr_number returns None for Supervisor Planning" {
  let ws = @phase.WorkflowState::Supervisor(
    @phase.SupervisorLifecycle::Planning,
  )
  assert_eq(workflow_state_pr_number(ws), None)
}

///|
async test "interpret_shutdown handoff called when chainlink_issue_id present" {
  let project_dir = "/tmp/choir-shutdown-handoff-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))

  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main"),
      workspace: project_dir + "/.choir/worktrees/leaf",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  // Create the chainlink issue id file so chainlink_issue_id_for_agent_workspace returns Some
  assert_true(@sys.create_dir_all(project_dir + "/.choir/worktrees/leaf"))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/worktrees/leaf/.chainlink_issue_id",
      "42\n",
    ),
  )

  let mut captured_issue_id : String? = None
  let mut captured_comment : String? = None
  let injected_handoff = async fn(issue_id : String, comment : String) {
    @async.sleep(0)
    captured_issue_id = Some(issue_id)
    captured_comment = Some(comment)
  }

  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    project_dir,
    None,
    Some(reg),
    mock_shutdown_runner_record_worktree,
    chainlink_write_handoff=Some(injected_handoff),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
  assert_eq(captured_issue_id, Some("42"))
  match captured_comment {
    Some(c) => {
      assert_true(c.contains("[leaf] [dev] shutdown"))
      assert_true(c.contains("branch: main.leaf"))
      assert_true(c.contains("pr: (none)"))
    }
    None => fail("expected handoff comment to be captured")
  }
}

///|
async test "interpret_shutdown handoff NOT called when shutdown blocked" {
  let project_dir = "/tmp/choir-shutdown-blocked-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))

  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main"),
      workspace: project_dir + "/.choir/worktrees/leaf",
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  // Write a lifecycle that blocks shutdown (ChangesRequested)
  let blocking_lifecycle : @phase.AgentLifecycle = {
    agent_id: "main.leaf",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number=3, next_round=1),
    ),
  }
  assert_true(@phase.write_lifecycle(project_dir, blocking_lifecycle))

  let mut handoff_called = false
  let injected_handoff = async fn(_issue_id : String, _comment : String) {
    @async.sleep(0)
    handoff_called = true
  }

  let args : ShutdownArgs = { caller_id: Some("main.leaf") }
  let got = interpret_shutdown(
    args,
    project_dir,
    None,
    Some(reg),
    mock_shutdown_runner_record_worktree,
    chainlink_write_handoff=Some(injected_handoff),
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "Changes requested")
    _ => fail("expected blocked err")
  }
  assert_false(handoff_called)
}

///|
async test "interpret_shutdown handoff NOT called when chainlink_issue_id absent" {
  let project_dir = "/tmp/choir-shutdown-no-cl-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))

  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf2"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main"),
      workspace: project_dir + "/.choir/worktrees/leaf2",
      branch: "main.leaf2",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_true(@sys.create_dir_all(project_dir + "/.choir/worktrees/leaf2"))
  // No .chainlink_issue_id file → chainlink_issue_id_for_agent_workspace returns None

  let mut handoff_called = false
  let injected_handoff = async fn(_issue_id : String, _comment : String) {
    @async.sleep(0)
    handoff_called = true
  }

  let args : ShutdownArgs = { caller_id: Some("main.leaf2") }
  let got = interpret_shutdown(
    args,
    project_dir,
    None,
    Some(reg),
    mock_shutdown_runner_record_worktree,
    chainlink_write_handoff=Some(injected_handoff),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
  assert_false(handoff_called)
}

///|
async test "interpret_shutdown handoff includes pr_number from lifecycle" {
  let project_dir = "/tmp/choir-shutdown-prnum-" + @sys.get_pid().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))

  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf3"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main"),
      workspace: project_dir + "/.choir/worktrees/leaf3",
      branch: "main.leaf3",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  assert_true(@sys.create_dir_all(project_dir + "/.choir/worktrees/leaf3"))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/worktrees/leaf3/.chainlink_issue_id",
      "99\n",
    ),
  )
  // Write a lifecycle with a PR number (Exitable — exit policy is Allowed)
  let lc : @phase.AgentLifecycle = {
    agent_id: "main.leaf3",
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Exitable),
  }
  assert_true(@phase.write_lifecycle(project_dir, lc))

  let mut captured_comment : String? = None
  let injected_handoff = async fn(_issue_id : String, comment : String) {
    @async.sleep(0)
    captured_comment = Some(comment)
  }

  let args : ShutdownArgs = { caller_id: Some("main.leaf3") }
  let got = interpret_shutdown(
    args,
    project_dir,
    None,
    Some(reg),
    mock_shutdown_runner_record_worktree,
    chainlink_write_handoff=Some(injected_handoff),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("shutdown")))
    }
    _ => fail("expected shutdown ok")
  }
  match captured_comment {
    Some(c) => {
      assert_true(c.contains("[leaf3] [dev] shutdown"))
      assert_true(c.contains("branch: main.leaf3"))
      // Exitable has no pr_number
      assert_true(c.contains("pr: (none)"))
    }
    None => fail("expected handoff comment")
  }
}
