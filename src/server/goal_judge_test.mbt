///|
fn goal_judge_test_eval(
  passing : Int,
  total : Int,
  failing_summary : String,
  evaluated_unix_sec : Int64,
) -> @types.GoalEvalResult {
  { passing, total, failing_summary, evaluated_unix_sec }
}

///|
fn goal_judge_test_open_goal(
  slug : String,
  last_eval : @types.GoalEvalResult?,
) -> @types.Goal {
  @types.Goal::new(slug, ["false"], 1L)
  .unwrap()
  .with_last_eval(
    last_eval.unwrap_or(goal_judge_test_eval(0, 1, "shell failed: false", 1L)),
  )
}

///|
async test "goal judge emits when evaluation transitions" {
  let judge = GoalJudgeState::new()
  let previous = goal_judge_test_eval(0, 2, "shell failed: first", 10L)
  let goal = @types.Goal::new("x", ["first", "second"], 1L)
    .unwrap()
    .with_last_eval(previous)
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut clears = 0
  let result = judge.tick_with(
    20L,
    fn() { Ok(Some(goal)) },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(1, 2, "shell failed: second", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  assert_eq(delivered.length(), 1)
  assert_eq(delivered[0], "[GOAL: x] 1/2 passing — shell failed: second")
  assert_eq(clears, 0)
  assert_eq(writes.length(), 1)
  match writes[0].last_eval {
    Some(eval) => assert_eq(eval.progress_label(), "1/2")
    None => fail("expected updated last_eval")
  }
}

///|
async test "goal judge suppresses unchanged state inside reminder window" {
  let judge = GoalJudgeState::new()
  let previous = goal_judge_test_eval(0, 1, "shell failed: false", 100L)
  let goal = goal_judge_test_open_goal("x", Some(previous))
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut clears = 0
  let result = judge.tick_with(
    120L,
    fn() { Ok(Some(goal)) },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  @debug.assert_eq(delivered, [])
  assert_eq(clears, 0)
  assert_eq(writes.length(), 0)
}

///|
async test "goal judge treats a same-second first eval as a real previous eval (no re-prod)" {
  // started_unix_sec and last_eval.evaluated_unix_sec are both second-
  // granularity; the first tick can stamp evaluated == started. That must
  // count as a previous eval so an unchanged-state second tick is rate-
  // limited rather than re-emitting the same [GOAL: ...] prod.
  let judge = GoalJudgeState::new()
  let goal = @types.Goal::new("x", ["false"], 5L)
    .unwrap()
    .with_last_eval(goal_judge_test_eval(0, 1, "shell failed: false", 5L))
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut clears = 0
  let result = judge.tick_with(
    10L,
    fn() { Ok(Some(goal)) },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  @debug.assert_eq(delivered, [])
  assert_eq(clears, 0)
}

///|
async test "goal judge emits complete exactly once and clears goal" {
  let judge = GoalJudgeState::new()
  let mut current_goal : @types.Goal? = Some(
    @types.Goal::new("x", ["true"], 1L).unwrap(),
  )
  let delivered : Array[String] = []
  let mut clears = 0
  let mut writes = 0
  let read_goal = fn() { Ok(current_goal) }
  let write_goal = fn(_updated : @types.Goal) {
    writes = writes + 1
    Ok(())
  }
  let clear_goal = fn() {
    clears = clears + 1
    current_goal = None
    Ok(())
  }
  let evaluator = async fn(_goal : @types.Goal, now : Int64) {
    @async.sleep(0)
    goal_judge_test_eval(1, 1, "", now)
  }
  let deliver = async fn(message : String, _status : @types.Status) {
    @async.sleep(0)
    delivered.push(message)
  }
  let first = judge.tick_with(
    20L, read_goal, write_goal, clear_goal, evaluator, deliver,
  )
  match first {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let second = judge.tick_with(
    50L, read_goal, write_goal, clear_goal, evaluator, deliver,
  )
  match second {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  @debug.assert_eq(delivered, ["[GOAL COMPLETE: x]"])
  assert_eq(clears, 1)
  assert_eq(writes, 0)
}

///|
async test "goal judge treats same-slug same-second replacement nonce as fresh state" {
  let judge = GoalJudgeState::new()
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut clears = 0
  let first_goal = @types.Goal::new("x", ["false"], 1L, nonce="first").unwrap()
  let first = judge.tick_with(
    20L,
    fn() { Ok(Some(first_goal)) },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match first {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let second_goal = @types.Goal::new("x", ["false"], 1L, nonce="second").unwrap()
  let second = judge.tick_with(
    21L,
    fn() { Ok(Some(second_goal)) },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match second {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  assert_eq(delivered.length(), 2)
  assert_eq(delivered[0], "[GOAL: x] 0/1 passing — shell failed: false")
  assert_eq(delivered[1], "[GOAL: x] 0/1 passing — shell failed: false")
  assert_eq(clears, 0)
  assert_eq(writes.length(), 2)
}

///|
async test "goal judge skips stale writes when kv changes during evaluation" {
  let judge = GoalJudgeState::new()
  let old_goal = @types.Goal::new("old", ["false"], 1L).unwrap()
  let new_goal = @types.Goal::new("new", ["false"], 2L).unwrap()
  let mut current_goal : @types.Goal? = Some(old_goal)
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut reads = 0
  let mut clears = 0
  let result = judge.tick_with(
    20L,
    fn() {
      reads = reads + 1
      Ok(current_goal)
    },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      current_goal = Some(new_goal)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  assert_eq(reads, 2)
  @debug.assert_eq(delivered, [])
  assert_eq(writes.length(), 0)
  assert_eq(clears, 0)
  match current_goal {
    Some(goal) => assert_eq(goal.slug, "new")
    None => fail("expected replacement goal to remain active")
  }
}

///|
async test "goal judge aborts write when kv changes immediately before write" {
  let judge = GoalJudgeState::new()
  let old_goal = @types.Goal::new("old", ["false"], 1L).unwrap()
  let new_goal = @types.Goal::new("new", ["false"], 2L).unwrap()
  let mut current_goal : @types.Goal? = Some(old_goal)
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut reads = 0
  let result = judge.tick_with(
    20L,
    fn() {
      reads = reads + 1
      Ok(current_goal)
    },
    fn(updated) {
      writes.push(updated)
      Ok(())
    },
    fn() { Ok(()) },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
      current_goal = Some(new_goal)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  assert_eq(reads, 3)
  @debug.assert_eq(delivered, [
    "[GOAL: old] 0/1 passing — shell failed: false",
  ])
  assert_eq(writes.length(), 0)
  match current_goal {
    Some(goal) => assert_eq(goal.slug, "new")
    None => fail("expected replacement goal to remain active")
  }
}

///|
async test "goal judge skips stale clears when kv changes during completion" {
  let judge = GoalJudgeState::new()
  let old_goal = @types.Goal::new("old", ["true"], 1L).unwrap()
  let new_goal = @types.Goal::new("new", ["false"], 2L).unwrap()
  let mut current_goal : @types.Goal? = Some(old_goal)
  let delivered : Array[String] = []
  let mut clears = 0
  let mut writes = 0
  let result = judge.tick_with(
    20L,
    fn() { Ok(current_goal) },
    fn(_updated) {
      writes = writes + 1
      Ok(())
    },
    fn() {
      clears = clears + 1
      current_goal = None
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      current_goal = Some(new_goal)
      goal_judge_test_eval(1, 1, "", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  @debug.assert_eq(delivered, [])
  assert_eq(clears, 0)
  assert_eq(writes, 0)
  match current_goal {
    Some(goal) => assert_eq(goal.slug, "new")
    None => fail("expected replacement goal to remain active")
  }
}

///|
async test "goal judge aborts delete when kv changes immediately before delete" {
  let judge = GoalJudgeState::new()
  let old_goal = @types.Goal::new("old", ["true"], 1L).unwrap()
  let new_goal = @types.Goal::new("new", ["false"], 2L).unwrap()
  let mut current_goal : @types.Goal? = Some(old_goal)
  let delivered : Array[String] = []
  let mut clears = 0
  let result = judge.tick_with(
    20L,
    fn() { Ok(current_goal) },
    fn(_updated) { Ok(()) },
    fn() {
      clears = clears + 1
      current_goal = None
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(1, 1, "", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
      current_goal = Some(new_goal)
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  @debug.assert_eq(delivered, ["[GOAL COMPLETE: old]"])
  assert_eq(clears, 0)
  match current_goal {
    Some(goal) => assert_eq(goal.slug, "new")
    None => fail("expected replacement goal to remain active")
  }
}

///|
async test "goal judge does not re-emit complete after clear failure" {
  let judge = GoalJudgeState::new()
  let goal = @types.Goal::new("x", ["true"], 1L).unwrap()
  let delivered : Array[String] = []
  let mut clears = 0
  let mut writes = 0
  let read_goal = fn() { Ok(Some(goal)) }
  let write_goal = fn(_updated : @types.Goal) {
    writes = writes + 1
    Ok(())
  }
  let clear_goal = fn() {
    clears = clears + 1
    Err(@types.ChoirError::workspace_error("delete failed"))
  }
  let evaluator = async fn(_goal : @types.Goal, now : Int64) {
    @async.sleep(0)
    goal_judge_test_eval(1, 1, "", now)
  }
  let deliver = async fn(message : String, _status : @types.Status) {
    @async.sleep(0)
    delivered.push(message)
  }
  let first = judge.tick_with(
    20L, read_goal, write_goal, clear_goal, evaluator, deliver,
  )
  match first {
    Err(e) => assert_true(e.message().contains("delete failed"))
    Ok(_) => fail("expected first clear failure")
  }
  let second = judge.tick_with(
    50L, read_goal, write_goal, clear_goal, evaluator, deliver,
  )
  match second {
    Err(e) => assert_true(e.message().contains("delete failed"))
    Ok(_) => fail("expected second clear failure")
  }
  @debug.assert_eq(delivered, ["[GOAL COMPLETE: x]"])
  assert_eq(clears, 2)
  assert_eq(writes, 0)
}

///|
async test "goal judge bounds completed goal memory after repeated clear failures" {
  let judge = GoalJudgeState::new()
  let mut current_goal = @types.Goal::new("x0", ["true"], 1L).unwrap()
  let delivered : Array[String] = []
  let evaluator = async fn(_goal : @types.Goal, now : Int64) {
    @async.sleep(0)
    goal_judge_test_eval(1, 1, "", now)
  }
  let deliver = async fn(message : String, _status : @types.Status) {
    @async.sleep(0)
    delivered.push(message)
  }
  for i = 0; i < 140; i = i + 1 {
    current_goal = @types.Goal::new(
      "x" + i.to_string(),
      ["true"],
      i.to_int64() + 1L,
      nonce="n" + i.to_string(),
    ).unwrap()
    let result = judge.tick_with(
      i.to_int64() + 20L,
      fn() { Ok(Some(current_goal)) },
      fn(_updated : @types.Goal) { Ok(()) },
      fn() { Err(@types.ChoirError::workspace_error("delete failed")) },
      evaluator,
      deliver,
    )
    match result {
      Err(e) => assert_true(e.message().contains("delete failed"))
      Ok(_) => fail("expected clear failure")
    }
  }
  assert_eq(delivered.length(), 140)
  assert_eq(judge.completed_goal_order.length(), 128)
  assert_false(judge.completed_goal_keys.contains("x0@n0"))
  assert_true(judge.completed_goal_keys.contains("x139@n139"))
}

///|
async test "server consumes requested goal judge tick flag" {
  let project_dir = "/tmp/choir-goal-requested-tick-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "test-session",
  }
  let state = ServerState::new(config, make_recovery_provider())
  state.request_goal_judge_tick()
  assert_true(state.goal_judge.tick_requested)
  let goal = @types.Goal::new("x", ["false"], 1L).unwrap()
  let delivered : Array[String] = []
  let mut reads = 0
  let consumed = state.process_requested_goal_judge_tick_with(
    20L,
    fn() {
      reads = reads + 1
      Ok(Some(goal))
    },
    async fn(_goal, now) {
      @async.sleep(0)
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(message, _status) {
      @async.sleep(0)
      delivered.push(message)
    },
    write_goal=fn(_updated) { Ok(()) },
    clear_goal=fn() { Ok(()) },
  )
  match consumed {
    Ok(true) => ()
    Ok(false) => fail("expected requested tick to be consumed")
    Err(e) => fail(e.message())
  }
  assert_false(state.goal_judge.tick_requested)
  assert_eq(reads, 3)
  @debug.assert_eq(delivered, ["[GOAL: x] 0/1 passing — shell failed: false"])
}

///|
async test "goal judge single-flight guard defers overlapping ticks" {
  let judge = GoalJudgeState::new()
  judge.tick_running = true
  let mut reads = 0
  let mut evaluations = 0
  let mut writes = 0
  let mut clears = 0
  let mut deliveries = 0
  let result = judge.tick_with(
    10L,
    fn() {
      reads = reads + 1
      Ok(Some(@types.Goal::new("x", ["false"], 1L).unwrap()))
    },
    fn(_updated) {
      writes = writes + 1
      Ok(())
    },
    fn() {
      clears = clears + 1
      Ok(())
    },
    async fn(_goal, now) {
      @async.sleep(0)
      evaluations = evaluations + 1
      goal_judge_test_eval(0, 1, "shell failed: false", now)
    },
    async fn(_message, _status) {
      @async.sleep(0)
      deliveries = deliveries + 1
    },
  )
  match result {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  assert_eq(reads, 0)
  assert_eq(evaluations, 0)
  assert_eq(writes, 0)
  assert_eq(clears, 0)
  assert_eq(deliveries, 0)
  assert_true(judge.tick_running)
  assert_true(judge.tick_requested)
}
