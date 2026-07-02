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

///|
test "parse_fork_wave_args per-leaf verify_satisfied_by_ci overrides wave-level base both ways" {
  let args = {
    "count": "3",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "verify_satisfied_by_ci": "false",
    "task_contracts": "[{\"verify_satisfied_by_ci\": true}, {}, {\"verify_satisfied_by_ci\": false}]",
  }
  match @tools.parse_fork_wave_args(".", @tools.tool_args_from_map(args)) {
    Ok(fork) => {
      // explicit leaf true overrides wave-level false
      @debug.assert_eq(fork.task_contracts[0].verify_satisfied_by_ci, true)
      // omitted inherits the wave-level base
      @debug.assert_eq(fork.task_contracts[1].verify_satisfied_by_ci, false)
      @debug.assert_eq(fork.task_contracts[2].verify_satisfied_by_ci, false)
    }
    Err(e) => fail("parse_fork_wave_args per-leaf override: " + e.message())
  }
  let base_true_args = {
    "count": "2",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "task_contracts": "[{\"verify_satisfied_by_ci\": false}, {}]",
  }
  match
    @tools.parse_fork_wave_args(".", @tools.tool_args_from_map(base_true_args)) {
    Ok(fork) => {
      // explicit leaf false overrides the default-true base
      @debug.assert_eq(fork.task_contracts[0].verify_satisfied_by_ci, false)
      @debug.assert_eq(fork.task_contracts[1].verify_satisfied_by_ci, true)
    }
    Err(e) => fail("parse_fork_wave_args base-true override: " + e.message())
  }
}

///|
test "parse_fork_wave_args appends choir lint when available" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(verify=Some("moon test --target native")),
      ),
      choir_lint_available=true,
    ) {
    Ok(fork) =>
      @debug.assert_eq(fork.task_contracts[0].verify, [
        "moon test --target native", "moon run src/bin/choir_lint --target native",
      ])
    Err(e) => fail("parse_fork_wave_args lint available: " + e.message())
  }
}

///|
test "parse_fork_wave_args skips choir lint when unavailable" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(verify=Some("moon test --target native")),
      ),
      choir_lint_available=false,
    ) {
    Ok(fork) =>
      @debug.assert_eq(fork.task_contracts[0].verify, [
        "moon test --target native",
      ])
    Err(e) => fail("parse_fork_wave_args lint unavailable: " + e.message())
  }
}

///|
test "parse_fork_wave_args does not use choir lint as only verify" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(fork_wave_verify_test_map()),
      choir_lint_available=true,
    ) {
    Ok(fork) => @debug.assert_eq(fork.task_contracts[0].verify, [])
    Err(e) => fail("parse_fork_wave_args lint-only rejection: " + e.message())
  }
}

///|
test "parse_fork_wave_args does not duplicate choir lint" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(
          verify=Some(
            "moon test --target native && moon run src/bin/choir_lint --target native",
          ),
        ),
      ),
      choir_lint_available=true,
    ) {
    Ok(fork) =>
      @debug.assert_eq(fork.task_contracts[0].verify, [
        "moon test --target native && moon run src/bin/choir_lint --target native",
      ])
    Err(e) => fail("parse_fork_wave_args lint idempotent: " + e.message())
  }
}

///|
test "parse_fork_wave_args appends choir lint after non-run mention" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(
          verify=Some("moon build src/bin/choir_lint --target native"),
        ),
      ),
      choir_lint_available=true,
    ) {
    Ok(fork) =>
      @debug.assert_eq(fork.task_contracts[0].verify, [
        "moon build src/bin/choir_lint --target native", "moon run src/bin/choir_lint --target native",
      ])
    Err(e) => fail("parse_fork_wave_args lint mention: " + e.message())
  }
}

///|
test "parse_fork_wave_args appends choir lint after non-target run arg" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(
          verify=Some("moon run src/bin/some_tool -- src/bin/choir_lint"),
        ),
      ),
      choir_lint_available=true,
    ) {
    Ok(fork) =>
      @debug.assert_eq(fork.task_contracts[0].verify, [
        "moon run src/bin/some_tool -- src/bin/choir_lint", "moon run src/bin/choir_lint --target native",
      ])
    Err(e) => fail("parse_fork_wave_args lint run arg: " + e.message())
  }
}

///|
test "parse_fork_wave_args appends choir lint after build-only run" {
  match
    @tools.parse_fork_wave_args(
      ".",
      @tools.tool_args_from_map(
        fork_wave_verify_test_map(
          verify=Some(
            "moon run --build-only src/bin/choir_lint --target native",
          ),
        ),
      ),
      choir_lint_available=true,
    ) {
    Ok(fork) =>
      @debug.assert_eq(fork.task_contracts[0].verify, [
        "moon run --build-only src/bin/choir_lint --target native", "moon run src/bin/choir_lint --target native",
      ])
    Err(e) => fail("parse_fork_wave_args lint build-only: " + e.message())
  }
}
