///|
pub(all) enum StopCheckResult {
  MustBlock(String)
  ShouldNudge(String)
  Clean
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for StopCheckResult with output(self, logger) {
  match self {
    MustBlock(reason) => {
      logger.write_string("MustBlock(")
      logger.write_string(reason)
      logger.write_string(")")
    }
    ShouldNudge(reason) => {
      logger.write_string("ShouldNudge(")
      logger.write_string(reason)
      logger.write_string(")")
    }
    Clean => logger.write_string("Clean")
  }
}

///|
pub(all) enum TransitionResult[P] {
  Transitioned(P)
  InvalidTransition(String)
} derive(Debug, Eq)

///|
pub impl[T : Show] Show for TransitionResult[T] with output(self, logger) {
  match self {
    Transitioned(p) => {
      logger.write_string("Transitioned(")
      p.output(logger)
      logger.write_string(")")
    }
    InvalidTransition(msg) => {
      logger.write_string("InvalidTransition(")
      logger.write_string(msg)
      logger.write_string(")")
    }
  }
}

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
  let sb = StringBuilder::new()
  for c in branch {
    if c == '.' {
      sb.write_string("--")
    } else if c == '/' || c == '\\' || c == '\u0000' {
      sb.write_char('_')
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}
