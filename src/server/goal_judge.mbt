///|
pub(all) struct GoalJudgeState {
  mut active_slug : String?
  mut last_prod_unix_sec : Int64?
  mut last_eval : @types.GoalEvalResult?
  mut tick_running : Bool
  mut tick_requested : Bool
  completed_goal_keys : Map[String, Bool]
}

///|
pub fn GoalJudgeState::new() -> GoalJudgeState {
  {
    active_slug: None,
    last_prod_unix_sec: None,
    last_eval: None,
    tick_running: false,
    tick_requested: false,
    completed_goal_keys: {},
  }
}

///|
fn GoalJudgeState::reset(self : GoalJudgeState) -> Unit {
  self.active_slug = None
  self.last_prod_unix_sec = None
  self.last_eval = None
}

///|
pub fn GoalJudgeState::request_tick(self : GoalJudgeState) -> Unit {
  self.tick_requested = true
}

///|
pub fn GoalJudgeState::note_superseded_goal(
  self : GoalJudgeState,
  slug : String,
) -> Unit {
  match self.active_slug {
    Some(active) if active == slug => self.reset()
    _ => ()
  }
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
  goal.slug + "@" + goal.started_unix_sec.to_string()
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
  self.completed_goal_keys.set(goal_judge_completion_key(goal), true)
}

///|
fn GoalJudgeState::forget_completed(
  self : GoalJudgeState,
  goal : @types.Goal,
) -> Unit {
  self.completed_goal_keys.remove(goal_judge_completion_key(goal))
}

///|
fn GoalJudgeState::note_prod(
  self : GoalJudgeState,
  now_unix_sec : Int64,
) -> Unit {
  self.last_prod_unix_sec = Some(now_unix_sec)
}

///|
fn GoalJudgeState::note_eval(
  self : GoalJudgeState,
  goal : @types.Goal,
  eval : @types.GoalEvalResult,
) -> Unit {
  self.active_slug = Some(goal.slug)
  self.last_eval = Some(eval)
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
    Ok(None) => {
      self.reset()
      return Ok(())
    }
    Err(e) => return Err(e)
  }
  let superseded = match self.active_slug {
    Some(slug) => slug != goal.slug
    None => false
  }
  if superseded {
    let old_slug = self.active_slug.unwrap_or("")
    deliver("[GOAL SUPERSEDED: " + old_slug + "]", @types.Status::Info)
    self.note_prod(now_unix_sec)
    self.last_eval = None
  }
  let previous_eval = if superseded || self.active_slug is None {
    None
  } else {
    match self.last_eval {
      Some(eval) => Some(eval)
      None => goal.last_eval
    }
  }
  let current_eval = evaluator(goal, now_unix_sec)
  if current_eval.is_complete() && self.already_completed(goal) {
    match clear_goal() {
      Ok(_) => {
        self.forget_completed(goal)
        self.reset()
        return Ok(())
      }
      Err(e) => return Err(e)
    }
  }
  match
    @types.goal_prod_decision(
      previous_eval,
      current_eval,
      self.last_prod_unix_sec,
      now_unix_sec,
      reminder_interval_sec~,
    ) {
    @types.GoalProdDecision::EmitComplete => {
      deliver(goal_judge_complete_message(goal), @types.Status::Success)
      self.note_prod(now_unix_sec)
      self.note_completed(goal)
      match clear_goal() {
        Ok(_) => {
          self.forget_completed(goal)
          self.reset()
          Ok(())
        }
        Err(e) => Err(e)
      }
    }
    @types.GoalProdDecision::EmitProgress
    | @types.GoalProdDecision::EmitReminder => {
      deliver(
        goal_judge_progress_message(goal, current_eval),
        @types.Status::Info,
      )
      self.note_prod(now_unix_sec)
      let updated = goal.with_last_eval(current_eval)
      match write_goal(updated) {
        Ok(_) => {
          self.note_eval(goal, current_eval)
          Ok(())
        }
        Err(e) => Err(e)
      }
    }
    @types.GoalProdDecision::Suppress => {
      let updated = goal.with_last_eval(current_eval)
      match write_goal(updated) {
        Ok(_) => {
          self.note_eval(goal, current_eval)
          Ok(())
        }
        Err(e) => Err(e)
      }
    }
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
    (self.append_file)(
      self.config.project_dir + "/.choir/delivery.log",
      "[goal-judge] target=" +
      target_id +
      " " +
      goal_judge_delivery_log_message(message) +
      "\n",
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
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  bd_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
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
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  bd_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
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
