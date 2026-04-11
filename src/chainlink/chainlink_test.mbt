///|
test "parse_chainlink_issue_from_json - valid" {
  let json_str =
    #|{
    #|  "id": 123,
    #|  "title": "Fix the bug",
    #|  "description": "It is broken",
    #|  "priority": "high",
    #|  "status": "in_progress",
    #|  "parent_id": 45,
    #|  "labels": ["bug", "ui"],
    #|  "blocked_by": [67, 89],
    #|  "subissues": [
    #|    {
    #|      "id": 124,
    #|      "title": "Sub bug",
    #|      "description": "Sub broken",
    #|      "priority": "low",
    #|      "status": "open",
    #|      "parent_id": 123,
    #|      "labels": [],
    #|      "blocked_by": [],
    #|      "subissues": []
    #|    }
    #|  ]
    #|}
  let json = @json.parse(json_str)
  let issue = parse_chainlink_issue_from_json(json)
  match issue {
    Some(i) => {
      assert_eq(i.id, 123)
      assert_eq(i.title, "Fix the bug")
      assert_eq(i.priority, "high")
      assert_eq(i.status, "in_progress")
      assert_eq(i.parent_id, Some(45))
      assert_eq(i.labels.length(), 2)
      assert_eq(i.blocked_by.length(), 2)
      assert_eq(i.subissues.length(), 1)
      assert_eq(i.subissues[0].id, 124)
    }
    None => fail("Failed to parse valid issue")
  }
}

///|
test "parse_chainlink_issue_list_from_json - valid array" {
  let json_str =
    #|[
    #|  {
    #|    "id": 1,
    #|    "title": "Issue 1",
    #|    "priority": "medium",
    #|    "status": "open"
    #|  },
    #|  {
    #|    "id": 2,
    #|    "title": "Issue 2",
    #|    "priority": "low",
    #|    "status": "closed"
    #|  }
    #|]
  let json = @json.parse(json_str)
  let issues = parse_chainlink_issue_list_from_json(json)
  assert_eq(issues.length(), 2)
  assert_eq(issues[0].id, 1)
  assert_eq(issues[1].id, 2)
}

///|
test "parse_chainlink_issue_from_json - malformed" {
  let json_str =
    #|"not an object"
  let json = @json.parse(json_str)
  let issue = parse_chainlink_issue_from_json(json)
  assert_true(issue is None)
}

///|
test "parse_chainlink_issue_from_json - missing required field" {
  let json_str =
    #|{
    #|  "id": 123,
    #|  "priority": "high",
    #|  "status": "open"
    #|}
  let json = @json.parse(json_str)
  let issue = parse_chainlink_issue_from_json(json)
  assert_true(issue is None)
}

// ──────────────────────────────────────────────────────────────────
// ChainlinkComment parser tests
// ──────────────────────────────────────────────────────────────────

///|
test "parse_chainlink_comment_from_json - valid comment parses correctly" {
  let json_str =
    #|{ "id": 7, "content": "Looks good", "kind": "plan" }
  let json = @json.parse(json_str)
  let comment = parse_chainlink_comment_from_json(json)
  match comment {
    Some(c) => {
      assert_eq(c.id, 7)
      assert_eq(c.content, "Looks good")
      assert_eq(c.kind, "plan")
    }
    None => fail("Expected Some comment")
  }
}

///|
test "parse_chainlink_comment_from_json - missing kind defaults to observation" {
  let json_str =
    #|{ "id": 3, "content": "Note" }
  let json = @json.parse(json_str)
  let comment = parse_chainlink_comment_from_json(json)
  match comment {
    Some(c) => assert_eq(c.kind, "observation")
    None => fail("Expected Some comment")
  }
}

///|
test "parse_chainlink_comment_from_json - missing id returns None" {
  let json_str =
    #|{ "content": "No id here", "kind": "plan" }
  let json = @json.parse(json_str)
  let comment = parse_chainlink_comment_from_json(json)
  assert_true(comment is None)
}

///|
test "parse_chainlink_comment_from_json - missing content returns None" {
  let json_str =
    #|{ "id": 5, "kind": "decision" }
  let json = @json.parse(json_str)
  let comment = parse_chainlink_comment_from_json(json)
  assert_true(comment is None)
}

// ──────────────────────────────────────────────────────────────────
// ChainlinkIssue comments field tests
// ──────────────────────────────────────────────────────────────────

///|
test "parse_chainlink_issue_from_json - parses comments array correctly" {
  let json_str =
    #|{
    #|  "id": 10,
    #|  "title": "Issue with comments",
    #|  "priority": "medium",
    #|  "status": "open",
    #|  "comments": [
    #|    { "id": 1, "content": "First", "kind": "plan" },
    #|    { "id": 2, "content": "Second", "kind": "decision" }
    #|  ]
    #|}
  let json = @json.parse(json_str)
  let issue = parse_chainlink_issue_from_json(json)
  match issue {
    Some(i) => {
      assert_eq(i.comments.length(), 2)
      assert_eq(i.comments[0].id, 1)
      assert_eq(i.comments[0].content, "First")
      assert_eq(i.comments[0].kind, "plan")
      assert_eq(i.comments[1].id, 2)
      assert_eq(i.comments[1].kind, "decision")
    }
    None => fail("Expected Some issue")
  }
}

///|
test "parse_chainlink_issue_from_json - absent comments key yields empty array" {
  let json_str =
    #|{ "id": 1, "title": "No comments", "priority": "medium", "status": "open" }
  let json = @json.parse(json_str)
  let issue = parse_chainlink_issue_from_json(json)
  match issue {
    Some(i) => assert_eq(i.comments.length(), 0)
    None => fail("Expected Some issue")
  }
}

// ──────────────────────────────────────────────────────────────────
// task_contract_from_chainlink_issue tests
// ──────────────────────────────────────────────────────────────────

///|
fn make_issue(
  title? : String = "Test task",
  description? : String? = None,
  blocked_by? : Array[Int] = [],
  comments? : Array[ChainlinkComment] = [],
) -> ChainlinkIssue {
  {
    id: 1,
    title,
    description,
    priority: "medium",
    status: "open",
    parent_id: None,
    labels: [],
    blocked_by,
    subissues: [],
    comments,
  }
}

///|
test "task_contract - no description, no comments → review_context is None" {
  let contract = task_contract_from_chainlink_issue(make_issue())
  assert_true(contract.review_context is None)
}

///|
test "task_contract - description only → review_context is Some(description)" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(description=Some("Do the thing")),
  )
  assert_eq(contract.review_context, Some("Do the thing"))
}

///|
test "task_contract - plan comments sorted by id with correct headers" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(comments=[
      { id: 20, content: "Second plan", kind: "plan" },
      { id: 10, content: "First plan", kind: "plan" },
    ]),
  )
  assert_eq(
    contract.review_context,
    Some("[plan #10]\nFirst plan\n\n[plan #20]\nSecond plan"),
  )
}

///|
test "task_contract - mixed plan and decision interleaved by id ascending" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(comments=[
      { id: 5, content: "Decision first", kind: "decision" },
      { id: 3, content: "Plan first", kind: "plan" },
    ]),
  )
  assert_eq(
    contract.review_context,
    Some("[plan #3]\nPlan first\n\n[decision #5]\nDecision first"),
  )
}

///|
test "task_contract - handoff comments appended after plan/decision block" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(comments=[
      { id: 1, content: "The plan", kind: "plan" },
      { id: 2, content: "Handoff note", kind: "handoff" },
    ]),
  )
  assert_eq(
    contract.review_context,
    Some("[plan #1]\nThe plan\n\n[handoff #2]\nHandoff note"),
  )
}

///|
test "task_contract - observation and result comments ignored" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(comments=[
      { id: 1, content: "obs text", kind: "observation" },
      { id: 2, content: "result text", kind: "result" },
    ]),
  )
  assert_true(contract.review_context is None)
}

///|
test "task_contract - trailing newlines in comment content are trimmed" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(comments=[{ id: 1, content: "Plan content\n\n", kind: "plan" }]),
  )
  assert_eq(contract.review_context, Some("[plan #1]\nPlan content"))
}

///|
test "task_contract - empty content after trim skips entry" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(comments=[{ id: 1, content: "   \n", kind: "plan" }]),
  )
  assert_true(contract.review_context is None)
}

///|
test "task_contract - whitespace-only description treated as absent" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(description=Some("   ")),
  )
  assert_true(contract.review_context is None)
}

///|
test "task_contract - description combined with plan comment" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(description=Some("Context here"), comments=[
      { id: 1, content: "Plan step", kind: "plan" },
    ]),
  )
  assert_eq(
    contract.review_context,
    Some("Context here\n\n[plan #1]\nPlan step"),
  )
}

///|
test "task_contract - blocked_by maps to constraints strings" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(blocked_by=[3, 7]),
  )
  assert_eq(contract.constraints, ["blocked by: #3", "blocked by: #7"])
}

///|
test "task_contract - title with surrounding whitespace is trimmed into goal" {
  let contract = task_contract_from_chainlink_issue(
    make_issue(title="  My Task  "),
  )
  assert_eq(contract.goal, "My Task")
}

///|
test "task_contract - scope acceptance_checks non_goals verify is empty" {
  let contract = task_contract_from_chainlink_issue(make_issue())
  assert_eq(contract.scope, [])
  assert_eq(contract.acceptance_checks, [])
  assert_eq(contract.non_goals, [])
  assert_eq(contract.verify, [])
}

// ──────────────────────────────────────────────────────────────────
// merge_chainlink_into_task_contract tests
// ──────────────────────────────────────────────────────────────────

///|
test "merge_chainlink - empty goal uses issue title, non-empty goal kept" {
  let issue = make_issue(title="Issue Title")
  let contract_empty = @types.TaskContract::{
    goal: "",
    scope: [],
    acceptance_checks: [],
    constraints: [],
    non_goals: [],
    review_context: None,
    verify: [],
  }
  let merged_empty = merge_chainlink_into_task_contract(issue, contract_empty)
  assert_eq(merged_empty.goal, "Issue Title")

  let contract_kept = @types.TaskContract::{
    ..contract_empty,
    goal: "Kept Goal",
  }
  let merged_kept = merge_chainlink_into_task_contract(issue, contract_kept)
  assert_eq(merged_kept.goal, "Kept Goal")
}

///|
test "merge_chainlink - review_context from description only" {
  let issue = make_issue(description=Some("Issue Desc"))
  let contract = @types.TaskContract::empty()
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(merged.review_context, Some("Issue Desc"))
}

///|
test "merge_chainlink - plan comments only with correct headers and ids" {
  let issue = make_issue(comments=[
    { id: 10, content: "Plan 10", kind: "plan" },
    { id: 20, content: "Plan 20", kind: "plan" },
  ])
  let contract = @types.TaskContract::empty()
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(
    merged.review_context,
    Some("[plan #10]\nPlan 10\n\n[plan #20]\nPlan 20"),
  )
}

///|
test "merge_chainlink - mixed plan+decision sorted by id ascending" {
  let issue = make_issue(comments=[
    { id: 15, content: "Decision 15", kind: "decision" },
    { id: 5, content: "Plan 5", kind: "plan" },
  ])
  let contract = @types.TaskContract::empty()
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(
    merged.review_context,
    Some("[plan #5]\nPlan 5\n\n[decision #15]\nDecision 15"),
  )
}

///|
test "merge_chainlink - only last 5 non-empty comments by highest id" {
  let issue = make_issue(comments=[
    { id: 1, content: "P1", kind: "plan" },
    { id: 2, content: "P2", kind: "plan" },
    { id: 3, content: "  ", kind: "plan" }, // empty after trim
    { id: 4, content: "P4", kind: "plan" },
    { id: 5, content: "P5", kind: "plan" },
    { id: 6, content: "P6", kind: "plan" },
    { id: 7, content: "P7", kind: "plan" },
  ])
  // Filter to non-empty trimmed comments, keep the 5 highest IDs, then output them sorted ascending: [2, 4, 5, 6, 7].
  let contract = @types.TaskContract::empty()
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(
    merged.review_context,
    Some(
      "[plan #2]\nP2\n\n[plan #4]\nP4\n\n[plan #5]\nP5\n\n[plan #6]\nP6\n\n[plan #7]\nP7",
    ),
  )
}

///|
test "merge_chainlink - description prepended to comments" {
  let issue = make_issue(description=Some("Desc"), comments=[
    { id: 1, content: "P1", kind: "plan" },
  ])
  let contract = @types.TaskContract::empty()
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(merged.review_context, Some("Desc\n\n[plan #1]\nP1"))
}

///|
test "merge_chainlink - contract review_context + chainlink content" {
  let issue = make_issue(description=Some("Desc"))
  let contract = @types.TaskContract::{
    ..@types.TaskContract::empty(),
    review_context: Some("Original"),
  }
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(
    merged.review_context,
    Some("Original\n\n--- chainlink plan history ---\n\nDesc"),
  )
}

///|
test "merge_chainlink - contract review_context + empty chainlink unchanged" {
  let issue = make_issue()
  let contract = @types.TaskContract::{
    ..@types.TaskContract::empty(),
    review_context: Some("Original"),
  }
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(merged.review_context, Some("Original"))
}

///|
test "merge_chainlink - constraints merged with dedup preserving order" {
  let issue = make_issue(blocked_by=[10, 20])
  let contract = @types.TaskContract::{
    ..@types.TaskContract::empty(),
    constraints: ["existing", "blocked by: #10"],
  }
  let merged = merge_chainlink_into_task_contract(issue, contract)
  // existing, blocked by: #10, (blocked by: #20)
  assert_eq(merged.constraints, [
    "existing", "blocked by: #10", "blocked by: #20",
  ])
}

///|
test "merge_chainlink - arrays unchanged" {
  let issue = make_issue()
  let contract = @types.TaskContract::{
    ..@types.TaskContract::empty(),
    scope: ["S"],
    acceptance_checks: ["A"],
    non_goals: ["N"],
    verify: ["V"],
  }
  let merged = merge_chainlink_into_task_contract(issue, contract)
  assert_eq(merged.scope, ["S"])
  assert_eq(merged.acceptance_checks, ["A"])
  assert_eq(merged.non_goals, ["N"])
  assert_eq(merged.verify, ["V"])
}
