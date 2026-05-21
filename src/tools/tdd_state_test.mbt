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
async test "leaf TDD red check rejects forged failing report when command passes" {
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Intent,
    test_command: Some("true"),
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
      workdir: Some("."),
    })
    (0, "actual pass")
  }
  let red = interpret_tdd_red_check(
    { caller_id: "main.leaf", exit_code: 1 },
    reader,
    writer,
    capture~,
  )
  match red {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("actual exit code"))
      assert_true(msg.contains("red check expected actual exit code"))
      assert_true(msg.contains("command: true"))
      assert_true(msg.contains("output_tail:\nactual pass"))
    }
    @types.Response::Ok(_) => fail("expected red gate to reject forged failure")
  }
  @debug.assert_eq(
    stored,
    Some({ phase: @types.LeafTddPhase::Intent, test_command: Some("true") }),
  )
}

///|
async test "leaf TDD red check rejects check-time non-test command forge" {
  let mut stored : @types.LeafTddState? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddState? { stored }
  let writer = fn(_agent_id : String, state : @types.LeafTddState) -> Unit {
    stored = Some(state)
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    @debug.assert_eq(cmd.workdir, Some("."))
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
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  assert_true(intent.is_ok())
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Intent,
      test_command: Some("moon test --target native"),
    }),
  )

  let red = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_red_check",
      args: { "caller_id": "main.leaf", "command": "false", "exit_code": "1" },
    },
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
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Intent,
      test_command: Some("moon test --target native"),
    }),
  )
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
  let mut stored : @types.LeafTddState? = Some({
    phase: @types.LeafTddPhase::Red,
    test_command: Some("false"),
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
      workdir: Some("."),
    })
    (1, "actual fail")
  }
  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    capture~,
  )
  match green {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("actual exit code"))
      assert_true(msg.contains("green check expected actual exit code 0"))
      assert_true(msg.contains("command: false"))
      assert_true(msg.contains("output_tail:\nactual fail"))
    }
    @types.Response::Ok(_) => fail("expected green gate to reject forged pass")
  }
  @debug.assert_eq(
    stored,
    Some({ phase: @types.LeafTddPhase::Red, test_command: Some("false") }),
  )
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
    @debug.assert_eq(cmd.workdir, Some("."))
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
      test_command: "moon test --target native",
    },
    reader,
    writer,
  )
  match intent {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get_json("phase"), Some("intent".to_json()))
    @types.Response::Err(msg) => fail("expected intent ok: " + msg)
  }
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Intent,
      test_command: Some("moon test --target native"),
    }),
  )

  let red = interpret_tdd_red_check(
    { caller_id: "main.leaf", exit_code: 2 },
    reader,
    writer,
    capture~,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Red,
      test_command: Some("moon test --target native"),
    }),
  )

  let green = interpret_tdd_green_check(
    { caller_id: "main.leaf", exit_code: 0, next_phase: None },
    reader,
    writer,
    capture~,
  )
  assert_true(green.is_ok())
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Green,
      test_command: Some("moon test --target native"),
    }),
  )

  let done = interpret_tdd_green_check(
    {
      caller_id: "main.leaf",
      exit_code: 0,
      next_phase: Some(@types.LeafTddPhase::Done),
    },
    reader,
    writer,
    capture~,
  )
  assert_true(done.is_ok())
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Done,
      test_command: Some("moon test --target native"),
    }),
  )
  assert_eq(capture_index, 3)
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
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  match intent {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("phase"), Some("intent"))
    @types.Response::Err(msg) => fail("expected intent dispatch ok: " + msg)
  }
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Intent,
      test_command: Some("moon test --target native"),
    }),
  )

  let red = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_red_check",
      args: { "caller_id": "main.leaf", "exit_code": "2" },
    },
    project_dir~,
    registry=Some(reg),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Red,
      test_command: Some("moon test --target native"),
    }),
  )

  let green = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_green_check",
      args: { "caller_id": "main.leaf", "exit_code": "0" },
    },
    project_dir~,
    registry=Some(reg),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  assert_true(green.is_ok())
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Green,
      test_command: Some("moon test --target native"),
    }),
  )

  let done = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_green_check",
      args: { "caller_id": "main.leaf", "exit_code": "0", "next_phase": "done" },
    },
    project_dir~,
    registry=Some(reg),
    tdd_state_reader=reader,
    tdd_state_writer=writer,
    capture~,
  )
  match done {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("phase"), Some("done"))
    @types.Response::Err(msg) => fail("expected done dispatch ok: " + msg)
  }
  @debug.assert_eq(
    stored,
    Some({
      phase: @types.LeafTddPhase::Done,
      test_command: Some("moon test --target native"),
    }),
  )
  assert_eq(capture_index, 3)
}
