///|
test "parse_open_prs extracts branch base and url" {
  let prs = parse_open_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/12\",\"createdAt\":\"2026-03-20T01:02:03Z\"},{\"number\":13,\"headRefName\":\"main.subtl.leaf-b\",\"baseRefName\":\"main.subtl\",\"url\":\"https://example.test/pr/13\",\"createdAt\":\"2026-03-21T00:00:00Z\"}]",
  )
  assert_eq(prs.length(), 2)
  assert_eq(prs[0].pr_number, 12)
  assert_eq(prs[0].branch, "main.leaf-a")
  assert_eq(prs[0].base, "main")
  assert_eq(prs[0].url, "https://example.test/pr/12")
  assert_eq(prs[0].created_sec, Some(1773968523L))
  assert_eq(prs[1].pr_number, 13)
  assert_eq(prs[1].branch, "main.subtl.leaf-b")
  assert_eq(prs[1].base, "main.subtl")
  assert_eq(prs[1].url, "https://example.test/pr/13")
  assert_eq(prs[1].created_sec, Some(1774051200L))
}

///|
test "parse_zellij_live_targets collects live tab and pane names" {
  let live = parse_zellij_live_targets(
    (
      #|[
      #|  {"id":7,"tab_id":1,"tab_name":"leaf-a","title":"zellij:tab-bar","is_plugin":true,"exited":false},
      #|  {"id":8,"tab_id":1,"tab_name":"leaf-a","title":"gemini --prompt-interactive","is_plugin":false,"exited":false},
      #|  {"id":9,"tab_id":2,"tab_name":"worker-a","title":"worker-a","is_plugin":false,"exited":true}
      #|]
    ),
  )
  assert_eq(live.tabs, ["leaf-a"])
  assert_eq(live.panes, ["gemini --prompt-interactive"])
}

///|
test "parse_open_prs ignores malformed entries" {
  let prs = parse_open_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\"},{\"number\":\"oops\",\"headRefName\":\"main.leaf-b\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/13\"}]",
  )
  assert_eq(prs.length(), 0)
}

///|
test "parse_github_time_utc_sec handles valid and invalid timestamps" {
  assert_eq(
    parse_github_time_utc_sec("2026-03-20T01:02:03Z"),
    Some(1773968523L),
  )
  assert_eq(
    parse_github_time_utc_sec("2026-03-20T01:02:03.456Z"),
    Some(1773968523L),
  )
  assert_eq(parse_github_time_utc_sec("2026-02-30T01:02:03Z"), None)
  assert_eq(parse_github_time_utc_sec("2026-03-20 01:02:03Z"), None)
}
