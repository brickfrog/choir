///|
fn goal_response_json(goal : @types.Goal) -> Json {
  @json.parse(goal.to_json_string()) catch {
    _ => goal.to_json_string().to_json()
  }
}

///|
priv struct GoalReadResult {
  goal : @types.Goal?
  warning : String?
}

///|
fn goal_eval_response_fields(eval : @types.GoalEvalResult) -> Map[String, Json] {
  {
    "passing": eval.passing.to_json(),
    "total": eval.total.to_json(),
    "progress": eval.progress_label().to_json(),
    "failing_summary": eval.failing_summary.to_json(),
    "evaluated_unix_sec": eval.evaluated_unix_sec.to_json(),
    "complete": eval.is_complete().to_json(),
  }
}

///|
async fn goal_noop_deliver(_message : String, _status : @types.Status) -> Unit {
  @async.sleep(0)
  ()
}

///|
fn goal_noop_request_tick() -> Unit {
  ()
}

///|
fn goal_read_current(
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
fn goal_read_current_best_effort(
  project_dir : String,
  session : String,
  read_file : (String) -> String,
) -> Result[GoalReadResult, @types.ChoirError] {
  let path = match @types.goal_kv_path(project_dir, session) {
    Ok(path) => path
    Err(e) => return Err(e)
  }
  let raw = read_file(path).trim().to_owned()
  if raw == "" {
    return Ok({ goal: None, warning: None })
  }
  match @types.Goal::from_json_string(raw) {
    Ok(goal) => Ok({ goal: Some(goal), warning: None })
    Err(e) =>
      Ok({
        goal: None,
        warning: Some("ignored corrupt existing goal: " + e.message()),
      })
  }
}

///|
pub async fn goal_evaluate_with_workspace_caps(
  goal : @types.Goal,
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  bd_capture : async (@workspace.Command) -> (Int, String),
  now_unix_sec : Int64,
) -> @types.GoalEvalResult {
  goal.evaluate(
    async fn(command : String) -> Int {
      let statuses = runner([
        @workspace.Command::{
          program: "sh",
          args: ["-c", command],
          workdir: Some(project_dir),
        },
      ]) catch {
        _ => [-1]
      }
      if statuses.length() == 0 {
        -1
      } else {
        statuses[0]
      }
    },
    async fn(bead_id : String) -> (Int, String) {
      bd_capture(@workspace.Command::{
        program: "bd",
        args: ["show", bead_id, "--json"],
        workdir: Some(project_dir),
      }) catch {
        _ => (-1, "")
      }
    },
    now_unix_sec~,
  )
}

///|
fn goal_status_response(goal : @types.Goal) -> @types.Response {
  let fields : Map[String, Json] = {
    "status": "active".to_json(),
    "active": true.to_json(),
    "slug": goal.slug.to_json(),
    "checks": goal.checks.length().to_json(),
    "started_unix_sec": goal.started_unix_sec.to_json(),
    "goal": goal_response_json(goal),
  }
  match goal.last_eval {
    Some(eval) => {
      let eval_fields = goal_eval_response_fields(eval)
      eval_fields.each(fn(k, v) { fields.set(k, v) })
    }
    None => {
      fields.set("passing", Int::to_json(0))
      fields.set("total", goal.checks.length().to_json())
      fields.set(
        "progress",
        ("0/" + goal.checks.length().to_string()).to_json(),
      )
      fields.set("failing_summary", "".to_json())
      fields.set("complete", false.to_json())
    }
  }
  @types.Response::ok_values(fields)
}

///|
pub async fn interpret_goal_set(
  args : GoalSetArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  bd_capture : async (@workspace.Command) -> (Int, String),
  read_file : (String) -> String,
  write_file_atomic : (String, String) -> Bool,
  create_dir_all : (String) -> Bool,
  now_unix_sec : Int64,
  nonce : String,
  goal_deliver? : async (String, @types.Status) -> Unit = goal_noop_deliver,
  goal_request_tick? : () -> Unit = goal_noop_request_tick,
) -> @types.Response {
  let existing = match
    goal_read_current_best_effort(project_dir, session, read_file) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let goal = match
    @types.Goal::new(args.input, args.verify, now_unix_sec, nonce~) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let eval = goal_evaluate_with_workspace_caps(
    goal, project_dir, runner, bd_capture, now_unix_sec,
  )
  if !create_dir_all(project_dir + "/.choir/kv") {
    return @types.Response::Err("failed to create goal kv directory")
  }
  let path = match @types.goal_kv_path(project_dir, session) {
    Ok(path) => path
    Err(e) => return @types.Response::Err(e.message())
  }
  if !write_file_atomic(path, goal.to_json_string()) {
    return @types.Response::Err("failed to write goal kv file: " + path)
  }
  match existing.goal {
    Some(old) =>
      goal_deliver("[GOAL SUPERSEDED: " + old.slug + "]", @types.Status::Info)
    None => ()
  }
  goal_request_tick()
  let kv_key = match @types.goal_kv_key(session) {
    Ok(key) => key
    Err(e) => return @types.Response::Err(e.message())
  }
  let fields : Map[String, Json] = {
    "status": "set".to_json(),
    "active": true.to_json(),
    "slug": goal.slug.to_json(),
    "kv_key": kv_key.to_json(),
    "superseded": (existing.goal is Some(_) || existing.warning is Some(_)).to_json(),
    "goal": goal_response_json(goal),
  }
  match existing.goal {
    Some(old) => fields.set("superseded_slug", old.slug.to_json())
    None => ()
  }
  match existing.warning {
    Some(warning) => fields.set("warning", warning.to_json())
    None => ()
  }
  let eval_fields = goal_eval_response_fields(eval)
  eval_fields.each(fn(k, v) { fields.set(k, v) })
  @types.Response::ok_values(fields)
}

///|
pub fn interpret_goal_clear(
  project_dir : String,
  session : String,
  read_file : (String) -> String,
  delete_file : (String) -> Bool,
) -> @types.Response {
  let path = match @types.goal_kv_path(project_dir, session) {
    Ok(path) => path
    Err(e) => return @types.Response::Err(e.message())
  }
  let current = match
    goal_read_current_best_effort(project_dir, session, read_file) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let fields : Map[String, Json] = {
    "status": "cleared".to_json(),
    "active": false.to_json(),
    "existed": (current.goal is Some(_) || current.warning is Some(_)).to_json(),
  }
  if current.goal is Some(_) || current.warning is Some(_) {
    if !delete_file(path) {
      return @types.Response::Err("failed to delete goal kv file: " + path)
    }
  }
  match current.goal {
    Some(goal) => fields.set("slug", goal.slug.to_json())
    None => ()
  }
  match current.warning {
    Some(warning) => fields.set("warning", warning.to_json())
    None => ()
  }
  @types.Response::ok_values(fields)
}

///|
pub async fn interpret_goal_status(
  args : GoalStatusArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  bd_capture : async (@workspace.Command) -> (Int, String),
  read_file : (String) -> String,
  now_unix_sec : Int64,
) -> @types.Response {
  let current = match goal_read_current(project_dir, session, read_file) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  match current {
    None =>
      @types.Response::ok_values({
        "status": "none".to_json(),
        "active": false.to_json(),
      })
    Some(goal) =>
      if args.evaluate {
        let eval = goal_evaluate_with_workspace_caps(
          goal, project_dir, runner, bd_capture, now_unix_sec,
        )
        goal_status_response(goal.with_last_eval(eval))
      } else {
        goal_status_response(goal)
      }
  }
}
