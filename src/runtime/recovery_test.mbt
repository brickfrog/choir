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
  @debug.assert_eq(prs[0].created_sec, Some(1773968523L))
  assert_eq(prs[1].pr_number, 13)
  assert_eq(prs[1].branch, "main.subtl.leaf-b")
  assert_eq(prs[1].base, "main.subtl")
  assert_eq(prs[1].url, "https://example.test/pr/13")
  @debug.assert_eq(prs[1].created_sec, Some(1774051200L))
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
test "parse_known_prs distinguishes merged and closed states" {
  let prs = parse_known_prs(
    "[{\"number\":12,\"headRefName\":\"main.leaf-a\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/12\",\"state\":\"CLOSED\",\"mergedAt\":\"2026-03-22T01:02:03Z\",\"createdAt\":\"2026-03-20T01:02:03Z\"},{\"number\":13,\"headRefName\":\"main.leaf-b\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/13\",\"state\":\"CLOSED\",\"mergedAt\":null,\"createdAt\":\"2026-03-21T00:00:00Z\"}]",
  )
  assert_eq(prs.length(), 2)
  assert_eq(prs[0].state, KnownPRState::Merged)
  assert_eq(prs[1].state, KnownPRState::Closed)
}

///|
/// Regression: the shell recovery provider used to `panic()` when
/// `gh pr list` returned malformed or truncated JSON. This broke the
/// boot-loop contract — the daemon whose entire job is tolerating
/// prior-run noise was the first thing to die on bad input. The
/// provider now logs to stderr and returns empty so the daemon can
/// rebuild state from the next tick. This test exercises both the
/// open_prs and find_prs_by_head closures via a capture stub that
/// produces invalid JSON.
async test "make_shell_recovery_provider open_prs falls back to empty on invalid JSON" {
  let bad_capture = async fn(_prog, _args, _cwd) {
    @async.sleep(0)
    "{not valid json"
  }
  let provider = make_shell_recovery_provider(bad_capture)
  let open_result = (provider.open_prs)("/tmp")
  assert_eq(open_result.length(), 0)
  let head_result = (provider.find_prs_by_head)("/tmp", "main.leaf")
  assert_eq(head_result.length(), 0)
  let head_any_result = (provider.find_prs_by_head_any)("/tmp", "main.leaf")
  assert_eq(head_any_result.length(), 0)
}

///|
async test "find_agent_for_pr_in_lifecycle finds agent ID by PR number" {
  let mock_provider : RecoveryProvider = {
    zellij_live: fn(_dir, _session) { { tabs: [], panes: [] } },
    open_prs: fn(_dir) { [] },
    find_prs_by_head: fn(_dir, _branch) { [] },
    find_prs_by_head_any: fn(_dir, _branch) { [] },
    find_pr_by_number: fn(_dir, _pr_number) { None },
    list_agent_containers: fn(_dir) { [] },
    list_agents_in_container: fn(_dir, _container) { [] },
    read_agent_config: fn(_dir, _container, _slug) { "" },
    get_agent_relative_workspace: fn(_container, _slug) { "" },
    list_lifecycle_ids: fn(_dir) { ["file1", "file2"] },
    read_lifecycle_content: fn(_dir, id) {
      if id == "file1" {
        "{\"agent_id\":\"agent1\",\"pr_number\":123}"
      } else {
        "{\"agent_id\":\"agent2\",\"pr_number\":456}"
      }
    },
    read_poller_state: fn(_dir) { [] },
    write_poller_state: fn(_dir, _tracked) { () },
    gh_poll_pr: fn(_num, _skip) {
      (
        true,
        @poller.ReviewState::Approved,
        "sha1",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
      )
    },
  }
  let agent_id = find_agent_for_pr_in_lifecycle(mock_provider, "/tmp", 123)
  @debug.assert_eq(agent_id, Some("agent1"))
  let agent_id_none = find_agent_for_pr_in_lifecycle(mock_provider, "/tmp", 999)
  @debug.assert_eq(agent_id_none, None)
}

///|
async test "find_pr_for_branch_in_provider finds PR by head branch" {
  let mock_provider : RecoveryProvider = {
    zellij_live: fn(_dir, _session) { { tabs: [], panes: [] } },
    open_prs: fn(_dir) { [] },
    find_prs_by_head: fn(_dir, branch) {
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
    find_prs_by_head_any: fn(_dir, _branch) { [] },
    find_pr_by_number: fn(_dir, _pr_number) { None },
    list_agent_containers: fn(_dir) { [] },
    list_agents_in_container: fn(_dir, _container) { [] },
    read_agent_config: fn(_dir, _container, _slug) { "" },
    get_agent_relative_workspace: fn(_container, _slug) { "" },
    list_lifecycle_ids: fn(_dir) { [] },
    read_lifecycle_content: fn(_dir, _id) { "" },
    read_poller_state: fn(_dir) { [] },
    write_poller_state: fn(_dir, _tracked) { () },
    gh_poll_pr: fn(_num, _skip) {
      (
        true,
        @poller.ReviewState::Approved,
        "sha1",
        @poller.CiRollupStatus::Success,
        "",
        true,
        false,
      )
    },
  }
  let res = find_pr_for_branch_in_provider(mock_provider, "/tmp", "feat/x")
  @debug.assert_eq(res, Some((123, "https://gh.test/123")))
  let res_none = find_pr_for_branch_in_provider(mock_provider, "/tmp", "feat/y")
  @debug.assert_eq(res_none, None)
}

///|
test "parse_github_time_utc_sec handles valid and invalid timestamps" {
  @debug.assert_eq(
    parse_github_time_utc_sec("2026-03-20T01:02:03Z"),
    Some(1773968523L),
  )
  @debug.assert_eq(
    parse_github_time_utc_sec("2026-03-20T01:02:03.456Z"),
    Some(1773968523L),
  )
  @debug.assert_eq(parse_github_time_utc_sec("2026-02-30T01:02:03Z"), None)
  @debug.assert_eq(parse_github_time_utc_sec("2026-03-20 01:02:03Z"), None)
}

///|
async test "shell recovery provider skips missing optional choir paths" {
  let project_dir = "/tmp/choir-recovery-missing-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir"))
  let provider = make_shell_recovery_provider((program, args, cwd) => {
    ignore(program)
    ignore(args)
    ignore(cwd)
    fail("capture should not run for missing optional paths")
    ""
  })
  assert_eq((provider.list_agents_in_container)(project_dir, "worktrees"), [])
  assert_eq((provider.read_agent_config)(project_dir, "agents", "root"), "")
  assert_eq((provider.list_lifecycle_ids)(project_dir), [])
  assert_eq((provider.read_lifecycle_content)(project_dir, "root"), "")
  assert_eq((provider.read_poller_state)(project_dir), [])
}
