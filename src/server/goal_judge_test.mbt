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
  judge.active_slug = Some("x")
  judge.last_eval = Some(previous)
  judge.last_prod_unix_sec = Some(10L)
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
  judge.active_slug = Some("x")
  judge.last_eval = Some(previous)
  judge.last_prod_unix_sec = Some(100L)
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
  assert_eq(delivered, [])
  assert_eq(clears, 0)
  assert_eq(writes.length(), 1)
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
  assert_eq(delivered, ["[GOAL COMPLETE: x]"])
  assert_eq(clears, 1)
  assert_eq(writes, 0)
}

///|
async test "goal judge emits superseded when kv slug changes" {
  let judge = GoalJudgeState::new()
  judge.active_slug = Some("old")
  judge.last_eval = Some(goal_judge_test_eval(0, 1, "shell failed: false", 1L))
  judge.last_prod_unix_sec = Some(1L)
  let delivered : Array[String] = []
  let writes : Array[@types.Goal] = []
  let mut clears = 0
  let result = judge.tick_with(
    2L,
    fn() { Ok(Some(@types.Goal::new("new", ["false"], 2L).unwrap())) },
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
  assert_eq(delivered.length(), 2)
  assert_eq(delivered[0], "[GOAL SUPERSEDED]")
  assert_eq(delivered[1], "[GOAL: new] 0/1 passing — shell failed: false")
  assert_eq(clears, 0)
  assert_eq(writes.length(), 1)
}
