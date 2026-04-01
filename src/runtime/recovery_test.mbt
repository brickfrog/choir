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
async test "find_agent_for_pr_in_lifecycle finds agent ID by PR number" {
  let mock_provider : RecoveryProvider = {
    zellij_live: async fn(_dir, _session) {
      @async.sleep(0)
      { tabs: [], panes: [] }
    },
    open_prs: async fn(_dir) {
      @async.sleep(0)
      []
    },
    find_prs_by_head: async fn(_dir, _branch) {
      @async.sleep(0)
      []
    },
    list_local_agents: async fn(_dir, _dir_name) {
      @async.sleep(0)
      []
    },
    read_local_config: async fn(_dir, _dir_name, _slug) {
      @async.sleep(0)
      ""
    },
    list_lifecycle_files: async fn(_dir) {
      @async.sleep(0)
      ["file1", "file2"]
    },
    read_lifecycle_file: async fn(path) {
      @async.sleep(0)
      if path == "file1" {
        "{\"agent_id\":\"agent1\",\"pr_number\":123}"
      } else {
        "{\"agent_id\":\"agent2\",\"pr_number\":456}"
      }
    },
  }
  let agent_id = find_agent_for_pr_in_lifecycle(mock_provider, "/tmp", 123)
  assert_eq(agent_id, Some("agent1"))
  let agent_id_none = find_agent_for_pr_in_lifecycle(mock_provider, "/tmp", 999)
  assert_eq(agent_id_none, None)
}

///|
async test "find_pr_for_branch_in_provider finds PR by head branch" {
  let mock_provider : RecoveryProvider = {
    zellij_live: async fn(_dir, _session) {
      @async.sleep(0)
      { tabs: [], panes: [] }
    },
    open_prs: async fn(_dir) {
      @async.sleep(0)
      []
    },
    find_prs_by_head: async fn(_dir, branch) {
      @async.sleep(0)
      if branch == "feat/x" {
        [
          {
            pr_number: 123,
            branch: "feat/x",
            base: "main",
            url: "https://gh.test/123",
            created_sec: Some(1000L),
          },
        ]
      } else {
        []
      }
    },
    list_local_agents: async fn(_dir, _dir_name) {
      @async.sleep(0)
      []
    },
    read_local_config: async fn(_dir, _dir_name, _slug) {
      @async.sleep(0)
      ""
    },
    list_lifecycle_files: async fn(_dir) {
      @async.sleep(0)
      []
    },
    read_lifecycle_file: async fn(_path) {
      @async.sleep(0)
      ""
    },
  }
  let res = find_pr_for_branch_in_provider(mock_provider, "/tmp", "feat/x")
  assert_eq(res, Some((123, "https://gh.test/123")))
  let res_none = find_pr_for_branch_in_provider(mock_provider, "/tmp", "feat/y")
  assert_eq(res_none, None)
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
