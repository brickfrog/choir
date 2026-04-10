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
