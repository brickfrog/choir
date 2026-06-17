///|
async test "baseline verify classifies non-zero command as AlreadyRed" {
  let git_cmds : Array[@workspace.Command] = []
  let verify_cmds : Array[@workspace.Command] = []
  let temp = "/repo/.choir/tmp/baseline-case-red"
  let got = baseline_verify_command_outcome(
    "abc123",
    "moon test --target native",
    "/repo",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      git_cmds.push(cmd)
      (0, "")
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      verify_cmds.push(cmd)
      (7, "red")
    },
    temp_worktree=Some(temp),
  )

  assert_true(got == BaselineOutcome::AlreadyRed)
  assert_eq(git_cmds.length(), 2)
  assert_eq(git_cmds[0].program, "git")
  @debug.assert_eq(git_cmds[0].args, ["worktree", "add", temp, "abc123"])
  @debug.assert_eq(git_cmds[0].workdir, Some("/repo"))
  @debug.assert_eq(git_cmds[1].args, ["worktree", "remove", "--force", temp])
  assert_eq(verify_cmds.length(), 1)
  assert_eq(verify_cmds[0].program, "sh")
  @debug.assert_eq(verify_cmds[0].args, ["-lc", "moon test --target native"])
  @debug.assert_eq(verify_cmds[0].workdir, Some(temp))
}

///|
async test "baseline verify classifies zero command as GreenAtBaseline" {
  let git_cmds : Array[@workspace.Command] = []
  let temp = "/repo/.choir/tmp/baseline-case-green"
  let got = baseline_verify_command_outcome(
    "def456",
    "moon run src/bin/choir_lint --target native",
    "/repo",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      git_cmds.push(cmd)
      (0, "")
    },
    async fn(_cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      (0, "green")
    },
    temp_worktree=Some(temp),
  )

  assert_true(got == BaselineOutcome::GreenAtBaseline)
  assert_eq(git_cmds.length(), 2)
  @debug.assert_eq(git_cmds[1].args, ["worktree", "remove", "--force", temp])
}

///|
async test "baseline verify returns Unknown for missing baseline sha" {
  let git_cmds : Array[@workspace.Command] = []
  let verify_cmds : Array[@workspace.Command] = []
  let got = baseline_verify_command_outcome(
    "  ",
    "moon test --target native",
    "/repo",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      git_cmds.push(cmd)
      (0, "")
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      verify_cmds.push(cmd)
      (0, "")
    },
    temp_worktree=Some("/repo/.choir/tmp/baseline-missing"),
  )

  assert_true(got == BaselineOutcome::Unknown)
  assert_eq(git_cmds.length(), 1)
  @debug.assert_eq(git_cmds[0].args, [
    "worktree", "remove", "--force", "/repo/.choir/tmp/baseline-missing",
  ])
  assert_eq(verify_cmds.length(), 0)
}

///|
async test "baseline verify removes temp worktree when add fails" {
  let git_cmds : Array[@workspace.Command] = []
  let verify_cmds : Array[@workspace.Command] = []
  let temp = "/repo/.choir/tmp/baseline-add-fails"
  let got = baseline_verify_command_outcome(
    "not-a-sha",
    "moon test --target native",
    "/repo",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      git_cmds.push(cmd)
      if cmd.args.length() >= 2 && cmd.args[1] == "add" {
        (128, "fatal: invalid reference")
      } else {
        (0, "")
      }
    },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      verify_cmds.push(cmd)
      (0, "")
    },
    temp_worktree=Some(temp),
  )

  assert_true(got == BaselineOutcome::Unknown)
  assert_eq(git_cmds.length(), 2)
  @debug.assert_eq(git_cmds[0].args, ["worktree", "add", temp, "not-a-sha"])
  @debug.assert_eq(git_cmds[1].args, ["worktree", "remove", "--force", temp])
  assert_eq(verify_cmds.length(), 0)
}
