///|
test "fork_wave_leaf_task_with_review_context leaves task unchanged when absent" {
  assert_eq(fork_wave_leaf_task_with_review_context("do work", None), "do work")
  assert_eq(
    fork_wave_leaf_task_with_review_context("do work", Some("   ")),
    "do work",
  )
}

///|
test "fork_wave_leaf_task_with_review_context appends CHOIR_REVIEW_CONTEXT section" {
  let got = fork_wave_leaf_task_with_review_context(
    "base",
    Some("keep plan/interpret split"),
  )
  assert_true(got.contains("## CHOIR_REVIEW_CONTEXT"))
  assert_true(got.contains("keep plan/interpret split"))
  assert_true(got.has_prefix("base"))
}

///|
test "fork_wave_spawn_plan embeds review_context in each leaf task" {
  let args = { ..fork_wave_args_base(), review_context: Some("arch: foo") }
  let plan = fork_wave_spawn_plan(args, 0, None, "/proj", "choir")
  assert_eq(plan.spawned_count, 2)
  assert_true(plan.spawned_specs[0].task.contains("## CHOIR_REVIEW_CONTEXT"))
  assert_true(plan.spawned_specs[0].task.contains("arch: foo"))
  assert_true(plan.spawned_specs[1].task.contains("arch: foo"))
}

///|
async fn mock_runner_expect_copilot_reviewer_only(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  assert_eq(cmds.length(), 1)
  assert_eq(cmds[0].program, "gh")
  assert_eq(
    cmds[0],
    file_pr_copilot_reviewer_gh_command(21, "/tmp/copilot-fpr"),
  )
  [0]
}

///|
async test "interpret_file_pr_post_success requests copilot reviewer when pr_review" {
  let project_dir = "/tmp/copilot-fpr"
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
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
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    true,
    effects,
    None,
    None,
    mock_runner_expect_copilot_reviewer_only,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
}

///|
async test "interpret_file_pr_post_success posts copilot review comment then requests reviewer" {
  let file_pr_copilot_runner_seq : Array[Int] = [0]
  let project_dir = "/tmp/rc-fpr"
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: Some("plan/interpret split"),
  }
  let pr : PullRequestInfo = {
    number: 55,
    url: "https://example.test/pr/55",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    true,
    effects,
    None,
    None,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      assert_eq(cmds.length(), 1)
      let n = file_pr_copilot_runner_seq[0]
      file_pr_copilot_runner_seq[0] = n + 1
      assert_eq(cmds[0].program, "gh")
      if n == 0 {
        assert_eq(cmds[0].args[0], "pr")
        assert_eq(cmds[0].args[1], "comment")
        assert_eq(cmds[0].args[2], "55")
        assert_eq(cmds[0].args[3], "--body")
        assert_eq(
          cmds[0].args[4],
          file_pr_copilot_review_comment_body("plan/interpret split"),
        )
        assert_eq(cmds[0].workdir, Some(project_dir))
      } else if n == 1 {
        assert_eq(cmds[0], file_pr_copilot_reviewer_gh_command(55, project_dir))
      } else {
        fail("unexpected extra runner invocation for file_pr copilot")
      }
      [0]
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  assert_eq(file_pr_copilot_runner_seq[0], 2)
}

///|
async test "interpret_file_pr_post_success copilot review comment failure is best-effort" {
  let file_pr_copilot_runner_seq : Array[Int] = [0]
  let project_dir = "/tmp/rc-fpr-comment-fail"
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: Some("plan/interpret split"),
  }
  let pr : PullRequestInfo = {
    number: 55,
    url: "https://example.test/pr/55",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    true,
    effects,
    None,
    None,
    async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      assert_eq(cmds.length(), 1)
      let n = file_pr_copilot_runner_seq[0]
      file_pr_copilot_runner_seq[0] = n + 1
      if n == 0 {
        assert_eq(cmds[0].args[1], "comment")
        [1]
      } else if n == 1 {
        assert_eq(cmds[0].args[0], "pr")
        assert_eq(cmds[0].args[1], "edit")
        [0]
      } else {
        fail("unexpected extra runner invocation")
        []
      }
    },
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok despite comment failure")
  }
  assert_eq(file_pr_copilot_runner_seq[0], 2)
  let log = @sys.read_file(log_path)
  assert_true(log.contains("copilot_review_comment failed"))
  assert_true(log.contains("pr=55"))
}

///|
async fn mock_runner_copilot_uses_worktree_path(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let wt = "/tmp/pr-split-test/.choir/worktrees/agent"
  assert_eq(cmds.length(), 1)
  assert_eq(cmds[0], file_pr_copilot_reviewer_gh_command(99, wt))
  [0]
}

///|
async test "interpret_file_pr_post_success copilot gh uses file_pr_workdir" {
  let project_root = "/tmp/pr-split-test"
  let worktree = "/tmp/pr-split-test/.choir/worktrees/agent"
  assert_true(@sys.create_dir_all(project_root + "/.choir"))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 99,
    url: "https://example.test/pr/99",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_root,
    "choir",
    args.branch,
    args.tracked_agent_id,
    worktree,
    pr.number,
    true,
    effects,
    None,
    None,
    mock_runner_copilot_uses_worktree_path,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
}

///|
async fn mock_runner_reject_gh(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  for cmd in cmds {
    if cmd.program == "gh" {
      fail("unexpected gh when pr_review disabled")
    }
  }
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async test "interpret_file_pr_post_success skips copilot when pr_review false" {
  let project_dir = "/tmp/no-copilot-fpr"
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let args : FilePrArgs = {
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
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    false,
    effects,
    None,
    None,
    mock_runner_reject_gh,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
}

///|
async fn mock_runner_copilot_reviewer_gh_nonzero(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  assert_eq(cmds.length(), 1)
  assert_eq(cmds[0].program, "gh")
  [1]
}

///|
async test "interpret_file_pr_post_success copilot reviewer failure is best-effort" {
  let project_dir = "/tmp/copilot-fail-fpr"
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let log_path = project_dir + "/.choir/delivery.log"
  ignore(@sys.delete_file_sync(log_path))
  let args : FilePrArgs = {
    branch: "main.leaf",
    parent_branch: Some("main"),
    tracked_agent_id: "main.leaf",
    title: None,
    body: None,
    review_context: None,
  }
  let pr : PullRequestInfo = {
    number: 33,
    url: "https://example.test/pr/33",
    state: "OPEN",
  }
  let plan = file_pr_plan(args, "main", pr, false)
  let effects = file_pr_post_success_effects(plan, false, false)
  let got = interpret_file_pr_post_success(
    project_dir,
    "choir",
    args.branch,
    args.tracked_agent_id,
    project_dir,
    pr.number,
    true,
    effects,
    None,
    None,
    mock_runner_copilot_reviewer_gh_nonzero,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok despite gh failure")
  }
  let log = @sys.read_file(log_path)
  assert_true(log.contains("copilot_reviewer_request failed"))
  assert_true(log.contains("pr=33"))
}

///|
fn fork_wave_args_base() -> ForkWaveArgs {
  {
    count: 2,
    tasks: ["shared task", "shared task"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "shared task" },
      { ..@types.TaskContract::empty(), goal: "shared task" },
    ],
    has_per_leaf_tasks: false,
    parent_branch: "main",
    caller_id: "main.tl",
    slug_prefix: "wave",
    agent_type: @types.AgentType::Claude,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: None,
  }
}

///|
test "fork_wave_spawn_plan builds specs and agent_ids for shared-task wave" {
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, None, "/proj", "choir")
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.skipped_count, 0)
  assert_eq(plan.agent_ids, "main.wave-0,main.wave-1")
  assert_eq(plan.skipped_ids, "")
  assert_eq(plan.spawned_slugs.length(), 2)
  assert_eq(plan.spawned_slugs[0], "wave-0")
  assert_eq(plan.spawned_slugs[1], "wave-1")
  assert_eq(plan.spawned_specs.length(), 2)
  assert_eq(plan.spawned_specs[0].spawn_depth, 0)
  assert_eq(plan.spawned_specs[0].task, "shared task")
  assert_eq(plan.spawned_specs[1].task, "shared task")
  assert_true(plan.cmds.length() > 0)
}

///|
test "fork_wave_spawn_plan disambiguates duplicate raw slugs" {
  let args : ForkWaveArgs = {
    count: 2,
    tasks: ["alpha beta", "alpha beta"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "alpha beta" },
      { ..@types.TaskContract::empty(), goal: "alpha beta" },
    ],
    has_per_leaf_tasks: true,
    parent_branch: "pb",
    caller_id: "pb.tl",
    slug_prefix: "wave",
    agent_type: @types.AgentType::MoonPilot,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: None,
  }
  let plan = fork_wave_spawn_plan(args, 0, None, "/p", "sess")
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.spawned_slugs[0], "alpha-beta")
  assert_eq(plan.spawned_slugs[1], "alpha-beta-1")
  assert_eq(plan.agent_ids, "pb.alpha-beta,pb.alpha-beta-1")
}

///|
test "fork_wave_spawn_plan skips active agents and records skipped_ids" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.wave-0",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/w",
      branch: "main.wave-0",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, Some(reg), "/proj", "choir")
  assert_eq(plan.spawned_count, 1)
  assert_eq(plan.skipped_count, 1)
  assert_eq(plan.skipped_ids, "main.wave-0")
  assert_eq(plan.agent_ids, "main.wave-1")
  assert_eq(plan.spawned_slugs, ["wave-1"])
}

///|
test "fork_wave_spawn_plan skips completing agents" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.wave-0",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/w",
      branch: "main.wave-0",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Completing,
    }),
  )
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, Some(reg), "/proj", "choir")
  assert_eq(plan.skipped_count, 1)
  assert_eq(plan.spawned_count, 1)
}

///|
test "fork_wave_spawn_plan passes child_spawn_depth into specs" {
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 3, None, "/proj", "choir")
  assert_eq(plan.spawned_specs[0].spawn_depth, 3)
  assert_eq(plan.spawned_specs[1].spawn_depth, 3)
}

///|
test "fork_wave_spawned_registry_agent matches fork_wave spawn upsert shape" {
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, None, "/proj", "choir")
  let spec = plan.spawned_specs[0]
  let agent = fork_wave_spawned_registry_agent(spec, "/proj", "choir")
  assert_eq(agent.agent_id, "main.wave-0")
  assert_eq(agent.role, @types.Role::Dev)
  assert_eq(agent.agent_type, @types.AgentType::Claude)
  assert_eq(agent.state, @types.AgentState::Spawning)
  assert_eq(agent.parent, Some("main.tl"))
  assert_eq(agent.host, @types.Host::Local)
  assert_eq(agent.spawn_depth, 0)
  assert_eq(agent.branch, "main.wave-0")
  assert_eq(agent.workspace, "/proj/.choir/worktrees/wave-0")
  let expected_tt = @workspace.local_target_for(
    "choir",
    "wave-0",
    @types.IsolationMode::Worktree,
  )
  assert_eq(agent.terminal_target, Some(expected_tt))
}

///|
test "fork_wave_post_spawn_host_steps ordering" {
  let steps = fork_wave_post_spawn_host_steps()
  assert_eq(steps.length(), 3)
  assert_eq(steps[0], ForkWavePostSpawnHostStep::RegistryUpsertSpawnedSpecs)
  assert_eq(
    steps[1],
    ForkWavePostSpawnHostStep::PerSlugTeamRegisterAndTlEventAndPaneResolve,
  )
  assert_eq(
    steps[2],
    ForkWavePostSpawnHostStep::RegistryTerminalTargetUpsertFromPanes,
  )
}

///|
test "fork_wave_child_spawn_depth increments for TL child role" {
  assert_eq(fork_wave_child_spawn_depth(Some(2), @types.Role::TL), 3)
  assert_eq(fork_wave_child_spawn_depth(None, @types.Role::TL), 1)
}

///|
test "fork_wave_child_spawn_depth copies depth for non-TL" {
  assert_eq(fork_wave_child_spawn_depth(Some(4), @types.Role::Dev), 4)
  assert_eq(fork_wave_child_spawn_depth(None, @types.Role::Dev), 0)
}

///|
test "fork_wave_caller_spawn_depth_from_registry matches dispatch lookup" {
  assert_eq(fork_wave_caller_spawn_depth_from_registry(None, "x"), None)
  let reg = @registry.AgentRegistry::new()
  assert_eq(
    fork_wave_caller_spawn_depth_from_registry(Some(reg), "missing"),
    None,
  )
  ignore(
    reg.upsert({
      agent_id: "main.tl",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/w",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 5,
      state: @types.AgentState::Active,
    }),
  )
  assert_eq(
    fork_wave_caller_spawn_depth_from_registry(Some(reg), "main.tl"),
    Some(5),
  )
}

///|
async fn mock_capture_fork_wave_must_not_run(
  _cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  fail("unexpected capture when parent_branch is not main")
  (0, "")
}

///|
async test "fork_wave_resolve_args_parent_branch skips detection when not main" {
  let args = fork_wave_args_base()
  let got = fork_wave_resolve_args_parent_branch(
    { ..args, parent_branch: "develop" },
    "/proj",
    mock_capture_fork_wave_must_not_run,
  )
  assert_eq(got.parent_branch, "develop")
}

///|
async fn mock_capture_origin_topic(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (0, "origin/topic\n")
}

///|
async fn mock_git_capture_fork_wave_clean(
  _program : String,
  _args : Array[String],
) -> String {
  @async.sleep(0)
  ""
}

///|
async test "fork_wave_resolve_args_parent_branch resolves main via detect" {
  let args = fork_wave_args_base()
  let got = fork_wave_resolve_args_parent_branch(
    { ..args, parent_branch: "main" },
    "/proj",
    mock_capture_origin_topic,
  )
  assert_eq(got.parent_branch, "topic")
}

///|
async test "interpret_fork_wave_spawn_effect_phase resolves parent branch and returns spawned response" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/proj",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 2,
      state: @types.AgentState::Active,
    }),
  )
  let args = fork_wave_args_base()
  let (resp, resolved_args, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    { ..args, parent_branch: "main" },
    "/proj",
    "choir",
    Some(reg),
    mock_capture_origin_topic,
    mock_git_capture_fork_wave_clean,
    mock_runner_all_ok,
  )
  assert_eq(resolved_args.parent_branch, "topic")
  assert_eq(spawn_plan.spawned_count, 2)
  assert_eq(spawn_plan.spawned_specs[0].spawn_depth, 2)
  assert_eq(spawn_plan.spawned_specs[1].spawn_depth, 2)
  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("status"), Some(String::to_json("spawned")))
      assert_eq(map.get("count"), Some(Int::to_json(2)))
      assert_eq(
        map.get("agent_ids"),
        Some(String::to_json("topic.wave-0,topic.wave-1")),
      )
    }
    _ => fail("expected spawned ok response")
  }
}

///|
async test "fork_wave_response_from_interpret_result passes Ok through" {
  let ok = @types.Response::ok_values({ "x": String::to_json("y") })
  let got = fork_wave_response_from_interpret_result(Ok(ok), mock_capture_empty)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("x"), Some(String::to_json("y")))
    }
    _ => fail("expected ok passthrough")
  }
}

///|
async test "fork_wave_response_from_interpret_result maps UncommittedChanges" {
  let err = @tools.ForkWaveError::UncommittedChanges(output=" M x\n")
  let got = fork_wave_response_from_interpret_result(
    Err(err),
    mock_capture_empty,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, err.message())
    _ => fail("expected Err from uncommitted")
  }
}

///|
async fn mock_capture_stderr_for_false(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "false" {
    return (0, "boom\n")
  }
  (0, "")
}

///|
async test "fork_wave_response_from_interpret_result CommandFailed with stderr" {
  let failing : @workspace.Command = {
    program: "false",
    args: [],
    workdir: None,
  }
  let err = @tools.ForkWaveError::CommandFailed(
    status=9,
    failing_cmd=Some(failing),
  )
  let got = fork_wave_response_from_interpret_result(
    Err(err),
    mock_capture_stderr_for_false,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "spawn failed (exit 9): boom")
    _ => fail("expected spawn failed detail")
  }
}

///|
async fn mock_capture_always_empty(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (0, "")
}

///|
async test "fork_wave_response_from_interpret_result CommandFailed empty detail" {
  let failing : @workspace.Command = {
    program: "true",
    args: [],
    workdir: None,
  }
  let err = @tools.ForkWaveError::CommandFailed(
    status=3,
    failing_cmd=Some(failing),
  )
  let got = fork_wave_response_from_interpret_result(
    Err(err),
    mock_capture_always_empty,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "command failed with status 3")
    _ => fail("expected generic status err")
  }
}

///|
async test "fork_wave_response_from_interpret_result CommandFailed no cmd" {
  let err = @tools.ForkWaveError::CommandFailed(
    status=2,
    failing_cmd=(None : @workspace.Command?),
  )
  let got = fork_wave_response_from_interpret_result(
    Err(err),
    mock_capture_always_empty,
  )
  match got {
    @types.Response::Err(msg) => assert_eq(msg, "command failed with status 2")
    _ => fail("expected generic status err")
  }
}

///|
test "fork_wave_spawn_plan - enrichment_issue Some → task_contracts enriched" {
  let contract = @types.TaskContract::empty()
  let args = ForkWaveArgs::{
    count: 1,
    tasks: ["Task 1"],
    task_contracts: [contract],
    has_per_leaf_tasks: true,
    parent_branch: "main",
    caller_id: "parent",
    slug_prefix: "leaf",
    agent_type: @types.AgentType::Gemini,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: Some("123"),
  }
  let issue = @types.ChainlinkIssue::{
    id: 123,
    title: "Enriched Title",
    description: None,
    priority: "medium",
    status: "open",
    parent_id: None,
    labels: [],
    blocked_by: [],
    subissues: [],
    comments: [],
  }
  let plan = fork_wave_spawn_plan(
    args,
    0,
    None,
    ".",
    "session",
    chainlink_enrichment_issue=Some(issue),
  )
  assert_eq(plan.spawned_specs.length(), 1)
  match plan.spawned_specs[0].task_contract {
    Some(c) => assert_eq(c.goal, "Enriched Title")
    None => fail("expected task_contract")
  }
}

///|
test "fork_wave_spawn_plan - enrichment_issue None → task_contracts unchanged" {
  let contract = @types.TaskContract::{
    ..@types.TaskContract::empty(),
    goal: "Original",
  }
  let args = ForkWaveArgs::{
    count: 1,
    tasks: ["Task 1"],
    task_contracts: [contract],
    has_per_leaf_tasks: true,
    parent_branch: "main",
    caller_id: "parent",
    slug_prefix: "leaf",
    agent_type: @types.AgentType::Gemini,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: Some("123"),
  }
  let plan = fork_wave_spawn_plan(
    args,
    0,
    None,
    ".",
    "session",
    chainlink_enrichment_issue=None,
  )
  assert_eq(plan.spawned_specs.length(), 1)
  match plan.spawned_specs[0].task_contract {
    Some(c) => assert_eq(c.goal, "Original")
    None => fail("expected task_contract")
  }
}

///|
