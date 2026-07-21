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
    #|  init [--lean]
    #|                        scaffold .choir, start choird, and open a Conductor
    #|
    #|Run
    #|  start [--lean]
    #|                        start choird and open a Conductor
    #|  serve                 run the orchestration server
    #|
    #|Goals
    #|  goal <bead-id|text> [--verify <cmd>]...   submit or inspect a Goal
    #|
    #|Control
    #|  stop [--purge]        stop the server (optionally purge runtime state)
    #|
    #|Internal:
    #|  mcp-stdio             bridge the Conductor MCP session to choird
    #|
  )
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
    @sys.init_cleanup_purge_artifacts_native()
  } else {
    @sys.init_cleanup_runtime_artifacts_native()
  }
  @sys.write_stdout("Choir stopped.\n")
}

///|
fn main {
  let args = @env.args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  match subcmd {
    "serve" => serve_run()
    "start" => start_run()
    "mcp-stdio" => mcp_run()
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
