///|
/// Pure tests for fork_wave_plan.
///
/// The key property being tested: Eff[A] is pure data. We can inspect
/// and walk the effect tree without executing any IO — no async, no mocks,
/// no injection. Just pattern matching on the description.
///
/// Compare to the injectable-mock tests in registry_test.mbt: those need
/// async + mock functions. These need nothing — the plan IS the test.

///|
test "plan first step is always a git status capture" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  assert_true(
    match plan {
      GitCapture(program="git", args=[_, _, "status", "--porcelain"], ..) =>
        true
      _ => false
    },
  )
}

///|
test "dirty working tree yields UncommittedChanges after status capture" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  let after_status = match plan {
    GitCapture(cont~, ..) => cont(" M src/foo.mbt\n")
    _ => fail("expected GitCapture as first step")
  }
  match after_status {
    Pure(Err(@tools.ForkWaveError::UncommittedChanges(output~))) =>
      assert_true(output.length() > 0)
    _ => fail("expected Pure(Err(UncommittedChanges))")
  }
}

///|
test "clean status proceeds to unpushed check" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  let after_status = match plan {
    GitCapture(cont~, ..) => cont("")
    _ => fail("expected GitCapture as first step")
  }
  assert_true(
    match after_status {
      GitCapture(args~, ..) => args.contains("log")
      _ => false
    },
  )
}

///|
test "unpushed commits yields UnpushedCommits after log capture" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  let after_log = match plan {
    GitCapture(cont~, ..) =>
      match cont("") {
        GitCapture(cont~, ..) => cont("abc1234 scaffold: add types\n")
        other => other
      }
    _ => fail("expected two GitCaptures")
  }
  match after_log {
    Pure(Err(@tools.ForkWaveError::UnpushedCommits(output~))) =>
      assert_true(output.contains("scaffold"))
    _ => fail("expected Pure(Err(UnpushedCommits))")
  }
}

///|
test "all skipped with no spawned yields already_running" {
  let plan = @tools.fork_wave_plan(".", [], 0, 1, "", "main.leaf-0")
  let after_both_checks = match plan {
    GitCapture(cont~, ..) =>
      match cont("") {
        GitCapture(cont~, ..) => cont("")
        other => other
      }
    _ => fail("expected two GitCaptures")
  }
  match after_both_checks {
    Pure(Ok(@types.Response::Ok(vals))) =>
      assert_eq(vals.get("status"), Some("already_running"))
    _ => fail("expected Pure(Ok(already_running))")
  }
}

///|
test "clean tree with commands reaches RunCommands" {
  let echo_cmd = @workspace.Command::{
    program: "echo",
    args: ["hi"],
    workdir: None,
  }
  let plan = @tools.fork_wave_plan(".", [echo_cmd], 1, 0, "main.leaf", "")
  let after_checks = match plan {
    GitCapture(cont~, ..) =>
      match cont("") {
        GitCapture(cont~, ..) => cont("")
        other => other
      }
    _ => fail("expected two GitCaptures")
  }
  assert_true(
    match after_checks {
      RunCommands(cmds~, ..) => cmds.length() == 1
      _ => false
    },
  )
}

///|
test "successful commands yield spawned response" {
  let echo_cmd = @workspace.Command::{
    program: "echo",
    args: ["hi"],
    workdir: None,
  }
  let plan = @tools.fork_wave_plan(".", [echo_cmd], 1, 0, "main.leaf-0", "")
  let after_run = match plan {
    GitCapture(cont~, ..) =>
      match cont("") {
        GitCapture(cont~, ..) =>
          match cont("") {
            RunCommands(cont~, ..) => cont([0])
            other => other
          }
        other => other
      }
    _ => fail("expected GitCapture → GitCapture → RunCommands")
  }
  match after_run {
    Pure(Ok(@types.Response::Ok(vals))) => {
      assert_eq(vals.get("status"), Some("spawned"))
      assert_eq(vals.get("count"), Some("1"))
    }
    _ => fail("expected Pure(Ok(spawned))")
  }
}

///|
test "failed command yields CommandFailed(status=1)" {
  let fail_cmd = @workspace.Command::{
    program: "false",
    args: [],
    workdir: None,
  }
  let plan = @tools.fork_wave_plan(".", [fail_cmd], 1, 0, "main.leaf", "")
  let after_run = match plan {
    GitCapture(cont~, ..) =>
      match cont("") {
        GitCapture(cont~, ..) =>
          match cont("") {
            RunCommands(cont~, ..) => cont([1])
            other => other
          }
        other => other
      }
    _ => fail("expected GitCapture → GitCapture → RunCommands")
  }
  match after_run {
    Pure(Err(@tools.ForkWaveError::CommandFailed(status~, ..))) =>
      assert_eq(status, 1)
    _ => fail("expected Pure(Err(CommandFailed(1)))")
  }
}
