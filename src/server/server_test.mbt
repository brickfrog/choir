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
test "manual rescue transfers PR ownership and supervisor summary to replacement leaf" {
  let project_dir = "/tmp/choir-rescue-happy-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config)
  let parent_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":tl") {
    Some(t) => t
    None => fail("expected parseable local target")
  }
  let parent_id = "main.tl"
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: parent_id,
      terminal_target: Some(parent_target),
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let shared_branch = "main.topic-leaf"
  let reuse_workspace = project_dir + "/.choir/worktrees/topic-leaf"
  let old_id = "main.topic-v0"
  let new_id = "main.topic-v1"
  let old_lc : @phase.AgentLifecycle = {
    agent_id: old_id,
    role: @types.Role::Dev,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ReviewOwned(
        pr_number=55,
        state=@phase.ReviewOwnership::OpenUnreviewed(
          url="https://github.com/o/r/pull/55",
        ),
      ),
    ),
  }
  assert_true(@phase.write_lifecycle(project_dir, old_lc))
  ignore(
    state.register_agent({
      agent_id: old_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/legacy",
      branch: shared_branch,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: new_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: reuse_workspace,
      branch: shared_branch,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let now = @poller.now_sec()
  state.poller.track(
    55, old_id, shared_branch, "main", "https://github.com/o/r/pull/55", now,
  )
  match state.transfer_leaf_ownership(old_id, new_id) {
    Ok(n) => assert_eq(n, 1)
    Err(e) => fail("transfer failed: " + e.message())
  }
  match state.poller.get(55) {
    Some(pr) => {
      assert_eq(pr.agent_id, new_id)
      assert_eq(pr.branch, shared_branch)
    }
    None => fail("PR 55 should remain tracked after rescue")
  }
  let replacement = match state.registry.get(new_id) {
    Ok(a) => a
    Err(e) => fail("replacement not registered: " + e.message())
  }
  assert_eq(replacement.branch, shared_branch)
  assert_true(replacement.workspace.contains(".choir/worktrees/"))
  match @phase.read_lifecycle(project_dir, new_id) {
    Some(lc) =>
      match lc.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::ReviewOwned(pr_number~, ..)
        ) => assert_eq(pr_number, 55)
        _ => fail("replacement should inherit review-owned lifecycle")
      }
    None => fail("missing replacement lifecycle")
  }
  match @phase.read_lifecycle(project_dir, parent_id) {
    Some(plc) =>
      match plc.workflow {
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, ..)
        ) => {
          assert_eq(children.length(), 1)
          assert_eq(children[0].child_id, new_id)
          match children[0].summary {
            @phase.ChildLifecycleSummary::ReviewOwned(pr_number~, ..) =>
              assert_eq(pr_number, 55)
            other =>
              fail(
                "parent should see replacement review state, got: " +
                other.to_string(),
              )
          }
        }
        _ => fail("parent should be supervising a single rescued child")
      }
    None => fail("missing parent lifecycle")
  }
  let deliveries = state.plan_poll_event_deliveries(
    @poller.PollEvent::ReviewReceived(55, "need fix"),
    new_id,
  )
  let mut parent_review_mentions_replacement = false
  for d in deliveries {
    match d {
      @message.DeliveryMethod::LocalTerminalInput(_, text) =>
        if text.contains(new_id) && text.contains("[REVIEW]") {
          parent_review_mentions_replacement = true
        }
      _ => ()
    }
  }
  assert_true(parent_review_mentions_replacement)
}

///|
test "manual rescue refuses unsalvageable cross-parent ownership transfer" {
  let project_dir = "/tmp/choir-rescue-refuse-" +
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
  let tl_a = "main.tl-a"
  let tl_b = "main.tl-b"
  ignore(
    state.register_agent({
      agent_id: tl_a,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: tl_a,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: tl_b,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: tl_b,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  let old_leaf = "main.leaf-old"
  let new_leaf = "main.leaf-new"
  ignore(
    state.register_agent({
      agent_id: old_leaf,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(tl_a),
      workspace: project_dir,
      branch: old_leaf,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id: new_leaf,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(tl_b),
      workspace: project_dir,
      branch: new_leaf,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
    }),
  )
  match state.transfer_leaf_ownership(old_leaf, new_leaf) {
    Err(@types.ExoError::ValidationError(msg)) =>
      assert_true(msg.contains("different parents"))
    Ok(_) => fail("expected validation error for mismatched parents")
    Err(e) => fail("unexpected error: " + e.message())
  }
}
