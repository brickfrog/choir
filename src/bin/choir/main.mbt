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
      "beads" => @choir_commands.beads_subcommand_run()
      "log" => @choir_commands.log_subcommand_run()
      "logs" => @choir_commands.logs_subcommand_run()
      "stats" => @choir_commands.stats_subcommand_run()
      "smoke" => @choir_commands.smoke_subcommand_run()
      "tl-policy-watch" => tl_policy_watch_run()
      _ => {
        @sys.write_stdout(
          "usage: choir <serve|dev|reload|tool <tool>|leaf-tool <tool>|mcp-stdio|trust-gemini-folder <path>|zellij-action <send|close>|hook|init [--recreate] [--purge] [--tl claude|codex|gemini|cursor_agent|agent] [--lean]|claude [--lean] [args...]|stop [--purge]|reply|watch|statusline|goal <bead-id|text> [--verify <cmd>]...|goal-clear|prompts <diff|sync>|skill <add|list|remove>|mcp <add|list|remove>|beads <wave-from|gate|merge-slot|spec-link|doctor>|log --wave <wave_id>|logs [--source serve|delivery|events <agent>|wave <id>] [--tail N] [--follow|-f] [--grep PATTERN] [--level trace|debug|info|warn|error]|stats [--wave <wave_id>|--agent-type <type>]|smoke beads-handoff|tl-policy-watch --pid <pid>>\n",
        )
        @sys.exit(1)
      }
    }
  }
}
