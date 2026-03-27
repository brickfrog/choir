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
) -> Eff[@types.Response] {
  GitCapture(program="git", args=["-C", project_dir, "status", "--porcelain"], cont=fn(
    status_out,
  ) {
    if status_out.trim().to_string() != "" {
      Pure(
        @types.Response::Err(
          "Working tree has uncommitted changes. Commit and push your scaffold work first, then call fork_wave.\n" +
          status_out.trim().to_string(),
        ),
      )
    } else {
      GitCapture(
        program="git",
        args=["-C", project_dir, "log", "--oneline", "@{u}..HEAD"],
        cont=fn(unpushed_out) {
          if unpushed_out.trim().to_string() != "" {
            Pure(
              @types.Response::Err(
                "Unpushed commits exist. Run 'git push' first, then call fork_wave.\n" +
                unpushed_out.trim().to_string(),
              ),
            )
          } else if spawned_count == 0 && skipped_count > 0 {
            Pure(
              @types.Response::ok_values({
                "status": String::to_json("already_running"),
                "count": Int::to_json(0),
                "skipped_ids": String::to_json(skipped_ids),
              }),
            )
          } else {
            RunCommands(cmds~, cont=fn(exit_codes) {
              let last = if exit_codes.length() > 0 {
                exit_codes[exit_codes.length() - 1]
              } else {
                0
              }
              if last != 0 {
                Pure(
                  @types.Response::Err(
                    "command failed with status " + last.to_string(),
                  ),
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
                Pure(@types.Response::ok_values(result))
              }
            })
          }
        },
      )
    }
  })
}
