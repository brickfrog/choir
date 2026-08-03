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
    #|  take --provider <claude|codex> [--scope <path>]... [--apply] <instruction>
    #|                        run one isolated, verified agent change
    #|  start [--lean] [--conductor <claude|codex>]
    #|                        start choird and open a Conductor
    #|  serve                 run the orchestration server
    #|
    #|Goals
    #|  goal status <goal-id>
    #|  goal steer <goal-id> <pause|resume|concurrency N>
    #|  goal cancel <goal-id>
    #|  goal archive <goal-id> [--dry-run]
    #|                        release a finished Goal's working storage
    #|  goal attach <take-id>
    #|  goal answer <request-id> <answer>
    #|
    #|Control
    #|  doctor                check every host dependency Choir needs
    #|  stop [--purge]        stop the server (optionally purge runtime state)
    #|
    #|Internal:
    #|  mcp-stdio             bridge the Conductor MCP session to choird
    #|  conductor-stop        park a built-in /goal until Choir emits an event
    #|  conductor-statusline  render cached Conductor and Claude session status
    #|  run-goals             execute durable Goal work for choird
    #|
  )
}

///|
test "CLI help exposes only the current Conductor and Goal controls" {
  let usage = choir_usage()
  assert_true(usage.contains("--conductor <claude|codex>"))
  assert_true(usage.contains("goal status <goal-id>"))
  assert_true(usage.contains("goal archive <goal-id> [--dry-run]"))
  assert_true(usage.contains("goal attach <take-id>"))
  assert_true(usage.contains("goal answer <request-id> <answer>"))
  assert_false(usage.contains("<bead-id|text>"))
  assert_true(usage.contains("take --provider <claude|codex>"))
  assert_true(usage.contains("doctor"))
}

///|
/// What the recorded pid file says about a daemon, before anything is killed.
/// A missing or unreadable pid file reads as `""`, which must not look like a
/// daemon that was stopped successfully.
pub(all) enum StopDaemonRecord {
  StopDaemonRecorded(Int)
  StopDaemonAbsent
  StopDaemonUnreadable(String)
} derive(Debug, Eq)

///|
pub fn stop_daemon_record(pid_text : String) -> StopDaemonRecord {
  let trimmed = pid_text.trim().to_owned()
  if trimmed == "" {
    return StopDaemonAbsent
  }
  let pid = @string.parse_int(trimmed) catch {
    _ => return StopDaemonUnreadable(trimmed)
  }
  if pid > 1 {
    StopDaemonRecorded(pid)
  } else {
    StopDaemonUnreadable(trimmed)
  }
}

///|
test "a missing pid file is not a stopped daemon" {
  assert_eq(stop_daemon_record(""), StopDaemonAbsent)
  assert_eq(stop_daemon_record("  \n"), StopDaemonAbsent)
  assert_eq(stop_daemon_record("4321\n"), StopDaemonRecorded(4321))
  // pid 0 and 1 are never this daemon, and neither is unparseable text.
  assert_eq(stop_daemon_record("0"), StopDaemonUnreadable("0"))
  assert_eq(stop_daemon_record("1"), StopDaemonUnreadable("1"))
  assert_eq(stop_daemon_record("-9"), StopDaemonUnreadable("-9"))
  assert_eq(stop_daemon_record("wedged"), StopDaemonUnreadable("wedged"))
}

///|
/// Read-only preflight over the full dependency matrix. Exits nonzero only
/// when a required dependency is missing or drifted, so an operator without
/// `gh` still gets a zero exit.
fn doctor_run() -> Unit {
  @async.run_async_main(async fn() {
    let report = @doctor_host.run_native_doctor()
    @sys.write_stdout(@command.render_doctor_report(report))
    if report.failures > 0 {
      @sys.exit(1)
    }
  })
}

///|
fn stop_run() -> Unit {
  let record = stop_daemon_record(@sys.read_file(".choir/run/server.pid"))
  match record {
    StopDaemonRecorded(pid) => {
      @sys.write_stdout("Stopping choird (PID \{pid})...\n")
      @sys.kill_server_tree_sequence_best_effort(pid)
      // The kill sequence is best effort, so termination is verified rather
      // than assumed: a wedged daemon must not report success.
      if @sys.pid_is_alive(pid) {
        @sys.write_stderr(
          "choir stop: choird (PID \{pid}) is still running after the stop sequence\n",
        )
        @sys.exit(1)
        return
      }
    }
    // Nothing to kill, but `--purge` still has runtime artifacts to reclaim,
    // so this reports honestly and continues rather than claiming a stop.
    StopDaemonAbsent =>
      @sys.write_stdout(
        "No choird was running here (no .choir/run/server.pid).\n",
      )
    StopDaemonUnreadable(value) => {
      @sys.write_stderr(
        "choir stop: .choir/run/server.pid does not name a daemon process: \{value}\n",
      )
      @sys.exit(1)
      return
    }
  }
  let stopped_a_daemon = record is StopDaemonRecorded(_)
  let terminal_message = if stopped_a_daemon {
    "Choir stopped.\n"
  } else {
    "Nothing was running to stop.\n"
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
      let direct = match
        @direct_take_host.purge_native_direct_take_resources(project_dir) {
        Ok(value) => value
        Err(error) => {
          @sys.init_cleanup_runtime_artifacts_native()
          @sys.write_stderr(
            "choir stop: direct Take purge failed: " + error.message() + "\n",
          )
          @sys.exit(1)
          return
        }
      }
      match @goal_host.purge_native_goal_resources(project_dir) {
        Ok(report) => {
          @sys.init_cleanup_purge_artifacts_native()
          @sys.write_stdout(
            "Purged \{direct.runtime_roots_removed} direct Take runtime root(s), \{report.runtime_roots_removed} Goal runtime root(s), \{report.git_refs_removed} owned Git ref(s), released \{report.source_claims_released} Bead claim(s), and reclaimed \{report.boxlite_bytes_reclaimed} BoxLite byte(s).\n",
          )
          @sys.write_stdout(terminal_message)
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
    @sys.write_stdout(terminal_message)
  }
}

///|
fn main {
  let args = @env.args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  match subcmd {
    "serve" => serve_run()
    "take" => take_run()
    "start" => start_run()
    "mcp-stdio" => mcp_run()
    "conductor-stop" => conductor_stop_run()
    "conductor-statusline" => conductor_statusline_run()
    "run-goals" => goal_worker_run()
    "init" => init_run()
    "stop" => stop_run()
    "doctor" => doctor_run()
    "goal" => goal_run()
    "help" | "-h" | "--help" | "" => @sys.write_stdout(choir_usage())
    _ => {
      @sys.write_stdout("choir: unknown command '" + subcmd + "'\n\n")
      @sys.write_stdout(choir_usage())
      @sys.exit(1)
    }
  }
}
