///|
pub fn render_human(snapshot : StatusSnapshot) -> String {
  let buf = StringBuilder::new()
  buf.write_string(
    "Choir Status (timestamp: " + snapshot.timestamp.to_string() + ")\n\n",
  )
  if snapshot.agents.length() == 0 {
    buf.write_string("No agents registered.\n")
    return buf.to_string()
  }
  for agent in snapshot.agents {
    buf.write_string(format_agent_human(agent))
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
pub fn render_json(snapshot : StatusSnapshot) -> String {
  let agents_json = snapshot.agents.map(agent_to_json)
  let json_obj : Map[String, Json] = Map::new()
  json_obj.set("timestamp", snapshot.timestamp.to_json())
  json_obj.set("agents", agents_json.to_json())
  json_obj.to_json().stringify()
}

///|
fn format_agent_human(agent : AgentStatus) -> String {
  let buf = StringBuilder::new()
  buf.write_string("Agent: " + agent.agent_id + "\n")
  buf.write_string("  Role: " + agent.role + "\n")
  buf.write_string("  Type: " + agent.agent_type + "\n")
  buf.write_string("  State: " + agent.state + "\n")
  buf.write_string("  Workflow: " + agent.workflow_state + "\n")
  match agent.parent {
    Some(parent) => buf.write_string("  Parent: " + parent + "\n")
    None => ()
  }
  if agent.children.length() > 0 {
    buf.write_string("  Children: " + agent.children.join(", ") + "\n")
  }
  buf.write_string("  Branch: " + agent.branch + "\n")
  buf.write_string("  Workspace: " + agent.workspace + "\n")
  match agent.tracked_pr {
    Some(pr) => buf.write_string(format_tracked_pr_human(pr))
    None => ()
  }
  match agent.blocked_summary {
    Some(summary) => buf.write_string("  Status: " + summary + "\n")
    None => ()
  }
  buf.to_string()
}

///|
fn format_tracked_pr_human(pr : TrackedPRInfo) -> String {
  let buf = StringBuilder::new()
  buf.write_string("  Tracked PR: #" + pr.pr_number.to_string() + "\n")
  if pr.url != "" {
    buf.write_string("    URL: " + pr.url + "\n")
  }
  buf.write_string("    Branch: " + pr.branch + "\n")
  buf.write_string("    Parent: " + pr.parent_branch + "\n")
  buf.write_string("    Review: " + pr.review_state + "\n")
  if pr.ci_failed {
    buf.write_string("    CI: Failed\n")
  }
  buf.to_string()
}

///|
fn agent_to_json(agent : AgentStatus) -> Json {
  let obj : Map[String, Json] = Map::new()
  obj.set("agent_id", agent.agent_id.to_json())
  obj.set("role", agent.role.to_json())
  obj.set("agent_type", agent.agent_type.to_json())
  obj.set("state", agent.state.to_json())
  obj.set("workflow_state", agent.workflow_state.to_json())
  obj.set("branch", agent.branch.to_json())
  obj.set("workspace", agent.workspace.to_json())
  match agent.parent {
    Some(parent) => obj.set("parent", parent.to_json())
    None => ()
  }
  if agent.children.length() > 0 {
    obj.set("children", agent.children.to_json())
  }
  match agent.tracked_pr {
    Some(pr) => obj.set("tracked_pr", tracked_pr_to_json(pr))
    None => ()
  }
  match agent.blocked_summary {
    Some(summary) => obj.set("blocked_summary", summary.to_json())
    None => ()
  }
  obj.to_json()
}

///|
fn tracked_pr_to_json(pr : TrackedPRInfo) -> Json {
  let obj : Map[String, Json] = Map::new()
  obj.set("pr_number", pr.pr_number.to_json())
  obj.set("branch", pr.branch.to_json())
  obj.set("parent_branch", pr.parent_branch.to_json())
  obj.set("review_state", pr.review_state.to_json())
  obj.set("ci_failed", pr.ci_failed.to_json())
  obj.set("first_seen", pr.first_seen.to_json())
  if pr.url != "" {
    obj.set("url", pr.url.to_json())
  }
  obj.to_json()
}
