///|
/// Stub for `choir log --wave <wave_id>`. Leaf A fills this in per
/// `.choir/context/wave-telemetry-spec.md`.
pub fn log_subcommand_run() -> Unit {
  @sys.write_stderr("choir log: not implemented yet\n")
  @sys.exit(1)
}
