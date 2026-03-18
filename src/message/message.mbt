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
