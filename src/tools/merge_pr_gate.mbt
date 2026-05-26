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
pub fn load_or_initialize_gate_state(
  project_dir : String,
  now_fn : () -> Int64,
  read : (String) -> String,
  write : (String, String) -> Bool,
) -> Result[MergeGateState, @types.ChoirError] {
  let path = merge_pr_audit_gate_state_path(project_dir)
  let body = read(path).trim().to_owned()
  if body != "" {
    let parsed : Json? = Some(@json.parse(body)) catch { _ => None }
    match parsed {
      Some(json) =>
        match merge_pr_gate_state_from_json(json) {
          Some(state) => return Ok(state)
          None =>
            return Err(
              @types.ChoirError::validation_error(
                "merge blocked: audit receipt gate state at .choir/audit-gate.json is malformed (missing or non-positive enabled_at_unix); fix or delete the file deliberately rather than silently resetting the grandfather boundary",
              ),
            )
        }
      None =>
        return Err(
          @types.ChoirError::validation_error(
            "merge blocked: audit receipt gate state at .choir/audit-gate.json is not valid JSON; fix or delete the file deliberately rather than silently resetting the grandfather boundary",
          ),
        )
    }
  }
  // AUDIT: missing-file path intentionally writes a fresh enabled_at_unix to
  // bootstrap first-deploy. A PR opened before this moment is grandfathered.
  // Proper fix is a config-driven `audit_receipt_required` flag that removes
  // the timestamp grandfather entirely — tracked separately, out of scope for
  // the audit-decouple PR.
  let state : MergeGateState = { enabled_at_unix: now_fn() }
  if write(path, state.to_json().stringify() + "\n") {
    Ok(state)
  } else {
    Err(
      @types.ChoirError::validation_error(
        "merge blocked: audit receipt gate could not persist .choir/audit-gate.json; refusing to merge because the grandfather timestamp is not durable",
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
