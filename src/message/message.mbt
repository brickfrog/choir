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
  TeamsInbox(String, String)
  LocalTerminalInput(String, String)
  TcpPush(String, String)
  UdsHttp(String, String)
} derive(Show, Eq)

///|
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
pub fn teams_inbox_json(
  sender : String,
  content : String,
  status : String,
) -> String {
  "{\"from\":\"" +
  escape_json_string(sender) +
  "\",\"content\":\"" +
  escape_json_string(content) +
  "\",\"status\":\"" +
  escape_json_string(status) +
  "\"}"
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
      match agent.agent_type {
        Claude =>
          TeamsInbox(
            teams_inbox_path(agent.agent_id),
            teams_inbox_json(sender_id, content, status),
          )
        Gemini => {
          let target = match agent.tmux_target {
            Some(t) => t
            None => agent.agent_id
          }
          LocalTerminalInput(target, format_message(sender_id, content))
        }
        MoonPilot => {
          let target = match agent.tmux_target {
            Some(t) => t
            None => agent.agent_id
          }
          LocalTerminalInput(target, format_message(sender_id, content))
        }
      }
  }
}
