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
  /// A spawn command exited with a non-zero status.
  CommandFailed(status~ : Int, failing_cmd~ : @workspace.Command?)
} derive(Show, Eq)

///|
pub fn ForkWaveError::message(self : ForkWaveError) -> String {
  match self {
    UncommittedChanges(output~) =>
      "Working tree has uncommitted changes. Commit and push your scaffold work first, then call fork_wave.\n" +
      output.trim().to_string()
    UnpushedCommits(output~) =>
      "Unpushed commits exist. Run 'git push' first, then call fork_wave.\n" +
      output.trim().to_string()
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
pub fn fork_wave_plan(
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
    if status_out.trim().to_string() != "" {
      Pure(Err(UncommittedChanges(output=status_out.trim().to_string())))
    } else {
      GitCapture(
        program="git",
        args=["-C", project_dir, "log", "--oneline", "@{u}..HEAD"],
        cont=fn(unpushed_out) {
          if unpushed_out.trim().to_string() != "" {
            Pure(Err(UnpushedCommits(output=unpushed_out.trim().to_string())))
          } else if spawned_count == 0 && skipped_count > 0 {
            Pure(
              Ok(
                @types.Response::ok_values({
                  "status": String::to_json("already_running"),
                  "count": Int::to_json(0),
                  "skipped_ids": String::to_json(skipped_ids),
                }),
              ),
            )
          } else {
            RunCommands(cmds~, cont=fn(exit_codes) {
              let mut failed_idx = -1
              let mut failed_status = 0
              for i = 0; i < exit_codes.length(); i = i + 1 {
                if exit_codes[i] != 0 {
                  failed_idx = i
                  failed_status = exit_codes[i]
                  break
                }
              }
              if failed_idx >= 0 {
                let failing = if failed_idx < cmds.length() {
                  Some(cmds[failed_idx])
                } else {
                  None
                }
                Pure(
                  Err(CommandFailed(status=failed_status, failing_cmd=failing)),
                )
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
        },
      )
    }
  })
}
