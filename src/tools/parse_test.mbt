///|
fn fork_wave_verify_test_map(verify? : String? = None) -> Map[String, String] {
  let args = {
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  }
  match verify {
    Some(value) => args.set("verify", value)
    None => ()
  }
  args
}

///|
test "parse_fork_wave_args verify default precedence" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(verify=Some("npm test")),
      ),
      project_verify_cmd=Some("cargo test"),
    ) {
    Ok(fork) => @debug.assert_eq(fork.task_contracts[0].verify, ["npm test"])
    Err(e) => fail("parse_fork_wave_args explicit verify: " + e.message())
  }

  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(fork_wave_verify_test_map()),
      project_verify_cmd=Some("cargo test"),
    ) {
    Ok(fork) => @debug.assert_eq(fork.task_contracts[0].verify, ["cargo test"])
    Err(e) =>
      fail("parse_fork_wave_args project verify default: " + e.message())
  }

  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(fork_wave_verify_test_map()),
    ) {
    Ok(fork) => @debug.assert_eq(fork.task_contracts[0].verify, [])
    Err(e) => fail("parse_fork_wave_args no verify default: " + e.message())
  }
}
