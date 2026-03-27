///|
test "parse_gh_pr_view_output maps valid gh json to review SHA and CI" {
  let json =
    #|{"reviews":[{"state":"APPROVED","body":"ship it"}],
    #|"headRefOid":"abc123def",
    #|"statusCheckRollup":[{"conclusion":"SUCCESS"}],
    #|"state":"OPEN"}
  let (ok, review, sha, ci_failed, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Approved)
  assert_eq(sha, "abc123def")
  assert_false(ci_failed)
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
  let (ok, review, sha, ci_failed, bodies, open) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, None_)
  assert_eq(sha, "")
  assert_false(ci_failed)
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
  let (ok, _rev, _sha, ci_failed, _bodies, _open) = parse_gh_pr_view_output(
    json,
  )
  assert_true(ok)
  assert_true(ci_failed)
}

///|
test "parse_gh_pr_view_output invalid json returns parse failure sentinel" {
  let (ok, review, sha, ci_failed, bodies, open) = parse_gh_pr_view_output(
    "not-json",
  )
  assert_false(ok)
  assert_eq(review, None_)
  assert_eq(sha, "")
  assert_false(ci_failed)
  assert_eq(bodies, "")
  assert_true(open)
}
