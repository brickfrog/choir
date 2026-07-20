///|
/// Non-native targets keep the public adapter surface type-correct while all
/// host-process operations fail closed.
pub async fn capture_command_merged(_cmd : Command) -> (Int, String) {
  (-1, "")
}

///|
pub async fn capture_harness_probe(
  _spec : @harness.HarnessProbeProcess,
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "provider declaration probes require the native target",
    ),
  )
}

///|
pub async fn capture_boxlite_live_evidence(
  _dedicated_root : String,
) -> Result[@sandbox.BoxLiteLiveEvidence, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "BoxLite live probes require the native target",
    ),
  )
}

///|
pub async fn capture_claude_synthetic_startup(
  _synthetic_root : String,
  _mcp_executable : String,
  _mcp_args : Array[String],
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "Claude synthetic startup probes require the native target",
    ),
  )
}

///|
pub async fn capture_claude_live_startup(
  _dedicated_root : String,
  _mcp_executable : String,
  _mcp_args : Array[String],
) -> Result[@harness.HarnessProbeCapture, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "Claude live startup probes require the native target",
    ),
  )
}

///|
pub async fn capture_codex_live_startup(
  _dedicated_root : String,
  _mcp_executable : String,
  _mcp_args : Array[String],
  _read_canary_path : String,
) -> Result[@harness.CodexLiveProbeEvidence, @types.ChoirError] {
  Err(
    @types.ChoirError::transport_error(
      "Codex live startup probes require the native target",
    ),
  )
}

///|
pub async fn capture_stdout_with_cwd(
  _program : String,
  _args : Array[String],
  _cwd : String?,
) -> String {
  ""
}

///|
pub async fn run_conductor_process(
  _cmd : Command,
  _environment : ConductorProcessEnvironment,
) -> Int {
  -1
}
