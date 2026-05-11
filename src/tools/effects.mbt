///|
/// Typed errors for the fork_wave execution path.
/// Variants carry structured data — callers match on the constructor,
/// not on substrings of a message.
pub(all) enum ForkWaveError {
  /// Working tree has uncommitted or staged changes.
  /// `output` is the raw `git status --porcelain` output.
  UncommittedChanges(output~ : String)
  /// Local commits exist that haven't been pushed.
  /// `output` is the raw `git log @{u}..HEAD` output.
  UnpushedCommits(output~ : String)
  /// Dirty paths outside scaffold_commit.paths exist before scaffold commit.
  ScaffoldCommitUnrelatedChanges(output~ : String)
  /// A scaffold_commit path has no working-tree/index change to commit.
  ScaffoldCommitPathUnchanged(path~ : String)
  /// A scaffold_commit git command exited with a non-zero status.
  ScaffoldCommandFailed(status~ : Int, failing_cmd~ : @workspace.Command?)
  /// HEAD is on a different branch than the requested parent_branch.
  /// scaffold_commit refuses to push: it would mutate the wrong branch.
  ScaffoldBranchMismatch(expected~ : String, actual~ : String)
  /// A spawn command exited with a non-zero status.
  CommandFailed(status~ : Int, failing_cmd~ : @workspace.Command?)
} derive(Debug, Eq)

///|
pub fn ForkWaveError::message(self : ForkWaveError) -> String {
  match self {
    UncommittedChanges(output~) =>
      "Working tree has uncommitted changes. Commit and push your scaffold work first, then call fork_wave.\n" +
      output.trim().to_owned()
    UnpushedCommits(output~) =>
      "Unpushed commits exist. Run 'git push' first, then call fork_wave.\n" +
      output.trim().to_owned()
    ScaffoldCommitUnrelatedChanges(output~) =>
      "scaffold_commit requires only scaffold paths to be dirty. Unrelated changes:\n" +
      output.trim().to_owned()
    ScaffoldCommitPathUnchanged(path~) =>
      "scaffold_commit path has no changes or does not exist: " + path
    ScaffoldCommandFailed(status~, ..) =>
      "scaffold_commit command failed with status " + status.to_string()
    ScaffoldBranchMismatch(expected~, actual~) =>
      "scaffold_commit refused: HEAD is on '" +
      actual +
      "' but parent_branch is '" +
      expected +
      "'. Check out '" +
      expected +
      "' before calling fork_wave with scaffold_commit."
    CommandFailed(status~, ..) =>
      "command failed with status " + status.to_string()
  }
}

///|
/// A description of side-effectful operations, parameterized by result type A.
///
/// Values of this type are pure data — no I/O occurs until fed to `interpret`.
/// This mirrors the exomonad pattern: Haskell yields effect descriptions,
/// Rust executes them. Here MoonBit yields `Eff[A]` trees, the async
/// interpreter executes them.
///
/// Usage:
///   let plan = fork_wave_plan(...)        // pure — no async, no IO
///   let resp = interpret(plan, runner~)   // async — executes the IO
pub(all) enum Eff[A] {
  /// Computation is complete.
  Pure(A)
  /// Capture stdout of a command, then continue with the result.
  GitCapture(
    program~ : String,
    args~ : Array[String],
    cont~ : (String) -> Eff[A]
  )
  /// Run a sequence of workspace commands, then continue with exit codes.
  RunCommands(cmds~ : Array[@workspace.Command], cont~ : (Array[Int]) -> Eff[A])
}

///|
/// Execute an `Eff[A]` tree by dispatching each effect to the provided
/// runners and threading results back through continuations.
///
/// This is the trampoline: unfold is building the Eff tree (pure),
/// fold is running it here (async).
pub async fn[A] interpret(
  m : Eff[A],
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> A {
  match m {
    Pure(a) => a
    GitCapture(program~, args~, cont~) =>
      interpret(
        cont(git_capture(program, args) catch { _ => "" }),
        git_capture~,
        runner~,
      )
    RunCommands(cmds~, cont~) =>
      interpret(cont(runner(cmds) catch { _ => [] }), git_capture~, runner~)
  }
}

///|
/// Pure description of what fork_wave needs to do.
///
/// Takes pre-computed values from the pure slug/command-building phase
/// and returns an effect tree describing the IO to perform.
/// The scaffold gate (git checks) and spawn are both encoded as effects —
/// no git or process calls happen here.
fn first_failed_command(
  cmds : Array[@workspace.Command],
  exit_codes : Array[Int],
) -> (Int, Int, @workspace.Command?) {
  let mut failed_idx = -1
  let mut failed_status = 0
  for i = 0; i < exit_codes.length(); i = i + 1 {
    if exit_codes[i] != 0 {
      failed_idx = i
      failed_status = exit_codes[i]
      break
    }
  }
  let failing = if failed_idx >= 0 && failed_idx < cmds.length() {
    Some(cmds[failed_idx])
  } else {
    None
  }
  (failed_idx, failed_status, failing)
}

///|
fn fork_wave_spawn_commands_phase(
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  if spawned_count == 0 && skipped_count > 0 {
    return Pure(
      Ok(
        @types.Response::ok_values({
          "status": String::to_json("already_running"),
          "count": Int::to_json(0),
          "skipped_ids": String::to_json(skipped_ids),
        }),
      ),
    )
  }
  RunCommands(cmds~, cont=fn(exit_codes) {
    let (failed_idx, failed_status, failing) = first_failed_command(
      cmds, exit_codes,
    )
    if failed_idx >= 0 {
      Pure(Err(CommandFailed(status=failed_status, failing_cmd=failing)))
    } else {
      let result : Map[String, Json] = {
        "status": String::to_json("spawned"),
        "count": Int::to_json(spawned_count),
        "agent_ids": String::to_json(agent_ids),
      }
      if skipped_count > 0 {
        result.set("skipped_ids", String::to_json(skipped_ids))
      }
      Pure(Ok(@types.Response::ok_values(result)))
    }
  })
}

///|
fn fork_wave_clean_gate_phase(
  project_dir : String,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  GitCapture(program="git", args=["-C", project_dir, "status", "--porcelain"], cont=fn(
    status_out,
  ) {
    if status_out.trim().to_owned() != "" {
      Pure(Err(UncommittedChanges(output=status_out.trim().to_owned())))
    } else {
      GitCapture(
        program="git",
        args=["-C", project_dir, "log", "--oneline", "@{u}..HEAD"],
        cont=fn(unpushed_out) {
          if unpushed_out.trim().to_owned() != "" {
            Pure(Err(UnpushedCommits(output=unpushed_out.trim().to_owned())))
          } else {
            fork_wave_spawn_commands_phase(
              cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
            )
          }
        },
      )
    }
  })
}

///|
fn fork_wave_scaffold_commit_commands(
  project_dir : String,
  scaffold : ForkWaveScaffoldCommit,
) -> Array[@workspace.Command] {
  let add_args = ["-C", project_dir, "add", "--"]
  for path in scaffold.paths {
    add_args.push(path)
  }
  let commit_args = ["-C", project_dir, "commit", "-m", scaffold.message, "--"]
  for path in scaffold.paths {
    commit_args.push(path)
  }
  [
    @workspace.Command::{ program: "git", args: add_args, workdir: None },
    @workspace.Command::{ program: "git", args: commit_args, workdir: None },
    @workspace.Command::{
      program: "git",
      args: ["-C", project_dir, "push"],
      workdir: None,
    },
  ]
}

///|
fn fork_wave_scaffold_commit_phase(
  project_dir : String,
  scaffold : ForkWaveScaffoldCommit,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
  path_index : Int,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  if path_index >= scaffold.paths.length() {
    let scaffold_cmds = fork_wave_scaffold_commit_commands(
      project_dir, scaffold,
    )
    return RunCommands(cmds=scaffold_cmds, cont=fn(exit_codes) {
      let (failed_idx, failed_status, failing) = first_failed_command(
        scaffold_cmds, exit_codes,
      )
      if failed_idx >= 0 {
        Pure(
          Err(ScaffoldCommandFailed(status=failed_status, failing_cmd=failing)),
        )
      } else {
        fork_wave_clean_gate_phase(
          project_dir, cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
        )
      }
    })
  }
  let path = scaffold.paths[path_index]
  GitCapture(
    program="git",
    args=["-C", project_dir, "status", "--porcelain", "--", path],
    cont=fn(status_out) {
      if status_out.trim().to_owned() == "" {
        Pure(Err(ScaffoldCommitPathUnchanged(path~)))
      } else {
        fork_wave_scaffold_commit_phase(
          project_dir,
          scaffold,
          cmds,
          spawned_count,
          skipped_count,
          agent_ids,
          skipped_ids,
          path_index + 1,
        )
      }
    },
  )
}

///|
/// Parse a `git status --porcelain` line and return the set of paths it
/// references. Rename/copy lines (`R` / `C` status) have the shape
/// `XY old -> new`; both `old` and `new` must be considered against
/// scaffold paths so a rename of a scaffold path isn't mis-flagged as
/// unrelated.
fn scaffold_preflight_paths_in_status_line(line : String) -> Array[String] {
  // Line shape: 'XY path' with path starting at index 3. Empty / too-short
  // lines have no paths.
  if line.length() < 4 {
    return []
  }
  let payload = line[3:].to_owned()
  let arrow = " -> "
  match payload.find(arrow) {
    Some(idx) =>
      [payload[:idx].to_owned(), payload[idx + arrow.length():].to_owned()]
    None => [payload]
  }
}

///|
/// Preflight check before scaffold_commit runs git add/commit/push. Ensures:
/// (a) HEAD is on the requested parent branch (otherwise scaffold's push
///     could mutate the wrong branch entirely),
/// (b) the parent branch has no unpushed commits (otherwise scaffold's push
///     would silently ship pre-existing local work the operator hadn't
///     reviewed), and
/// (c) the working tree is clean OUTSIDE the scaffold paths (otherwise the
///     scaffold commit goes through but the post-scaffold clean_gate then
///     fails, leaving a pushed commit behind that's now hard to back out).
/// Dirty entries that match `scaffold.paths` (including the `new` side of a
/// rename) are expected and allowed — they're what the scaffold is going
/// to commit.
fn fork_wave_scaffold_preflight_phase(
  project_dir : String,
  scaffold : ForkWaveScaffoldCommit,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
  parent_branch : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  GitCapture(
    program="git",
    args=["-C", project_dir, "rev-parse", "--abbrev-ref", "HEAD"],
    cont=fn(head_out) {
      let head_branch = head_out.trim().to_owned()
      if head_branch != parent_branch {
        Pure(
          Err(
            ScaffoldBranchMismatch(expected=parent_branch, actual=head_branch),
          ),
        )
      } else {
        GitCapture(
          program="git",
          args=["-C", project_dir, "log", "--oneline", "@{u}..HEAD"],
          cont=fn(unpushed_out) {
            if unpushed_out.trim().to_owned() != "" {
              Pure(Err(UnpushedCommits(output=unpushed_out.trim().to_owned())))
            } else {
              GitCapture(
                program="git",
                args=["-C", project_dir, "status", "--porcelain"],
                cont=fn(status_out) {
                  let scaffold_paths : Map[String, Bool] = {}
                  for p in scaffold.paths {
                    scaffold_paths.set(p, true)
                  }
                  let unrelated : Array[String] = []
                  for line in status_out.split("\n") {
                    let trimmed = line.to_owned()
                    if trimmed.length() < 4 {
                      continue
                    }
                    let paths = scaffold_preflight_paths_in_status_line(trimmed)
                    let mut all_in_scaffold = true
                    for p in paths {
                      if !scaffold_paths.contains(p) {
                        all_in_scaffold = false
                        break
                      }
                    }
                    if !all_in_scaffold {
                      unrelated.push(trimmed)
                    }
                  }
                  if unrelated.length() > 0 {
                    Pure(Err(UncommittedChanges(output=unrelated.join("\n"))))
                  } else {
                    fork_wave_scaffold_commit_phase(
                      project_dir, scaffold, cmds, spawned_count, skipped_count,
                      agent_ids, skipped_ids, 0,
                    )
                  }
                },
              )
            }
          },
        )
      }
    },
  )
}

///|
pub fn fork_wave_plan(
  project_dir : String,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
  scaffold_commit? : ForkWaveScaffoldCommit? = None,
  parent_branch? : String = "",
) -> Eff[Result[@types.Response, ForkWaveError]] {
  // Already-running short-circuit BEFORE any scaffold work: if every
  // requested leaf was deduped, fork_wave is a no-op and must not mutate
  // the parent branch. `fork_wave_spawn_commands_phase` already returns
  // the already_running response without running cmds; route there
  // directly when scaffold is present too, so a no-op fork_wave call
  // can't accidentally push a scaffold commit.
  if spawned_count == 0 && skipped_count > 0 {
    return fork_wave_spawn_commands_phase(
      cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
    )
  }
  match scaffold_commit {
    None =>
      fork_wave_clean_gate_phase(
        project_dir, cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
      )
    Some(scaffold) =>
      // Preflight before scaffold runs: no unpushed commits AND only the
      // scaffold paths are dirty. Without this, scaffold could push
      // pre-existing local work OR leave a pushed scaffold commit behind
      // when the post-scaffold clean_gate later fails.
      fork_wave_scaffold_preflight_phase(
        project_dir, scaffold, cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
        parent_branch,
      )
  }
}
