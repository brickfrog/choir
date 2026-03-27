///|
pub fn git_worktree_add(
  path : String,
  branch : String,
  start_point : String,
) -> Command {
  {
    program: "git",
    args: ["worktree", "add", path, "-b", branch, start_point],
    workdir: None,
  }
}

///|
pub fn git_worktree_remove(path : String) -> Command {
  {
    program: "git",
    args: ["worktree", "remove", "--force", path],
    workdir: None,
  }
}

///|
pub fn git_push(branch : String) -> Command {
  {
    program: "git",
    args: ["push", "--force-with-lease", "-u", "origin", branch],
    workdir: None,
  }
}

///|
pub fn git_fetch() -> Command {
  { program: "git", args: ["fetch"], workdir: None }
}
