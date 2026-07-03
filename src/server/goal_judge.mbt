///|
pub(all) struct GoalJudgeState {
  mut tick_running : Bool
  mut tick_requested : Bool
  completed_goal_keys : Map[String, Bool]
  completed_goal_order : Array[String]
}

///|
let goal_judge_completed_goal_key_limit : Int = 128

///|
pub fn GoalJudgeState::new() -> GoalJudgeState {
  {
    tick_running: false,
    tick_requested: false,
    completed_goal_keys: {},
    completed_goal_order: [],
  }
}

///|
pub fn GoalJudgeState::request_tick(self : GoalJudgeState) -> Unit {
  self.tick_requested = true
}

///|
fn GoalJudgeState::begin_tick(self : GoalJudgeState) -> Bool {
  if self.tick_running {
    self.request_tick()
    false
  } else {
    self.tick_running = true
    self.tick_requested = false
    true
  }
}

///|
fn GoalJudgeState::finish_tick(self : GoalJudgeState) -> Unit {
  self.tick_running = false
}

///|
fn goal_judge_progress_failing_summary(eval : @types.GoalEvalResult) -> String {
  if eval.failing_summary == "" {
    "no failing checks"
  } else {
    eval.failing_summary
  }
}

///|
fn goal_judge_progress_message(
  goal : @types.Goal,
  eval : @types.GoalEvalResult,
) -> String {
  "[GOAL: " +
  goal.slug +
  "] " +
  eval.progress_label() +
  " passing — " +
  goal_judge_progress_failing_summary(eval)
}

///|
fn goal_judge_complete_message(goal : @types.Goal) -> String {
  "[GOAL COMPLETE: " + goal.slug + "]"
}

///|
fn goal_judge_completion_key(goal : @types.Goal) -> String {
  goal.slug + "@" + goal.nonce
}

///|
fn goal_judge_same_goal(a : @types.Goal, b : @types.Goal) -> Bool {
  a.slug == b.slug && a.nonce == b.nonce
}

///|
fn goal_judge_current_matches(
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  evaluated_goal : @types.Goal,
) -> Result[Bool, @types.ChoirError] {
  match read_goal() {
    Ok(Some(current)) => Ok(goal_judge_same_goal(current, evaluated_goal))
    Ok(None) => Ok(false)
    Err(e) => Err(e)
  }
}

///|
fn goal_judge_write_if_current(
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  evaluated_goal : @types.Goal,
  write_goal : (@types.Goal) -> Result[Unit, @types.ChoirError],
  updated_goal : @types.Goal,
) -> Result[Bool, @types.ChoirError] {
  match goal_judge_current_matches(read_goal, evaluated_goal) {
    Ok(true) =>
      // No flock on the KV; the re-read-immediately-before-write narrows but
      // does not eliminate the sub-ms window. The consequence is a clobbered
      // goal the user re-issues; recoverable. A fully serialized fix would
      // route all goal mutations through the server's loop; out of scope here.
      match write_goal(updated_goal) {
        Ok(_) => Ok(true)
        Err(e) => Err(e)
      }
    Ok(false) => Ok(false)
    Err(e) => Err(e)
  }
}

///|
fn goal_judge_clear_if_current(
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  evaluated_goal : @types.Goal,
  clear_goal : () -> Result[Unit, @types.ChoirError],
) -> Result[Bool, @types.ChoirError] {
  match goal_judge_current_matches(read_goal, evaluated_goal) {
    Ok(true) =>
      // No flock on the KV; the re-read-immediately-before-delete narrows but
      // does not eliminate the sub-ms window. The consequence is a clobbered
      // goal the user re-issues; recoverable. A fully serialized fix would
      // route all goal mutations through the server's loop; out of scope here.
      match clear_goal() {
        Ok(_) => Ok(true)
        Err(e) => Err(e)
      }
    Ok(false) => Ok(false)
    Err(e) => Err(e)
  }
}

///|
fn goal_judge_previous_eval(goal : @types.Goal) -> @types.GoalEvalResult? {
  // `>=`, not `>`: started_unix_sec and evaluated_unix_sec are both
  // second-granularity (@poller.now_sec()), so the first judge tick can
  // legitimately stamp evaluated_unix_sec == started_unix_sec when it runs
  // in the same wall-clock second the goal was created. With `>` that valid
  // first eval was discarded, previous_eval became None, and the same
  // `[GOAL: …]` progress prod was re-emitted instead of being rate-limited.
  match goal.last_eval {
    Some(eval) if eval.evaluated_unix_sec >= goal.started_unix_sec => Some(eval)
    _ => None
  }
}

///|
fn GoalJudgeState::already_completed(
  self : GoalJudgeState,
  goal : @types.Goal,
) -> Bool {
  self.completed_goal_keys.contains(goal_judge_completion_key(goal))
}

///|
fn GoalJudgeState::note_completed(
  self : GoalJudgeState,
  goal : @types.Goal,
) -> Unit {
  let key = goal_judge_completion_key(goal)
  if !self.completed_goal_keys.contains(key) {
    self.completed_goal_order.push(key)
  }
  self.completed_goal_keys.set(key, true)
  while self.completed_goal_order.length() > goal_judge_completed_goal_key_limit {
    let old = self.completed_goal_order.remove(0)
    self.completed_goal_keys.remove(old)
  }
}

///|
fn GoalJudgeState::forget_completed(
  self : GoalJudgeState,
  goal : @types.Goal,
) -> Unit {
  let key = goal_judge_completion_key(goal)
  self.completed_goal_keys.remove(key)
  let mut i = 0
  while i < self.completed_goal_order.length() {
    if self.completed_goal_order[i] == key {
      ignore(self.completed_goal_order.remove(i))
    } else {
      i = i + 1
    }
  }
}

///|
pub async fn GoalJudgeState::tick_with(
  self : GoalJudgeState,
  now_unix_sec : Int64,
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  write_goal : (@types.Goal) -> Result[Unit, @types.ChoirError],
  clear_goal : () -> Result[Unit, @types.ChoirError],
  evaluator : async (@types.Goal, Int64) -> @types.GoalEvalResult,
  deliver : async (String, @types.Status) -> Unit,
  reminder_interval_sec? : Int64 = @types.goal_prod_reminder_interval_sec,
) -> Result[Unit, @types.ChoirError] {
  if !self.begin_tick() {
    return Ok(())
  }
  let result = self.tick_once_with(
    now_unix_sec,
    read_goal,
    write_goal,
    clear_goal,
    evaluator,
    deliver,
    reminder_interval_sec~,
  )
  self.finish_tick()
  result
}

///|
async fn GoalJudgeState::tick_once_with(
  self : GoalJudgeState,
  now_unix_sec : Int64,
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  write_goal : (@types.Goal) -> Result[Unit, @types.ChoirError],
  clear_goal : () -> Result[Unit, @types.ChoirError],
  evaluator : async (@types.Goal, Int64) -> @types.GoalEvalResult,
  deliver : async (String, @types.Status) -> Unit,
  reminder_interval_sec? : Int64 = @types.goal_prod_reminder_interval_sec,
) -> Result[Unit, @types.ChoirError] {
  let goal = match read_goal() {
    Ok(Some(goal)) => goal
    Ok(None) => return Ok(())
    Err(e) => return Err(e)
  }
  let previous_eval = goal_judge_previous_eval(goal)
  let last_prod_unix_sec = match previous_eval {
    Some(eval) => Some(eval.evaluated_unix_sec)
    None => None
  }
  let current_eval = evaluator(goal, now_unix_sec)
  if current_eval.is_complete() && self.already_completed(goal) {
    match goal_judge_clear_if_current(read_goal, goal, clear_goal) {
      Ok(true) => {
        self.forget_completed(goal)
        return Ok(())
      }
      Ok(false) => {
        self.forget_completed(goal)
        return Ok(())
      }
      Err(e) => return Err(e)
    }
  }
  match
    @types.goal_prod_decision(
      previous_eval,
      current_eval,
      last_prod_unix_sec,
      now_unix_sec,
      reminder_interval_sec~,
    ) {
    @types.GoalProdDecision::EmitComplete =>
      match goal_judge_current_matches(read_goal, goal) {
        Ok(true) => {
          deliver(goal_judge_complete_message(goal), @types.Status::Success)
          self.note_completed(goal)
          match goal_judge_clear_if_current(read_goal, goal, clear_goal) {
            Ok(true) => {
              self.forget_completed(goal)
              Ok(())
            }
            Ok(false) => Ok(())
            Err(e) => Err(e)
          }
        }
        Ok(false) => Ok(())
        Err(e) => Err(e)
      }
    @types.GoalProdDecision::EmitProgress
    | @types.GoalProdDecision::EmitReminder =>
      match goal_judge_current_matches(read_goal, goal) {
        Ok(true) => {
          deliver(
            goal_judge_progress_message(goal, current_eval),
            @types.Status::Info,
          )
          let updated = goal.with_last_eval(current_eval)
          match
            goal_judge_write_if_current(read_goal, goal, write_goal, updated) {
            Ok(_) => Ok(())
            Err(e) => Err(e)
          }
        }
        Ok(false) => Ok(())
        Err(e) => Err(e)
      }
    @types.GoalProdDecision::Suppress => Ok(())
  }
}

///|
fn goal_judge_read_goal(
  project_dir : String,
  session : String,
  read_file : (String) -> String,
) -> Result[@types.Goal?, @types.ChoirError] {
  let path = match @types.goal_kv_path(project_dir, session) {
    Ok(path) => path
    Err(e) => return Err(e)
  }
  let raw = read_file(path).trim().to_owned()
  if raw == "" {
    return Ok(None)
  }
  match @types.Goal::from_json_string(raw) {
    Ok(goal) => Ok(Some(goal))
    Err(e) => Err(e)
  }
}

///|
fn goal_judge_write_goal(
  project_dir : String,
  session : String,
  write_file_atomic : (String, String) -> Bool,
  goal : @types.Goal,
) -> Result[Unit, @types.ChoirError] {
  let path = match @types.goal_kv_path(project_dir, session) {
    Ok(path) => path
    Err(e) => return Err(e)
  }
  if write_file_atomic(path, goal.to_json_string()) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "failed to write goal kv file: " + path,
      ),
    )
  }
}

///|
fn goal_judge_clear_goal(
  project_dir : String,
  session : String,
  delete_file : (String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  let path = match @types.goal_kv_path(project_dir, session) {
    Ok(path) => path
    Err(e) => return Err(e)
  }
  if delete_file(path) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "failed to delete goal kv file: " + path,
      ),
    )
  }
}

///|
async fn goal_judge_evaluate_with_caps(
  goal : @types.Goal,
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  bd_capture : async (@workspace.Command) -> (Int, String),
  now_unix_sec : Int64,
) -> @types.GoalEvalResult {
  @tools.goal_evaluate_with_workspace_caps(
    goal, project_dir, runner, bd_capture, now_unix_sec,
  )
}

///|
fn goal_judge_tl_agent_id(state : ServerState) -> String {
  state.config.agent_id.unwrap_or("root")
}

///|
fn goal_judge_delivery_log_message(raw : String) -> String {
  let buf = StringBuilder::new()
  for c in raw {
    if c == '\n' || c == '\r' {
      buf.write_char(' ')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
async fn ServerState::deliver_goal_judge_message(
  self : ServerState,
  message : String,
  status : @types.Status,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let target_id = goal_judge_tl_agent_id(self)
  ignore(
    @poller.append_delivery_log_line(
      self.append_file,
      self.config.project_dir,
      "[goal-judge] target=" +
      target_id +
      " " +
      goal_judge_delivery_log_message(message),
    ),
  )
  try {
    let target = self.resolve_parent_by_id(target_id)
    ignore(
      self.durable_deliver_to_agent(
        target, "goal_judge", message, status, runner,
      ),
    )
  } catch {
    e =>
      @moontrace.error("goal judge delivery failed", fields=[
        @moontrace.field("target", target_id),
        @moontrace.field("error", e.to_string()),
      ])
  }
}

///|
pub async fn ServerState::process_goal_judge_tick_with(
  self : ServerState,
  now_unix_sec : Int64,
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  evaluator : async (@types.Goal, Int64) -> @types.GoalEvalResult,
  deliver : async (String, @types.Status) -> Unit,
  write_goal? : (@types.Goal) -> Result[Unit, @types.ChoirError] = fn(goal) {
    goal_judge_write_goal(
      self.config.project_dir,
      self.config.terminal_session,
      self.write_file_atomic,
      goal,
    )
  },
  clear_goal? : () -> Result[Unit, @types.ChoirError] = fn() {
    goal_judge_clear_goal(
      self.config.project_dir,
      self.config.terminal_session,
      self.delete_file,
    )
  },
  reminder_interval_sec? : Int64 = @types.goal_prod_reminder_interval_sec,
) -> Result[Unit, @types.ChoirError] {
  self.goal_judge.tick_with(
    now_unix_sec,
    read_goal,
    write_goal,
    clear_goal,
    evaluator,
    deliver,
    reminder_interval_sec~,
  )
}

///|
pub async fn ServerState::process_requested_goal_judge_tick_with(
  self : ServerState,
  now_unix_sec : Int64,
  read_goal : () -> Result[@types.Goal?, @types.ChoirError],
  evaluator : async (@types.Goal, Int64) -> @types.GoalEvalResult,
  deliver : async (String, @types.Status) -> Unit,
  write_goal? : (@types.Goal) -> Result[Unit, @types.ChoirError] = fn(goal) {
    goal_judge_write_goal(
      self.config.project_dir,
      self.config.terminal_session,
      self.write_file_atomic,
      goal,
    )
  },
  clear_goal? : () -> Result[Unit, @types.ChoirError] = fn() {
    goal_judge_clear_goal(
      self.config.project_dir,
      self.config.terminal_session,
      self.delete_file,
    )
  },
  reminder_interval_sec? : Int64 = @types.goal_prod_reminder_interval_sec,
) -> Result[Bool, @types.ChoirError] {
  if !self.goal_judge.tick_requested || self.goal_judge.tick_running {
    return Ok(false)
  }
  match
    self.process_goal_judge_tick_with(
      now_unix_sec,
      read_goal,
      evaluator,
      deliver,
      write_goal~,
      clear_goal~,
      reminder_interval_sec~,
    ) {
    Ok(_) => Ok(true)
    Err(e) => Err(e)
  }
}

///|
pub fn ServerState::request_goal_judge_tick(self : ServerState) -> Unit {
  self.goal_judge.request_tick()
}

///|
pub async fn ServerState::process_requested_goal_judge_tick(
  self : ServerState,
  now_unix_sec : Int64,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
  bd_capture~ : async (@workspace.Command) -> (Int, String),
) -> Bool {
  match
    self.process_requested_goal_judge_tick_with(
      now_unix_sec,
      fn() {
        goal_judge_read_goal(
          self.config.project_dir,
          self.config.terminal_session,
          self.read_file,
        )
      },
      async fn(goal, now) {
        goal_judge_evaluate_with_caps(
          goal,
          self.config.project_dir,
          runner,
          bd_capture,
          now,
        )
      },
      async fn(message, status) {
        self.deliver_goal_judge_message(message, status, runner)
      },
    ) {
    Ok(consumed) => consumed
    Err(e) => {
      @moontrace.error("goal judge requested tick failed", fields=[
        @moontrace.field("error", e.message()),
      ])
      true
    }
  }
}

///|
pub async fn ServerState::process_goal_judge_tick(
  self : ServerState,
  now_unix_sec : Int64,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
  bd_capture~ : async (@workspace.Command) -> (Int, String),
) -> Unit {
  match
    self.process_goal_judge_tick_with(
      now_unix_sec,
      fn() {
        goal_judge_read_goal(
          self.config.project_dir,
          self.config.terminal_session,
          self.read_file,
        )
      },
      async fn(goal, now) {
        goal_judge_evaluate_with_caps(
          goal,
          self.config.project_dir,
          runner,
          bd_capture,
          now,
        )
      },
      async fn(message, status) {
        self.deliver_goal_judge_message(message, status, runner)
      },
    ) {
    Ok(_) => ()
    Err(e) =>
      @moontrace.error("goal judge tick failed", fields=[
        @moontrace.field("error", e.message()),
      ])
  }
}

///|
fn goal_judge_post_tool_trigger(
  req : @types.Request,
  resp : @types.Response,
) -> Bool {
  if !resp.is_ok() {
    return false
  }
  req.req_method == "tools/call" &&
  (req.name == "merge_pr" || req.name == "notify_parent")
}
