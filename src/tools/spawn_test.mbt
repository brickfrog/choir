///|
test "spawn_worker_ok_response matches spawned envelope" {
  match
    spawn_worker_ok_response(
      "main.w1",
      @types.AgentType::Codex,
      Some("choir-beads-live-smoke"),
    ) {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.w1")))
      @debug.assert_eq(map.get("agent_ids"), Some(String::to_json("main.w1")))
      @debug.assert_eq(map.get("role"), Some(String::to_json("worker")))
      @debug.assert_eq(map.get("agent_type"), Some(String::to_json("codex")))
      @debug.assert_eq(
        map.get("beads_issue_id"),
        Some(String::to_json("choir-beads-live-smoke")),
      )
      match map.get("agents") {
        Some(Array(agents)) => {
          assert_eq(agents.length(), 1)
          assert_true(
            agents[0]
            .stringify()
            .contains("\"beads_issue_id\":\"choir-beads-live-smoke\""),
          )
        }
        _ => fail("expected agents array")
      }
    }
    _ => fail("expected ok")
  }
}

///|
test "ensure_agy_migration_ready rejects incomplete Gemini migration" {
  match ensure_agy_migration_ready(true) {
    Err(e) =>
      assert_eq(
        e.message(),
        "config error: Gemini provider retired — agy migration incomplete",
      )
    Ok(_) => fail("expected agy migration gate rejection")
  }
  match ensure_agy_migration_ready(false) {
    Ok(_) => ()
    Err(e) => fail("unexpected agy migration gate error: " + e.message())
  }
}

///|
async test "dispatch rejects spawn_gemini when agy migration is incomplete" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "gem",
    parent_branch: "main",
    parent_session_id: None,
  }
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("runner should not run when agy gate rejects")
  }
  let got = dispatch(
    ToolRequest::SpawnGemini(spawn_args),
    runner~,
    agy_migration_incomplete=true,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(
        msg, "config error: Gemini provider retired — agy migration incomplete",
      )
    _ => fail("expected spawn_gemini agy gate error")
  }
}

///|
async test "dispatch rejects fork_wave gemini when agy migration is incomplete" {
  let args : ForkWaveArgs = {
    count: 1,
    tasks: ["t"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "t" }],
    has_per_leaf_tasks: false,
    parent_branch: "main",
    caller_id: "main.tl",
    slug_prefix: "g",
    agent_type: @types.AgentType::Gemini,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    model: None,
    depends_on: [],
    scaffold_commit: None,
  }
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("runner should not run when agy gate rejects")
  }
  let got = dispatch(
    ToolRequest::ForkWave(args),
    runner~,
    agy_migration_incomplete=true,
  )
  match got {
    @types.Response::Err(msg) =>
      assert_eq(
        msg, "config error: Gemini provider retired — agy migration incomplete",
      )
    _ => fail("expected fork_wave agy gate error")
  }
}

///|
test "spawn_worker_plan builds default dedicated-tab worker spec registry row and response" {
  let worker_args : WorkerSpawnArgs = {
    task: "t",
    task_contract: {
      ..@types.TaskContract::empty(),
      goal: "t",
      beads_issue_id: Some("choir-issue-1"),
    },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::MoonPilot,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let plan = spawn_worker_plan(worker_args, "develop", "sess", "/proj")
  assert_eq(plan.agent_id, "develop.w1")
  assert_eq(plan.spec.parent_branch, "develop")
  assert_eq(plan.spec.slug, "w1")
  assert_eq(plan.spec.role, @types.Role::Worker)
  assert_eq(plan.spec.isolation, @types.IsolationMode::InlineDedicatedTab)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.spawn_depth, 0)
  let expected_tt = @workspace.local_target_for(
    "sess",
    "w1",
    @types.IsolationMode::InlineDedicatedTab,
  )
  assert_eq(plan.terminal_target, expected_tt)
  assert_eq(plan.registry_agent.role, @types.Role::Worker)
  assert_eq(plan.registry_agent.agent_type, @types.AgentType::MoonPilot)
  assert_eq(plan.registry_agent.workspace, "/proj")
  assert_eq(plan.registry_agent.branch, "develop.w1")
  assert_eq(plan.registry_agent.state, @types.AgentState::Active)
  match plan.registry_agent.parent {
    Some(p) => assert_eq(p, "main.tl")
    None => fail("expected parent")
  }
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("develop.w1")))
      @debug.assert_eq(
        map.get("agent_type"),
        Some(String::to_json("moon_pilot")),
      )
      @debug.assert_eq(map.get("role"), Some(String::to_json("worker")))
      @debug.assert_eq(
        map.get("beads_issue_id"),
        Some(String::to_json("choir-issue-1")),
      )
    }
    _ => fail("expected ok")
  }
}

///|
test "spawn_worker_plan inline dedicated tab targets zellij tab" {
  let worker_args : WorkerSpawnArgs = {
    task: "audit",
    task_contract: { ..@types.TaskContract::empty(), goal: "audit" },
    caller_id: "main.tl",
    slug: "audit-worker",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let plan = spawn_worker_plan(
    worker_args,
    "main",
    "choir-session",
    "/project",
    isolation=@types.IsolationMode::InlineDedicatedTab,
  )
  assert_eq(plan.spec.isolation, @types.IsolationMode::InlineDedicatedTab)
  assert_eq(plan.spec.isolation.to_string(), "inline_dedicated_tab")
  assert_eq(plan.terminal_target.kind, @types.TargetKind::ZellijTab)
  assert_eq(plan.terminal_target.session, "choir-session")
  assert_eq(plan.terminal_target.name, "audit-worker")
}

///|
test "spawn_worker_plan inline dedicated tab keeps project workspace" {
  let worker_args : WorkerSpawnArgs = {
    task: "audit",
    task_contract: { ..@types.TaskContract::empty(), goal: "audit" },
    caller_id: "main.tl",
    slug: "audit-worker",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let plan = spawn_worker_plan(
    worker_args,
    "main",
    "choir-session",
    "/project",
    isolation=@types.IsolationMode::InlineDedicatedTab,
  )
  assert_eq(plan.registry_agent.workspace, "/project")
  assert_eq(plan.registry_agent.branch, "main.audit-worker")
}

///|
test "spawn_worker_plan keeps default review worker in project workspace" {
  let worker_args : WorkerSpawnArgs = {
    task: "read-only review",
    task_contract: { ..@types.TaskContract::empty(), goal: "review branch" },
    caller_id: "main.tl",
    slug: "audit-worker",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Review,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let plan = spawn_worker_plan(
    worker_args, "feature/review-target", "choir-session", "/project",
  )
  assert_eq(plan.spec.isolation, @types.IsolationMode::InlineDedicatedTab)
  assert_eq(plan.registry_agent.workspace, "/project")
  assert_eq(plan.registry_agent.branch, "feature/review-target.audit-worker")
}

///|
test "spawn_worker_plan isolates opt-in review worker in review namespace" {
  let worker_args : WorkerSpawnArgs = {
    task: "review branch with mutation probes",
    task_contract: { ..@types.TaskContract::empty(), goal: "review branch" },
    caller_id: "main.tl",
    slug: "audit-worker",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Review,
    parent_branch: Some("feature/review-target"),
    isolation: Some(@types.IsolationMode::Worktree),
    model: None,
  }
  let plan = spawn_worker_plan(
    worker_args, "feature/review-target", "choir-session", "/project",
  )
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(
    plan.registry_agent.workspace,
    "/project/.choir/review-worktrees/feature_review-target.audit-worker",
  )
  assert_false(plan.registry_agent.workspace == "/project")
  assert_false(
    plan.registry_agent.workspace == "/project/.choir/worktrees/audit-worker",
  )
  assert_false(
    plan.registry_agent.workspace == "/project/.choir/worktrees/live-leaf",
  )
}

///|
test "launch_commands inline dedicated tab uses zellij new-tab" {
  let cmds = @workspace.launch_commands(
    "choir-session",
    "audit-worker",
    "/project",
    [],
    { program: "echo", args: ["READY"], workdir: None },
    @types.IsolationMode::InlineDedicatedTab,
  )
  assert_eq(cmds.length(), 1)
  let cmd = cmds[0]
  assert_eq(cmd.program, "zellij")
  assert_eq(cmd.args[0], "--session")
  assert_eq(cmd.args[1], "choir-session")
  assert_eq(cmd.args[2], "action")
  assert_eq(cmd.args[3], "new-tab")
  assert_eq(cmd.args[4], "--name")
  assert_eq(cmd.args[5], "audit-worker")
  assert_false(cmd.args[2] == "run")
}

///|
fn spawn_test_agent_token_output() -> String {
  "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 10 21 32 43 54 65 76 87 98 a9 ba cb dc ed fe 0f\n"
}

///|
fn spawn_test_is_agent_token_command(cmd : @workspace.Command) -> Bool {
  cmd.program == "od" && cmd.args == ["-An", "-tx1", "-N32", "/dev/urandom"]
}

///|
async fn spawn_test_mint_agent_token() -> Result[String, @types.ChoirError] {
  @async.sleep(0)
  Ok("spawn-test-token")
}

///|
async fn mock_capture_origin_main(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if spawn_test_is_agent_token_command(cmd) {
    return (0, spawn_test_agent_token_output())
  }
  (0, "origin/main\n")
}

///|
fn upsert_spawn_test_root(reg : @registry.AgentRegistry) -> Unit {
  upsert_spawn_test_parent_with_role(reg, "root", @types.Role::TL)
}

///|
fn upsert_spawn_test_parent(
  reg : @registry.AgentRegistry,
  agent_id : String,
) -> Unit {
  upsert_spawn_test_parent_with_role(reg, agent_id, @types.Role::TL)
}

///|
fn upsert_spawn_test_parent_with_role(
  reg : @registry.AgentRegistry,
  agent_id : String,
  role : @types.Role,
) -> Unit {
  ignore(
    reg.upsert({
      agent_id: @types.AgentId(agent_id),
      role,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/tmp/root",
      branch: "feature/small-fixes",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
}

///|
fn upsert_spawn_test_child_with_state(
  reg : @registry.AgentRegistry,
  agent_id : String,
  state : @types.AgentState,
) -> Unit {
  ignore(
    reg.upsert({
      agent_id: @types.AgentId(agent_id),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/tmp/existing-child",
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state,
    }),
  )
}

///|
fn assert_registry_parent(
  reg : @registry.AgentRegistry,
  agent_id : String,
  parent_id : String,
) -> Unit raise {
  try reg.get(agent_id) catch {
    _ => fail("expected worker in registry")
  } noraise {
    a =>
      match a.parent {
        Some(p) => assert_eq(p, parent_id)
        None => fail("expected parent")
      }
  }
}

///|
async test "interpret_spawn_worker rejects live canonical agent id collision" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "main.tl")
  upsert_spawn_test_child_with_state(reg, "main.w1", @types.AgentState::Active)
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("spawn commands must not run for a live id collision")
    []
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    runner,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("canonical_agent_id 'main.w1'"))
      assert_true(msg.contains("live"))
    }
    @types.Response::Ok(_) => fail("expected live id collision rejection")
  }
  try reg.get("main.w1") catch {
    _ => fail("expected existing child to remain in registry")
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Dev)
      assert_eq(agent.workspace, "/tmp/existing-child")
      assert_eq(agent.state, @types.AgentState::Active)
    }
  }
}

///|
async test "interpret_spawn_worker allows terminal canonical agent id collision" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "main.tl")
  upsert_spawn_test_child_with_state(reg, "main.w1", @types.AgentState::Done)
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("agent_id"), Some("main.w1"))
    @types.Response::Err(msg) =>
      fail("terminal id collision should be reusable: " + msg)
  }
  try reg.get("main.w1") catch {
    _ => fail("expected refreshed worker in registry")
  } noraise {
    agent => {
      assert_eq(agent.role, @types.Role::Worker)
      assert_eq(agent.workspace, "/tmp/p")
      assert_eq(agent.state, @types.AgentState::Active)
    }
  }
}

///|
async test "interpret_spawn_worker registers agent on success" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  let captured : Map[String, @types.TaskContract] = {}
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
    record_task_contract=fn(agent_id, contract) {
      match contract {
        Some(value) => captured.set(agent_id, value)
        None => captured.remove(agent_id)
      }
    },
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
    }
    _ => fail("expected ok")
  }
  try reg.get("main.w1") catch {
    _ => fail("expected worker in registry")
  } noraise {
    a => {
      assert_eq(a.role, @types.Role::Worker)
      assert_eq(a.workspace, "/tmp/p")
    }
  }
  @debug.assert_eq(
    captured.get("main.w1"),
    Some({ ..@types.TaskContract::empty(), goal: "unit" }),
  )
}

///|
async test "interpret_spawn_worker threads model override into codex launch" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w-model",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: Some("codex-worker"),
  }
  let reg = @registry.AgentRegistry::new()
  let saw_model_flag : Array[Bool] = [false]
  let saw_model_value : Array[Bool] = [false]
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if spawn_test_is_agent_token_command(cmd) {
      return (0, spawn_test_agent_token_output())
    }
    if cmd.program == "git" {
      return (0, "origin/main\n")
    }
    if cmd.program == "zellij" {
      let body = cmd.args.join("\n")
      if body.contains("--model") {
        saw_model_flag[0] = true
      }
      if body.contains("codex-worker") {
        saw_model_value[0] = true
      }
      return (0, "")
    }
    (0, "")
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    capture,
    Some(reg),
    read_file=fn(_) { "" },
  )
  match got {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
  assert_true(saw_model_flag[0])
  assert_true(saw_model_value[0])
}

///|
async test "interpret_spawn_worker isolated review targets explicit parent branch" {
  let worker_args : WorkerSpawnArgs = {
    task: "review branch with mutation probes",
    task_contract: { ..@types.TaskContract::empty(), goal: "review branch" },
    caller_id: "main.tl",
    slug: "audit-worker",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Review,
    parent_branch: Some("feature/review-target"),
    isolation: Some(@types.IsolationMode::Worktree),
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "main.tl")
  let saw_current_branch : Array[Bool] = [false]
  let saw_default_branch : Array[Bool] = [false]
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if spawn_test_is_agent_token_command(cmd) {
      return (0, spawn_test_agent_token_output())
    }
    if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
      saw_current_branch[0] = true
      return (0, "main\n")
    }
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      saw_default_branch[0] = true
      return (0, "origin/main\n")
    }
    (0, "")
  }
  let saw_fetch : Array[Bool] = [false]
  let saw_worktree_add : Array[Bool] = [false]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program ==
        @workspace.native_git_fetch_origin_branch_best_effort_program &&
        cmd.args == ["/tmp/p", "feature/review-target"] {
        saw_fetch[0] = true
      }
      if cmd.program == "git" &&
        cmd.args ==
        [
          "worktree", "add", "/tmp/p/.choir/review-worktrees/feature_review-target.audit-worker",
          "-b", "feature/review-target.audit-worker", "origin/feature/review-target",
        ] {
        saw_worktree_add[0] = true
      }
    }
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    runner,
    capture,
    Some(reg),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(
        map.get("agent_id"),
        Some(String::to_json("feature/review-target.audit-worker")),
      )
    }
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
  try reg.get("feature/review-target.audit-worker") catch {
    _ => fail("expected review worker in registry")
  } noraise {
    agent => {
      assert_eq(
        agent.workspace,
        "/tmp/p/.choir/review-worktrees/feature_review-target.audit-worker",
      )
      assert_false(agent.workspace == "/tmp/p")
      assert_false(agent.workspace == "/tmp/p/.choir/worktrees/audit-worker")
    }
  }
  assert_false(saw_current_branch[0])
  assert_false(saw_default_branch[0])
  assert_true(saw_fetch[0])
  assert_true(saw_worktree_add[0])
}

///|
async test "interpret_spawn_worker isolated review rejects missing parent branch" {
  let worker_args : WorkerSpawnArgs = {
    task: "review branch with mutation probes",
    task_contract: { ..@types.TaskContract::empty(), goal: "review branch" },
    caller_id: "main.tl",
    slug: "audit-worker",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Review,
    parent_branch: None,
    isolation: Some(@types.IsolationMode::Worktree),
    model: None,
  }
  let runner_called : Array[Bool] = [false]
  let capture_called : Array[Bool] = [false]
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    async fn(_cmds) {
      @async.sleep(0)
      runner_called[0] = true
      []
    },
    async fn(_cmd) {
      @async.sleep(0)
      capture_called[0] = true
      (0, "")
    },
    None,
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("requires explicit parent_branch"))
      assert_true(msg.contains("refusing to infer review target"))
    }
    _ => fail("expected missing parent_branch rejection")
  }
  assert_false(runner_called[0])
  assert_false(capture_called[0])
}

///|
async test "interpret_spawn_worker gemini seeds agy shared cache before default worker launch" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w-agy",
    agent_type: @types.AgentType::Gemini,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let capture_seen : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    capture_seen.push(cmd.program + " " + cmd.args.join(" "))
    if spawn_test_is_agent_token_command(cmd) {
      return (0, spawn_test_agent_token_output())
    }
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (0, "")
    }
    if cmd.program == "git" {
      return (0, "origin/main\n")
    }
    if cmd.program == "env" && cmd.args.contains("agy") {
      return (0, "")
    }
    (0, "")
  }
  let runner_calls : Array[Int] = [0]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    runner_calls[0] = runner_calls[0] + 1
    let call = runner_calls[0]
    if call == 1 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_validate_program,
      )
      @debug.assert_eq(cmds[0].args, ["/tmp/p"])
      return [1]
    }
    if call == 2 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_prepare_program,
      )
      @debug.assert_eq(cmds[0].args, ["/tmp/p"])
      return [0]
    }
    if call == 3 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_validate_program,
      )
      @debug.assert_eq(cmds[0].args, ["/tmp/p"])
      return [0]
    }
    assert_true(cmds.length() > 0)
    assert_eq(
      cmds.any(fn(cmd) {
        cmd.program == @workspace.native_agy_shared_cache_seed_if_needed_program
      }),
      false,
    )
    let mut cache_links_index = -1
    let mut eager_bootstrap_count = 0
    let mut cache_links_args_ok = false
    for i = 0; i < cmds.length(); i = i + 1 {
      let cmd = cmds[i]
      if cache_links_index < 0 &&
        cmd.program == @workspace.native_agy_cache_links_program {
        cache_links_index = i
      }
      if cmd.program == @workspace.native_agy_cache_links_program &&
        cmd.args == ["/tmp/p", "/tmp/p"] {
        cache_links_args_ok = true
      }
      assert_false(cmd.program == "zellij")
      if cmd.program == "env" && cmd.args.contains("agy") {
        eager_bootstrap_count = eager_bootstrap_count + 1
      }
    }
    assert_eq(eager_bootstrap_count, 0)
    assert_true(cache_links_index >= 0)
    assert_true(cache_links_args_ok)
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    runner,
    capture,
    None,
  )
  assert_eq(runner_calls[0], 4)
  assert_true(capture_seen.contains("agy --help"))
  assert_true(
    capture_seen.contains(
      "env HOME=/tmp/p/.choir/agy-shared-cache/home agy --dangerously-skip-permissions --print Reply READY.",
    ),
  )
  assert_true(
    capture_seen.any(fn(seen) {
      seen.has_prefix("zellij ") && seen.contains("HOME=/tmp/p/.choir/agy-home")
    }),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.w-agy")))
      @debug.assert_eq(map.get("agent_type"), Some(String::to_json("gemini")))
    }
    @types.Response::Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
async test "interpret_spawn_worker gemini warns and proceeds after revalidate seed failure" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w-agy-seed-warn",
    agent_type: @types.AgentType::Gemini,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if spawn_test_is_agent_token_command(cmd) {
      return (0, spawn_test_agent_token_output())
    }
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (0, "")
    }
    if cmd.program == "git" {
      return (0, "origin/main\n")
    }
    if cmd.program == "env" && cmd.args.contains("agy") {
      return (0, "")
    }
    (0, "")
  }
  let runner_calls : Array[Int] = [0]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    runner_calls[0] = runner_calls[0] + 1
    let statuses = []
    let call = runner_calls[0]
    if call == 1 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_validate_program,
      )
      statuses.push(1)
    } else if call == 2 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_prepare_program,
      )
      statuses.push(0)
    } else if call == 3 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_validate_program,
      )
      statuses.push(1)
    } else {
      assert_true(cmds.length() > 0)
      assert_true(
        cmds.any(fn(cmd) {
          cmd.program == @workspace.native_agy_cache_links_program
        }),
      )
      assert_false(cmds.any(fn(cmd) { cmd.program == "zellij" }))
      for _ in cmds {
        statuses.push(0)
      }
    }
    statuses
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    runner,
    capture,
    None,
  )
  assert_eq(runner_calls[0], 4)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      match map.get("warning") {
        Some(warning_json) => {
          let warning = warning_json.stringify()
          assert_true(
            warning.contains("agy shared cache seed re-validate failed"),
          )
          assert_true(
            warning.contains(
              "Gemini/agy spawn will continue without the warmed shared cache",
            ),
          )
          assert_true(warning.contains("exit 1"))
          assert_true(warning.contains("shared cache is still incomplete"))
          assert_false(warning.contains("transport error"))
          assert_false(warning.contains("command failed with status 1"))
          assert_false(warning.contains("requires the shared runtime cache"))
        }
        None => fail("expected agy seed warning")
      }
    }
    @types.Response::Err(msg) =>
      fail("seed failure must not abort spawn: " + msg)
  }
}

///|
async test "interpret_spawn_worker gemini warns with bootstrap stderr without rerunning bootstrap" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w-agy-bootstrap-fail",
    agent_type: @types.AgentType::Gemini,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let bootstrap_captures : Array[Int] = [0]
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if spawn_test_is_agent_token_command(cmd) {
      return (0, spawn_test_agent_token_output())
    }
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (0, "")
    }
    if cmd.program == "git" {
      return (0, "origin/main\n")
    }
    if cmd.program == "env" && cmd.args.contains("agy") {
      bootstrap_captures[0] = bootstrap_captures[0] + 1
      return (7, "bootstrap stderr")
    }
    (0, "")
  }
  let runner_calls : Array[Int] = [0]
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    runner_calls[0] = runner_calls[0] + 1
    let call = runner_calls[0]
    if call == 1 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_validate_program,
      )
      [1]
    } else if call == 2 {
      assert_eq(cmds.length(), 1)
      assert_eq(
        cmds[0].program,
        @workspace.native_agy_shared_cache_prepare_program,
      )
      [0]
    } else {
      assert_false(cmds.any(fn(cmd) { cmd.program == "zellij" }))
      let statuses = []
      for _ in cmds {
        statuses.push(0)
      }
      statuses
    }
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    runner,
    capture,
    None,
  )
  assert_eq(runner_calls[0], 3)
  assert_eq(bootstrap_captures[0], 1)
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      match map.get("warning") {
        Some(warning_json) => {
          let warning = warning_json.stringify()
          assert_true(
            warning.contains("agy shared cache seed cold-bootstrap failed"),
          )
          assert_true(warning.contains("exit 7"))
          assert_true(warning.contains("bootstrap stderr"))
          assert_false(
            warning.contains("HOME=/tmp/p/.choir/agy-shared-cache/home"),
          )
        }
        None => fail("expected bootstrap warning")
      }
    }
    @types.Response::Err(msg) =>
      fail("bootstrap failure must not abort spawn: " + msg)
  }
}

///|
async test "interpret_spawn_worker gemini fails before runner when agy is unavailable" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main.tl",
    slug: "w-agy-missing",
    agent_type: @types.AgentType::Gemini,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let runner_called : Array[Bool] = [false]
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "agy" && cmd.args == ["--help"] {
      return (1, "")
    }
    if cmd.program == "git" {
      return (0, "origin/main\n")
    }
    fail("unexpected capture: " + cmd.to_string())
    (0, "")
  }
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    async fn(_cmds) {
      @async.sleep(0)
      runner_called[0] = true
      []
    },
    capture,
    None,
  )
  assert_false(runner_called[0])
  match got {
    @types.Response::Err(msg) =>
      assert_eq(msg, agy_binary_unavailable_message())
    _ => fail("expected agy unavailable error")
  }
}

///|
async test "interpret_spawn_worker normalizes unregistered caller_id to registered root parent" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main",
    slug: "w-unregistered",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_root(reg)
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
    }
    _ => fail("expected ok")
  }
  assert_registry_parent(reg, "main.w-unregistered", "root")
}

///|
async test "interpret_spawn_worker prefers literal root agent id over another TL" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main",
    slug: "w-literal-root",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent_with_role(reg, "primary", @types.Role::TL)
  upsert_spawn_test_parent_with_role(reg, "root", @types.Role::TL)
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  assert_registry_parent(reg, "main.w-literal-root", "root")
}

///|
async test "interpret_spawn_worker preserves registered caller_id as parent" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "root",
    slug: "w-registered",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_root(reg)
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  assert_registry_parent(reg, "main.w-registered", "root")
}

///|
async test "interpret_spawn_worker rejects ambiguous multi-TL with no root" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main",
    slug: "w-ambiguous",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "tl-a")
  upsert_spawn_test_parent(reg, "tl-b")
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("spawn_worker caller_id 'main' is not registered"),
      )
      assert_true(msg.contains("agent registry"))
    }
    _ => fail("expected err")
  }
}

///|
async test "interpret_spawn_worker rejects ambiguous non-root TL agents with root-like names" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main",
    slug: "w-multi-root",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent_with_role(reg, "root-a", @types.Role::TL)
  upsert_spawn_test_parent_with_role(reg, "root-b", @types.Role::TL)
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("spawn_worker caller_id 'main' is not registered"),
      )
      assert_true(msg.contains("agent registry"))
    }
    _ => fail("expected err")
  }
}

///|
async test "interpret_spawn_worker normalizes unregistered caller_id to single non-root TL" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: { ..@types.TaskContract::empty(), goal: "unit" },
    caller_id: "main",
    slug: "w-single-tl",
    agent_type: @types.AgentType::Claude,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "only-tl")
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_origin_main,
    Some(reg),
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  assert_registry_parent(reg, "main.w-single-tl", "only-tl")
}

///|
async test "interpret_spawn_worker mirrors assigned beads on success" {
  let worker_args : WorkerSpawnArgs = {
    task: "unit",
    task_contract: {
      ..@types.TaskContract::empty(),
      goal: "unit",
      beads_issue_id: Some("choir-worker"),
    },
    caller_id: "main.tl",
    slug: "w1",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: None,
    isolation: None,
    model: None,
  }
  let seen : Array[String] = []
  let got = interpret_spawn_worker(
    worker_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if spawn_test_is_agent_token_command(cmd) {
        return (0, spawn_test_agent_token_output())
      }
      if cmd.program == "bd" {
        seen.push(cmd.args.join(" "))
      }
      if cmd.program == "git" {
        (0, "origin/main\n")
      } else {
        (0, "")
      }
    },
    None,
  )
  match got {
    @types.Response::Ok(_) => ()
    _ => fail("expected ok")
  }
  let rendered = seen.join("\n")
  assert_true(rendered.contains("update choir-worker"))
  assert_true(rendered.contains("--status in_progress"))
  assert_true(rendered.contains("--assignee main.w1"))
  assert_true(rendered.contains("choir_agent_type=codex"))
  assert_true(rendered.contains("audit record"))
  assert_true(rendered.contains("spawned main.w1"))
}

///|
test "spawn_remote_plan builds dev claude worktree spec and spawned response" {
  let spawn_args : RemoteSpawnArgs = {
    task: "remote-task",
    task_contract: { ..@types.TaskContract::empty(), goal: "remote-task" },
    caller_id: "main.tl",
    slug: "leaf-a",
    parent_branch: "main",
    ssh_target: "user@remote.example",
    repo_url: "https://github.com/o/r.git",
    tcp_addr: "192.168.1.10:7777",
    parent_session_id: Some("sess-1"),
  }
  let plan = spawn_remote_plan(spawn_args)
  assert_eq(plan.spec.slug, "leaf-a")
  assert_eq(plan.spec.role, @types.Role::Dev)
  assert_eq(plan.spec.agent_type, @types.AgentType::Claude)
  assert_eq(plan.spec.task, "remote-task")
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.parent_branch, "main")
  assert_eq(plan.spec.reuse_workspace, false)
  @debug.assert_eq(plan.spec.workspace_slug, None)
  @debug.assert_eq(plan.spec.reuse_git_branch, None)
  assert_eq(plan.spec.spawn_depth, 0)
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(
        map.get("agent_id"),
        Some(String::to_json("main.leaf-a")),
      )
      @debug.assert_eq(map.get("slug"), Some(String::to_json("leaf-a")))
      @debug.assert_eq(
        map.get("host"),
        Some(String::to_json("user@remote.example")),
      )
    }
    _ => fail("expected ok response")
  }
}

///|
async test "interpret_spawn_remote returns plan ok when runner succeeds" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "pb.caller",
    slug: "s1",
    parent_branch: "pb",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let got = interpret_spawn_remote(
    spawn_args,
    mock_runner_all_ok,
    mock_capture_empty,
    mint_agent_token=Some(spawn_test_mint_agent_token),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("pb.s1")))
      @debug.assert_eq(map.get("slug"), Some(String::to_json("s1")))
      @debug.assert_eq(map.get("host"), Some(String::to_json("h")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_spawn_remote returns err when run_strict fails" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "x",
    slug: "y",
    parent_branch: "main",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let reg = @registry.AgentRegistry::new()
  let got = interpret_spawn_remote(
    spawn_args,
    mock_runner_first_fails,
    mock_capture_empty,
    registry=Some(reg),
    mint_agent_token=Some(spawn_test_mint_agent_token),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected err from run_strict")
  }
  @debug.assert_eq(reg.credential_for_agent("main.y"), None)
}

///|
async test "dispatch spawn_remote rejects live canonical agent id collision before runner" {
  let spawn_args : RemoteSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "leaf-a",
    parent_branch: "main",
    ssh_target: "h",
    repo_url: "u",
    tcp_addr: "a",
    parent_session_id: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "main.tl")
  upsert_spawn_test_child_with_state(
    reg,
    "main.leaf-a",
    @types.AgentState::Active,
  )
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("remote spawn commands must not run for a live id collision")
    []
  }
  let got = dispatch(
    ToolRequest::SpawnRemote(spawn_args),
    runner~,
    capture=mock_capture_empty,
    registry=Some(reg),
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("canonical_agent_id 'main.leaf-a'"))
      assert_true(msg.contains("live"))
    }
    @types.Response::Ok(_) => fail("expected live id collision rejection")
  }
}

///|
test "spawn_gemini_plan builds dev gemini worktree spec and spawned response" {
  let spawn_args : SpawnGeminiArgs = {
    task: "do the thing",
    task_contract: { ..@types.TaskContract::empty(), goal: "do the thing" },
    caller_id: "main.tl",
    slug: "g1",
    parent_branch: "main",
    parent_session_id: Some("sess-1"),
  }
  let plan = spawn_gemini_plan(spawn_args)
  assert_eq(plan.spec.slug, "g1")
  assert_eq(plan.spec.role, @types.Role::Dev)
  assert_eq(plan.spec.agent_type, @types.AgentType::Gemini)
  assert_eq(plan.spec.task, "do the thing")
  assert_eq(plan.spec.isolation, @types.IsolationMode::Worktree)
  assert_eq(plan.spec.parent_id, "main.tl")
  assert_eq(plan.spec.parent_branch, "main")
  assert_eq(plan.spec.reuse_workspace, false)
  @debug.assert_eq(plan.spec.workspace_slug, None)
  @debug.assert_eq(plan.spec.reuse_git_branch, None)
  assert_eq(plan.spec.spawn_depth, 0)
  match plan.ok_response {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("main.g1")))
      @debug.assert_eq(map.get("slug"), Some(String::to_json("g1")))
    }
    _ => fail("expected ok response")
  }
}

///|
async test "interpret_spawn_gemini returns plan ok when runner succeeds" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "pb.caller",
    slug: "gem",
    parent_branch: "pb",
    parent_session_id: None,
  }
  let got = interpret_spawn_gemini(
    spawn_args,
    "/tmp/p",
    "choir",
    mock_runner_all_ok,
    mock_capture_empty,
    mint_agent_token=Some(spawn_test_mint_agent_token),
  )
  match got {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some(String::to_json("spawned")))
      @debug.assert_eq(map.get("agent_id"), Some(String::to_json("pb.gem")))
      @debug.assert_eq(map.get("slug"), Some(String::to_json("gem")))
    }
    _ => fail("expected ok")
  }
}

///|
async test "interpret_spawn_gemini returns err when run_strict fails" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "x",
    slug: "y",
    parent_branch: "main",
    parent_session_id: None,
  }
  let reg = @registry.AgentRegistry::new()
  let got = interpret_spawn_gemini(
    spawn_args,
    "/tmp/p",
    "choir",
    mock_runner_first_fails,
    mock_capture_empty,
    registry=Some(reg),
    mint_agent_token=Some(spawn_test_mint_agent_token),
  )
  match got {
    @types.Response::Err(msg) =>
      assert_true(msg.contains("failed") || msg.contains("status"))
    _ => fail("expected err from run_strict")
  }
  @debug.assert_eq(reg.credential_for_agent("main.y"), None)
}

///|
async test "dispatch spawn_gemini rejects live canonical agent id collision before runner" {
  let spawn_args : SpawnGeminiArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "gem",
    parent_branch: "main",
    parent_session_id: None,
  }
  let reg = @registry.AgentRegistry::new()
  upsert_spawn_test_parent(reg, "main.tl")
  upsert_spawn_test_child_with_state(reg, "main.gem", @types.AgentState::Active)
  let runner = async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    fail("gemini spawn commands must not run for a live id collision")
    []
  }
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    fail("agy checks must not run for a live id collision")
    (0, "")
  }
  let got = dispatch(
    ToolRequest::SpawnGemini(spawn_args),
    runner~,
    capture~,
    registry=Some(reg),
  )
  match got {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("canonical_agent_id 'main.gem'"))
      assert_true(msg.contains("live"))
    }
    @types.Response::Ok(_) => fail("expected live id collision rejection")
  }
}

///|
test "ensure_caller_can_spawn rejects callers in Failed state" {
  // Regression: a worker spawned against a Failed parent has no live terminal
  // to receive `notify_parent`; the work output dies in the worker's pane.
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("root"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/proj",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Failed,
    }),
  )
  match ensure_caller_can_spawn("root", Some(reg)) {
    Ok(_) => fail("expected Err for caller in Failed state")
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("root"))
      assert_true(msg.contains("terminal state"))
      assert_true(msg.contains("notify_parent"))
    }
  }
}

///|
test "ensure_caller_can_spawn rejects callers in Done state" {
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
      spawn_depth: 0,
      state: @types.AgentState::Done,
    }),
  )
  match ensure_caller_can_spawn("main.tl", Some(reg)) {
    Ok(_) => fail("expected Err for caller in Done state")
    Err(_) => ()
  }
}

///|
test "ensure_caller_can_spawn allows callers in Active state" {
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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  match ensure_caller_can_spawn("main.tl", Some(reg)) {
    Ok(_) => ()
    Err(e) => fail("expected Ok for Active caller, got: " + e.message())
  }
}

///|
test "ensure_caller_can_spawn allows callers not in registry (synthesized root path)" {
  // The synthesized root TL agent isn't in the registry until it registers.
  // Pre-registration spawns from a freshly-launched TL session (or test
  // harnesses without a registry) must still go through.
  let reg = @registry.AgentRegistry::new()
  match ensure_caller_can_spawn("user-12345-67890", Some(reg)) {
    Ok(_) => ()
    Err(e) => fail("expected Ok for unregistered caller, got: " + e.message())
  }
}

///|
test "ensure_caller_can_spawn allows None registry (test/non-orchestration paths)" {
  match ensure_caller_can_spawn("anyone", None) {
    Ok(_) => ()
    Err(e) => fail("expected Ok for None registry, got: " + e.message())
  }
}

///|
