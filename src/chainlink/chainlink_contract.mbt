///|
pub fn task_contract_from_chainlink_issue(
  issue : ChainlinkIssue,
) -> @types.TaskContract {
  let goal = issue.title.trim().to_string()
  let constraints = []
  for n in issue.blocked_by {
    constraints.push("blocked by: #\{n}")
  }

  // Description part
  let desc_part = match issue.description {
    Some(s) => s.trim().to_string()
    None => ""
  }

  // Plan + decision comments sorted by id ascending
  let plan_decision = issue.comments.filter(fn(c) {
    c.kind == "plan" || c.kind == "decision"
  })
  plan_decision.sort_by(fn(a, b) { a.id.compare(b.id) })
  let pd_parts : Array[String] = []
  for c in plan_decision {
    let t = c.content.trim().to_string()
    if t != "" {
      pd_parts.push("[\{c.kind} #\{c.id}]\n\{t}")
    }
  }

  // Handoff comments sorted by id ascending
  let handoffs = issue.comments.filter(fn(c) { c.kind == "handoff" })
  handoffs.sort_by(fn(a, b) { a.id.compare(b.id) })
  let h_parts : Array[String] = []
  for c in handoffs {
    let t = c.content.trim().to_string()
    if t != "" {
      h_parts.push("[\{c.kind} #\{c.id}]\n\{t}")
    }
  }

  // Assemble review_context
  let all_parts : Array[String] = []
  if desc_part != "" {
    all_parts.push(desc_part)
  }
  for p in pd_parts {
    all_parts.push(p)
  }
  for p in h_parts {
    all_parts.push(p)
  }
  let review_context = if all_parts.length() == 0 {
    None
  } else {
    Some(all_parts.join("\n\n"))
  }

  {
    goal,
    scope: [],
    acceptance_checks: [],
    constraints,
    non_goals: [],
    review_context,
    verify: [],
  }
}
