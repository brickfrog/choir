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
    #|  init [--recreate] [--purge] [--tl <claude|codex|gemini|cursor_agent|agent>] [--lean]
    #|                        scaffold .choir and start the server + TL
    #|
    #|Run
    #|  serve                 run the orchestration server
    #|  dev                   start a dev TL session
    #|
    #|Goals
    #|  goal <bead-id|text> [--verify <cmd>]...   set the active TL goal
    #|  goal-clear            clear the active goal
    #|
    #|Inspect
    #|  logs [--source serve|delivery|events <agent>|wave <id>] [--tail N] [--follow|-f] [--grep PATTERN] [--level ...]
    #|  log --wave <wave_id>  print a wave's log
    #|  stats [--wave <id>|--agent-type <type>]   usage/cost stats
    #|  watch                 live status watcher
    #|
    #|Configure
    #|  config schema [--format=md|json]
    #|  prompts <diff|sync>   inspect / sync prompt assets
    #|  skill <add|list|remove>
    #|  mcp <add|list|remove>
    #|  beads <wave-from|gate|merge-slot|spec-link|doctor>
    #|
    #|Control
    #|  stop [--purge]        stop the server (optionally purge runtime state)
    #|
    #|Internal (invoked by choir/agents, not for direct use):
    #|  tool, leaf-tool, mcp-stdio, hook, zellij-action, claude, reply,
    #|  statusline, reload, trust-gemini-folder, smoke
    #|
  )
}

///|
fn main {
  let args = @env.args()
  let subcmd = if args.length() >= 2 { args[1] } else { "" }
  if subcmd == @exec.DEV_RELOAD_SUBCOMMAND {
    dev_reload_run()
  } else {
    match subcmd {
      "serve" => serve_run()
      "dev" => dev_run()
      "reload" => reload_run()
      "tool" => tool_run()
      "leaf-tool" => leaf_tool_run()
      "mcp-stdio" => mcp_run()
      "trust-gemini-folder" => trust_gemini_folder_run()
      "zellij-action" => zellij_action_run()
      "hook" => hook_run()
      "init" => init_run()
      "claude" => claude_wrapper_run()
      "stop" => stop_run()
      "reply" => reply_run()
      "watch" => watch_run()
      "statusline" => statusline_run()
      "goal" => goal_run()
      "goal-clear" => goal_clear_run()
      "prompts" => prompts_cmd_run()
      "skill" => @choir_commands.skill_subcommand_run()
      "mcp" => @choir_commands.mcp_subcommand_run()
      "config" => @choir_commands.config_subcommand_run()
      "beads" => @choir_commands.beads_subcommand_run()
      "log" => @choir_commands.log_subcommand_run()
      "logs" => @choir_commands.logs_subcommand_run()
      "stats" => @choir_commands.stats_subcommand_run()
      "smoke" => @choir_commands.smoke_subcommand_run()
      "help" | "-h" | "--help" | "" => @sys.write_stdout(choir_usage())
      _ => {
        @sys.write_stdout("choir: unknown command '" + subcmd + "'\n\n")
        @sys.write_stdout(choir_usage())
        @sys.exit(1)
      }
    }
  }
}
