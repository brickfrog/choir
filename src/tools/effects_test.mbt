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
test "beads journals alone do not dirty fork_wave clean gate" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  let after_status = match plan {
    GitCapture(cont~, ..) =>
      cont(" M .beads/choir.jsonl\n?? .beads/new-child.jsonl\n")
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
test "beads journals are omitted from fork_wave dirty detail when mixed" {
  let plan = @tools.fork_wave_plan(".", [], 1, 0, "main.leaf", "")
  let after_status = match plan {
    GitCapture(cont~, ..) => cont(" M .beads/choir.jsonl\n M src/foo.mbt\n")
    _ => fail("expected GitCapture as first step")
  }
  match after_status {
    Pure(Err(@tools.ForkWaveError::UncommittedChanges(output~))) => {
      assert_true(output.contains("src/foo.mbt"))
      assert_false(output.contains(".beads/choir.jsonl"))
    }
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
  let after_pre_sha = match after_status {
    GitCapture(args=[_, _, "rev-parse", "HEAD"], cont~, ..) =>
      cont("1111111111111111111111111111111111111111\n")
    _ => fail("expected pre-scaffold HEAD capture")
  }
  // After the preflight passes, the next step is the per-path
  // status check inside scaffold_commit_phase (path_index=0).
  match after_pre_sha {
    GitCapture(args~, ..) => assert_true(args.contains("--porcelain"))
    _ => fail("expected scaffold per-path status check to follow")
  }
}

///|
test "scaffold compensation command builder emits reset and force-with-lease" {
  let cmds = @tools.fork_wave_scaffold_compensation_commands(
    "/proj", "1111111111111111111111111111111111111111",
  )
  assert_eq(cmds.length(), 2)
  @debug.assert_eq(cmds[0].args, [
    "-C", "/proj", "reset", "--hard", "1111111111111111111111111111111111111111",
  ])
  @debug.assert_eq(cmds[1].args, ["-C", "/proj", "push", "--force-with-lease"])
}

///|
test "scaffold compensation failure message warns before force push recovery" {
  let msg = @tools.ForkWaveError::ScaffoldCompensationFailed(
    pre_scaffold_sha="1111111111111111111111111111111111111111",
    original_error="Working tree has uncommitted changes",
    status=1,
    failing_cmd=None,
  ).message()
  assert_true(msg.contains("confirm no concurrent commits would be discarded"))
  assert_true(msg.contains("Do not force-push blindly"))
  assert_true(msg.contains("git push --force-with-lease"))
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
async test "fork_wave_capture_baseline_sha reads origin parent branch not head" {
  let calls : Array[String] = []
  let got = @tools.fork_wave_capture_baseline_sha("/repo", "feature/parent", async fn(
    program : String,
    args : Array[String],
  ) -> String {
    @async.sleep(0)
    assert_eq(program, "git")
    calls.push(args.join(" "))
    if args == ["-C", "/repo", "rev-parse", "origin/feature/parent"] {
      return "origin-parent-sha\n"
    }
    if args == ["-C", "/repo", "rev-parse", "HEAD"] {
      return "server-head-sha\n"
    }
    fail("unexpected git args: " + args.join(" "))
    ""
  })
  assert_eq(got, "origin-parent-sha")
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], "-C /repo rev-parse origin/feature/parent")
}

///|
async test "fork_wave_capture_baseline_sha returns empty when origin parent branch is missing" {
  let calls : Array[String] = []
  let got = @tools.fork_wave_capture_baseline_sha("/repo", "feature/missing", async fn(
    program : String,
    args : Array[String],
  ) -> String {
    @async.sleep(0)
    assert_eq(program, "git")
    calls.push(args.join(" "))
    if args == ["-C", "/repo", "rev-parse", "origin/feature/missing"] {
      raise @types.ChoirError::git_error("synthetic missing origin ref")
    }
    fail("unexpected git args: " + args.join(" "))
    ""
  })
  assert_eq(got, "")
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], "-C /repo rev-parse origin/feature/missing")
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

///|
async test "spawn launch diagnostics capture failing zellij once and redact stderr" {
  let secret_arg = "tcp_auth_token=super-secret"
  let setup = @workspace.Command::{
    program: "mkdir",
    args: ["-p", "/repo/.choir/worktrees/leaf-a"],
    workdir: None,
  }
  let launch = @workspace.Command::{
    program: "zellij",
    args: [
      "--session", "choir", "action", "new-tab", "--name", "leaf-a", "--cwd", "/repo/.choir/worktrees/leaf-a",
      "--", "env", secret_arg, "codex",
    ],
    workdir: None,
  }
  let runner_cmds : Array[@workspace.Command] = []
  let captured_cmds : Array[@workspace.Command] = []
  let diagnostics : Array[@tools.SpawnLaunchDiagnostic] = []
  let long_prefix = "x".repeat(2200)
  let (statuses, captured_outputs) = @tools.run_commands_with_spawn_launch_capture(
    [
      @tools.SpawnLaunchCommandBinding::{
        agent_id: "main.leaf-a",
        command_index: 1,
      },
    ],
    [setup, launch],
    async fn(cmds) {
      @async.sleep(0)
      let statuses = []
      for cmd in cmds {
        assert_false(cmd.program == "zellij")
        runner_cmds.push(cmd)
        statuses.push(0)
      }
      statuses
    },
    async fn(captured) {
      @async.sleep(0)
      captured_cmds.push(captured)
      (
        27,
        long_prefix +
        "\nzellij stderr: tab failed tcp_auth_token=stderr-secret Authorization: Bearer bearer-secret\n",
      )
    },
    fn(diagnostic) { diagnostics.push(diagnostic) },
  )
  assert_eq(statuses.length(), 2)
  assert_eq(statuses[0], 0)
  assert_eq(statuses[1], 27)
  assert_eq(runner_cmds.length(), 1)
  assert_eq(runner_cmds[0].program, "mkdir")
  assert_eq(captured_cmds.length(), 1)
  assert_eq(captured_cmds[0].program, "zellij")
  match captured_outputs.get(1) {
    Some(output) => {
      assert_true(output.contains("zellij stderr: tab failed"))
      assert_true(output.contains("tcp_auth_token=[REDACTED]"))
      assert_true(output.contains("Bearer [REDACTED]"))
      assert_false(output.contains("stderr-secret"))
      assert_false(output.contains("bearer-secret"))
    }
    None => fail("expected cached spawn launch capture output")
  }
  assert_eq(diagnostics.length(), 1)
  match diagnostics[0] {
    @tools.SpawnLaunchDiagnostic::SpawnCommandFailed(
      agent_id~,
      command_index~,
      status~,
      command_summary~,
      stderr_tail~
    ) => {
      assert_eq(agent_id, "main.leaf-a")
      assert_eq(command_index, 1)
      assert_eq(status, 27)
      assert_true(command_summary.contains("zellij action new-tab"))
      assert_true(command_summary.contains("name=leaf-a"))
      assert_false(command_summary.contains(secret_arg))
      assert_true(stderr_tail.contains("zellij stderr: tab failed"))
      assert_true(stderr_tail.contains("tcp_auth_token=[REDACTED]"))
      assert_true(stderr_tail.contains("Bearer [REDACTED]"))
      assert_false(stderr_tail.contains("stderr-secret"))
      assert_false(stderr_tail.contains("bearer-secret"))
      assert_true(stderr_tail.length() <= 2048)
    }
    _ => fail("expected SpawnCommandFailed diagnostic")
  }
}
