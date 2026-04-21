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
      "skill" => skill_subcommand_run()
      "mcp" => mcp_subcommand_run()
      "log" => log_subcommand_run()
      "stats" => stats_subcommand_run()
      "tl-policy-watch" => tl_policy_watch_run()
      "tl-parent-override" => tl_parent_override_run()
      _ => {
        @sys.write_stdout(
          "usage: choir <serve|dev|tool <tool>|leaf-tool <tool>|mcp-stdio|trust-gemini-folder <path>|zellij-action <send|close>|hook|init [--recreate] [--purge] [--tl claude|codex|gemini|cursor_agent|agent] [--lean]|claude [--lean] [args...]|stop [--purge]|reply|watch|statusline|skill <add|list|remove>|mcp <add|list|remove>|log --wave <wave_id>|stats [--wave <wave_id>|--agent-type <type>]|tl-policy-watch --pid <pid>|tl-parent-override <on|off>>\n",
        )
        @sys.exit(1)
      }
    }
  }
}
