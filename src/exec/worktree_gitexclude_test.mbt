///|
/// Hermetic repo under /tmp: after seeding `info/exclude`, agent-style dotdirs do not dirty status.
test "worktree_seed_agent_runtime_gitexclude keeps porcelain clean" {
  let tmp = "/tmp/choir-gexcl-" + @sys.get_pid().to_string()
  let repo = tmp + "/repo"
  let wt = tmp + "/wt"
  let porcelain_out = tmp + "/porcelain.txt"
  let qrepo = @sys.shell_quote(repo)
  let qwt = @sys.shell_quote(wt)
  let qout = @sys.shell_quote(porcelain_out)
  assert_true(@sys.create_dir_all(repo))
  assert_eq(@sys.system("git -C " + qrepo + " init -b main"), 0)
  assert_eq(@sys.system("git -C " + qrepo + " config user.email t@e.x"), 0)
  assert_eq(@sys.system("git -C " + qrepo + " config user.name t"), 0)
  assert_true(@sys.write_file_sync(repo + "/README.md", "x\n"))
  assert_eq(@sys.system("git -C " + qrepo + " add README.md"), 0)
  assert_eq(@sys.system("git -C " + qrepo + " commit -m init"), 0)
  assert_eq(
    @sys.system("git -C " + qrepo + " worktree add -b leaf " + qwt + " HEAD"),
    0,
  )
  let seed = @workspace.command_seed_worktree_agent_runtime_gitexclude(wt)
  assert_eq(
    @workspace.run_native_worktree_seed_agent_runtime_gitexclude_command(seed),
    0,
  )
  assert_true(@sys.create_dir_all(wt + "/.cursor"))
  assert_true(@sys.write_file_sync(wt + "/.cursor/foo", ""))
  assert_eq(@sys.system("git -C " + qwt + " status --porcelain > " + qout), 0)
  assert_eq(@sys.read_file(porcelain_out), "")
  ignore(@sys.rm_rf(tmp))
}
