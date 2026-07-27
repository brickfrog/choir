///| When the daemon log has grown enough to roll, and what to do about it.
///
/// Both the serve daemon and the Goal worker append to one file for the life
/// of the workspace with no cap. A Goal that fails its tick is retried every
/// second and logged every time, so the file that grows fastest is the one
/// nobody is watching.
///
/// The plan is decided here and applied at the host boundary, so the ordering
/// that makes rotation safe — oldest first, or a rename destroys a generation
/// that has not been shifted yet — is testable without a filesystem.

///|
pub(all) struct LogRotationPolicy {
  /// Roll once the live file is at least this large.
  maximum_bytes : Int
  /// How many rolled generations to keep. Zero discards on roll.
  retained_generations : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Sized so a rolled set is bounded at roughly 64 MiB per daemon: enough to
/// hold the run-up to an incident, small enough that it cannot quietly consume
/// a workspace.
pub fn default_log_rotation_policy() -> LogRotationPolicy {
  { maximum_bytes: 16 * 1024 * 1024, retained_generations: 3 }
}

///|
pub(all) struct LogRotationPlan {
  /// Generations to remove, because they fall outside what is retained.
  discard : Array[String]
  /// Renames to apply in this order. Later generations move first, so no
  /// rename overwrites a file that has not been shifted yet.
  rotate : Array[(String, String)]
} derive(Debug, Eq)

///|
pub fn log_rotation_plan_is_empty(plan : LogRotationPlan) -> Bool {
  plan.discard.length() == 0 && plan.rotate.length() == 0
}

///|
pub fn log_generation_path(path : String, generation : Int) -> String {
  path + "." + generation.to_string()
}

///|
/// Decide whether the live log rolls, given how large it currently is.
///
/// `observed_bytes` is what the host measured. A file that could not be
/// measured reports zero and rolls nothing, because rotating on an unknown
/// size would discard logs on every write when the measurement is broken.
pub fn plan_log_rotation(
  path : String,
  observed_bytes : Int,
  policy : LogRotationPolicy,
) -> LogRotationPlan {
  if policy.maximum_bytes <= 0 ||
    observed_bytes < policy.maximum_bytes ||
    path == "" {
    return { discard: [], rotate: [] }
  }
  let discard : Array[String] = []
  let rotate : Array[(String, String)] = []
  if policy.retained_generations <= 0 {
    // Nothing is kept, so the live file is removed rather than rolled.
    discard.push(path)
    return { discard, rotate }
  }
  // The oldest retained generation has nowhere to go.
  discard.push(log_generation_path(path, policy.retained_generations))
  // Shift from the oldest backwards: rolling .1 first would overwrite .2
  // before .2 had moved.
  for generation = policy.retained_generations - 1
      generation >= 1
      generation = generation - 1 {
    rotate.push(
      (
        log_generation_path(path, generation),
        log_generation_path(path, generation + 1),
      ),
    )
  }
  rotate.push((path, log_generation_path(path, 1)))
  { discard, rotate }
}
