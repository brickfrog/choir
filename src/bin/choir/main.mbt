///|
/// Grouped, human-readable CLI help. Human commands are grouped by purpose;
/// internal commands (invoked by choir/agents, not for direct use) are listed
/// separately so `choir` and `choir help` are navigable at a glance.
fn choir_usage() -> String {
  (
    #|choir — agent orchestration
    #|
    #|Usage: choir <command> [args]
    #|
    #|Setup
    #|  init [--lean] [--conductor <claude|codex>]
    #|                        scaffold .choir, start choird, and open a Conductor
    #|
    #|Run
    #|  start [--lean] [--conductor <claude|codex>]
    #|                        start choird and open a Conductor
    #|  serve                 run the orchestration server
    #|
    #|Goals
    #|  goal status <goal-id>
    #|  goal steer <goal-id> <pause|resume|concurrency N>
    #|  goal cancel <goal-id>
    #|  goal attach <take-id>
    #|  goal answer <request-id> <answer>
    #|
    #|Control
    #|  stop [--purge]        stop the server (optionally purge runtime state)
    #|
    #|Internal:
    #|  mcp-stdio             bridge the Conductor MCP session to choird
    #|  run-goals             execute durable Goal work for choird
    #|
  )
}

///|
test "CLI help exposes only the current Conductor and Goal controls" {
  let usage = choir_usage()
  assert_true(usage.contains("--conductor <claude|codex>"))
  assert_true(usage.contains("goal status <goal-id>"))
  assert_true(usage.contains("goal attach <take-id>"))
  assert_true(usage.contains("goal answer <request-id> <answer>"))
  assert_false(usage.contains("<bead-id|text>"))
  assert_false(usage.contains("--verify"))
}

///|
fn stop_run() -> Unit {
  let pid_text = @sys.read_file(".choir/run/server.pid").trim().to_owned()
  let pid = @string.parse_int(pid_text) catch { _ => 0 }
  if pid > 1 {
    @sys.write_stdout("Stopping choird (PID \{pid})...\n")
    @sys.kill_server_tree_sequence_best_effort(pid)
  }
  if @env.args().contains("--purge") {
    let project_dir = match @sys.realpath_native(".") {
      Some(value) => value
      None => {
        @sys.write_stderr(
          "choir stop: failed to resolve the project directory\n",
        )
        @sys.exit(1)
        return
      }
    }
    @async.run_async_main(async fn() {
      match @exec.purge_native_goal_resources(project_dir) {
        Ok(report) => {
          @sys.init_cleanup_purge_artifacts_native()
          @sys.write_stdout(
            "Purged \{report.runtime_roots_removed} Goal runtime root(s) and \{report.git_refs_removed} owned Git ref(s).\n",
          )
          @sys.write_stdout("Choir stopped.\n")
        }
        Err(error) => {
          @sys.init_cleanup_runtime_artifacts_native()
          @sys.write_stderr(
            "choir stop: runtime purge failed: " + error.message() + "\n",
          )
          @sys.exit(1)
        }
      }
    })
  } else {
    @sys.init_cleanup_runtime_artifacts_native()
    @sys.write_stdout("Choir stopped.\n")
  }
}

///|
fn main {
  let args = @env.args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  match subcmd {
    "serve" => serve_run()
    "start" => start_run()
    "mcp-stdio" => mcp_run()
    "run-goals" => goal_worker_run()
    "init" => init_run()
    "stop" => stop_run()
    "goal" => goal_run()
    "help" | "-h" | "--help" | "" => @sys.write_stdout(choir_usage())
    _ => {
      @sys.write_stdout("choir: unknown command '" + subcmd + "'\n\n")
      @sys.write_stdout(choir_usage())
      @sys.exit(1)
    }
  }
}
