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
test "dirty working tree yields Done(Err) after status capture" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  let after_status = match plan {
    GitCapture(cont~, ..) => cont(" M src/foo.mbt\n")
    _ => fail("expected GitCapture as first step")
  }
  match after_status {
    Pure(@types.Response::Err(msg)) =>
      assert_true(msg.contains("uncommitted changes"))
    _ => fail("expected Pure(Err) for dirty tree")
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
test "unpushed commits yields Done(Err) after log capture" {
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
    Pure(@types.Response::Err(msg)) =>
      assert_true(msg.contains("Unpushed commits"))
    _ => fail("expected Pure(Err) for unpushed commits")
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
    Pure(resp) =>
      match resp {
        @types.Response::Ok(vals) =>
          assert_eq(vals.get("status"), Some("already_running"))
        _ => fail("expected Ok response")
      }
    _ => fail("expected Pure after clean checks with no-spawn")
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
    Pure(@types.Response::Ok(vals)) => {
      assert_eq(vals.get("status"), Some("spawned"))
      assert_eq(vals.get("count"), Some("1"))
    }
    _ => fail("expected Pure(Ok(spawned))")
  }
}

///|
test "failed command yields Err response" {
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
    Pure(@types.Response::Err(msg)) =>
      assert_true(msg.contains("command failed"))
    _ => fail("expected Pure(Err) for failed command")
  }
}
