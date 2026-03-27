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

///|
/// Run `git fetch origin <branch>` in `project_dir`. On failure, print a warning to stderr
/// and exit 0 so spawn sequences continue.
pub fn git_fetch_origin_branch_best_effort(
  project_dir : String,
  branch : String,
) -> Command {
  {
    program: "sh",
    args: [
      "-c", "cd \"$1\" && { git fetch origin \"$2\" || { printf '%s\\n' \"choir: warning: git fetch origin $2 failed\" >&2; true; }; }",
      "sh", project_dir, branch,
    ],
    workdir: None,
  }
}

///|
/// Run `git merge --ff-only origin/<branch>` in `project_dir`. On failure, print a warning
/// to stderr and exit 0 so spawn sequences continue.
pub fn git_merge_ff_origin_branch_best_effort(
  project_dir : String,
  branch : String,
) -> Command {
  {
    program: "sh",
    args: [
      "-c", "cd \"$1\" && { git merge --ff-only \"origin/$2\" || { printf '%s\\n' \"choir: warning: git merge --ff-only origin/$2 failed\" >&2; true; }; }",
      "sh", project_dir, branch,
    ],
    workdir: None,
  }
}
