///|
/// Format a message for delivery to an agent pane.
pub fn format_message(sender : String, content : String) -> String {
  "[from: " + sender + "] " + content
}

///|
/// Format a failure notification.
pub fn format_failure(agent_id : String, content : String) -> String {
  "[FAILED: " + agent_id + "] " + content
}

///|
/// Format a PR-ready notification.
pub fn format_pr_ready(agent_id : String) -> String {
  "[PR READY: " + agent_id + "]"
}

///|
/// Format a fixes-pushed notification.
pub fn format_fixes_pushed(agent_id : String) -> String {
  "[FIXES PUSHED: " + agent_id + "]"
}

///|
/// Format a review-timeout notification.
pub fn format_review_timeout(agent_id : String) -> String {
  "[REVIEW TIMEOUT: " + agent_id + "]"
}

///|
pub(all) enum DeliveryMethod {
  TeamsInbox(String, String, fallback_target~ : String?)
  LocalTerminalInput(String, String)
  TcpPush(String, String)
  UdsHttp(String, String)
} derive(Show, Eq)

///|
pub fn teams_inbox_json(
  sender : String,
  content : String,
  status : String,
) -> String {
  {
    "from": sender.to_json(),
    "content": content.to_json(),
    "status": status.to_json(),
  }
  .to_json()
  .stringify()
}

///|
pub fn teams_inbox_path(agent_name : String) -> String {
  "~/.claude/teams/" + agent_name + "/inboxes/default.json"
}

///|
pub fn plan_delivery(
  agent : @types.Agent,
  sender_id : String,
  content : String,
  status : String,
) -> DeliveryMethod {
  match agent.host {
    Remote(_) => TcpPush(agent.agent_id, format_message(sender_id, content))
    Local =>
      match agent.terminal_target {
        Some(target) =>
          // Terminal injection for all agents with a live terminal.
          // For Claude TL this is essential — InboxPoller only runs
          // while Claude is processing a turn, not while idle at prompt.
          LocalTerminalInput(target, format_message(sender_id, content))
        None =>
          match agent.agent_type {
            Claude =>
              TeamsInbox(
                teams_inbox_path(agent.agent_id),
                teams_inbox_json(sender_id, content, status),
                fallback_target=Some(agent.agent_id),
              )
            _ =>
              LocalTerminalInput(
                agent.agent_id,
                format_message(sender_id, content),
              )
          }
      }
  }
}
