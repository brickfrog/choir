///|
/// The status vocabulary exposed by the current beads adapter.
pub(all) enum TaskStatus {
  Todo
  InProgress
  /// Tracker states Choir reads but never sets. Without them a single deferred
  /// Bead makes the whole graph unparseable, and a planner cannot ask for the
  /// open work that is actually startable.
  Blocked
  Deferred
  Done
} derive(Debug, Eq)
