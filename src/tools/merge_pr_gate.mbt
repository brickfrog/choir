///|
pub(all) struct MergeGateState {
  enabled_at_unix : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn merge_pr_audit_gate_state_path(project_dir : String) -> String {
  project_dir + "/.choir/audit-gate.json"
}

///|
fn merge_pr_gate_state_from_json(json : Json) -> MergeGateState? {
  guard json is Object(fields) else { return None }
  match @types.json_field_int64(fields, "enabled_at_unix") {
    Some(value) if value > 0L => Some({ enabled_at_unix: value })
    _ => None
  }
}

///|
pub fn load_gate_state(
  project_dir : String,
  read : (String) -> String,
  path_exists? : (String) -> Bool = @sys.path_exists,
) -> Result[MergeGateState, @types.ChoirError] {
  let path = merge_pr_audit_gate_state_path(project_dir)
  if !path_exists(path) {
    return Err(
      @types.ChoirError::validation_error(
        "merge blocked: audit receipt gate state at .choir/audit-gate.json is missing. Seed it explicitly with an `enabled_at_unix` value chosen by the operator (e.g. `printf '{\"enabled_at_unix\":%s}' \"$(date +%s)\" > .choir/audit-gate.json`); merge_pr refuses to invent the grandfather boundary itself.",
      ),
    )
  }
  let body = read(path).trim().to_owned()
  if body == "" {
    return Err(
      @types.ChoirError::validation_error(
        "merge blocked: audit receipt gate state at .choir/audit-gate.json is empty; fix or delete the file deliberately rather than silently resetting the grandfather boundary",
      ),
    )
  }
  let parsed : Json? = Some(@json.parse(body)) catch { _ => None }
  match parsed {
    Some(json) =>
      match merge_pr_gate_state_from_json(json) {
        Some(state) => Ok(state)
        None =>
          Err(
            @types.ChoirError::validation_error(
              "merge blocked: audit receipt gate state at .choir/audit-gate.json is malformed (missing or non-positive enabled_at_unix); fix or delete the file deliberately rather than silently resetting the grandfather boundary",
            ),
          )
      }
    None =>
      Err(
        @types.ChoirError::validation_error(
          "merge blocked: audit receipt gate state at .choir/audit-gate.json is not valid JSON; fix or delete the file deliberately rather than silently resetting the grandfather boundary",
        ),
      )
  }
}

///|
pub fn merge_pr_audit_gate_required(
  state : MergeGateState,
  pr_first_seen_unix : Int64,
) -> Bool {
  pr_first_seen_unix >= state.enabled_at_unix
}
