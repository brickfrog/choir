///|
/// Shared inert capability mocks for blackbox tests: abort when invoked, so a
/// test that unexpectedly reaches host I/O fails loudly (the same contract as
/// @exec's hermetic-test guard). Tests that exercise a capability inject
/// their own recording mock instead.
async fn unreached_runner(_cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  abort("test: runner must not be invoked")
}

///|
async fn unreached_git_capture(
  _program : String,
  _args : Array[String],
) -> String {
  @async.sleep(0)
  abort("test: git_capture must not be invoked")
}

///|
async fn unreached_capture(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  abort("test: capture must not be invoked")
}

///|
async fn unreached_hook_capture(
  _hook_path : String,
  _input_json : String,
  _cwd : String?,
) -> (Int, String) {
  @async.sleep(0)
  abort("test: hook_capture must not be invoked")
}
