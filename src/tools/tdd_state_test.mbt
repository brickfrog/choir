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
test "leaf TDD red check rejects a passing reported result" {
  match plan_tdd_red_check_transition(Some(@types.LeafTddPhase::Intent), 0) {
    Err(e) => {
      assert_true(e.message().contains("expected failing test"))
      assert_true(e.message().contains("exit_code != 0"))
    }
    Ok(_) => fail("expected red gate to reject passing result")
  }
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
test "leaf TDD green check rejects failing reported result" {
  match
    plan_tdd_green_check_transition(Some(@types.LeafTddPhase::Red), 1, None) {
    Err(e) => {
      assert_true(e.message().contains("expected passing test"))
      assert_true(e.message().contains("exit_code == 0"))
    }
    Ok(_) => fail("expected green gate to reject failing result")
  }
}

///|
test "leaf TDD tool handlers persist phase through injected tracker" {
  let mut stored : @types.LeafTddPhase? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddPhase? { stored }
  let writer = fn(_agent_id : String, phase : @types.LeafTddPhase) -> Unit {
    stored = Some(phase)
  }
  let intent = interpret_tdd_intent(
    {
      caller_id: "main.leaf",
      intent: "cover file_pr gate",
      test_command: Some("moon test --target native"),
    },
    reader,
    writer,
  )
  match intent {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get_json("phase"), Some("intent".to_json()))
    @types.Response::Err(msg) => fail("expected intent ok: " + msg)
  }
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Intent))

  let red = interpret_tdd_red_check(
    {
      caller_id: "main.leaf",
      command: "moon test --target native",
      exit_code: 2,
      output: None,
    },
    reader,
    writer,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Red))

  let green = interpret_tdd_green_check(
    {
      caller_id: "main.leaf",
      command: "moon test --target native",
      exit_code: 0,
      output: None,
      next_phase: None,
    },
    reader,
    writer,
  )
  assert_true(green.is_ok())
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Green))

  let done = interpret_tdd_green_check(
    {
      caller_id: "main.leaf",
      command: "moon test --target native",
      exit_code: 0,
      output: None,
      next_phase: Some(@types.LeafTddPhase::Done),
    },
    reader,
    writer,
  )
  assert_true(done.is_ok())
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Done))
}

///|
async test "dispatch_call parses TDD tools and persists the full gate sequence" {
  let mut stored : @types.LeafTddPhase? = None
  let reader = fn(_agent_id : String) -> @types.LeafTddPhase? { stored }
  let writer = fn(_agent_id : String, phase : @types.LeafTddPhase) -> Unit {
    stored = Some(phase)
  }
  let project_dir = "/tmp/choir-tdd-dispatch-" + @sys.get_pid().to_string()

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
    tdd_phase_reader=reader,
    tdd_phase_writer=writer,
  )
  match intent {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("phase"), Some("intent"))
    @types.Response::Err(msg) => fail("expected intent dispatch ok: " + msg)
  }
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Intent))

  let red = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_red_check",
      args: {
        "caller_id": "main.leaf",
        "command": "moon test --target native",
        "exit_code": "2",
      },
    },
    project_dir~,
    tdd_phase_reader=reader,
    tdd_phase_writer=writer,
  )
  assert_true(red.is_ok())
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Red))

  let green = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_green_check",
      args: {
        "caller_id": "main.leaf",
        "command": "moon test --target native",
        "exit_code": "0",
      },
    },
    project_dir~,
    tdd_phase_reader=reader,
    tdd_phase_writer=writer,
  )
  assert_true(green.is_ok())
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Green))

  let done = dispatch_call(
    ToolCall::{
      role: @types.Role::Dev,
      name: "tdd_green_check",
      args: {
        "caller_id": "main.leaf",
        "command": "moon test --target native",
        "exit_code": "0",
        "next_phase": "done",
      },
    },
    project_dir~,
    tdd_phase_reader=reader,
    tdd_phase_writer=writer,
  )
  match done {
    @types.Response::Ok(fields) =>
      @debug.assert_eq(fields.get("phase"), Some("done"))
    @types.Response::Err(msg) => fail("expected done dispatch ok: " + msg)
  }
  @debug.assert_eq(stored, Some(@types.LeafTddPhase::Done))
}
