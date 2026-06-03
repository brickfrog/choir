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
test "allocate_wave_id sees an existing reservation index" {
  let project_dir = "/tmp/choir-wave-id-reservation-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  ignore(@sys.create_dir_all(project_dir))
  let now = 1776000000000L
  let pid = 4242
  let first = allocate_wave_id(project_dir, "audit-fix", now, pid)
  match
    save_wave_index(
      project_dir,
      WaveIndex::new(first, "feature-wave-telemetry", now, []),
    ) {
    Ok(_) => ()
    Err(e) => {
      ignore(@sys.rm_rf(project_dir))
      fail(e.message())
      return
    }
  }
  let second = allocate_wave_id(project_dir, "audit-fix", now, pid)
  assert_true(second != first)
  assert_true(second.has_prefix(first + "-"))
  ignore(@sys.rm_rf(project_dir))
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
        @debug.assert_eq(cmds[0].workdir, Some(project_dir))
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
      { ..@types.TaskContract::empty(), goal: "shared task", verify: ["true"] },
      { ..@types.TaskContract::empty(), goal: "shared task", verify: ["true"] },
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
    merge_strategy: None,
    depends_on: [],
    scaffold_commit: None,
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
test "fork_wave_validate_resolved_task_contracts rejects dev leaf without verify" {
  let args = {
    ..fork_wave_args_base(),
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "shared task" },
      { ..@types.TaskContract::empty(), goal: "shared task" },
    ],
  }
  match
    fork_wave_validate_resolved_task_contracts(
      args,
      wave_id=Some("wave-1776000000000-4242"),
    ) {
    Ok(_) => fail("expected missing verify rejection")
    Err(e) => {
      assert_true(e.message().contains("no verify command"))
      assert_true(e.message().contains("main.wave-1776000000000-4242-0"))
    }
  }
}

///|
test "fork_wave_validate_resolved_task_contracts accepts per-leaf verify" {
  let args = {
    ..fork_wave_args_base(),
    task_contracts: [
      { ..@types.TaskContract::empty(), verify: ["npm test"] },
      { ..@types.TaskContract::empty(), verify: ["cargo test"] },
    ],
  }
  match fork_wave_validate_resolved_task_contracts(args) {
    Ok(_) => ()
    Err(e) => fail("expected valid contracts: " + e.message())
  }
}

///|
test "fork_wave_validate_resolved_task_contracts rejects short arrays for all roles" {
  let worker_args = {
    ..fork_wave_args_base(),
    child_role: @types.Role::Worker,
    count: 2,
    tasks: ["worker one", "worker two"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "one" }],
  }
  match fork_wave_validate_resolved_task_contracts(worker_args) {
    Ok(_) => fail("expected short task_contracts rejection")
    Err(e) => {
      assert_true(e.message().contains("task count 2"))
      assert_true(e.message().contains("task_contracts length 1"))
    }
  }
  let task_args = {
    ..fork_wave_args_base(),
    child_role: @types.Role::TL,
    count: 2,
    tasks: ["only one"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "one" },
      { ..@types.TaskContract::empty(), goal: "two" },
    ],
  }
  match fork_wave_validate_resolved_task_contracts(task_args) {
    Ok(_) => fail("expected short tasks rejection")
    Err(e) => {
      assert_true(e.message().contains("task count 2"))
      assert_true(e.message().contains("tasks length 1"))
    }
  }
}

///|
test "fork_wave_spawn_plan embeds wave_id discriminator in shared leaf identity" {
  let args = {
    ..fork_wave_args_base(),
    count: 1,
    tasks: ["shared task"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "shared task" }],
  }
  let first = fork_wave_spawn_plan(
    args,
    0,
    None,
    "/proj",
    "choir",
    wave_id=Some("wave-1776000000000-4242"),
  )
  let second = fork_wave_spawn_plan(
    args,
    0,
    None,
    "/proj",
    "choir",
    wave_id=Some("wave-1776000000001-4242"),
  )
  assert_eq(first.spawned_count, 1)
  assert_eq(second.spawned_count, 1)
  let first_slug = first.spawned_slugs[0]
  let second_slug = second.spawned_slugs[0]
  assert_eq(first_slug, "wave-1776000000000-4242-0")
  assert_eq(second_slug, "wave-1776000000001-4242-0")
  assert_false(first_slug.contains("."))
  assert_false(second_slug.contains("."))
  assert_true(first_slug != second_slug)
  assert_true(first.agent_ids != second.agent_ids)
  assert_eq(first.agent_ids, "main.wave-1776000000000-4242-0")
  assert_eq(second.agent_ids, "main.wave-1776000000001-4242-0")
  let first_agent = fork_wave_spawned_registry_agent(
    first.spawned_specs[0],
    "/proj",
    "choir",
  )
  let second_agent = fork_wave_spawned_registry_agent(
    second.spawned_specs[0],
    "/proj",
    "choir",
  )
  assert_true(first_agent.branch != second_agent.branch)
  assert_true(first_agent.workspace != second_agent.workspace)
  assert_eq(first_agent.branch, "main.wave-1776000000000-4242-0")
  assert_eq(
    first_agent.workspace,
    "/proj/.choir/worktrees/wave-1776000000000-4242-0",
  )
  @debug.assert_eq(
    first_agent.terminal_target,
    Some(
      @workspace.local_target_for(
        "choir",
        "wave-1776000000000-4242-0",
        @types.IsolationMode::Worktree,
      ),
    ),
  )
}

///|
test "fork_wave_spawn_plan persists merge_strategy override to leaf local config" {
  let args = {
    ..fork_wave_args_base(),
    merge_strategy: Some(@types.MergeStrategy::Squash),
  }
  let plan = fork_wave_spawn_plan(args, 0, None, "/proj", "choir")
  let mut found = false
  for cmd in plan.cmds {
    if cmd.args.length() >= 3 && cmd.args[1] == "config.local.toml" {
      found = true
      assert_true(cmd.args[2].contains("merge_strategy = \"squash\""))
    }
  }
  assert_true(found)
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
    merge_strategy: None,
    depends_on: [],
    scaffold_commit: None,
  }
  let plan = fork_wave_spawn_plan(args, 0, None, "/p", "sess")
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.spawned_slugs[0], "alpha-beta")
  assert_eq(plan.spawned_slugs[1], "alpha-beta-1")
  assert_eq(plan.agent_ids, "pb.alpha-beta,pb.alpha-beta-1")
}

///|
test "fork_wave_spawn_plan disambiguates when a later raw slug matches an earlier emitted slug" {
  // tasks ["alpha beta", "alpha beta", "alpha beta 1"]: leaf 1's disambiguated
  // slug ("alpha-beta-1") equals leaf 2's raw slug. seen_slugs must track
  // EMITTED slugs, not just raw, so all three stay distinct.
  let args : ForkWaveArgs = {
    count: 3,
    tasks: ["alpha beta", "alpha beta", "alpha beta 1"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "alpha beta" },
      { ..@types.TaskContract::empty(), goal: "alpha beta" },
      { ..@types.TaskContract::empty(), goal: "alpha beta 1" },
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
    merge_strategy: None,
    depends_on: [],
    scaffold_commit: None,
  }
  let plan = fork_wave_spawn_plan(args, 0, None, "/p", "sess")
  assert_eq(plan.spawned_count, 3)
  let slugs = plan.spawned_slugs
  let unique : Map[String, Int] = {}
  for s in slugs {
    unique.set(s, 1)
  }
  assert_eq(unique.length(), 3)
}

///|
test "fork_wave_spawn_plan embeds wave_id discriminator in per-leaf task slugs" {
  let args : ForkWaveArgs = {
    count: 2,
    tasks: ["Implement Leaf A", "Implement Leaf B"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "Implement Leaf A" },
      { ..@types.TaskContract::empty(), goal: "Implement Leaf B" },
    ],
    has_per_leaf_tasks: true,
    parent_branch: "pb",
    caller_id: "pb.tl",
    slug_prefix: "feature/foo",
    agent_type: @types.AgentType::MoonPilot,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    depends_on: [],
    scaffold_commit: None,
  }
  let plan = fork_wave_spawn_plan(
    args,
    0,
    None,
    "/p",
    "sess",
    wave_id=Some("feature-foo-1776000000000-4242"),
  )
  assert_eq(
    plan.spawned_slugs[0],
    "feature-foo-implement-leaf-a-1776000000000-4242",
  )
  assert_eq(
    plan.spawned_slugs[1],
    "feature-foo-implement-leaf-b-1776000000000-4242",
  )
  assert_false(plan.spawned_slugs[0].contains("."))
  assert_false(plan.spawned_slugs[1].contains("."))
  assert_false(plan.spawned_slugs[0].contains("--"))
  assert_false(plan.spawned_slugs[1].contains("--"))
  assert_eq(
    plan.agent_ids,
    "pb.feature-foo-implement-leaf-a-1776000000000-4242,pb.feature-foo-implement-leaf-b-1776000000000-4242",
  )
}

///|
test "fork_wave_spawn_plan honors custom slug_prefix for per-leaf tasks" {
  let args : ForkWaveArgs = {
    count: 2,
    tasks: ["Implement Leaf A", "Implement Leaf B"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "Implement Leaf A" },
      { ..@types.TaskContract::empty(), goal: "Implement Leaf B" },
    ],
    has_per_leaf_tasks: true,
    parent_branch: "pb",
    caller_id: "pb.tl",
    slug_prefix: "sandbox",
    agent_type: @types.AgentType::MoonPilot,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    depends_on: [],
    scaffold_commit: None,
  }
  let plan = fork_wave_spawn_plan(args, 0, None, "/p", "sess")
  assert_eq(plan.spawned_slugs[0], "sandbox-implement-leaf-a")
  assert_eq(plan.spawned_slugs[1], "sandbox-implement-leaf-b")
  assert_eq(
    plan.agent_ids,
    "pb.sandbox-implement-leaf-a,pb.sandbox-implement-leaf-b",
  )
}

///|
test "fork_wave_spawn_plan flattens slash in slug_prefix for child slugs" {
  let args : ForkWaveArgs = {
    count: 2,
    tasks: ["Implement Leaf A", "Implement Leaf B"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "Implement Leaf A" },
      { ..@types.TaskContract::empty(), goal: "Implement Leaf B" },
    ],
    has_per_leaf_tasks: true,
    parent_branch: "pb",
    caller_id: "pb.tl",
    slug_prefix: "feature/foo",
    agent_type: @types.AgentType::MoonPilot,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    depends_on: [],
    scaffold_commit: None,
  }
  let plan = fork_wave_spawn_plan(args, 0, None, "/p", "sess")
  assert_eq(plan.spawned_slugs[0], "feature-foo-implement-leaf-a")
  assert_eq(plan.spawned_slugs[1], "feature-foo-implement-leaf-b")
  assert_eq(
    plan.agent_ids,
    "pb.feature-foo-implement-leaf-a,pb.feature-foo-implement-leaf-b",
  )
}

///|
test "fork_wave_spawn_plan leaves active collision rejection to preflight" {
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
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.skipped_count, 0)
  assert_eq(plan.skipped_ids, "")
  assert_eq(plan.agent_ids, "main.wave-0,main.wave-1")
  @debug.assert_eq(plan.spawned_slugs, ["wave-0", "wave-1"])
}

///|
test "fork_wave_spawn_plan leaves completing collision rejection to preflight" {
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
  assert_eq(plan.skipped_count, 0)
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.agent_ids, "main.wave-0,main.wave-1")
}

///|
async test "interpret_fork_wave_spawn_effect_phase rejects live canonical agent id collision" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "feature/parent.wave-0",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/w",
      branch: "feature/parent.wave-0",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("spawn commands must not run for a live id collision")
    []
  }
  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    { ..fork_wave_args_base(), parent_branch: "feature/parent" },
    "/proj",
    "choir",
    Some(reg),
    mock_capture_fork_wave_must_not_run,
    mock_git_capture_fork_wave_clean,
    runner,
  )
  assert_eq(spawn_plan.spawned_count, 0)
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("canonical_agent_id 'feature/parent.wave-0'"))
      assert_true(msg.contains("live"))
    }
    @types.Response::Ok(_) => fail("expected live id collision rejection")
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase preflights wave_id leaf identity" {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "feature/parent.wave-0",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/w",
      branch: "feature/parent.wave-0",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let args = {
    ..fork_wave_args_base(),
    count: 1,
    tasks: ["shared task"],
    task_contracts: [
      { ..@types.TaskContract::empty(), goal: "shared task", verify: ["true"] },
    ],
    parent_branch: "feature/parent",
  }
  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    Some(reg),
    mock_capture_fork_wave_must_not_run,
    mock_git_capture_fork_wave_clean,
    mock_runner_all_ok,
    wave_id=Some("wave-1776000000000-4242"),
  )
  assert_eq(spawn_plan.spawned_count, 1)
  assert_eq(spawn_plan.agent_ids, "feature/parent.wave-1776000000000-4242-0")
  match resp {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
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
  @debug.assert_eq(agent.parent, Some("main.tl"))
  assert_eq(agent.host, @types.Host::Local)
  assert_eq(agent.spawn_depth, 0)
  assert_eq(agent.branch, "main.wave-0")
  assert_eq(agent.workspace, "/proj/.choir/worktrees/wave-0")
  let expected_tt = @workspace.local_target_for(
    "choir",
    "wave-0",
    @types.IsolationMode::Worktree,
  )
  @debug.assert_eq(agent.terminal_target, Some(expected_tt))
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
fn fork_wave_test_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn fork_wave_event_has_string_field(
  event : @moontrace.Event,
  key : String,
  expected : String,
) -> Bool {
  match fork_wave_test_field_value(event.fields, key) {
    Some(value) => value == String::to_json(expected)
    None => false
  }
}

///|
fn fork_wave_event_is_no_zellij_tab_warn_for(
  event : @moontrace.Event,
  agent_id : String,
  slug : String,
  session : String,
) -> Bool {
  event.level == @moontrace.Level::Warn &&
  fork_wave_event_has_string_field(event, "event", "spawn_no_zellij_tab") &&
  fork_wave_event_has_string_field(event, "agent_id", agent_id) &&
  fork_wave_event_has_string_field(event, "slug", slug) &&
  fork_wave_event_has_string_field(event, "session", session)
}

///|
fn fork_wave_no_zellij_tab_warn_count(events : Array[@moontrace.Event]) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn {
      match fork_wave_test_field_value(event.fields, "event") {
        Some(value) =>
          if value == String::to_json("spawn_no_zellij_tab") {
            count = count + 1
          }
        None => ()
      }
    }
  }
  count
}

///|
fn fork_wave_no_zellij_tab_warn_event_for(
  events : Array[@moontrace.Event],
  agent_id : String,
  slug : String,
  session : String,
) -> @moontrace.Event? {
  for event in events {
    if fork_wave_event_is_no_zellij_tab_warn_for(event, agent_id, slug, session) {
      return Some(event)
    }
  }
  None
}

///|
fn assert_fork_wave_string_field(
  fields : Array[@moontrace.Field],
  key : String,
  expected : String,
) -> Unit raise {
  match fork_wave_test_field_value(fields, key) {
    Some(value) => @debug.assert_eq(value, String::to_json(expected))
    None => fail("expected moontrace field " + key)
  }
}

///|
fn fork_wave_single_leaf_args(slug_prefix : String) -> ForkWaveArgs {
  {
    ..fork_wave_args_base(),
    count: 1,
    tasks: ["shared task"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "shared task" }],
    slug_prefix,
  }
}

///|
async test "fork_wave post-spawn warns only when spawned tab has no resolvable pane" {
  let project_dir = "/tmp/choir-fork-wave-missing-pane-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let session = "choir-missing-pane-test"
  let args = fork_wave_single_leaf_args("no-tab")
  let plan = fork_wave_spawn_plan(args, 0, None, project_dir, session)
  let reg = @registry.AgentRegistry::new()
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  interpret_fork_wave_post_spawn(args, plan, project_dir, session, Some(reg), capture=async fn(
    cmd,
  ) {
    @async.sleep(0)
    if cmd.program == "zellij" {
      (0, "[]")
    } else {
      (0, "")
    }
  })
  @moontrace.clear_subscriber()
  let warn = match
    fork_wave_no_zellij_tab_warn_event_for(
      captured, "main.no-tab-0", "no-tab-0", session,
    ) {
    Some(event) => event
    None => fail("expected missing zellij tab warning")
  }
  assert_true(
    warn.message.contains("no resolvable zellij tab/pane after launch"),
  )
  assert_true(warn.message.contains("zellij new-tab no-op"))
  assert_true(warn.message.contains("immediate agent exit"))
  assert_fork_wave_string_field(warn.fields, "event", "spawn_no_zellij_tab")
  assert_fork_wave_string_field(warn.fields, "agent_id", "main.no-tab-0")
  assert_fork_wave_string_field(warn.fields, "slug", "no-tab-0")
  assert_fork_wave_string_field(warn.fields, "session", session)
  ignore(@sys.rm_rf(project_dir))

  let resolved_project_dir = "/tmp/choir-fork-wave-resolved-pane-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(resolved_project_dir))
  let resolved_session = "choir-resolved-pane-test"
  let resolved_args = fork_wave_single_leaf_args("resolved-tab")
  let resolved_plan = fork_wave_spawn_plan(
    resolved_args,
    0,
    None,
    resolved_project_dir,
    resolved_session,
  )
  let resolved_reg = @registry.AgentRegistry::new()
  let resolved_captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { resolved_captured.push(event) })
  interpret_fork_wave_post_spawn(
    resolved_args,
    resolved_plan,
    resolved_project_dir,
    resolved_session,
    Some(resolved_reg),
    capture=async fn(cmd) {
      @async.sleep(0)
      if cmd.program == "zellij" {
        (0, "[{\"id\":7,\"tab_name\":\"resolved-tab-0\",\"is_plugin\":false}]")
      } else {
        (0, "")
      }
    },
  )
  @moontrace.clear_subscriber()
  assert_eq(fork_wave_no_zellij_tab_warn_count(resolved_captured), 0)
  ignore(@sys.rm_rf(resolved_project_dir))
}

///|
async test "fork_wave post-spawn records server task contracts" {
  let project_dir = "/tmp/choir-fork-wave-contract-capture-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, None, project_dir, "choir")
  let reg = @registry.AgentRegistry::new()
  let captured : Map[String, @types.TaskContract] = {}
  interpret_fork_wave_post_spawn(
    args,
    plan,
    project_dir,
    "choir",
    Some(reg),
    capture=async fn(cmd) {
      @async.sleep(0)
      if cmd.program == "zellij" {
        (
          0, "[{\"id\":7,\"tab_name\":\"wave-0\",\"is_plugin\":false},{\"id\":8,\"tab_name\":\"wave-1\",\"is_plugin\":false}]",
        )
      } else {
        (0, "")
      }
    },
    record_task_contract=fn(agent_id, contract) {
      match contract {
        Some(value) => captured.set(agent_id, value)
        None => captured.remove(agent_id)
      }
    },
  )
  @debug.assert_eq(
    captured.get("main.wave-0"),
    Some({
      ..@types.TaskContract::empty(),
      goal: "shared task",
      verify: ["true"],
    }),
  )
  @debug.assert_eq(
    captured.get("main.wave-1"),
    Some({
      ..@types.TaskContract::empty(),
      goal: "shared task",
      verify: ["true"],
    }),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "fork_wave post-spawn does not clobber a live registry collision" {
  let project_dir = "/tmp/choir-fork-wave-live-collision-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, None, project_dir, "choir")
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.wave-0",
      role: @types.Role::Worker,
      agent_type: @types.AgentType::MoonPilot,
      parent: Some("main.tl"),
      workspace: "/tmp/existing-live",
      branch: "main.wave-0",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 4,
      state: @types.AgentState::Active,
    }),
  )
  interpret_fork_wave_post_spawn(args, plan, project_dir, "choir", Some(reg), capture=async fn(
    _cmd,
  ) {
    @async.sleep(0)
    (0, "[{\"id\":9,\"tab_name\":\"wave-1\",\"is_plugin\":false}]")
  })
  try reg.get("main.wave-0") catch {
    _ => fail("expected existing live agent to remain in registry")
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Worker)
      assert_eq(agent.agent_type, @types.AgentType::MoonPilot)
      assert_eq(agent.workspace, "/tmp/existing-live")
      assert_eq(agent.spawn_depth, 4)
      assert_eq(agent.state, @types.AgentState::Active)
      @debug.assert_eq(agent.terminal_target, None)
    }
  }
  try reg.get("main.wave-1") catch {
    _ => fail("expected non-colliding sibling to be registered")
  } noraise {
    agent => assert_eq(agent.role, @types.Role::Dev)
  }
  ignore(@sys.rm_rf(project_dir))
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
test "fork_wave beads policy warning is quiet for trivial main fork" {
  let args = {
    ..fork_wave_args_base(),
    count: 1,
    tasks: ["single"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "single" }],
    parent_branch: "main",
  }
  @debug.assert_eq(fork_wave_missing_beads_policy_warning(args), None)
}

///|
test "fork_wave beads policy warns for multi leaf missing ids" {
  let warning = fork_wave_missing_beads_policy_warning(fork_wave_args_base())
  match warning {
    Some(msg) => {
      assert_true(msg.contains("multi-leaf fork_wave"))
      assert_true(msg.contains("leaf 1"))
      assert_true(msg.contains("leaf 2"))
      assert_true(msg.contains("task_contracts"))
    }
    None => fail("expected missing beads warning")
  }
}

///|
test "fork_wave beads policy warns for feature branch single leaf" {
  let args = {
    ..fork_wave_args_base(),
    count: 1,
    tasks: ["single"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "single" }],
    parent_branch: "feature/beads",
  }
  let warning = fork_wave_missing_beads_policy_warning(args)
  match warning {
    Some(msg) => assert_true(msg.contains("feature-branch fork_wave"))
    None => fail("expected feature branch warning")
  }
}

///|
test "fork_wave beads policy accepts per leaf ids" {
  let args = {
    ..fork_wave_args_base(),
    task_contracts: [
      {
        ..@types.TaskContract::empty(),
        goal: "a",
        beads_issue_id: Some("choir-leaf-a"),
      },
      {
        ..@types.TaskContract::empty(),
        goal: "b",
        beads_issue_id: Some("choir-leaf-b"),
      },
    ],
  }
  @debug.assert_eq(fork_wave_missing_beads_policy_warning(args), None)
}

///|
test "fork_wave response carries beads policy warning" {
  let resp = fork_wave_response_with_beads_policy_warning(
    @types.Response::ok_values({ "status": "spawned".to_json() }),
    fork_wave_args_base(),
  )
  match resp {
    @types.Response::Ok(fields) =>
      match fields.get("warning") {
        Some(msg) => assert_true(msg.contains("beads policy warning"))
        None => fail("expected warning field")
      }
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "fork_wave_caller_spawn_depth_from_registry matches dispatch lookup" {
  @debug.assert_eq(fork_wave_caller_spawn_depth_from_registry(None, "x"), None)
  let reg = @registry.AgentRegistry::new()
  @debug.assert_eq(
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
  @debug.assert_eq(
    fork_wave_caller_spawn_depth_from_registry(Some(reg), "main.tl"),
    Some(5),
  )
}

///|
async fn mock_capture_fork_wave_must_not_run(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "zellij" &&
    (cmd.args.contains("new-tab") || cmd.args.contains("run")) {
    return (0, "")
  }
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
async fn mock_git_capture_fork_wave_scaffold_changed(
  program : String,
  args : Array[String],
) -> String {
  @async.sleep(0)
  if program != "git" {
    fail("unexpected program: " + program)
  }
  if args == ["-C", "/proj", "rev-parse", "--abbrev-ref", "HEAD"] {
    return "feature/parent\n"
  }
  if args == ["-C", "/proj", "status", "--porcelain", "--", "src/shared.mbt"] {
    return " M src/shared.mbt\n"
  }
  if args == ["-C", "/proj", "status", "--porcelain"] {
    return ""
  }
  if args == ["-C", "/proj", "rev-parse", "HEAD"] {
    return "1111111111111111111111111111111111111111\n"
  }
  if args == ["-C", "/proj", "log", "--oneline", "@{u}..HEAD"] {
    return ""
  }
  fail("unexpected git args: " + args.join(" "))
  ""
}

///|
async fn mock_git_capture_fork_wave_no_scaffold_change(
  program : String,
  args : Array[String],
) -> String {
  @async.sleep(0)
  if program != "git" {
    fail("unexpected program: " + program)
  }
  if args == ["-C", "/proj", "rev-parse", "--abbrev-ref", "HEAD"] {
    return "feature/parent\n"
  }
  if args == ["-C", "/proj", "status", "--porcelain"] {
    return ""
  }
  if args == ["-C", "/proj", "log", "--oneline", "@{u}..HEAD"] {
    return ""
  }
  if args == ["-C", "/proj", "rev-parse", "HEAD"] {
    return "1111111111111111111111111111111111111111\n"
  }
  if args == ["-C", "/proj", "status", "--porcelain", "--", "missing.mbt"] {
    return ""
  }
  fail("unexpected git args: " + args.join(" "))
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
async test "interpret_fork_wave_spawn_effect_phase commits scaffold before worktree add" {
  let runner_seq : Array[Int] = [0]
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    scaffold_commit: Some({
      message: "chore: scaffold shared wave surface",
      paths: ["src/shared.mbt"],
    }),
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let seq = runner_seq[0]
    runner_seq[0] = seq + 1
    if seq == 0 {
      assert_eq(cmds.length(), 3)
      assert_eq(cmds[0].program, "git")
      @debug.assert_eq(cmds[0].args, [
        "-C", "/proj", "add", "--", "src/shared.mbt",
      ])
      @debug.assert_eq(cmds[1].args, [
        "-C", "/proj", "commit", "-m", "chore: scaffold shared wave surface", "--",
        "src/shared.mbt",
      ])
      @debug.assert_eq(cmds[2].args, ["-C", "/proj", "push"])
      for cmd in cmds {
        assert_false(cmd.args.contains("worktree"))
      }
    } else if seq == 1 || seq == 2 {
      let mut saw_worktree_add = false
      for cmd in cmds {
        assert_false(cmd.program == "zellij")
        if cmd.program == "git" &&
          cmd.args.contains("worktree") &&
          cmd.args.contains("add") {
          saw_worktree_add = true
        }
      }
      assert_true(saw_worktree_add)
    } else {
      fail("unexpected extra runner invocation")
    }
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    mock_capture_fork_wave_must_not_run,
    mock_git_capture_fork_wave_scaffold_changed,
    runner,
  )
  assert_eq(spawn_plan.spawned_count, 2)
  assert_eq(runner_seq[0], 3)
  match resp {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("status"), Some("spawned"))
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase seeds agy shared cache once before leaves spawn" {
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    agent_type: @types.AgentType::Gemini,
  }
  let runner_seq : Array[Int] = [0]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let seq = runner_seq[0]
    runner_seq[0] = seq + 1
    match seq {
      0 => {
        assert_eq(cmds.length(), 1)
        assert_eq(
          cmds[0].program,
          @workspace.native_agy_shared_cache_validate_program,
        )
        @debug.assert_eq(cmds[0].args, ["/proj"])
        [1]
      }
      1 => {
        assert_eq(cmds.length(), 1)
        assert_eq(
          cmds[0].program,
          @workspace.native_agy_shared_cache_prepare_program,
        )
        @debug.assert_eq(cmds[0].args, ["/proj"])
        [0]
      }
      2 => {
        assert_eq(cmds.length(), 1)
        assert_eq(
          cmds[0].program,
          @workspace.native_agy_shared_cache_validate_program,
        )
        @debug.assert_eq(cmds[0].args, ["/proj"])
        [0]
      }
      3 | 4 => {
        assert_true(cmds.length() > 1)
        let mut seed_count = 0
        let mut eager_bootstrap_count = 0
        let mut first_worktree_add = -1
        for i = 0; i < cmds.length(); i = i + 1 {
          let cmd = cmds[i]
          assert_false(cmd.program == "zellij")
          if cmd.program ==
            @workspace.native_agy_shared_cache_seed_if_needed_program ||
            cmd.program == @workspace.native_agy_shared_cache_prepare_program ||
            cmd.program == @workspace.native_agy_shared_cache_validate_program {
            seed_count = seed_count + 1
          }
          if cmd.program == "env" && cmd.args.contains("agy") {
            eager_bootstrap_count = eager_bootstrap_count + 1
          }
          if first_worktree_add < 0 &&
            cmd.program == "git" &&
            cmd.args.contains("worktree") &&
            cmd.args.contains("add") {
            first_worktree_add = i
          }
        }
        assert_eq(seed_count, 0)
        assert_eq(eager_bootstrap_count, 0)
        assert_true(first_worktree_add >= 0)
        let statuses = []
        for _ in cmds {
          statuses.push(0)
        }
        statuses
      }
      _ => fail("unexpected extra runner invocation")
    }
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (0, "agy help")
    }
    if cmd.program == "env" && cmd.args.contains("agy") {
      @debug.assert_eq(cmd.workdir, Some("/proj"))
      return (0, "READY.")
    }
    if cmd.program == "zellij" &&
      (cmd.args.contains("new-tab") || cmd.args.contains("run")) {
      return (0, "")
    }
    fail("unexpected capture: " + cmd.to_string())
    (0, "")
  }

  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    capture,
    mock_git_capture_fork_wave_clean,
    runner,
  )

  assert_eq(runner_seq[0], 5)
  assert_eq(spawn_plan.spawned_count, 2)
  match resp {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("status"), Some("spawned"))
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase warns and spawns when agy seed revalidate fails" {
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    agent_type: @types.AgentType::Gemini,
  }
  let runner_seq : Array[Int] = [0]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let seq = runner_seq[0]
    runner_seq[0] = seq + 1
    match seq {
      0 => {
        assert_eq(cmds.length(), 1)
        assert_eq(
          cmds[0].program,
          @workspace.native_agy_shared_cache_validate_program,
        )
        [1]
      }
      1 => {
        assert_eq(cmds.length(), 1)
        assert_eq(
          cmds[0].program,
          @workspace.native_agy_shared_cache_prepare_program,
        )
        [0]
      }
      2 => {
        assert_eq(cmds.length(), 1)
        assert_eq(
          cmds[0].program,
          @workspace.native_agy_shared_cache_validate_program,
        )
        [1]
      }
      3 | 4 => {
        assert_true(cmds.length() > 1)
        let mut saw_worktree_add = false
        for cmd in cmds {
          assert_false(cmd.program == "zellij")
          if cmd.program == "git" &&
            cmd.args.contains("worktree") &&
            cmd.args.contains("add") {
            saw_worktree_add = true
          }
        }
        assert_true(saw_worktree_add)
        let statuses = []
        for _ in cmds {
          statuses.push(0)
        }
        statuses
      }
      _ => fail("unexpected extra runner invocation")
    }
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (0, "agy help")
    }
    if cmd.program == "env" && cmd.args.contains("agy") {
      return (0, "READY.")
    }
    if cmd.program == "zellij" &&
      (cmd.args.contains("new-tab") || cmd.args.contains("run")) {
      return (0, "")
    }
    fail("unexpected capture: " + cmd.to_string())
    (0, "")
  }

  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    capture,
    mock_git_capture_fork_wave_clean,
    runner,
  )

  assert_eq(runner_seq[0], 5)
  assert_eq(spawn_plan.spawned_count, 2)
  match resp {
    @types.Response::Ok(fields) =>
      match fields.get("warning") {
        Some(warning) => {
          assert_true(
            warning.contains("agy shared cache seed re-validate failed"),
          )
          assert_true(warning.contains("exit 1"))
          assert_false(warning.contains("transport error"))
        }
        None => fail("expected seed warning")
      }
    @types.Response::Err(msg) =>
      fail("seed failure must not abort fork_wave: " + msg)
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase fails loudly when agy is unavailable" {
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    agent_type: @types.AgentType::Gemini,
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (-1, "")
    }
    fail("unexpected capture: " + cmd.to_string())
    (0, "")
  }
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("spawn commands must not run when agy is unavailable")
    []
  }

  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    capture,
    mock_git_capture_fork_wave_clean,
    runner,
  )

  assert_eq(spawn_plan.spawned_count, 0)
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("agy binary"))
      assert_true(msg.contains("Antigravity IDE"))
    }
    @types.Response::Ok(_) => fail("expected agy availability failure")
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase compensates post-scaffold clean failure" {
  let runner_seq : Array[Int] = [0]
  let status_calls : Array[Int] = [0]
  let pre_sha = "1111111111111111111111111111111111111111"
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    scaffold_commit: Some({
      message: "chore: scaffold shared wave surface",
      paths: ["src/shared.mbt"],
    }),
  }
  let git_capture = async fn(
    program : String,
    git_args : Array[String],
  ) -> String {
    @async.sleep(0)
    if program != "git" {
      fail("unexpected program: " + program)
    }
    if git_args == ["-C", "/proj", "rev-parse", "--abbrev-ref", "HEAD"] {
      return "feature/parent\n"
    }
    if git_args == ["-C", "/proj", "log", "--oneline", "@{u}..HEAD"] {
      return ""
    }
    if git_args == ["-C", "/proj", "status", "--porcelain"] {
      let n = status_calls[0]
      status_calls[0] = n + 1
      return if n == 0 { " M src/shared.mbt\n" } else { "?? stray.mbt\n" }
    }
    if git_args == ["-C", "/proj", "rev-parse", "HEAD"] {
      return pre_sha + "\n"
    }
    if git_args ==
      ["-C", "/proj", "status", "--porcelain", "--", "src/shared.mbt"] {
      return " M src/shared.mbt\n"
    }
    fail("unexpected git args: " + git_args.join(" "))
    ""
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let seq = runner_seq[0]
    runner_seq[0] = seq + 1
    if seq == 0 {
      assert_eq(cmds.length(), 3)
      @debug.assert_eq(cmds[0].args, [
        "-C", "/proj", "add", "--", "src/shared.mbt",
      ])
      @debug.assert_eq(cmds[2].args, ["-C", "/proj", "push"])
    } else if seq == 1 {
      assert_eq(cmds.length(), 2)
      @debug.assert_eq(cmds[0].args, ["-C", "/proj", "reset", "--hard", pre_sha])
      @debug.assert_eq(cmds[1].args, [
        "-C", "/proj", "push", "--force-with-lease",
      ])
    } else {
      fail("unexpected extra runner invocation")
    }
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let (resp, _, _) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    mock_capture_fork_wave_must_not_run,
    git_capture,
    runner,
  )
  assert_eq(runner_seq[0], 2)
  assert_eq(status_calls[0], 2)
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("Working tree has uncommitted changes"))
      assert_true(msg.contains("stray.mbt"))
    }
    @types.Response::Ok(_) => fail("expected post-scaffold failure")
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase fails scaffold_commit nonexistent path loudly" {
  let runner_called : Array[Bool] = [false]
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    scaffold_commit: Some({
      message: "chore: scaffold shared wave surface",
      paths: ["missing.mbt"],
    }),
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    runner_called[0] = true
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let (resp, _, _) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    mock_capture_fork_wave_must_not_run,
    mock_git_capture_fork_wave_no_scaffold_change,
    runner,
  )
  assert_false(runner_called[0])
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("scaffold_commit path"))
      assert_true(msg.contains("missing.mbt"))
    }
    @types.Response::Ok(_) => fail("expected scaffold_commit failure")
  }
}

///|
async test "interpret_fork_wave_spawn_effect_phase fails loudly when scaffold commit fails" {
  let runner_seq : Array[Int] = [0]
  let args = {
    ..fork_wave_args_base(),
    parent_branch: "feature/parent",
    scaffold_commit: Some({
      message: "chore: scaffold shared wave surface",
      paths: ["src/shared.mbt"],
    }),
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" && cmd.args.contains("commit") {
      return (1, "nothing to commit\n")
    }
    fail("unexpected capture: " + cmd.to_string())
    (0, "")
  }
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let seq = runner_seq[0]
    runner_seq[0] = seq + 1
    if seq != 0 {
      fail("spawn commands must not run after scaffold commit failure")
    }
    assert_eq(cmds.length(), 3)
    [0, 1]
  }
  let (resp, _, _) = interpret_fork_wave_spawn_effect_phase(
    args,
    "/proj",
    "choir",
    None,
    capture,
    mock_git_capture_fork_wave_scaffold_changed,
    runner,
  )
  // Runner ran exactly once. The error path must NOT re-run the failing
  // scaffold command to capture stderr — re-execution of git
  // add/commit/push would be side-effectful (could succeed on the second
  // attempt while we report Err, leaving the repo mutated). Confirm the
  // error reports the failing argv from the original execution without a
  // second invocation.
  assert_eq(runner_seq[0], 1)
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("scaffold_commit command failed"))
      assert_true(msg.contains("argv:"))
      assert_true(msg.contains("commit"))
    }
    @types.Response::Ok(_) => fail("expected scaffold_commit failure")
  }
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
  let args = {
    ..fork_wave_args_base(),
    task_contracts: [
      {
        ..@types.TaskContract::empty(),
        goal: "shared task",
        beads_issue_id: Some("choir-leaf-a"),
        verify: ["true"],
      },
      {
        ..@types.TaskContract::empty(),
        goal: "shared task",
        beads_issue_id: Some("choir-leaf-b"),
        verify: ["true"],
      },
    ],
  }
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
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("count"), Some(Int::to_json(2)))
      @debug.assert_eq(
        map.get("agent_ids"),
        Some(String::to_json("topic.wave-0,topic.wave-1")),
      )
      @debug.assert_eq(map.get("role"), Some(String::to_json("dev")))
      @debug.assert_eq(map.get("agent_type"), Some(String::to_json("claude")))
      match map.get("agents") {
        Some(Array(agents)) => {
          assert_eq(agents.length(), 2)
          let first = agents[0].stringify()
          let second = agents[1].stringify()
          if !first.contains("\"agent_id\":\"topic.wave-0\"") {
            fail(first)
          }
          if !first.contains("\"beads_issue_id\":\"choir-leaf-a\"") {
            fail(first)
          }
          if !second.contains("\"agent_id\":\"topic.wave-1\"") {
            fail(second)
          }
          if !second.contains("\"beads_issue_id\":\"choir-leaf-b\"") {
            fail(second)
          }
        }
        _ => fail("expected agents metadata")
      }
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
      @debug.assert_eq(map.get("x"), Some(String::to_json("y")))
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
test "fork_wave_spawn_plan allows Failed agents after kill_agent to respawn" {
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
      state: @types.AgentState::Failed,
    }),
  )
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, Some(reg), "/proj", "choir")
  assert_eq(plan.skipped_count, 0)
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.skipped_ids, "")
  assert_eq(plan.agent_ids, "main.wave-0,main.wave-1")
  @debug.assert_eq(plan.spawned_slugs, ["wave-0", "wave-1"])
}

///|
test "fork_wave_spawn_plan allows Done agents to respawn" {
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
      state: @types.AgentState::Done,
    }),
  )
  let args = fork_wave_args_base()
  let plan = fork_wave_spawn_plan(args, 0, Some(reg), "/proj", "choir")
  assert_eq(plan.skipped_count, 0)
  assert_eq(plan.spawned_count, 2)
  assert_eq(plan.skipped_ids, "")
  assert_eq(plan.agent_ids, "main.wave-0,main.wave-1")
  @debug.assert_eq(plan.spawned_slugs, ["wave-0", "wave-1"])
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
