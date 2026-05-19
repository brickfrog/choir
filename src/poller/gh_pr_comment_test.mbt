///|
async test "gh_pr_comment uses gh pr comment argv and body" {
  let seen : Array[@workspace.Command] = []
  let body = "[AUDIT cycle 2]\n\nFinding 1: still broken\n"
  let result = gh_pr_comment(42, body, "/repo", capture=async fn(cmd) {
    @async.sleep(0)
    seen.push(cmd)
    (0, "")
  })
  match result {
    Ok(_) => ()
    Err(e) => fail("expected successful comment command: " + e.message())
  }
  assert_eq(seen.length(), 1)
  let cmd = seen[0]
  assert_eq(cmd.program, "gh")
  @debug.assert_eq(cmd.args, ["pr", "comment", "42", "--body", body])
  @debug.assert_eq(cmd.workdir, Some("/repo"))
}

///|
async test "gh_pr_comment reports capture failure without throwing" {
  let result = gh_pr_comment(7, "body", "/repo", capture=async fn(_cmd) {
    @async.sleep(0)
    (9, "gh unavailable")
  })
  match result {
    Ok(_) => fail("expected gh failure")
    Err(e) => {
      assert_true(e.message().contains("PR #7"))
      assert_true(e.message().contains("gh unavailable"))
    }
  }
}
