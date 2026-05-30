///|
test "gh pr view json field lists include mergeability fields" {
  assert_true(gh_pr_view_json_fields.contains("mergeable"))
  assert_true(gh_pr_view_json_fields.contains("mergeStateStatus"))
  assert_true(gh_pr_view_json_fields.contains("mergedAt"))
  assert_true(gh_pr_view_fallback_json_fields.contains("mergeable"))
  assert_true(gh_pr_view_fallback_json_fields.contains("mergeStateStatus"))
  assert_true(gh_pr_view_fallback_json_fields.contains("mergedAt"))
}

///|
test "parse_mergeable covers GitHub variants and unknown fallback" {
  assert_eq(parse_mergeable("MERGEABLE"), Mergeable::Mergeable)
  assert_eq(parse_mergeable("CONFLICTING"), Mergeable::Conflicting)
  assert_eq(parse_mergeable("UNKNOWN"), Mergeable::Unknown)
  assert_eq(parse_mergeable("future-value"), Mergeable::Unknown)
}

///|
test "parse_merge_state_status covers GitHub variants and unknown fallback" {
  assert_eq(parse_merge_state_status("CLEAN"), MergeStateStatus::Clean)
  assert_eq(parse_merge_state_status("UNSTABLE"), MergeStateStatus::Unstable)
  assert_eq(parse_merge_state_status("BLOCKED"), MergeStateStatus::Blocked)
  assert_eq(parse_merge_state_status("HAS_HOOKS"), MergeStateStatus::HasHooks)
  assert_eq(parse_merge_state_status("BEHIND"), MergeStateStatus::Behind)
  assert_eq(parse_merge_state_status("UNKNOWN"), MergeStateStatus::Unknown)
  assert_eq(parse_merge_state_status("DIRTY"), MergeStateStatus::Dirty)
  assert_eq(parse_merge_state_status("future-value"), MergeStateStatus::Unknown)
}

///|
test "merged_at_from_iso reuses shared ISO timestamp parser" {
  @debug.assert_eq(
    merged_at_from_iso("2026-05-18T00:27:59Z"),
    Some(1779064079L),
  )
  @debug.assert_eq(merged_at_from_iso("not-a-timestamp"), None)
  @debug.assert_eq(merged_at_from_iso("2026-05-18T00:27:59+02:00"), None)
}

///|
test "parse_gh_pr_view_output maps valid gh json to review SHA and CI" {
  let json =
    #|{"reviews":[{"state":"APPROVED","body":"ship it"}],
    #|"headRefOid":"abc123def",
    #|"statusCheckRollup":[{"conclusion":"SUCCESS"}],
    #|"state":"OPEN",
    #|"mergeable":"MERGEABLE",
    #|"mergeStateStatus":"CLEAN",
    #|"mergedAt":"2026-05-18T00:27:59Z"}
  let (
    ok,
    review,
    sha,
    ci_rollup,
    bodies,
    open,
    mergeable,
    merge_state_status,
    merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Approved)
  assert_eq(sha, "abc123def")
  assert_eq(ci_rollup, Success)
  assert_eq(bodies, "ship it")
  assert_true(open)
  assert_eq(mergeable, Mergeable::Mergeable)
  assert_eq(merge_state_status, MergeStateStatus::Clean)
  @debug.assert_eq(merged_at_unix, Some(1779064079L))
}

///|
test "parse_gh_pr_view_output maps invalid mergedAt to unknown timestamp" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"abc123def",
    #|"statusCheckRollup":[],
    #|"state":"OPEN",
    #|"mergeable":"UNKNOWN",
    #|"mergeStateStatus":"UNKNOWN",
    #|"mergedAt":"not-a-timestamp"}
  let (
    ok,
    _review,
    _sha,
    _ci_rollup,
    _bodies,
    _open,
    _mergeable,
    _merge_state_status,
    merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  @debug.assert_eq(merged_at_unix, None)
}

///|
test "parse_gh_pr_view_output keeps closed unmerged distinct from merged" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"abc123def",
    #|"statusCheckRollup":[],
    #|"state":"CLOSED",
    #|"mergeable":"UNKNOWN",
    #|"mergeStateStatus":"UNKNOWN",
    #|"mergedAt":null}
  let (
    ok,
    _review,
    _sha,
    _ci_rollup,
    _bodies,
    open,
    _mergeable,
    _merge_state_status,
    merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_false(open)
  @debug.assert_eq(merged_at_unix, None)
}

///|
test "parse_gh_pr_view_output empty reviews yields None_" {
  let json =
    #|{"reviews":[],
    #|"headRefOid":"",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (
    ok,
    review,
    sha,
    ci_rollup,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, None_)
  assert_eq(sha, "")
  assert_eq(ci_rollup, NoChecks)
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
  let (
    ok,
    review,
    _sha,
    _ci,
    _bodies,
    _open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
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
  let (
    ok,
    _rev,
    _sha,
    ci_rollup,
    _bodies,
    _open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(ci_rollup, Failure)
}

///|
test "parse_gh_pr_view_output invalid json returns parse failure sentinel" {
  let (
    ok,
    review,
    sha,
    ci_rollup,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output("not-json")
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
  let (
    ok,
    review,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
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
  let (
    ok,
    review,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
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
  let (
    ok,
    review,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
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
  let (
    ok,
    review,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Commented)
  assert_eq(
    bodies, "Looks good overall.\n---\n[src/bar.mbt] Please tighten this branch condition.",
  )
  assert_true(open)
}

///|
test "parse_gh_pr_view_output does not filter bracketed review mentioning overview mid-sentence" {
  let json =
    #|{"reviews":[{"state":"COMMENTED","body":"[CRITICAL] The ## pull request overview section is missing auth headers."}],
    #|"inline_comments":[],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (
    ok,
    review,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(review, Commented)
  assert_eq(
    bodies, "[CRITICAL] The ## pull request overview section is missing auth headers.",
  )
  assert_true(open)
}

///|
test "parse_gh_pr_view_output inline comment with line number gets path:line prefix" {
  let json =
    #|{"reviews":[],
    #|"inline_comments":[{"path":"src/a.mbt","body":"Add error handling here.","line":10}],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (
    ok,
    _r,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(bodies, "[src/a.mbt:10] Add error handling here.")
  assert_true(open)
}

///|
test "parse_gh_pr_view_output same body on different lines both appear in output" {
  let json =
    #|{"reviews":[],
    #|"inline_comments":[
    #|  {"path":"src/a.mbt","body":"Add error handling here.","line":10},
    #|  {"path":"src/a.mbt","body":"Add error handling here.","line":42}
    #|],
    #|"headRefOid":"sha",
    #|"statusCheckRollup":[],
    #|"state":"OPEN"}
  let (
    ok,
    _r,
    _sha,
    _ci,
    bodies,
    open,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
  assert_true(ok)
  assert_eq(
    bodies, "[src/a.mbt:10] Add error handling here.\n---\n[src/a.mbt:42] Add error handling here.",
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
  let (
    ok,
    _r,
    _sha,
    ci_rollup,
    _b,
    _o,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
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
  let (
    ok,
    _r,
    _sha,
    ci_rollup,
    _b,
    _o,
    _mergeable,
    _merge_state_status,
    _merged_at_unix,
  ) = parse_gh_pr_view_output(json)
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

///|
test "parse_copilot_in_reviews detects copilot-pull-request-reviewer in reviews" {
  let json =
    #|{"reviews":[{"state":"COMMENTED","author":{"login":"copilot-pull-request-reviewer"},"body":"overview"}]}
  assert_true(parse_copilot_in_reviews(json))
}

///|
test "parse_copilot_in_reviews false when only human reviewers" {
  let json =
    #|{"reviews":[{"state":"APPROVED","author":{"login":"octocat"},"body":"lgtm"}]}
  assert_false(parse_copilot_in_reviews(json))
}

///|
test "parse_copilot_in_reviews false on empty reviews array" {
  let json =
    #|{"reviews":[]}
  assert_false(parse_copilot_in_reviews(json))
}

///|
test "parse_copilot_in_reviews false on malformed json" {
  assert_false(parse_copilot_in_reviews("not json"))
}
