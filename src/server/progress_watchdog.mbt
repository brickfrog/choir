///|
pub const PROGRESS_STALL_SEC : Int64 = 900L

///|
pub const PROGRESS_LS_REMOTE_TIMEOUT_SEC : Int64 = 30L

///|
pub const PROGRESS_LS_REMOTE_PROBE_SEC : Int64 = 60L

///|
pub(all) enum ProgressWatchdogDecision {
  DoNothing
  Rescue
} derive(Debug, Eq)

///|
pub impl Show for ProgressWatchdogDecision with output(self, logger) -> Unit {
  match self {
    DoNothing => logger.write_string("DoNothing")
    Rescue => logger.write_string("Rescue")
  }
}

///|
pub fn progress_watchdog_decision(
  applies : Bool,
  last_commit_at : Int64,
  now : Int64,
  threshold_sec : Int64,
) -> ProgressWatchdogDecision {
  if !applies || last_commit_at <= 0L {
    return DoNothing
  }
  if now - last_commit_at >= threshold_sec {
    Rescue
  } else {
    DoNothing
  }
}

///|
pub fn pick_rescue_agent_type(current : @types.AgentType) -> @types.AgentType {
  match current {
    @types.AgentType::Codex => @types.AgentType::Claude
    @types.AgentType::Claude => @types.AgentType::MoonPilot
    @types.AgentType::MoonPilot => @types.AgentType::CursorAgent
    @types.AgentType::CursorAgent => @types.AgentType::Gemini
    @types.AgentType::Gemini => @types.AgentType::Codex
    @types.AgentType::Unknown => @types.AgentType::Codex
  }
}
