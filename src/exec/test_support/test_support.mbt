///|
pub let hermetic_no_exec_env : String = "CHOIR_TEST_NO_EXEC"

///|
pub let real_exec_integration_env : String = "CHOIR_TEST_REAL_EXEC"

///|
pub fn hermetic_exec_violation_message(command : String) -> String {
  "hermetic-test violation: real exec " +
  command +
  " -- inject a mock capture/runner"
}

///|
pub fn hermetic_test_no_exec_enabled() -> Bool {
  @env.get_env_var(hermetic_no_exec_env) is Some(_)
}

///|
pub fn real_exec_integration_enabled() -> Bool {
  match @env.get_env_var(real_exec_integration_env) {
    Some(value) => value == "1"
    None => false
  }
}
