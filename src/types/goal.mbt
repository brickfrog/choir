///|
pub(all) enum GoalSource {
  BeadId(String)
  Text(String)
} derive(Debug, Eq)

///|
pub(all) enum GoalCheck {
  ShellCommand(String)
  BeadStateClosed(String)
} derive(Debug, Eq)

///|
pub(all) struct GoalEvalResult {
  passing : Int
  total : Int
  failing_summary : String
  evaluated_unix_sec : Int64
} derive(Debug, Eq)

///|
pub(all) struct Goal {
  slug : String
  source : GoalSource
  checks : Array[GoalCheck]
  started_unix_sec : Int64
  last_eval : GoalEvalResult?
} derive(Debug, Eq)

///|
pub(all) enum GoalProdDecision {
  EmitProgress
  EmitReminder
  EmitComplete
  Suppress
} derive(Debug, Eq)

///|
pub let goal_prod_reminder_interval_sec : Int64 = 300L

///|
fn goal_validation_error(message : String) -> ChoirError {
  ChoirError::validation_error(message)
}

///|
fn goal_empty_checks_error() -> ChoirError {
  goal_validation_error(
    "a freeform goal needs at least one --verify <cmd>; or pass a bead id to inherit its acceptance.",
  )
}

///|
fn goal_json_null() -> Json {
  @json.parse("null") catch {
    _ => "".to_json()
  }
}

///|
fn validate_goal_kv_key(key : String) -> Result[Unit, ChoirError] {
  if key == "" {
    return Err(goal_validation_error("goal kv key cannot be empty"))
  }
  if key == "." {
    return Err(goal_validation_error("goal kv key cannot be '.'"))
  }
  if key.contains("..") {
    return Err(goal_validation_error("goal kv key cannot contain '..'"))
  }
  if key.contains("/") {
    return Err(goal_validation_error("goal kv key cannot contain '/'"))
  }
  for c in key {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.') {
      return Err(
        goal_validation_error(
          "invalid character in goal kv key: " + c.to_string(),
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn goal_kv_key(session : String) -> Result[String, ChoirError] {
  if session.trim().to_owned() == "" {
    return Err(goal_validation_error("goal kv session cannot be empty"))
  }
  let key = "tl-goal--" + session + ".json"
  match validate_goal_kv_key(key) {
    Ok(_) => Ok(key)
    Err(e) => Err(e)
  }
}

///|
pub fn goal_kv_path(
  project_dir : String,
  session : String,
) -> Result[String, ChoirError] {
  match goal_kv_key(session) {
    Ok(key) => Ok(project_dir + "/.choir/kv/" + key)
    Err(e) => Err(e)
  }
}

///|
fn goal_is_lower_alnum(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
}

///|
fn goal_is_prefix_char(c : Char) -> Bool {
  goal_is_lower_alnum(c) || c == '-' || c == '_'
}

///|
fn goal_all_digits(s : String) -> Bool {
  if s == "" {
    return false
  }
  for c in s {
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
fn goal_generated_bead_base(s : String) -> Bool {
  let hyphen = match s.rev_find("-") {
    Some(i) => i
    None => return false
  }
  if hyphen <= 0 || hyphen + 1 >= s.length() {
    return false
  }
  let prefix = s[0:hyphen].to_owned()
  let suffix = s[hyphen + 1:s.length()].to_owned()
  if suffix.length() != 3 {
    return false
  }
  for c in prefix {
    if !goal_is_prefix_char(c) {
      return false
    }
  }
  for c in suffix {
    if !goal_is_lower_alnum(c) {
      return false
    }
  }
  true
}

///|
pub fn goal_input_is_bead_id(raw : String) -> Bool {
  let trimmed = raw.trim().to_owned()
  if trimmed == "" {
    return false
  }
  if trimmed.contains(" ") ||
    trimmed.contains("\t") ||
    trimmed.contains("\n") ||
    trimmed.contains("\r") {
    return false
  }
  if trimmed.has_prefix("-") ||
    trimmed.has_prefix(".") ||
    trimmed.has_suffix("-") ||
    trimmed.has_suffix(".") ||
    trimmed.contains("..") {
    return false
  }
  match trimmed.split_once(".") {
    Some((base, child)) =>
      goal_generated_bead_base(base.to_owned()) &&
      goal_all_digits(child.to_owned())
    None => goal_generated_bead_base(trimmed)
  }
}

///|
fn goal_text_slug(text : String) -> String {
  let lowered = text.trim().to_lower().to_owned()
  let mut out = ""
  let mut last_dash = false
  for c in lowered {
    if goal_is_lower_alnum(c) {
      out = out + c.to_string()
      last_dash = false
    } else if out != "" && !last_dash {
      out = out + "-"
      last_dash = true
    }
    if out.length() >= 48 {
      break
    }
  }
  while out.has_suffix("-") {
    out = out[0:out.length() - 1].to_owned()
  }
  if out == "" {
    "goal"
  } else {
    out
  }
}

///|
pub fn GoalSource::from_input(raw : String) -> Result[GoalSource, ChoirError] {
  let trimmed = raw.trim().to_owned()
  if trimmed == "" {
    return Err(goal_validation_error("goal cannot be empty"))
  }
  if goal_input_is_bead_id(trimmed) {
    Ok(GoalSource::BeadId(trimmed))
  } else {
    Ok(GoalSource::Text(trimmed))
  }
}

///|
pub fn GoalSource::slug(self : GoalSource) -> String {
  match self {
    BeadId(id) => id
    Text(text) => goal_text_slug(text)
  }
}

///|
fn goal_source_value(source : GoalSource) -> String {
  match source {
    BeadId(id) => id
    Text(text) => text
  }
}

///|
fn goal_source_tag(source : GoalSource) -> String {
  match source {
    BeadId(_) => "bead_id"
    Text(_) => "text"
  }
}

///|
fn GoalSource::to_goal_json(self : GoalSource) -> Json {
  {
    "tag": goal_source_tag(self).to_json(),
    "value": goal_source_value(self).to_json(),
  }.to_json()
}

///|
fn GoalSource::from_goal_json(json : Json) -> Result[GoalSource, ChoirError] {
  guard json is Object(obj) else {
    return Err(goal_validation_error("goal source must be an object"))
  }
  let tag = match obj.get("tag") {
    Some(String(value)) => value
    _ => return Err(goal_validation_error("goal source missing tag"))
  }
  let value = match obj.get("value") {
    Some(String(value)) => value
    _ => return Err(goal_validation_error("goal source missing value"))
  }
  match tag {
    "bead_id" => Ok(GoalSource::BeadId(value))
    "text" => Ok(GoalSource::Text(value))
    _ => Err(goal_validation_error("unknown goal source tag: " + tag))
  }
}

///|
fn GoalCheck::to_goal_json(self : GoalCheck) -> Json {
  match self {
    ShellCommand(command) =>
      { "tag": "shell".to_json(), "command": command.to_json() }.to_json()
    BeadStateClosed(bead_id) =>
      { "tag": "bead_closed".to_json(), "bead_id": bead_id.to_json() }.to_json()
  }
}

///|
fn GoalCheck::from_goal_json(json : Json) -> Result[GoalCheck, ChoirError] {
  guard json is Object(obj) else {
    return Err(goal_validation_error("goal check must be an object"))
  }
  let tag = match obj.get("tag") {
    Some(String(value)) => value
    _ => return Err(goal_validation_error("goal check missing tag"))
  }
  match tag {
    "shell" =>
      match obj.get("command") {
        Some(String(command)) => Ok(GoalCheck::ShellCommand(command))
        _ => Err(goal_validation_error("shell goal check missing command"))
      }
    "bead_closed" =>
      match obj.get("bead_id") {
        Some(String(bead_id)) => Ok(GoalCheck::BeadStateClosed(bead_id))
        _ => Err(goal_validation_error("bead goal check missing bead_id"))
      }
    _ => Err(goal_validation_error("unknown goal check tag: " + tag))
  }
}

///|
fn GoalEvalResult::to_goal_json(self : GoalEvalResult) -> Json {
  {
    "passing": self.passing.to_json(),
    "total": self.total.to_json(),
    "failing_summary": self.failing_summary.to_json(),
    "evaluated_unix_sec": self.evaluated_unix_sec.to_json(),
  }.to_json()
}

///|
fn GoalEvalResult::from_goal_json(
  json : Json,
) -> Result[GoalEvalResult, ChoirError] {
  guard json is Object(obj) else {
    return Err(goal_validation_error("goal eval result must be an object"))
  }
  let passing = match json_field_int(obj, "passing") {
    Some(value) => value
    None => return Err(goal_validation_error("goal eval missing passing"))
  }
  let total = match json_field_int(obj, "total") {
    Some(value) => value
    None => return Err(goal_validation_error("goal eval missing total"))
  }
  let failing_summary = match json_field_string(obj, "failing_summary") {
    Some(value) => value
    None => ""
  }
  let evaluated_unix_sec = match json_field_int64(obj, "evaluated_unix_sec") {
    Some(value) => value
    None =>
      return Err(goal_validation_error("goal eval missing evaluated_unix_sec"))
  }
  Ok({ passing, total, failing_summary, evaluated_unix_sec })
}

///|
pub fn GoalEvalResult::is_complete(self : GoalEvalResult) -> Bool {
  self.total > 0 && self.passing >= self.total
}

///|
pub fn GoalEvalResult::progress_label(self : GoalEvalResult) -> String {
  self.passing.to_string() + "/" + self.total.to_string()
}

///|
pub fn Goal::new(
  input : String,
  verify_commands : Array[String],
  started_unix_sec : Int64,
) -> Result[Goal, ChoirError] {
  let source = match GoalSource::from_input(input) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let checks : Array[GoalCheck] = []
  match source {
    BeadId(id) => checks.push(GoalCheck::BeadStateClosed(id))
    Text(_) => ()
  }
  for command in verify_commands {
    let trimmed = command.trim().to_owned()
    if trimmed != "" {
      checks.push(GoalCheck::ShellCommand(trimmed))
    }
  }
  if checks.length() == 0 {
    return Err(goal_empty_checks_error())
  }
  Ok({ slug: source.slug(), source, checks, started_unix_sec, last_eval: None })
}

///|
pub fn Goal::with_last_eval(self : Goal, last_eval : GoalEvalResult) -> Goal {
  { ..self, last_eval: Some(last_eval) }
}

///|
pub fn Goal::to_json_string(self : Goal) -> String {
  let check_json : Array[Json] = []
  for check in self.checks {
    check_json.push(check.to_goal_json())
  }
  let obj : Map[String, Json] = {
    "slug": self.slug.to_json(),
    "source": self.source.to_goal_json(),
    "checks": check_json.to_json(),
    "started_unix_sec": self.started_unix_sec.to_json(),
    "last_eval": match self.last_eval {
      Some(result) => result.to_goal_json()
      None => goal_json_null()
    },
  }
  obj.to_json().stringify()
}

///|
pub fn Goal::from_json_string(raw : String) -> Result[Goal, ChoirError] {
  let parsed = @json.parse(raw) catch {
    _ => return Err(goal_validation_error("invalid goal JSON"))
  }
  guard parsed is Object(obj) else {
    return Err(goal_validation_error("goal JSON must be an object"))
  }
  let slug = match json_field_string(obj, "slug") {
    Some(value) => value
    None => return Err(goal_validation_error("goal missing slug"))
  }
  let source = match obj.get("source") {
    Some(value) =>
      match GoalSource::from_goal_json(value) {
        Ok(parsed) => parsed
        Err(e) => return Err(e)
      }
    None => return Err(goal_validation_error("goal missing source"))
  }
  let checks : Array[GoalCheck] = []
  match obj.get("checks") {
    Some(Array(items)) =>
      for item in items {
        match GoalCheck::from_goal_json(item) {
          Ok(check) => checks.push(check)
          Err(e) => return Err(e)
        }
      }
    Some(_) => return Err(goal_validation_error("goal checks must be an array"))
    None => return Err(goal_validation_error("goal missing checks"))
  }
  if checks.length() == 0 {
    return Err(goal_empty_checks_error())
  }
  let started_unix_sec = match json_field_int64(obj, "started_unix_sec") {
    Some(value) => value
    None => return Err(goal_validation_error("goal missing started_unix_sec"))
  }
  let last_eval = match obj.get("last_eval") {
    None | Some(Null) => None
    Some(value) =>
      match GoalEvalResult::from_goal_json(value) {
        Ok(parsed) => Some(parsed)
        Err(e) => return Err(e)
      }
  }
  Ok({ slug, source, checks, started_unix_sec, last_eval })
}

///|
fn goal_bead_json_status_closed(output : String) -> Bool {
  let parsed = @json.parse(output) catch { _ => return false }
  guard parsed is Object(obj) else { return false }
  match obj.get("status") {
    Some(String("closed")) => true
    _ => false
  }
}

///|
fn goal_check_failure_summary(check : GoalCheck) -> String {
  match check {
    ShellCommand(command) => "shell failed: " + command
    BeadStateClosed(bead_id) => "bead not closed: " + bead_id
  }
}

///|
pub async fn Goal::evaluate(
  self : Goal,
  runner : async (String) -> Int,
  bd_capture : async (String) -> (Int, String),
  now_unix_sec? : Int64 = 0L,
) -> GoalEvalResult {
  let failing : Array[String] = []
  let mut passing = 0
  for check in self.checks {
    let passed = match check {
      ShellCommand(command) => runner(command) == 0
      BeadStateClosed(bead_id) => {
        let (status, output) = bd_capture(bead_id)
        status == 0 && goal_bead_json_status_closed(output)
      }
    }
    if passed {
      passing = passing + 1
    } else {
      failing.push(goal_check_failure_summary(check))
    }
  }
  {
    passing,
    total: self.checks.length(),
    failing_summary: failing.join("; "),
    evaluated_unix_sec: now_unix_sec,
  }
}

///|
pub fn goal_prod_decision(
  previous_eval : GoalEvalResult?,
  current_eval : GoalEvalResult,
  last_prod_unix_sec : Int64?,
  now_unix_sec : Int64,
  reminder_interval_sec? : Int64 = goal_prod_reminder_interval_sec,
) -> GoalProdDecision {
  if current_eval.is_complete() {
    return match previous_eval {
      Some(prev) if prev.is_complete() => GoalProdDecision::Suppress
      _ => GoalProdDecision::EmitComplete
    }
  }
  match previous_eval {
    None => GoalProdDecision::EmitProgress
    Some(prev) =>
      if prev.passing != current_eval.passing ||
        prev.total != current_eval.total ||
        prev.failing_summary != current_eval.failing_summary {
        GoalProdDecision::EmitProgress
      } else {
        match last_prod_unix_sec {
          Some(last_prod) if now_unix_sec - last_prod >= reminder_interval_sec =>
            GoalProdDecision::EmitReminder
          None => GoalProdDecision::EmitReminder
          _ => GoalProdDecision::Suppress
        }
      }
  }
}
