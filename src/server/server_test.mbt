///|
test "notify_parent uses live registry parent when present" {
  let project_dir = "/tmp/choir-notify-parent-test-" +
    "live-present-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config)

  let parent_id = "main.parent"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => fail("expected parseable local target")
  }

  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: parent_id,
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )

  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )

  let message = "hello parent"
  let res = state.notify_parent(caller_id, message, "success")
  match res {
    Ok(@message.DeliveryMethod::LocalTerminalInput(target, text)) => {
      assert_eq(target, live_target)
      assert_eq(text, "[from: " + caller_id + "] " + message)
    }
    Ok(other) => fail("unexpected delivery method: " + other.to_string())
    Err(e) => fail("expected Ok delivery, got: " + e.to_string())
  }
}

///|
test "notify_parent falls back to persisted lifecycle when parent missing from registry" {
  let project_dir = "/tmp/choir-notify-parent-test-" +
    "fallback-lifecycle-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config)

  let parent_id = "main.parent"
  // Persisted lifecycle exists on disk, but the parent agent is intentionally not inserted into the live registry.
  assert_true(
    @phase.write_lifecycle(
      project_dir,
      @phase.lifecycle_for_role(parent_id, @types.Role::Dev),
    ),
  )

  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )

  let message = "hello parent"
  let res = state.notify_parent(caller_id, message, "success")
  match res {
    Ok(@message.DeliveryMethod::LocalTerminalInput(target, text)) => {
      let expected_target = match
        @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":parent") {
        Some(t) => t
        None => fail("expected parseable local target")
      }
      assert_eq(target, expected_target)
      assert_eq(text, "[from: " + caller_id + "] " + message)
    }
    Ok(other) => fail("unexpected delivery method: " + other.to_string())
    Err(e) => fail("expected Ok delivery, got: " + e.to_string())
  }
}

///|
test "notify_parent returns clear error when parent cannot be resolved" {
  let project_dir = "/tmp/choir-notify-parent-test-" +
    "cannot-resolve-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config)

  let parent_id = "main.parent"
  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )

  // Ensure we are truly in the "cannot be resolved" case:
  // there should be no persisted lifecycle for the parent.
  assert_true(@phase.read_lifecycle(project_dir, parent_id) == None)

  let message = "hello parent"
  let res = state.notify_parent(caller_id, message, "success")
  match res {
    Err(@types.ExoError::AgentNotFound(id)) => assert_eq(id, parent_id)
    Ok(_) => fail("expected Err AgentNotFound, got Ok")
    Err(e) => fail("expected Err AgentNotFound, got: " + e.to_string())
  }
}

///|
test "transfer_leaf_ownership moves PR tracking and marks old leaf rescued" {
  let project_dir = "/tmp/choir-rescue-test-ok-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "s",
  }
  let state = ServerState::new(config)
  let tl = "main.tl"
  ignore(
    state.register_agent({
      agent_id: tl,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: tl,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let from_id = "main.leaf-v1"
  let to_id = "main.leaf-v2"
  let shared_branch = "main.shared-leaf"
  ignore(
    state.register_agent({
      agent_id: from_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(tl),
      workspace: project_dir + "/w1",
      branch: shared_branch,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: to_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(tl),
      workspace: project_dir + "/w2",
      branch: shared_branch,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  state.poller.track(
    99, from_id, shared_branch, "main", "https://example.test/pr/99", 0L,
  )
  ignore(
    @phase.write_lifecycle(project_dir, {
      agent_id: from_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=99,
          state=@phase.ReviewOwnership::OpenUnreviewed(
            url="https://example.test/pr/99",
          ),
        ),
      ),
    }),
  )
  match state.transfer_leaf_ownership(from_id, to_id) {
    Ok(n) => assert_eq(n, 1)
    Err(e) => fail("expected Ok transfer: " + e.to_string())
  }
  match state.poller.get(99) {
    Some(tr) => {
      assert_eq(tr.agent_id, to_id)
      assert_eq(tr.branch, shared_branch)
    }
    None => fail("expected tracked PR")
  }
  match @phase.read_lifecycle(project_dir, from_id) {
    Some(lc) =>
      match lc.process {
        @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::ReplacedByRescue
        ) => ()
        _ => fail("expected finalized replaced-by-rescue process")
      }
    None => fail("expected old leaf lifecycle")
  }
  match @phase.read_lifecycle(project_dir, to_id) {
    Some(lc) =>
      match lc.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(pr_number=p, ..)
        ) => if p != 99 { fail("replacement should carry PR workflow") }
        _ => fail("expected ReviewOwned on replacement")
      }
    None => fail("expected replacement lifecycle")
  }
}

///|
test "transfer_leaf_ownership refuses branch mismatch when PRs are tracked" {
  let project_dir = "/tmp/choir-rescue-test-refuse-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "s",
  }
  let state = ServerState::new(config)
  let tl = "main.tl"
  ignore(
    state.register_agent({
      agent_id: tl,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: tl,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let from_id = "main.leaf-old"
  let to_id = "main.leaf-new"
  ignore(
    state.register_agent({
      agent_id: from_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(tl),
      workspace: project_dir + "/a",
      branch: "main.branch-a",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: to_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(tl),
      workspace: project_dir + "/b",
      branch: "main.branch-b",
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  state.poller.track(7, from_id, "main.branch-a", "main", "", 0L)
  match state.transfer_leaf_ownership(from_id, to_id) {
    Err(@types.ExoError::ValidationError(msg)) =>
      assert_true(msg.contains("branch"))
    Ok(_) => fail("expected validation error")
    Err(e) => fail("unexpected err: " + e.to_string())
  }
}
