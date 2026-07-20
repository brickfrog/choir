///|
/// The caller role carried by the local transport. Only the Conductor role is
/// currently authorized to submit or steer Goals; the other variants keep the
/// transport fail-closed when a restricted client identifies itself.
pub(all) enum Role {
  TL
  Dev
  Worker
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for Role with fn output(self, logger) -> Unit {
  match self {
    TL => logger.write_string("TL")
    Dev => logger.write_string("Dev")
    Worker => logger.write_string("Worker")
  }
}

///|
/// The status vocabulary exposed by the current beads adapter.
pub(all) enum TaskStatus {
  Todo
  InProgress
  Done
} derive(Debug, Eq)
