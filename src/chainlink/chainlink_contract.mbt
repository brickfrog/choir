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

///|
pub fn merge_chainlink_into_task_contract(
  issue : ChainlinkIssue,
  contract : @types.TaskContract,
) -> @types.TaskContract {
  let goal = if contract.goal.trim() == "" {
    issue.title.trim().to_string()
  } else {
    contract.goal
  }

  // Collect plan+decision comments. Filter to non-empty content (trimmed) FIRST
  let non_empty_pd = issue.comments.filter(fn(c) {
    (c.kind == "plan" || c.kind == "decision") && c.content.trim() != ""
  })

  // Sort by id ascending
  non_empty_pd.sort_by(fn(a, b) { a.id.compare(b.id) })

  // Then take last 5 by id (highest 5 ids)
  let len = non_empty_pd.length()
  let last_5 : Array[ChainlinkComment] = []
  let start_idx = if len > 5 { len - 5 } else { 0 }
  for i = start_idx; i < len; i = i + 1 {
    last_5.push(non_empty_pd[i])
  }

  let comment_parts : Array[String] = []
  for c in last_5 {
    comment_parts.push("[\{c.kind} #\{c.id}]\n\{c.content.trim()}")
  }

  let comment_block = comment_parts.join("\n\n")

  let desc_part = match issue.description {
    Some(d) => {
      let trimmed = d.trim().to_string()
      if trimmed != "" {
        trimmed
      } else {
        ""
      }
    }
    None => ""
  }

  let chainlink_contribution = if desc_part != "" && comment_block != "" {
    desc_part + "\n\n" + comment_block
  } else if desc_part != "" {
    desc_part
  } else {
    comment_block
  }

  let review_context = match contract.review_context {
    None =>
      if chainlink_contribution != "" {
        Some(chainlink_contribution)
      } else {
        None
      }
    Some(tl) =>
      if chainlink_contribution != "" {
        Some(
          tl + "\n\n--- chainlink plan history ---\n\n" + chainlink_contribution,
        )
      } else {
        Some(tl)
      }
  }

  let constraints : Array[String] = []
  for c in contract.constraints {
    constraints.push(c)
  }
  for n in issue.blocked_by {
    let s = "blocked by: #\{n}"
    let mut found = false
    for c in constraints {
      if c == s {
        found = true
        break
      }
    }
    if !found {
      constraints.push(s)
    }
  }

  {
    goal,
    scope: contract.scope.filter(fn(_s) { true }),
    acceptance_checks: contract.acceptance_checks.filter(fn(_s) { true }),
    constraints,
    non_goals: contract.non_goals.filter(fn(_s) { true }),
    review_context,
    verify: contract.verify.filter(fn(_s) { true }),
  }
}
