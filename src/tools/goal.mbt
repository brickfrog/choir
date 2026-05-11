///|
fn goal_response_json(goal : @types.Goal) -> Json {
  @json.parse(goal.to_json_string()) catch {
    _ => goal.to_json_string().to_json()
  }
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
fn goal_read_current(
  project_dir : String,
  session : String,
  read_file : (String) -> String,
) -> Result[@types.Goal?, @types.ChoirError] {
  let raw = read_file(@types.goal_kv_path(project_dir, session))
    .trim()
    .to_owned()
  if raw == "" {
    return Ok(None)
  }
  match @types.Goal::from_json_string(raw) {
    Ok(goal) => Ok(Some(goal))
    Err(e) => Err(e)
  }
}

///|
async fn goal_evaluate_with_workspace_caps(
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
      ])
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
      })
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
) -> @types.Response {
  let previous = match goal_read_current(project_dir, session, read_file) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let goal = match @types.Goal::new(args.input, args.verify, now_unix_sec) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let eval = goal_evaluate_with_workspace_caps(
    goal, project_dir, runner, bd_capture, now_unix_sec,
  )
  let goal = goal.with_last_eval(eval)
  if !create_dir_all(project_dir + "/.choir/kv") {
    return @types.Response::Err("failed to create goal kv directory")
  }
  let path = @types.goal_kv_path(project_dir, session)
  if !write_file_atomic(path, goal.to_json_string()) {
    return @types.Response::Err("failed to write goal kv file: " + path)
  }
  let fields : Map[String, Json] = {
    "status": "set".to_json(),
    "active": true.to_json(),
    "slug": goal.slug.to_json(),
    "kv_key": @types.goal_kv_key(session).to_json(),
    "superseded": (previous is Some(_)).to_json(),
    "goal": goal_response_json(goal),
  }
  match previous {
    Some(old) => fields.set("superseded_slug", old.slug.to_json())
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
  let current = match goal_read_current(project_dir, session, read_file) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  ignore(delete_file(@types.goal_kv_path(project_dir, session)))
  let fields : Map[String, Json] = {
    "status": "cleared".to_json(),
    "active": false.to_json(),
    "existed": (current is Some(_)).to_json(),
  }
  match current {
    Some(goal) => fields.set("slug", goal.slug.to_json())
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
  write_file_atomic : (String, String) -> Bool,
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
        let updated = goal.with_last_eval(eval)
        let path = @types.goal_kv_path(project_dir, session)
        if !write_file_atomic(path, updated.to_json_string()) {
          return @types.Response::Err("failed to write goal kv file: " + path)
        }
        goal_status_response(updated)
      } else {
        goal_status_response(goal)
      }
  }
}
