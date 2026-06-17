///|
pub(all) enum BaselineOutcome {
  AlreadyRed
  GreenAtBaseline
  Unknown
} derive(Debug, Eq)

///|
fn baseline_verify_join_project_path(
  project_dir : String,
  rel_path : String,
) -> String {
  let root = project_dir.trim().to_owned()
  if root == "" {
    rel_path
  } else if root == "/" {
    "/" + rel_path
  } else if root.has_suffix("/") {
    root + rel_path
  } else {
    root + "/" + rel_path
  }
}

///|
fn baseline_verify_safe_component(value : String) -> String {
  let trimmed = value.trim().to_owned()
  let short = if trimmed.length() > 32 {
    trimmed[:32].to_owned()
  } else {
    trimmed
  }
  let safe = short
    .replace(old="/", new="-")
    .replace(old="\\", new="-")
    .replace(old=" ", new="-")
    .replace(old="\n", new="-")
    .replace(old="\r", new="-")
    .replace(old="\t", new="-")
    .replace(old=":", new="-")
  if safe == "" {
    "unknown"
  } else {
    safe
  }
}

///|
let baseline_verify_temp_worktree_counter : @ref.Ref[Int64] = @ref.new(0L)

///|
fn baseline_verify_next_temp_worktree_suffix() -> String {
  baseline_verify_temp_worktree_counter.val = baseline_verify_temp_worktree_counter.val +
    1L
  baseline_verify_temp_worktree_counter.val.to_string()
}

///|
fn baseline_verify_default_temp_worktree(
  project_dir : String,
  baseline_sha : String,
) -> String {
  let stamp = @env.now().reinterpret_as_int64().to_string()
  let suffix = baseline_verify_next_temp_worktree_suffix()
  baseline_verify_join_project_path(
    project_dir,
    ".choir/baseline-verify-" +
    baseline_verify_safe_component(baseline_sha) +
    "-" +
    stamp +
    "-" +
    suffix,
  )
}

///|
fn baseline_verify_worktree_add_command(
  project_dir : String,
  temp_worktree : String,
  baseline_sha : String,
) -> @workspace.Command {
  {
    program: "git",
    args: ["worktree", "add", temp_worktree, baseline_sha],
    workdir: Some(project_dir),
  }
}

///|
fn baseline_verify_worktree_remove_command(
  project_dir : String,
  temp_worktree : String,
) -> @workspace.Command {
  {
    program: "git",
    args: ["worktree", "remove", "--force", temp_worktree],
    workdir: Some(project_dir),
  }
}

///|
fn baseline_verify_shell_command(
  command : String,
  temp_worktree : String,
) -> @workspace.Command {
  { program: "sh", args: ["-lc", command], workdir: Some(temp_worktree) }
}

///|
async fn baseline_verify_remove_worktree_best_effort(
  project_dir : String,
  temp_worktree : String,
  git_capture : async (@workspace.Command) -> (Int, String),
) -> Unit {
  ignore(
    git_capture(
      baseline_verify_worktree_remove_command(project_dir, temp_worktree),
    ) catch {
      _ => (-1, "")
    },
  )
}

///|
pub async fn baseline_verify_command_outcome(
  baseline_sha : String,
  command : String,
  project_dir : String,
  git_capture : async (@workspace.Command) -> (Int, String),
  capture : async (@workspace.Command) -> (Int, String),
  temp_worktree? : String? = None,
) -> BaselineOutcome {
  let sha = baseline_sha.trim().to_owned()
  let mut created = false
  let temp = match temp_worktree {
    Some(path) => {
      let trimmed = path.trim().to_owned()
      if trimmed == "" {
        return BaselineOutcome::Unknown
      }
      trimmed
    }
    None => baseline_verify_default_temp_worktree(project_dir, sha)
  }
  if sha == "" {
    return BaselineOutcome::Unknown
  }

  let (add_exit, _) = git_capture(
    baseline_verify_worktree_add_command(project_dir, temp, sha),
  ) catch {
    _ => return BaselineOutcome::Unknown
  }
  if add_exit != 0 {
    return BaselineOutcome::Unknown
  }
  created = true

  let (verify_exit, _) = capture(baseline_verify_shell_command(command, temp)) catch {
    _ => {
      if created {
        baseline_verify_remove_worktree_best_effort(
          project_dir, temp, git_capture,
        )
      }
      return BaselineOutcome::Unknown
    }
  }
  let outcome = if verify_exit == 0 {
    BaselineOutcome::GreenAtBaseline
  } else if verify_exit > 0 {
    BaselineOutcome::AlreadyRed
  } else {
    BaselineOutcome::Unknown
  }
  if created {
    baseline_verify_remove_worktree_best_effort(project_dir, temp, git_capture)
  }
  outcome
}

///|
test "baseline verify default temp worktree appends process-local counter" {
  let prefix = "/repo/.choir/baseline-verify-same-sha-"
  let first = baseline_verify_default_temp_worktree("/repo", "same/sha")
  let second = baseline_verify_default_temp_worktree("/repo", "same/sha")
  assert_true(first.has_prefix(prefix))
  assert_true(second.has_prefix(prefix))
  assert_true(first[prefix.length():].to_owned().contains("-"))
  assert_true(second[prefix.length():].to_owned().contains("-"))
  assert_true(first != second)
}
