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
