///|
test "progress_watchdog_decision does nothing below threshold" {
  assert_eq(
    progress_watchdog_decision(true, 100L, 999L, 900L),
    ProgressWatchdogDecision::DoNothing,
  )
}

///|
test "progress_watchdog_decision rescues at and above threshold" {
  assert_eq(
    progress_watchdog_decision(true, 100L, 1000L, 900L),
    ProgressWatchdogDecision::Rescue,
  )
  assert_eq(
    progress_watchdog_decision(true, 100L, 1001L, 900L),
    ProgressWatchdogDecision::Rescue,
  )
}

///|
test "progress_watchdog_decision does nothing when predicate does not apply" {
  assert_eq(
    progress_watchdog_decision(false, 100L, 5000L, 900L),
    ProgressWatchdogDecision::DoNothing,
  )
}

///|
test "progress_watchdog_decision fails closed before any commit observation" {
  assert_eq(
    progress_watchdog_decision(true, 0L, 5000L, 900L),
    ProgressWatchdogDecision::DoNothing,
  )
}

///|
test "pick_rescue_agent_type rotates through fallback chain and wraps" {
  assert_eq(
    pick_rescue_agent_type(@types.AgentType::Codex),
    @types.AgentType::Claude,
  )
  assert_eq(
    pick_rescue_agent_type(@types.AgentType::Claude),
    @types.AgentType::MoonPilot,
  )
  assert_eq(
    pick_rescue_agent_type(@types.AgentType::MoonPilot),
    @types.AgentType::CursorAgent,
  )
  assert_eq(
    pick_rescue_agent_type(@types.AgentType::CursorAgent),
    @types.AgentType::Gemini,
  )
  assert_eq(
    pick_rescue_agent_type(@types.AgentType::Gemini),
    @types.AgentType::Codex,
  )
}
