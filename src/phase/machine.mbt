///|
pub(all) enum StopCheckResult {
  MustBlock(String)
  ShouldNudge(String)
  Clean
} derive(Show, Eq)

///|
pub(all) enum TransitionResult[P] {
  Transitioned(P)
  InvalidTransition(String)
} derive(Show, Eq)

///|
pub fn describe_stop_result(r : StopCheckResult) -> String {
  match r {
    MustBlock(reason) => "Must block: " + reason
    ShouldNudge(reason) => "Should nudge: " + reason
    Clean => "Clean"
  }
}

///|
pub fn sanitize_branch(branch : String) -> String {
  let mut res = ""
  for c in branch {
    if c == '.' {
      res = res + "--"
    } else {
      res = res + c.to_string()
    }
  }
  res
}

///|
pub fn scoped_phase_key(machine_name : String, branch : String) -> String {
  "phase-" + machine_name + "--" + sanitize_branch(branch)
}

///|
pub fn get_phase(
  project_dir : String,
  machine_name : String,
  branch : String,
) -> String? {
  let key = scoped_phase_key(machine_name, branch)
  let path = project_dir + "/.choir/kv/" + key
  let content = @sys.read_file(path)
  if content == "" {
    None
  } else {
    Some(content)
  }
}

///|
pub fn set_phase(
  project_dir : String,
  machine_name : String,
  branch : String,
  json : String,
) -> Bool {
  let key = scoped_phase_key(machine_name, branch)
  let path = project_dir + "/.choir/kv/" + key
  @sys.write_file_sync(path, json)
}

///|
pub fn apply_event(
  project_dir : String,
  machine_name : String,
  branch : String,
  current_json : String?,
  default_phase_json : String,
  transition_fn : (String, String) -> (String, Bool),
  event_json : String,
) -> String? {
  let current = match current_json {
    Some(j) => j
    None => default_phase_json
  }
  let (next_json, changed) = transition_fn(current, event_json)
  if changed {
    let ok = set_phase(project_dir, machine_name, branch, next_json)
    if ok {
      Some(next_json)
    } else {
      None
    }
  } else {
    Some(current)
  }
}
