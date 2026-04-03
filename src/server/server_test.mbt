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
  let state = ServerState::new(config, make_recovery_provider())

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
      spawn_depth: 0,
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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let message = "hello parent"
  let res = try? state.notify_parent(caller_id, message, "success")
  match res {
    Ok(@message.DeliveryMethod::LocalTerminalInput(target, text)) => {
      assert_eq(target, live_target)
      assert_eq(text, "[from: " + caller_id + "] " + message)
    }
    Ok(other) => fail("unexpected delivery method: " + other.to_string())
    Err(e) => fail("expected Ok delivery, got: " + e.message())
  }
}

///|
test "init_run_id reuses existing run_id file" {
  let project_dir = "/tmp/choir-run-id-test-existing-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let run_id_path = project_dir + "/.choir/run_id"
  assert_true(@sys.write_file_sync(run_id_path, "stable-run-id\n"))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "s",
  }
  let state = ServerState::new(config, make_recovery_provider())
  assert_eq(state.run_id, "stable-run-id")
}

///|
test "init_run_id persists generated run_id via native write" {
  let project_dir = "/tmp/choir-run-id-test-fresh-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir))
  let config = {
    ..@types.Config::default(),
    project_dir,
    terminal_session: "s",
  }
  let state = ServerState::new(config, make_recovery_provider())
  let on_disk = @sys.read_file(project_dir + "/.choir/run_id")
  assert_eq(state.run_id, on_disk)
  assert_true(state.run_id.length() > 0)
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
  let state = ServerState::new(config, make_recovery_provider())

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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let message = "hello parent"
  let res = try? state.notify_parent(caller_id, message, "success")
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
    Err(e) => fail("expected Ok delivery, got: " + e.message())
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
  let state = ServerState::new(config, make_recovery_provider())

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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  // Ensure we are truly in the "cannot be resolved" case:
  // there should be no persisted lifecycle for the parent.
  assert_true(@phase.read_lifecycle(project_dir, parent_id) == None)

  let message = "hello parent"
  let res = try? state.notify_parent(caller_id, message, "success")
  match res {
    Ok(_) => fail("expected Err AgentNotFound, got Ok")
    Err(e) => assert_eq(e.message(), "agent not found: " + parent_id)
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
  let state = ServerState::new(config, make_recovery_provider())
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
      spawn_depth: 0,
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
      spawn_depth: 0,
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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let now = @poller.now_sec()
  state.poller.track(
    55, old_id, shared_branch, "main", "https://github.com/o/r/pull/55", now,
  )
  try state.transfer_leaf_ownership(old_id, new_id) catch {
    e => fail("transfer failed: " + @types.choir_error_message_from_caught(e))
  } noraise {
    n => assert_eq(n, 1)
  }
  match state.poller.get(55) {
    Some(pr) => {
      assert_eq(pr.agent_id, new_id)
      assert_eq(pr.branch, shared_branch)
    }
    None => fail("PR 55 should remain tracked after rescue")
  }
  let replacement = try state.registry.get(new_id) catch {
    e =>
      fail(
        "replacement not registered: " +
        @types.choir_error_message_from_caught(e),
      )
  } noraise {
    a => a
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
    None,
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
async test "merge_pr after restart finalizes offline recovered owner and updates parent summary" {
  let project_dir = "/tmp/choir-merge-restart-offline-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let parent_id = "main.tl"
  let child_id = "main.claude-leaf"
  let pr_number = 88
  let parent_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":TL") {
    Some(t) => t
    None => fail("expected parseable parent target")
  }
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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let parent_child : @phase.ChildLifecycle = {
    child_id,
    slug: @phase.extract_slug(child_id),
    branch: child_id,
    agent_type: "claude",
    summary: @phase.ChildLifecycleSummary::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: parent_id,
      role: @types.Role::TL,
      process: @phase.ProcessState::Connected,
      workflow: @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Supervising(children=[parent_child], wave=1),
      ),
    }),
  )
  assert_true(
    @phase.write_lifecycle(project_dir, {
      agent_id: child_id,
      role: @types.Role::Dev,
      process: @phase.ProcessState::Finalized(
        reason=@phase.FinalizeReason::RecoveredDone,
      ),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number~,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )
  ignore(
    state.register_agent({
      agent_id: child_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/claude-leaf",
      branch: child_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Done,
    }),
  )
  state.poller.track_recovered(
    pr_number,
    child_id,
    child_id,
    "main",
    "https://example.test/pr/88",
    100L,
    @poller.ReviewState::Approved,
    "",
    "deadbeef",
    @poller.CiRollupStatus::Unknown,
    false,
  )
  let req = @types.Request::{
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "merge_pr",
    args: @types.RequestArgs::new({
      "pr_number": pr_number.to_string(),
      "caller_id": parent_id,
      "parent_branch": "main",
    }),
  }
  let resp = state.handle_with_runner(req, runner=async fn(
    cmds : Array[@workspace.Command],
  ) {
    @async.sleep(0)
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  })
  assert_true(resp.is_ok())
  assert_eq(resp.ok_field("status"), Some("merged"))
  assert_true(state.poller.get(pr_number) == None)
  match @phase.read_lifecycle(project_dir, child_id) {
    Some(lifecycle) => {
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(reason~)) =>
          assert_eq(reason, @phase.FinalizeReason::Merged)
        other =>
          fail(
            "expected merged child lifecycle to be done, got: " +
            other.to_string(),
          )
      }
    }
    None => fail("expected merged child lifecycle")
  }
  match @phase.read_lifecycle(project_dir, parent_id) {
    Some(lifecycle) =>
      match lifecycle.workflow {
        @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, ..)
        )
        | @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::WaveComplete(children~, ..)
        ) => {
          assert_eq(children.length(), 1)
          match children[0].summary {
            @phase.ChildLifecycleSummary::Done => ()
            other =>
              fail(
                "expected parent summary to mark merged child done, got: " +
                other.to_string(),
              )
          }
        }
        other =>
          fail(
            "expected supervising or wave-complete parent lifecycle after merge, got: " +
            other.to_string(),
          )
      }
    None => fail("expected parent lifecycle after merge")
  }
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
  let state = ServerState::new(config, make_recovery_provider())
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
      spawn_depth: 0,
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
      spawn_depth: 0,
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
      spawn_depth: 0,
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
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  try state.transfer_leaf_ownership(old_leaf, new_leaf) catch {
    e =>
      assert_true(
        @types.choir_error_message_from_caught(e).contains("different parents"),
      )
  } noraise {
    _ => fail("expected validation error for mismatched parents")
  }
}
