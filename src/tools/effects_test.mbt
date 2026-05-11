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
test "all skipped with no spawned yields already_running without git probes" {
  // The already-running path must short-circuit BEFORE the clean gate so
  // a no-op fork_wave call doesn't mutate or push the parent branch.
  // Asserting Pure(...) directly proves no GitCaptures happened.
  let plan = @tools.fork_wave_plan(".", [], 0, 1, "", "main.leaf-0")
  match plan {
    Pure(Ok(@types.Response::Ok(vals))) =>
      @debug.assert_eq(vals.get("status"), Some("already_running"))
    _ =>
      fail(
        "expected Pure(Ok(already_running)) with no git probes for a no-op fork_wave",
      )
  }
}

///|
test "scaffold_commit preflight refuses when HEAD is not the parent_branch" {
  let scaffold = @tools.ForkWaveScaffoldCommit::{
    message: "scaffold: shared struct field",
    paths: ["src/server/state.mbt"],
  }
  let echo_cmd = @workspace.Command::{
    program: "echo",
    args: ["hi"],
    workdir: None,
  }
  let plan = @tools.fork_wave_plan(
    ".",
    [echo_cmd],
    1,
    0,
    "main.leaf",
    "",
    scaffold_commit=Some(scaffold),
    parent_branch="feature/expected",
  )
  // First step is rev-parse HEAD; feed "different/branch" — preflight must
  // refuse rather than push the scaffold to the wrong branch.
  let after_rev_parse = match plan {
    GitCapture(args=[_, _, "rev-parse", "--abbrev-ref", "HEAD"], cont~, ..) =>
      cont("different/branch\n")
    _ => fail("expected first step to be rev-parse HEAD")
  }
  match after_rev_parse {
    Pure(Err(@tools.ForkWaveError::ScaffoldBranchMismatch(expected~, actual~))) => {
      assert_eq(expected, "feature/expected")
      assert_eq(actual, "different/branch")
    }
    _ => fail("expected ScaffoldBranchMismatch")
  }
}

///|
test "scaffold_commit preflight accepts rename lines whose target is in scaffold.paths" {
  // `git status --porcelain` rename lines look like 'R  old -> new'.
  // The preflight must recognize that both old AND new belong to the
  // scaffold set; otherwise the rename is mis-flagged as unrelated and
  // fork_wave aborts.
  let scaffold = @tools.ForkWaveScaffoldCommit::{
    message: "scaffold: rename module",
    paths: ["src/old.mbt", "src/new.mbt"],
  }
  let echo_cmd = @workspace.Command::{
    program: "echo",
    args: ["hi"],
    workdir: None,
  }
  let plan = @tools.fork_wave_plan(
    ".",
    [echo_cmd],
    1,
    0,
    "main.leaf",
    "",
    scaffold_commit=Some(scaffold),
    parent_branch="feature/parent",
  )
  let after_rev_parse = match plan {
    GitCapture(args=[_, _, "rev-parse", "--abbrev-ref", "HEAD"], cont~, ..) =>
      cont("feature/parent\n")
    _ => fail("expected rev-parse HEAD")
  }
  let after_unpushed = match after_rev_parse {
    GitCapture(args=[_, _, "log", "--oneline", "@{u}..HEAD"], cont~, ..) =>
      cont("")
    _ => fail("expected unpushed log capture")
  }
  let after_status = match after_unpushed {
    GitCapture(args=[_, _, "status", "--porcelain"], cont~, ..) =>
      cont("R  src/old.mbt -> src/new.mbt\n")
    _ => fail("expected status --porcelain capture")
  }
  // After the preflight passes, the next step is the per-path
  // status check inside scaffold_commit_phase (path_index=0).
  match after_status {
    GitCapture(args~, ..) => assert_true(args.contains("--porcelain"))
    _ => fail("expected scaffold per-path status check to follow")
  }
}

///|
test "all skipped with scaffold_commit still short-circuits without running scaffold" {
  // The pre-scaffold check must also fire for the scaffold path: if every
  // leaf is deduped, we must not push a scaffold commit for a no-op call.
  let scaffold = @tools.ForkWaveScaffoldCommit::{
    message: "scaffold: shared struct field",
    paths: ["src/server/state.mbt"],
  }
  let plan = @tools.fork_wave_plan(
    ".",
    [],
    0,
    1,
    "",
    "main.leaf-0",
    scaffold_commit=Some(scaffold),
  )
  match plan {
    Pure(Ok(@types.Response::Ok(vals))) =>
      @debug.assert_eq(vals.get("status"), Some("already_running"))
    _ =>
      fail(
        "expected Pure(Ok(already_running)) — scaffold must not run for a no-op fork_wave",
      )
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
      @debug.assert_eq(vals.get("status"), Some("spawned"))
      @debug.assert_eq(vals.get("count"), Some("1"))
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
