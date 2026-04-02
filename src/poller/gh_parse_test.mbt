///|
test "parse_gh_pr_view_output maps valid gh json to review SHA and CI" {
  let json =
    #|{"reviews":[{"state":"APPROVED","body":"ship it"}],
    #|"headRefOid":"abc123def",
    #|"statusCheckRollup":[{"conclusion":"SUCCESS"}],
    #|"state":"OPEN"}
  let (ok, review, sha, ci_rollup, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Approved)
  assert_eq(sha, "abc123def")
  assert_eq(ci_rollup, Success)
  assert_eq(bodies, "ship it")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output empty reviews yields None_" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (ok, review, sha, ci_rollup, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, None_)
  assert_eq(sha, "")
  assert_eq(ci_rollup, Unknown)
  assert_eq(bodies, "")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output last decisive review state wins" {
  let json =
    #|{"reviews":[
    #|  {"state":"CHANGES_REQUESTED","body":"fix"},
    #|  {"state":"APPROVED","body":"ok"}
    #|],
    #|"headRefOid":"x",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (ok, review, _sha, _ci, _bodies, _open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Approved)
}

///|
test "parse_gh_pr_view_output detects CI failure from rollup" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[{"conclusion":"FAILURE"}],
    #|"state":"OPEN"}
  let (ok, _rev, _sha, ci_rollup, _bodies, _open) = parse_gh_pr_view_output(
    json,
  )
  assert_true(ok)
  assert_eq(ci_rollup, Failure)
}

///|
test "parse_gh_pr_view_output invalid json returns parse failure sentinel" {
  let (ok, review, sha, ci_rollup, bodies, open) = parse_gh_pr_view_output(
    "not-json",
  )
  assert_false(ok)
  assert_eq(review, None_)
  assert_eq(sha, "")
  assert_eq(ci_rollup, Unknown)
  assert_eq(bodies, "")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output filters pull request overview review noise" {
  let json =
    #|{"reviews":[
    #|  {"state":"COMMENTED","body":"Please change the heading."},
    #|  {"state":"COMMENTED","body":"Pull request overview\n\nAdds a smoke test file."}
    #|],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (ok, review, _sha, _ci, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Commented)
  assert_eq(bodies, "Please change the heading.")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output filters Copilot markdown pull request overview" {
  let json =
    #|{"reviews":[{"state":"COMMENTED","body":"## Pull request overview\n\nThis PR improves things.\n\n### Reviewed changes\n\n| File | Description |\n| ---- | ----------- |\n| a.mbt | b |"}],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (ok, review, _sha, _ci, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Commented)
  assert_eq(bodies, "")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output dedupes repeated review bodies" {
  let json =
    #|{"reviews":[
    #|  {"state":"COMMENTED","body":"Please change the heading."},
    #|  {"state":"COMMENTED","body":"Please change the heading."}
    #|],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (ok, review, _sha, _ci, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Commented)
  assert_eq(bodies, "Please change the heading.")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output filters pull request overview inline noise with path prefix" {
  let json =
    #|{"reviews":[{"state":"COMMENTED","body":"Looks good overall."}],
    #|"inline_comments":[
    #|  {"path":"src/foo.mbt","body":"Pull request overview\n\nAdds a smoke test file."},
    #|  {"path":"src/bar.mbt","body":"Please tighten this branch condition."}
    #|],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (ok, review, _sha, _ci, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Commented)
  assert_eq(
    bodies, "Looks good overall.\n---\n[src/bar.mbt] Please tighten this branch condition.",
  )
  assert_true(open)
}

///|
test "parse_gh_pr_view_output rollup InProgress when check is still running" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[{"state":"IN_PROGRESS","conclusion":""}],
    #|"state":"OPEN"}
  let (ok, _r, _sha, ci_rollup, _b, _o) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(ci_rollup, InProgress)
}

///|
test "parse_gh_pr_view_output rollup InProgress when one check still pending" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[
    #|  {"conclusion":"SUCCESS"},
    #|  {"state":"PENDING","conclusion":""}
    #|],
    #|"state":"OPEN"}
  let (ok, _r, _sha, ci_rollup, _b, _o) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(ci_rollup, InProgress)
}

///|
test "parse_issue_comment_logins_for_copilot_present detects github-copilot without bot suffix" {
  assert_true(
    parse_issue_comment_logins_for_copilot_present("[\"github-copilot\"]"),
  )
}

///|
test "parse_issue_comment_logins_for_copilot_present detects github-copilot bot" {
  assert_true(
    parse_issue_comment_logins_for_copilot_present("[\"github-copilot[bot]\"]"),
  )
}

///|
test "parse_issue_comment_logins_for_copilot_present detects copilot-pull-request-reviewer" {
  assert_true(
    parse_issue_comment_logins_for_copilot_present(
      "[\"copilot-pull-request-reviewer\"]",
    ),
  )
}

///|
test "parse_issue_comment_logins_for_copilot_present detects copilot-pull-request-reviewer bot suffix" {
  assert_true(
    parse_issue_comment_logins_for_copilot_present(
      "[\"copilot-pull-request-reviewer[bot]\"]",
    ),
  )
}

///|
test "parse_issue_comment_logins_for_copilot_present detects copilot-swe-agent without bot suffix" {
  assert_true(
    parse_issue_comment_logins_for_copilot_present("[\"copilot-swe-agent\"]"),
  )
}

///|
test "parse_issue_comment_logins_for_copilot_present detects copilot-swe-agent bot suffix" {
  assert_true(
    parse_issue_comment_logins_for_copilot_present(
      "[\"copilot-swe-agent[bot]\"]",
    ),
  )
}

///|
test "parse_issue_comment_logins_for_copilot_present false for human login" {
  assert_false(parse_issue_comment_logins_for_copilot_present("[\"octocat\"]"))
}

///|
test "parse_issue_comment_logins_for_copilot_present false for empty input" {
  assert_false(parse_issue_comment_logins_for_copilot_present(""))
}
