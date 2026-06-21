///|
fn tdd_test_escape_toml_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn tdd_test_write_verify_config(
  agent_workspace : String,
  verify : Array[String],
) -> Unit {
  ignore(@sys.create_dir_all(agent_workspace + "/.choir"))
  let contract = { ..@types.TaskContract::empty(), goal: "tdd verify", verify }
  ignore(
    @sys.write_file_sync(
      agent_workspace + "/.choir/config.local.toml",
      "task_contract_json = \"" +
      tdd_test_escape_toml_string(contract.to_json_string()) +
      "\"\n",
    ),
  )
}

///|
fn tdd_test_verify_contract(verify : Array[String]) -> @types.TaskContract {
  { ..@types.TaskContract::empty(), goal: "tdd verify", verify }
}

///|
fn tdd_test_contract_reader(
  contract : @types.TaskContract,
) -> (String) -> @types.TaskContract? {
  fn(_agent_id : String) -> @types.TaskContract? { Some(contract) }
}

///|
fn tdd_test_registry(agent_workspace : String) -> @registry.AgentRegistry {
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some("main.tl"),
      workspace: agent_workspace,
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  reg
}

///|
test "leaf TDD state machine requires intent red green done in order" {
  match plan_tdd_intent_transition(None) {
    Ok(phase) => assert_eq(phase, @types.LeafTddPhase::Intent)
    Err(e) => fail("expected intent to start: " + e.message())
  }
  match plan_tdd_red_check_transition(Some(@types.LeafTddPhase::Intent), 2) {
    Ok(phase) => assert_eq(phase, @types.LeafTddPhase::Red)
    Err(e) => fail("expected failing test to open red gate: " + e.message())
  }
  match
    plan_tdd_green_check_transition(Some(@types.LeafTddPhase::Red), 0, None) {
    Ok(phase) => assert_eq(phase, @types.LeafTddPhase::Green)
    Err(e) => fail("expected passing test to reach green: " + e.message())
  }
  match
    plan_tdd_green_check_transition(
      Some(@types.LeafTddPhase::Green),
      0,
      Some(@types.LeafTddPhase::Done),
    ) {
    Ok(phase) => assert_eq(phase, @types.LeafTddPhase::Done)
    Err(e) => fail("expected passing test to mark done: " + e.message())
  }
}

///|
test "TDD check workdir fails closed without registry" {
  match tdd_check_workdir(None, "main.leaf") {
    Err(e) => {
      assert_true(e.message().contains("without an agent registry"))
      assert_true(e.message().contains("leaf TDD gate"))
    }
    Ok(_) => fail("expected TDD workdir resolution to fail without registry")
  }
}

///|
async test "leaf TDD intent rejects leaf-authored command outside configured verify" {
  let project_dir = "/tmp/choir-tdd-forge-intent-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract([
    "moon test --target native", "moon check --target native",
  ])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let intent = interpret_tdd_intent(
    {
      caller_id: "main.leaf",
      intent: "forge with a marker file",
      test_command: Some("test -e forge.marker"),
      artifact_path: None,
    },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
  )
  match intent {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("must match the configured verify command"))
      assert_true(msg.contains("moon test --target native"))
      assert_true(msg.contains("moon check --target native"))
    }
    @types.Response::Ok(_) =>
      fail("expected forged test_command to be rejected")
  }
  @debug.assert_eq(stored, None)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD intent accepts non-code artifact when configured verify owns artifact path" {
  let project_dir = "/tmp/choir-tdd-artifact-intent-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract([
    "test -f 'docs/non-code.md' && moon test --target native",
  ])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let intent = interpret_tdd_intent(
    {
      caller_id: "main.leaf",
      intent: "write non-code artifact",
      test_command: None,
      artifact_path: Some("docs/non-code.md"),
    },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
  )
  match intent {
    @types.Response::Ok(fields) => {
      @debug.assert_eq(fields.get_json("phase"), Some("intent".to_json()))
      @debug.assert_eq(
        fields.get_json("artifact_path"),
        Some("docs/non-code.md".to_json()),
      )
      @debug.assert_eq(
        fields.get_json("test_command"),
        Some(
          "test -f 'docs/non-code.md' && moon test --target native".to_json(),
        ),
      )
    }
    @types.Response::Err(msg) => fail("expected artifact intent ok: " + msg)
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Intent }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD intent rejects artifact path not owned by configured verify" {
  let project_dir = "/tmp/choir-tdd-artifact-reject-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["moon test --target native"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let intent = interpret_tdd_intent(
    {
      caller_id: "main.leaf",
      intent: "write non-code artifact",
      test_command: None,
      artifact_path: Some("docs/non-code.md"),
    },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
  )
  match intent {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains(
          "artifact mode requires the configured verify command to check",
        ),
      )
      assert_true(msg.contains("docs/non-code.md"))
      assert_true(msg.contains("test -f docs/non-code.md && <verify>"))
    }
    @types.Response::Ok(_) =>
      fail("expected unowned artifact_path to be rejected")
  }
  let substring_intent = interpret_tdd_intent(
    {
      caller_id: "main.leaf",
      intent: "write non-code artifact",
      test_command: None,
      artifact_path: Some("test"),
    },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
  )
  match substring_intent {
    @types.Response::Err(msg) =>
      assert_true(
        msg.contains(
          "artifact mode requires the configured verify command to check",
        ),
      )
    @types.Response::Ok(_) =>
      fail("expected substring artifact_path to be rejected")
  }
  @debug.assert_eq(stored, None)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD intent rejects unsafe artifact paths" {
  let project_dir = "/tmp/choir-tdd-artifact-path-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract([
    "test -f docs/non-code.md && moon test --target native",
  ])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  for path in ["/tmp/out.md", "../out.md", "docs/../out.md"] {
    let intent = interpret_tdd_intent(
      {
        caller_id: "main.leaf",
        intent: "write non-code artifact",
        test_command: None,
        artifact_path: Some(path),
      },
      reader,
      writer,
      registry=Some(reg),
      task_contract_reader=tdd_test_contract_reader(contract),
    )
    match intent {
      @types.Response::Err(msg) => assert_true(msg.contains("artifact_path"))
      @types.Response::Ok(_) => fail("expected unsafe artifact path rejection")
    }
  }
  @debug.assert_eq(stored, None)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD red check rejects forged failing report when command passes" {
  let project_dir = "/tmp/choir-tdd-red-forge-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["true"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Intent,
  })
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    @debug.assert_eq(cmd, @workspace.Command::{
      program: "sh",
      args: ["-lc", "true"],
      workdir: Some(leaf_worktree),
    })
    (0, "actual pass")
  }
  let red = interpret_tdd_red_check(
    { caller_id: "main.leaf", exit_code: 1 },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
  )
  match red {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("actual exit code"))
      assert_true(msg.contains("red check expected exit code"))
      assert_true(msg.contains("command: true"))
      assert_true(msg.contains("output_tail:\nactual pass"))
    }
    @types.Response::Ok(_) => fail("expected red gate to reject forged failure")
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Intent }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD red check rejects check-time non-test command forge" {
  let project_dir = "/tmp/choir-tdd-check-time-forge-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["moon test --target native"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    @debug.assert_eq(cmd.workdir, Some(leaf_worktree))
    if cmd.args == ["-lc", "moon test --target native"] {
      (0, "declared suite passed")
    } else if cmd.args == ["-lc", "false"] {
      (1, "forged non-test command failed")
    } else {
      fail("unexpected TDD command: " + cmd.args.join(" "))
    }
  }
  let intent = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_intent",
      args: {
        "caller_id": "main.leaf",
        "intent": "cover forge rejection",
        "test_command": "moon test --target native",
      },
    },
    project_dir~,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  assert_true(intent.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Intent }))

  let red = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_red_check",
      args: { "caller_id": "main.leaf", "command": "false", "exit_code": "1" },
    },
    project_dir~,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  match red {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("actual exit code 0"))
      assert_true(msg.contains("command: moon test --target native"))
    }
    @types.Response::Ok(_) =>
      fail("expected red gate to reject check-time command forge")
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Intent }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD red check ignores leaf-rewritten verify config" {
  let project_dir = "/tmp/choir-tdd-config-rewrite-forge-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["false"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Intent,
  })
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  tdd_test_write_verify_config(leaf_worktree, ["true"])
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    @debug.assert_eq(cmd, @workspace.Command::{
      program: "sh",
      args: ["-lc", "false"],
      workdir: Some(leaf_worktree),
    })
    (1, "authoritative verify still fails")
  }
  let red = interpret_tdd_red_check(
    { caller_id: "main.leaf", exit_code: 1 },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Red }))
  ignore(@sys.rm_rf(project_dir))
}

///|
test "leaf TDD green check cannot skip red phase" {
  match
    plan_tdd_green_check_transition(
      Some(@types.LeafTddPhase::Intent),
      0,
      Some(@types.LeafTddPhase::Done),
    ) {
    Err(e) =>
      assert_true(e.message().contains("Intent -> Red -> Green -> Done"))
    Ok(_) => fail("expected green gate to reject skipped red phase")
  }
}

///|
async test "leaf TDD green check rejects forged passing report when command fails" {
  let project_dir = "/tmp/choir-tdd-green-forge-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["false"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Red,
  })
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    @debug.assert_eq(cmd, @workspace.Command::{
      program: "sh",
      args: ["-lc", "false"],
      workdir: Some(leaf_worktree),
    })
    (1, "actual fail")
  }
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
  )
  match green {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("actual exit code"))
      assert_true(msg.contains("green check expected exit code 0"))
      assert_true(msg.contains("command: false"))
      assert_true(msg.contains("output_tail:\nactual fail"))
    }
    @types.Response::Ok(_) => fail("expected green gate to reject forged pass")
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Red }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD green check prefers configured no-exec fast lane" {
  let project_dir = "/tmp/choir-tdd-green-fast-lane-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let fast = "CHOIR_TEST_NO_EXEC=1 moon test --target native"
  let slow = "moon test --target native"
  let lint = "moon run src/bin/choir_lint --target native"
  let contract = tdd_test_verify_contract([fast, slow, lint])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Red,
  })
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let seen_commands : Array[String] = []
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      assert_eq(cmd.program, "sh")
      @debug.assert_eq(cmd.workdir, Some(leaf_worktree))
      let command = cmd.args[1]
      seen_commands.push(command)
      if command == fast {
        (0, "fast lane passed\n")
      } else {
        fail("green check should not run slow verify lane: " + command)
      }
    },
  )
  match green {
    @types.Response::Ok(fields) => {
      @debug.assert_eq(fields.get_json("phase"), Some("green".to_json()))
      @debug.assert_eq(
        fields.get_json("command"),
        Some((fast + " && " + slow + " && " + lint).to_json()),
      )
      match fields.get_json("output_tail") {
        Some(Json::String(value)) =>
          assert_true(value.contains("fast lane passed"))
        _ => fail("expected fast lane output tail")
      }
    }
    @types.Response::Err(msg) =>
      fail("expected fast lane green check to pass: " + msg)
  }
  @debug.assert_eq(seen_commands, [fast])
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Green }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD green check blocks failing no-exec fast lane" {
  let project_dir = "/tmp/choir-tdd-green-fast-lane-red-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let fast = "CHOIR_TEST_NO_EXEC=1 moon test --target native"
  let slow = "moon test --target native"
  let contract = tdd_test_verify_contract([fast, slow])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let stored : @types.LeafTddState? = Some({ phase: @types.LeafTddPhase::Red })
  let mut writer_called = false
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, _state : @types.LeafTddState) -> Unit {
    writer_called = true
  }
  let seen_commands : Array[String] = []
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      let command = cmd.args[1]
      seen_commands.push(command)
      if command == fast {
        (9, "fast lane failed\n")
      } else {
        fail("green check should stop before slow verify lane: " + command)
      }
    },
  )
  match green {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("green check expected exit code 0"))
      assert_true(msg.contains("command: " + fast))
      assert_true(msg.contains("fast lane failed"))
    }
    @types.Response::Ok(_) => fail("expected failing fast lane to block")
  }
  @debug.assert_eq(seen_commands, [fast])
  assert_false(writer_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD green check treats baseline-red command as advisory" {
  let project_dir = "/tmp/choir-tdd-green-advisory-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["cmd-a", "cmd-b"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Red,
  })
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let seen_commands : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    assert_eq(cmd.program, "sh")
    @debug.assert_eq(cmd.workdir, Some(leaf_worktree))
    let command = cmd.args[1]
    if command == "cmd-a && cmd-b" {
      fail("green check should run verify commands individually")
    }
    seen_commands.push(command)
    if command == "cmd-a" {
      (7, "cmd-a failed\n")
    } else if command == "cmd-b" {
      (0, "cmd-b passed\n")
    } else {
      fail("unexpected TDD command: " + command)
    }
  }
  let mut baseline_lookup_calls = 0
  let mut baseline_verify_calls = 0
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 7, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
    baseline_sha_for_agent=fn(agent_id : String) -> String? {
      baseline_lookup_calls = baseline_lookup_calls + 1
      if agent_id == "main.leaf" {
        Some("baseline-sha")
      } else {
        None
      }
    },
    baseline_verify=async fn(
      sha : String,
      command : String,
      baseline_project_dir : String,
      _git_capture : async (@workspace.Command) -> (Int, String),
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> BaselineOutcome {
      @async.sleep(0)
      baseline_verify_calls = baseline_verify_calls + 1
      assert_eq(sha, "baseline-sha")
      assert_eq(command, "cmd-a")
      assert_eq(baseline_project_dir, leaf_worktree)
      BaselineOutcome::AlreadyRed
    },
  )
  match green {
    @types.Response::Ok(fields) =>
      match fields.get_json("output_tail") {
        Some(Json::String(value)) =>
          assert_true(value.contains("advisory, not blocking"))
        _ => fail("expected advisory output tail")
      }
    @types.Response::Err(msg) =>
      fail("expected advisory green check to pass: " + msg)
  }
  @debug.assert_eq(seen_commands, ["cmd-a", "cmd-b"])
  assert_eq(baseline_lookup_calls, 1)
  assert_eq(baseline_verify_calls, 1)
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Green }))
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD green check blocks command red from green baseline" {
  let project_dir = "/tmp/choir-tdd-green-regression-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["cmd-a"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let stored : @types.LeafTddState? = Some({ phase: @types.LeafTddPhase::Red })
  let mut writer_called = false
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, _state : @types.LeafTddState) -> Unit {
    writer_called = true
  }
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 7, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture=async fn(_cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      (2, "cmd-a failed\n")
    },
    baseline_sha_for_agent=fn(_agent_id : String) -> String? {
      Some("baseline-sha")
    },
    baseline_verify=async fn(
      _sha : String,
      _command : String,
      _baseline_project_dir : String,
      _git_capture : async (@workspace.Command) -> (Int, String),
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> BaselineOutcome {
      @async.sleep(0)
      BaselineOutcome::GreenAtBaseline
    },
  )
  match green {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("green check expected exit code 0"))
      assert_true(msg.contains("command: cmd-a"))
      assert_true(msg.contains("cmd-a failed"))
    }
    @types.Response::Ok(_) =>
      fail("expected green baseline regression to block")
  }
  assert_false(writer_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD green check blocks after advisory when later command regresses" {
  let project_dir = "/tmp/choir-tdd-green-advisory-regression-" +
    @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["cmd-a", "cmd-b"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let stored : @types.LeafTddState? = Some({ phase: @types.LeafTddPhase::Red })
  let mut writer_called = false
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, _state : @types.LeafTddState) -> Unit {
    writer_called = true
  }
  let seen_commands : Array[String] = []
  let baseline_commands : Array[String] = []
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 7, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      let command = cmd.args[1]
      seen_commands.push(command)
      if command == "cmd-a" {
        (7, "cmd-a failed\n")
      } else if command == "cmd-b" {
        (9, "cmd-b failed\n")
      } else {
        fail("unexpected TDD command: " + command)
      }
    },
    baseline_sha_for_agent=fn(_agent_id : String) -> String? {
      Some("baseline-sha")
    },
    baseline_verify=async fn(
      _sha : String,
      command : String,
      _baseline_project_dir : String,
      _git_capture : async (@workspace.Command) -> (Int, String),
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> BaselineOutcome {
      @async.sleep(0)
      baseline_commands.push(command)
      if command == "cmd-a" {
        BaselineOutcome::AlreadyRed
      } else if command == "cmd-b" {
        BaselineOutcome::GreenAtBaseline
      } else {
        BaselineOutcome::Unknown
      }
    },
  )
  match green {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("command: cmd-b"))
      assert_true(msg.contains("cmd-b failed"))
    }
    @types.Response::Ok(_) =>
      fail("expected later green-baseline regression to block")
  }
  @debug.assert_eq(seen_commands, ["cmd-a", "cmd-b"])
  @debug.assert_eq(baseline_commands, ["cmd-a", "cmd-b"])
  assert_false(writer_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "leaf TDD green check blocks unknown baseline outcome" {
  let project_dir = "/tmp/choir-tdd-green-unknown-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["cmd-a"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let stored : @types.LeafTddState? = Some({ phase: @types.LeafTddPhase::Red })
  let mut writer_called = false
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, _state : @types.LeafTddState) -> Unit {
    writer_called = true
  }
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture=async fn(_cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      (2, "cmd-a failed\n")
    },
    baseline_sha_for_agent=fn(_agent_id : String) -> String? {
      Some("baseline-sha")
    },
    baseline_verify=async fn(
      _sha : String,
      _command : String,
      _baseline_project_dir : String,
      _git_capture : async (@workspace.Command) -> (Int, String),
      _capture : async (@workspace.Command) -> (Int, String),
    ) -> BaselineOutcome {
      @async.sleep(0)
      BaselineOutcome::Unknown
    },
  )
  match green {
    @types.Response::Err(msg) => assert_true(msg.contains("command: cmd-a"))
    @types.Response::Ok(_) => fail("expected unknown baseline to block")
  }
  assert_false(writer_called)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "leaf TDD optional refactor requires green and a final passing check" {
  match
    plan_tdd_green_check_transition(
      Some(@types.LeafTddPhase::Green),
      0,
      Some(@types.LeafTddPhase::Refactor),
    ) {
    Ok(phase) => assert_eq(phase, @types.LeafTddPhase::Refactor)
    Err(e) => fail("expected green to enter refactor: " + e.message())
  }
  match
    plan_tdd_green_check_transition(
      Some(@types.LeafTddPhase::Refactor),
      1,
      Some(@types.LeafTddPhase::Done),
    ) {
    Err(e) => assert_true(e.message().contains("expected passing test"))
    Ok(_) => fail("expected refactor completion to reject failing result")
  }
  match
    plan_tdd_green_check_transition(
      Some(@types.LeafTddPhase::Refactor),
      0,
      Some(@types.LeafTddPhase::Green),
    ) {
    Err(e) => assert_true(e.message().contains("advance only to Done"))
    Ok(_) => fail("expected refactor to advance only to Done")
  }
  match
    plan_tdd_green_check_transition(
      Some(@types.LeafTddPhase::Refactor),
      0,
      Some(@types.LeafTddPhase::Done),
    ) {
    Ok(phase) => assert_eq(phase, @types.LeafTddPhase::Done)
    Err(e) =>
      fail("expected passing refactor check to mark done: " + e.message())
  }
}

///|
async test "leaf TDD tool handlers persist phase through injected tracker" {
  let project_dir = "/tmp/choir-tdd-handlers-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["moon test --target native"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = tdd_test_registry(leaf_worktree)
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let expected_exit_codes : Array[Int] = [2, 0, 0]
  let mut capture_index = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    assert_eq(cmd.program, "sh")
    @debug.assert_eq(cmd.args, ["-lc", "moon test --target native"])
    @debug.assert_eq(cmd.workdir, Some(leaf_worktree))
    if capture_index >= expected_exit_codes.length() {
      fail("unexpected extra TDD command capture")
    }
    let exit_code = expected_exit_codes[capture_index]
    capture_index = capture_index + 1
    (exit_code, "captured command " + capture_index.to_string())
  }
  let intent = interpret_tdd_intent(
    {
      caller_id: "main.leaf",
      intent: "cover file_pr gate",
      test_command: None,
      artifact_path: None,
    },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
  )
  match intent {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get_json("phase"), Some("intent".to_json()))
    @types.Response::Err(msg) => fail("expected intent ok: " + msg)
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Intent }))

  let red = interpret_tdd_red_check(
    { caller_id: "main.leaf", exit_code: 2 },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Red }))

  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
  )
  assert_true(green.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Green }))

  let done = interpret_tdd_green_check(
    {
      caller_id: "main.leaf",
      exit_code: 0,
      next_phase: Some(@types.LeafTddPhase::Done),
    },
    reader,
    writer,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    capture~,
  )
  assert_true(done.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Done }))
  assert_eq(capture_index, 3)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "dispatch_call parses TDD tools and persists the full gate sequence" {
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let project_dir = "/tmp/choir-tdd-dispatch-" + @sys.get_pid().to_string()
  let leaf_worktree = project_dir + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(project_dir))
  let contract = tdd_test_verify_contract(["moon test --target native"])
  tdd_test_write_verify_config(leaf_worktree, contract.verify)
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: "main.leaf",
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some("root"),
      workspace: leaf_worktree,
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let expected_exit_codes : Array[Int] = [2, 0, 0]
  let mut capture_index = 0
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" {
      return (0, "")
    }
    assert_eq(cmd.program, "sh")
    @debug.assert_eq(cmd.args, ["-lc", "moon test --target native"])
    @debug.assert_eq(cmd.workdir, Some(leaf_worktree))
    if capture_index >= expected_exit_codes.length() {
      fail("unexpected extra TDD command capture")
    }
    let exit_code = expected_exit_codes[capture_index]
    capture_index = capture_index + 1
    (exit_code, "captured dispatch command " + capture_index.to_string())
  }

  let intent = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_intent",
      args: {
        "caller_id": "main.leaf",
        "intent": "cover parser dispatch path",
        "test_command": "moon test --target native",
      },
    },
    project_dir~,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  match intent {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("phase"), Some("intent"))
    @types.Response::Err(msg) => fail("expected intent dispatch ok: " + msg)
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Intent }))

  let red = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_red_check",
      args: { "caller_id": "main.leaf", "exit_code": "2" },
    },
    project_dir~,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Red }))

  let green = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_green_check",
      args: { "caller_id": "main.leaf", "exit_code": "0" },
    },
    project_dir~,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  assert_true(green.is_ok())
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Green }))

  let done = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_green_check",
      args: { "caller_id": "main.leaf", "exit_code": "0", "next_phase": "done" },
    },
    project_dir~,
    registry=Some(reg),
    task_contract_reader=tdd_test_contract_reader(contract),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  match done {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("phase"), Some("done"))
    @types.Response::Err(msg) => fail("expected done dispatch ok: " + msg)
  }
  @debug.assert_eq(stored, Some({ phase: @types.LeafTddPhase::Done }))
  assert_eq(capture_index, 3)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "red check exit zero explains missing red and artifact verify recovery" {
  match plan_tdd_red_check_transition(Some(@types.LeafTddPhase::Intent), 0) {
    Err(e) => {
      let message = e.message()
      assert_true(message.contains("configured verify passed (exit 0)"))
      assert_true(message.contains("no failing test"))
      assert_true(message.contains("write the failing test first"))
      assert_true(message.contains("non-code"))
      assert_true(message.contains("artifact"))
      assert_true(message.contains("test -f <path> && <verify>"))
      assert_true(message.contains("notify the parent TL"))
    }
    Ok(_) => fail("expected exit 0 red check to reject")
  }
}
