///|
test "config defaults to the local project layout" {
  let config = parse_config("").unwrap()
  assert_eq(config.project_dir, ".")
  assert_eq(config.listen_uds, ".choir/run/server.sock")
  assert_eq(config.pull_request_delivery, {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  })
}

///|
test "checked-in delivery policy enables typed automatic merging" {
  let config = parse_config(
    "[delivery]\npull_requests = \"auto_merge\"\nmerge_method = \"rebase\"\n",
  ).unwrap()
  assert_eq(config.pull_request_delivery, {
    mode: @types.PullRequestDeliveryMode::PullRequestAutoMerge,
    merge_method: @types.PullRequestMergeMethod::PullRequestRebaseMerge,
  })
  assert_true(parse_config("[delivery]\npull_requests = \"guess\"\n") is Err(_))
  assert_true(parse_config("[delivery]\nmerge_method = \"guess\"\n") is Err(_))
}

///|
test "provider capacity defaults to a bound above per-Goal parallelism" {
  let config = parse_config("").unwrap()
  assert_eq(config.provider_capacity, {
    claude_subscription_cli: 4,
    codex_subscription_cli: 4,
    global_execution_ceiling: None,
  })
}

///|
test "Goal executor capacity is a typed positive host bound" {
  let defaults = parse_config("").unwrap()
  assert_eq(defaults.goal_executor_capacity, { maximum_parallel_jobs: 4 })
  let configured = parse_config("[capacity]\ngoals = \"7\"\n").unwrap()
  assert_eq(configured.goal_executor_capacity.maximum_parallel_jobs, 7)
  assert_true(parse_config("[capacity]\ngoals = \"0\"\n") is Err(_))
  assert_true(parse_config("[capacity]\ngoals = \"1025\"\n") is Err(_))
  assert_true(parse_config("[capacity]\ngoals = \"many\"\n") is Err(_))
}

///|
test "WorkOrder executor capacity is a separate typed host bound" {
  let defaults = parse_config("").unwrap()
  assert_eq(defaults.work_order_executor_capacity, { maximum_parallel_jobs: 4 })
  let configured = parse_config("[capacity]\nwork_orders = \"7\"\n").unwrap()
  assert_eq(configured.work_order_executor_capacity.maximum_parallel_jobs, 7)
  assert_true(parse_config("[capacity]\nwork_orders = \"0\"\n") is Err(_))
  assert_true(parse_config("[capacity]\nwork_orders = \"1025\"\n") is Err(_))
  assert_true(parse_config("[capacity]\nwork_orders = \"many\"\n") is Err(_))
}

///|
/// A bound nobody meant is worse than no configuration at all: zero stops the
/// daemon dispatching anything and a negative one would admit everything.
test "provider capacity is read as typed positive bounds" {
  let config = parse_config(
    "[capacity]\nclaude = \"2\"\ncodex = \"3\"\nglobal = \"4\"\n",
  ).unwrap()
  assert_eq(config.provider_capacity, {
    claude_subscription_cli: 2,
    codex_subscription_cli: 3,
    global_execution_ceiling: Some(4),
  })
  assert_true(parse_config("[capacity]\nclaude = \"0\"\n") is Err(_))
  assert_true(parse_config("[capacity]\ncodex = \"-1\"\n") is Err(_))
  assert_true(parse_config("[capacity]\nglobal = \"0\"\n") is Err(_))
  assert_true(parse_config("[capacity]\nclaude = \"many\"\n") is Err(_))
  // The per-Goal ceiling is a different knob and is not read from here.
  assert_true(
    parse_config("[capacity]\nmaximum_parallel_parts = \"9\"\n").unwrap().provider_capacity ==
    @types.Config::default().provider_capacity,
  )
}

///|
test "machine-local capacity overrides the checked-in capacity" {
  let config = parse_config(
    "[capacity]\nclaude = \"2\"\ncodex = \"2\"\ngoals = \"3\"\nwork_orders = \"2\"\n",
    local_content=Some(
      "[capacity]\nclaude = \"5\"\ngoals = \"6\"\nwork_orders = \"5\"\n",
    ),
  ).unwrap()
  assert_eq(config.provider_capacity.claude_subscription_cli, 5)
  assert_eq(config.provider_capacity.codex_subscription_cli, 2)
  assert_eq(config.goal_executor_capacity.maximum_parallel_jobs, 6)
  assert_eq(config.work_order_executor_capacity.maximum_parallel_jobs, 5)
}

///|
test "repository path settings are obsolete and ignored" {
  let config = parse_config(
    "project_dir = \"/checked-in\"\nlisten_uds = \"/checked-in.sock\"\n",
    local_content=Some(
      "project_dir = \"/local repo\"\nlisten_uds = \"/local.sock\"\n",
    ),
  ).unwrap()
  assert_eq(config.project_dir, ".")
  assert_eq(config.listen_uds, ".choir/run/server.sock")
}

///|
test "TOML reader preserves quoted values and ignores comments" {
  let doc = parse_toml_doc(
    "project_dir = \"/repo #1\" # comment\nlisten_uds = '/tmp/choir.sock'\n",
  )
  @debug.assert_eq(doc.get_optional_nonempty("project_dir"), Some("/repo #1"))
  @debug.assert_eq(
    doc.get_optional_nonempty("listen_uds"),
    Some("/tmp/choir.sock"),
  )
}
