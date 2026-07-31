///|
/// Non-native targets keep the public adapter surface type-correct while all
/// host-process operations fail closed.
pub async fn capture_command_merged(_cmd : Command) -> (Int, String) {
  (-1, "")
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

///|
pub fn spawn_native_goal_worker(
  _choir_executable : String,
  _project_dir : String,
  spawn? : (Command) -> Result[Int, @types.ChoirError] = fn(_) {
    Err(@types.ChoirError::transport_error("native execution unavailable"))
  },
) -> Result[Int, @types.ChoirError] {
  spawn({ program: "", args: [], workdir: None })
}
