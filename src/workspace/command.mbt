///|
/// A validated process invocation assembled by an adapter. Orchestration code
/// passes these values to injected execution capabilities; it never runs them
/// directly.
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Debug, Eq)

///|
pub impl Show for Command with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}
