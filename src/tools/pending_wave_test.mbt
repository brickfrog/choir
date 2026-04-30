///|
fn pending_wave_test_project_dir(label : String) -> String {
  "/tmp/choir-pending-wave-" +
  label +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
fn pending_wave_test_args(
  caller_id : String,
  slug_prefix : String,
  depends_on : Array[String],
) -> @tools.ForkWaveArgs {
  {
    count: 1,
    tasks: ["work"],
    task_contracts: [{ ..@types.TaskContract::empty(), goal: "work" }],
    has_per_leaf_tasks: false,
    parent_branch: "main",
    caller_id,
    slug_prefix,
    agent_type: @types.AgentType::Claude,
    child_role: @types.Role::Dev,
    parent_session_id: None,
    review_context: Some("ctx"),
    automerge: Some(true),
    review_mode: Some(@types.ReviewMode::SinglePass),
    depends_on,
  }
}

///|
fn pending_wave_test_setup(label : String) -> String {
  let project_dir = pending_wave_test_project_dir(label)
  ignore(@sys.rm_rf(project_dir))
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  project_dir
}

///|
fn pending_wave_test_dev_lifecycle(
  agent_id : String,
  workflow : @phase.DevLifecycle,
  process : @phase.ProcessState,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::Dev,
    process,
    workflow: @phase.WorkflowState::Dev(workflow),
  }
}

///|
test "pending_wave_to_json_string round-trip preserves args" {
  let args = pending_wave_test_args("main.tl", "wave", [
    "main.dep-a", "main.dep-b",
  ])
  let pw : @tools.PendingWave = { wave_id: "wave-100-7", args }
  let json_str = @tools.pending_wave_to_json_string(pw)
  match @tools.parse_pending_wave(json_str) {
    Some(round_tripped) => {
      assert_eq(round_tripped.wave_id, "wave-100-7")
      assert_eq(round_tripped.args.caller_id, "main.tl")
      assert_eq(round_tripped.args.slug_prefix, "wave")
      assert_eq(round_tripped.args.parent_branch, "main")
      assert_eq(round_tripped.args.agent_type, @types.AgentType::Claude)
      assert_eq(round_tripped.args.child_role, @types.Role::Dev)
      assert_eq(round_tripped.args.tasks, ["work"])
      assert_eq(round_tripped.args.has_per_leaf_tasks, false)
      assert_eq(round_tripped.args.count, 1)
      @debug.assert_eq(round_tripped.args.review_context, Some("ctx"))
      @debug.assert_eq(round_tripped.args.automerge, Some(true))
      @debug.assert_eq(
        round_tripped.args.review_mode,
        Some(@types.ReviewMode::SinglePass),
      )
      assert_eq(round_tripped.args.depends_on, ["main.dep-a", "main.dep-b"])
      assert_eq(round_tripped.args.task_contracts.length(), 1)
      assert_eq(round_tripped.args.task_contracts[0].goal, "work")
    }
    None => fail("parse_pending_wave returned None")
  }
}

///|
test "parse_pending_wave returns None on garbage input" {
  @debug.assert_eq(@tools.parse_pending_wave(""), None)
  @debug.assert_eq(@tools.parse_pending_wave("not json"), None)
  @debug.assert_eq(@tools.parse_pending_wave("[1,2,3]"), None)
}

///|
test "write_pending_wave + read_pending_wave round-trip via disk" {
  let project_dir = pending_wave_test_setup("write-read")
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  let pw : @tools.PendingWave = { wave_id: "wv-1", args }
  assert_true(@tools.write_pending_wave(project_dir, pw))
  match @tools.read_pending_wave(project_dir, "wv-1") {
    Some(got) => {
      assert_eq(got.wave_id, "wv-1")
      assert_eq(got.args.depends_on, ["main.dep"])
    }
    None => fail("read_pending_wave: None")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "list_pending_wave_paths picks up only pending-wave-- entries" {
  let project_dir = pending_wave_test_setup("list")
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-a", args }))
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-b", args }))
  // unrelated kv entry — must not be returned.
  ignore(
    @sys.write_file_sync(project_dir + "/.choir/kv/lifecycle--main--dep", "{}"),
  )
  let paths = @tools.list_pending_wave_paths(project_dir)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(paths.length(), 2)
}

///|
test "evaluate_pending_wave: Wait when dep has no lifecycle" {
  let project_dir = pending_wave_test_setup("wait-empty")
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  let pw : @tools.PendingWave = { wave_id: "wv-x", args }
  let decision = @tools.evaluate_pending_wave(project_dir, pw)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(decision, @tools.PendingWaveDecision::Wait)
}

///|
test "evaluate_pending_wave: ReadyToSpawn when all deps merged" {
  let project_dir = pending_wave_test_setup("ready")
  let merged = pending_wave_test_dev_lifecycle(
    "main.dep-a",
    @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
    @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
  )
  ignore(@phase.write_lifecycle(project_dir, merged))
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep-a"])
  let pw : @tools.PendingWave = { wave_id: "wv-r", args }
  let decision = @tools.evaluate_pending_wave(project_dir, pw)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(decision, @tools.PendingWaveDecision::ReadyToSpawn)
}

///|
test "evaluate_pending_wave: FailedDep when one dep failed" {
  let project_dir = pending_wave_test_setup("fail-dep")
  let merged = pending_wave_test_dev_lifecycle(
    "main.dep-a",
    @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged),
    @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
  )
  let failed_lc = pending_wave_test_dev_lifecycle(
    "main.dep-b",
    @phase.DevLifecycle::Failed(reason=@phase.FailureReason::WatchdogTimeout),
    @phase.ProcessState::Failed(reason=@phase.FailureReason::WatchdogTimeout),
  )
  ignore(@phase.write_lifecycle(project_dir, merged))
  ignore(@phase.write_lifecycle(project_dir, failed_lc))
  let args = pending_wave_test_args("main.tl", "wv", [
    "main.dep-a", "main.dep-b",
  ])
  let pw : @tools.PendingWave = { wave_id: "wv-f", args }
  let decision = @tools.evaluate_pending_wave(project_dir, pw)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(decision, @tools.PendingWaveDecision::FailedDep("main.dep-b"))
}

///|
test "evaluate_pending_wave: Done with non-merged reason counts as failed" {
  let project_dir = pending_wave_test_setup("done-shutdown")
  let shutdown_lc = pending_wave_test_dev_lifecycle(
    "main.dep",
    @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Shutdown),
    @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Shutdown),
  )
  ignore(@phase.write_lifecycle(project_dir, shutdown_lc))
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  let pw : @tools.PendingWave = { wave_id: "wv-s", args }
  let decision = @tools.evaluate_pending_wave(project_dir, pw)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(decision, @tools.PendingWaveDecision::FailedDep("main.dep"))
}

///|
test "validate_pending_wave_deps: ok when dep in registry" {
  let project_dir = pending_wave_test_setup("validate-reg")
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.dep"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/w",
      branch: "main.dep",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let got = @tools.validate_pending_wave_deps(project_dir, Some(reg), [
    "main.dep",
  ])
  ignore(@sys.rm_rf(project_dir))
  assert_true(got is Ok(_))
}

///|
test "validate_pending_wave_deps: ok when dep has lifecycle file" {
  let project_dir = pending_wave_test_setup("validate-lifecycle")
  let lc = pending_wave_test_dev_lifecycle(
    "main.dep",
    @phase.DevLifecycle::Working,
    @phase.ProcessState::Connected,
  )
  ignore(@phase.write_lifecycle(project_dir, lc))
  let got = @tools.validate_pending_wave_deps(project_dir, None, ["main.dep"])
  ignore(@sys.rm_rf(project_dir))
  assert_true(got is Ok(_))
}

///|
test "validate_pending_wave_deps: config_error on unknown dep" {
  let project_dir = pending_wave_test_setup("validate-unknown")
  match
    @tools.validate_pending_wave_deps(project_dir, None, ["main.does-not-exist"]) {
    Err(e) => {
      ignore(@sys.rm_rf(project_dir))
      assert_true(e.message().contains("main.does-not-exist"))
    }
    Ok(_) => {
      ignore(@sys.rm_rf(project_dir))
      fail("expected config_error for unknown dep")
    }
  }
}

///|
test "validate_pending_wave_deps: config_error on empty entry" {
  let project_dir = pending_wave_test_setup("validate-empty")
  let got = @tools.validate_pending_wave_deps(project_dir, None, ["   "])
  ignore(@sys.rm_rf(project_dir))
  assert_true(got is Err(_))
}

///|
test "validate_pending_wave_deps: rejects TL-id dep via registry with role in error" {
  let project_dir = pending_wave_test_setup("validate-tl-registry")
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.tl"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/w",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let got = @tools.validate_pending_wave_deps(project_dir, Some(reg), [
    "main.tl",
  ])
  ignore(@sys.rm_rf(project_dir))
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("main.tl"))
      assert_true(msg.contains("dev leaves"))
      assert_true(msg.contains("role=tl"))
    }
    Ok(_) => fail("expected config_error for TL-id dep")
  }
}

///|
test "validate_pending_wave_deps: rejects TL-id dep via lifecycle file" {
  let project_dir = pending_wave_test_setup("validate-tl-lifecycle")
  // Lifecycle file for a TL agent — would otherwise pass the exists check.
  let lc : @phase.AgentLifecycle = {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
  }
  ignore(@phase.write_lifecycle(project_dir, lc))
  let got = @tools.validate_pending_wave_deps(project_dir, None, ["main.tl"])
  ignore(@sys.rm_rf(project_dir))
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("main.tl"))
      assert_true(msg.contains("dev leaves"))
      assert_true(msg.contains("role=tl"))
    }
    Ok(_) => fail("expected config_error for TL-id dep from lifecycle")
  }
}

///|
test "validate_pending_wave_deps: rejects Root-id dep" {
  let project_dir = pending_wave_test_setup("validate-root")
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main"),
      role: @types.Role::Root,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: "/w",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let got = @tools.validate_pending_wave_deps(project_dir, Some(reg), ["main"])
  ignore(@sys.rm_rf(project_dir))
  assert_true(got is Err(_))
}

///|
test "validate_pending_wave_deps: accepts Dev-id dep via lifecycle" {
  let project_dir = pending_wave_test_setup("validate-dev-ok")
  let lc = pending_wave_test_dev_lifecycle(
    "main.dep",
    @phase.DevLifecycle::Working,
    @phase.ProcessState::Connected,
  )
  ignore(@phase.write_lifecycle(project_dir, lc))
  let got = @tools.validate_pending_wave_deps(project_dir, None, ["main.dep"])
  ignore(@sys.rm_rf(project_dir))
  assert_true(got is Ok(_))
}

///|
test "validate_pending_wave_deps: rejects Worker-id dep" {
  let project_dir = pending_wave_test_setup("validate-worker")
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.worker"),
      role: @types.Role::Worker,
      agent_type: @types.AgentType::Claude,
      parent: Some("main.tl"),
      workspace: "/w",
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let got = @tools.validate_pending_wave_deps(project_dir, Some(reg), [
    "main.worker",
  ])
  ignore(@sys.rm_rf(project_dir))
  match got {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("main.worker"))
      assert_true(msg.contains("dev leaves"))
      assert_true(msg.contains("role=worker"))
    }
    Ok(_) => fail("expected config_error for Worker-id dep")
  }
}

///|
test "dep_failed_notify_message format" {
  let msg = @tools.dep_failed_notify_message("wv-99", "main.bad")
  assert_eq(msg, "[DEP FAILED] wave wv-99 — dep failed: main.bad")
}

///|
async fn pending_wave_runner_record(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  ignore(cmds)
  let zeros : Array[Int] = []
  for _ in cmds {
    zeros.push(0)
  }
  zeros
}

///|
async test "mark_pending_wave_failed writes failed marker, deletes pending" {
  let project_dir = pending_wave_test_setup("mark-failed")
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  let pw : @tools.PendingWave = { wave_id: "wv-mark", args }
  assert_true(@tools.write_pending_wave(project_dir, pw))
  @tools.mark_pending_wave_failed(
    project_dir,
    None,
    pending_wave_runner_record,
    pw,
    "main.dep",
  )
  let pending_after = @sys.read_file(
    @tools.pending_wave_kv_path(project_dir, "wv-mark"),
  )
  let failed_after = @sys.read_file(
    @tools.failed_wave_kv_path(project_dir, "wv-mark"),
  )
  ignore(@sys.rm_rf(project_dir))
  assert_eq(pending_after, "")
  assert_true(failed_after.contains("dep failed: main.dep"))
  assert_true(failed_after.contains("wv-mark"))
}

///|
test "pending_waves_naming_dep filters by depends_on entries" {
  let project_dir = pending_wave_test_setup("naming")
  let a = pending_wave_test_args("main.tl", "wv", ["main.x"])
  let b = pending_wave_test_args("main.tl", "wv", ["main.y", "main.x"])
  let c = pending_wave_test_args("main.tl", "wv", ["main.y"])
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-a", args: a }))
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-b", args: b }))
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-c", args: c }))
  let matches = @tools.pending_waves_naming_dep(project_dir, "main.x")
  ignore(@sys.rm_rf(project_dir))
  assert_eq(matches.length(), 2)
}

///|
test "generate_pending_wave_id format" {
  let id = @tools.generate_pending_wave_id("alpha", 1700000000L, 4242)
  assert_eq(id, "alpha-1700000000-4242")
}

///|
test "pending_wave_kv_key prefix is pending-wave--" {
  assert_eq(@tools.pending_wave_kv_key("foo"), "pending-wave--foo")
  assert_eq(@tools.failed_wave_kv_key("foo"), "failed-wave--foo")
}

///|
test "allocate_pending_wave_id appends suffix on collision" {
  let project_dir = pending_wave_test_setup("allocate-collision")
  let base_id = @tools.generate_pending_wave_id("wv", 42L, 7)
  // Simulate an existing pending file at the base id.
  ignore(
    @sys.write_file_sync(
      @tools.pending_wave_kv_path(project_dir, base_id),
      "{}",
    ),
  )
  let allocated = @tools.allocate_pending_wave_id(project_dir, "wv", 42L, 7)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(allocated, base_id + "-1")
}

///|
test "allocate_pending_wave_id returns base when free" {
  let project_dir = pending_wave_test_setup("allocate-free")
  let allocated = @tools.allocate_pending_wave_id(project_dir, "wv", 99L, 5)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(allocated, @tools.generate_pending_wave_id("wv", 99L, 5))
}

///|
test "allocate_pending_wave_id walks suffix until free slot" {
  let project_dir = pending_wave_test_setup("allocate-walk")
  let base_id = @tools.generate_pending_wave_id("wv", 1L, 1)
  ignore(
    @sys.write_file_sync(
      @tools.pending_wave_kv_path(project_dir, base_id),
      "{}",
    ),
  )
  ignore(
    @sys.write_file_sync(
      @tools.pending_wave_kv_path(project_dir, base_id + "-1"),
      "{}",
    ),
  )
  ignore(
    @sys.write_file_sync(
      @tools.pending_wave_kv_path(project_dir, base_id + "-2"),
      "{}",
    ),
  )
  let allocated = @tools.allocate_pending_wave_id(project_dir, "wv", 1L, 1)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(allocated, base_id + "-3")
}

///|
test "reap_unparseable_pending_waves deletes empty + invalid entries" {
  let project_dir = pending_wave_test_setup("reap")
  // valid entry
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-ok", args }))
  // empty file (partial-write)
  ignore(
    @sys.write_file_sync(project_dir + "/.choir/kv/pending-wave--wv-empty", ""),
  )
  // garbage JSON
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/pending-wave--wv-garbage",
      "{not-json",
    ),
  )
  // wrong shape (parses but not a pending wave)
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/pending-wave--wv-wrong",
      "{\"wave_id\":\"wv-wrong\"}",
    ),
  )
  let removed = @tools.reap_unparseable_pending_waves(project_dir)
  let remaining_paths = @tools.list_pending_wave_paths(project_dir)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(removed.length(), 3)
  assert_true(removed.contains("pending-wave--wv-empty"))
  assert_true(removed.contains("pending-wave--wv-garbage"))
  assert_true(removed.contains("pending-wave--wv-wrong"))
  assert_eq(remaining_paths.length(), 1)
}

///|
test "reap_unparseable_pending_waves keeps a parseable entry" {
  let project_dir = pending_wave_test_setup("reap-keep")
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  ignore(@tools.write_pending_wave(project_dir, { wave_id: "wv-keep", args }))
  let removed = @tools.reap_unparseable_pending_waves(project_dir)
  let remaining = @tools.list_pending_wave_paths(project_dir)
  ignore(@sys.rm_rf(project_dir))
  assert_eq(removed.length(), 0)
  assert_eq(remaining.length(), 1)
}

///|
async test "interpret_kill_agent deletes a malformed pending wave file" {
  let project_dir = pending_wave_test_setup("kill-malformed")
  let wave_id = "wv-malformed"
  // File exists but cannot be parsed as a PendingWave.
  ignore(
    @sys.write_file_sync(
      @tools.pending_wave_kv_path(project_dir, wave_id),
      "{\"wave_id\":42}",
    ),
  )
  let args : @tools.KillAgentArgs = { agent_id: wave_id, reason: "cleanup" }
  let resp = @tools.interpret_kill_agent(
    args,
    None,
    pending_wave_runner_record,
    project_dir~,
  )
  let still_there = @sys.read_file(
    @tools.pending_wave_kv_path(project_dir, wave_id),
  )
  ignore(@sys.rm_rf(project_dir))
  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(
        map.get("status"),
        Some(String::to_json("killed_pending_wave")),
      )
      @debug.assert_eq(map.get("wave_id"), Some(String::to_json(wave_id)))
    }
    _ => fail("expected killed_pending_wave ok response")
  }
  assert_eq(still_there, "")
}

///|
async test "interpret_kill_agent deletes a parseable pending wave file" {
  let project_dir = pending_wave_test_setup("kill-parseable")
  let args = pending_wave_test_args("main.tl", "wv", ["main.dep"])
  let pw : @tools.PendingWave = { wave_id: "wv-good", args }
  ignore(@tools.write_pending_wave(project_dir, pw))
  let kill_args : @tools.KillAgentArgs = {
    agent_id: "wv-good",
    reason: "user-cancel",
  }
  let resp = @tools.interpret_kill_agent(
    kill_args,
    None,
    pending_wave_runner_record,
    project_dir~,
  )
  let still_there = @sys.read_file(
    @tools.pending_wave_kv_path(project_dir, "wv-good"),
  )
  ignore(@sys.rm_rf(project_dir))
  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(
        map.get("status"),
        Some(String::to_json("killed_pending_wave")),
      )
    }
    _ => fail("expected killed_pending_wave ok response")
  }
  assert_eq(still_there, "")
}
