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
/// Lines appended to a new worktree's `.git/info/exclude` so agent IDEs can drop
/// `.cursor/`, `.codex/`, `.gemini/` without dirtying `git status` (see `command_seed_worktree_agent_runtime_gitexclude`).
pub fn agent_runtime_gitexclude_snippet() -> String {
  (
    #|# choir: agent-runtime junk
    #|.cursor/
    #|.codex/
    #|.gemini/
  )
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
/// Run `git fetch origin <branch>` in `project_dir`. If `cd` to `project_dir` fails, or fetch
/// fails, print a warning to stderr and exit 0 so spawn sequences continue.
pub fn git_fetch_origin_branch_best_effort(
  project_dir : String,
  branch : String,
) -> Command {
  {
    program: native_git_fetch_origin_branch_best_effort_program,
    args: [project_dir, branch],
    workdir: None,
  }
}

///|
/// Best-effort cleanup of an existing worktree directory and branch before `git worktree add`.
/// Always exits 0 when executed via `exec.run` so spawn sequences continue.
pub fn git_worktree_bootstrap_cleanup_best_effort(
  project_dir : String,
  workspace : String,
  branch : String,
) -> Command {
  {
    program: native_worktree_bootstrap_cleanup_program,
    args: [project_dir, workspace, branch],
    workdir: None,
  }
}
