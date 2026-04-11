///|
async fn mock_capture_threads_failed(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (1, "gh error")
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  (0, "")
}

///|
async fn mock_capture_threads_one(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"T1\",\"isResolved\":false,\"path\":\"f.mbt\",\"comments\":{\"nodes\":[{\"body\":\"fix\"}]}}]}}}}}",
    )
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  (0, "")
}

///|
async fn mock_capture_threads_none(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  (0, "")
}

///|
async test "dispatch NotifyParent blocks on unresolved threads" {
  let project_dir = "/tmp/choir-test-notify-gate-" + @sys.get_pid().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))

  let agent_id = "leaf-1"
  let pr_number = 123
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.Connected,
    workflow: @phase.Dev(
      @phase.ReviewOwned(pr_number~, state=@phase.OpenUnreviewed(url="")),
    ),
  }

  ignore(@phase.write_lifecycle(project_dir, lifecycle))

  let reg = @registry.AgentRegistry::new()
  let parent : @types.Agent = {
    agent_id: @types.AgentId::to_string(@types.AgentId("parent")),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let child : @types.Agent = {
    agent_id: @types.AgentId::to_string(@types.AgentId(agent_id)),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("parent"),
    workspace: project_dir,
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  reg.insert(child)
  reg.insert(parent)

  let req = ToolRequest::NotifyParent({
    caller_id: agent_id,
    message: "done",
    status: @types.Status::Success,
  })

  // Case 1: One unresolved thread
  let resp1 = dispatch(
    req,
    project_dir~,
    registry=Some(reg),
    capture=mock_capture_threads_one,
  )
  match resp1 {
    Err(msg) => {
      assert_true(msg.contains("notify_parent blocked"))
      assert_true(msg.contains("1 unresolved review thread"))
    }
    Ok(_) => fail("expected block on unresolved threads")
  }

  // Case 2: Zero unresolved threads
  let resp2 = dispatch(
    req,
    project_dir~,
    registry=Some(reg),
    capture=mock_capture_threads_none,
  )
  assert_true(resp2.is_ok())

  // Case 3: gh failure (should block due to GAP 2 change)
  let resp3 = dispatch(
    req,
    project_dir~,
    registry=Some(reg),
    capture=mock_capture_threads_failed,
  )
  match resp3 {
    Err(msg) => {
      assert_true(msg.contains("notify_parent blocked"))
      assert_true(msg.contains("1 unresolved review thread"))
    }
    Ok(_) => fail("expected block on gh failure")
  }

  ignore(@sys.system("rm -rf " + project_dir))
}
