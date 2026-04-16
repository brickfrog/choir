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
async fn mock_capture_repo_view_fails(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" &&
    cmd.args.length() >= 3 &&
    cmd.args[0] == "repo" &&
    cmd.args[1] == "view" {
    return (1, "")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
fn write_notify_gate_leaf_review_owned(
  project_dir : String,
  agent_id : String,
  pr_number : Int,
) -> Unit {
  let lifecycle : @phase.AgentLifecycle = {
    agent_id,
    role: @types.Role::Dev,
    process: @phase.Connected,
    workflow: @phase.Dev(
      @phase.ReviewOwned(pr_number~, state=@phase.OpenUnreviewed(url="")),
    ),
  }
  ignore(@phase.write_lifecycle(project_dir, lifecycle))
}

///|
async test "dispatch NotifyParent blocked attempts local zellij send with NOTIFY BLOCKED" {
  let project_dir = "/tmp/choir-test-notify-blocked-send-" +
    @sys.get_pid().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let marker = project_dir + "/.choir/notify_blocked_delivery.marker"
  ignore(@sys.delete_file_sync(marker))
  let marker_ref = @ref.new(marker)

  let agent_id = "leaf-nb"
  let pr_number = 77
  let reg = @registry.AgentRegistry::new()
  let parent : @types.Agent = {
    agent_id: @types.AgentId("parent-nb"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: @types.LocalTarget::parse("zellij-tab:choir:nptl"),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let child : @types.Agent = {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("parent-nb"),
    workspace: project_dir,
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  ignore(try? reg.insert(child))
  ignore(try? reg.insert(parent))

  write_notify_gate_leaf_review_owned(project_dir, agent_id, pr_number)
  let req = ToolRequest::NotifyParent({
    caller_id: agent_id,
    message: "done",
    status: @types.Status::Success,
  })
  async fn runner_record_notify_blocked_text(
    cmds : Array[@workspace.Command],
  ) -> Array[Int] {
    @async.sleep(0)
    let path = marker_ref.val
    if path != "" {
      for cmd in cmds {
        for arg in cmd.args {
          if arg.contains("[NOTIFY BLOCKED]") {
            ignore(@sys.write_file_sync(path, "yes"))
          }
        }
      }
    }
    [0]
  }
  let resp = dispatch(
    req,
    project_dir~,
    session="choir",
    registry=Some(reg),
    capture=mock_capture_threads_one,
    runner=runner_record_notify_blocked_text,
  )
  match resp {
    Err(msg) => assert_true(msg.contains("notify_parent blocked"))
    Ok(_) => fail("expected block")
  }
  assert_eq(@sys.read_file(marker).trim(), "yes")
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "dispatch NotifyParent blocks on unresolved threads" {
  let project_dir = "/tmp/choir-test-notify-gate-" + @sys.get_pid().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))

  let agent_id = "leaf-1"
  let pr_number = 123

  let reg = @registry.AgentRegistry::new()
  let parent : @types.Agent = {
    agent_id: @types.AgentId("parent"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Gemini,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: None,
    host: @types.Host::Remote("test"),
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
  let child : @types.Agent = {
    agent_id: @types.AgentId(agent_id),
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
  ignore(try? reg.insert(child))
  ignore(try? reg.insert(parent))

  let req = ToolRequest::NotifyParent({
    caller_id: agent_id,
    message: "done",
    status: @types.Status::Success,
  })

  // Case 1: One unresolved thread
  write_notify_gate_leaf_review_owned(project_dir, agent_id, pr_number)
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
  write_notify_gate_leaf_review_owned(project_dir, agent_id, pr_number)
  let resp2 = dispatch(
    req,
    project_dir~,
    registry=Some(reg),
    capture=mock_capture_threads_none,
  )
  assert_true(resp2.is_ok())

  // Case 3: gh GraphQL failure (fail-closed)
  write_notify_gate_leaf_review_owned(project_dir, agent_id, pr_number)
  let resp3 = dispatch(
    req,
    project_dir~,
    registry=Some(reg),
    capture=mock_capture_threads_failed,
  )
  match resp3 {
    Err(msg) => {
      assert_true(msg.contains("notify_parent blocked"))
      assert_true(msg.contains("gh unavailable"))
      assert_true(msg.contains("could not fetch review thread state"))
    }
    Ok(_) => fail("expected block on gh failure")
  }

  // Case 4: gh repo view unavailable (owner/repo resolution fails)
  write_notify_gate_leaf_review_owned(project_dir, agent_id, pr_number)
  let resp4 = dispatch(
    req,
    project_dir~,
    registry=Some(reg),
    capture=mock_capture_repo_view_fails,
  )
  match resp4 {
    Err(msg) => {
      assert_true(msg.contains("notify_parent blocked"))
      assert_true(msg.contains("gh unavailable"))
      assert_true(msg.contains("could not fetch review thread state"))
    }
    Ok(_) => fail("expected block when gh repo view unavailable")
  }

  ignore(@sys.rm_rf(project_dir))
}
