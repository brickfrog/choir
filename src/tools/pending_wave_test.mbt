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
      assert_eq(round_tripped.args.review_context, Some("ctx"))
      assert_eq(round_tripped.args.automerge, Some(true))
      assert_eq(
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
  assert_eq(@tools.parse_pending_wave(""), None)
  assert_eq(@tools.parse_pending_wave("not json"), None)
  assert_eq(@tools.parse_pending_wave("[1,2,3]"), None)
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
