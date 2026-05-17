///|
pub let idle_watchdog_warning_percent : Int64 = 70L

///|
pub fn should_emit_70_pct_warning(
  idle_sec : Int64,
  threshold : Int64,
  already_warned : Bool,
) -> Bool {
  if already_warned || threshold <= 0L {
    return false
  }
  if idle_sec >= threshold {
    return false
  }
  idle_sec * 100L >= threshold * idle_watchdog_warning_percent
}
