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
  let res = try? state.notify_parent(caller_id, message, @types.Status::Success)
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
  let res = try? state.notify_parent(caller_id, message, @types.Status::Success)
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
  let res = try? state.notify_parent(caller_id, message, @types.Status::Success)
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
    match d.delivery {
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
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/adversary-approved-88",
      "true",
    ),
  )
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
    agent_type: @types.AgentType::Claude,
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
      "force": "true",
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

///|
async test "replay_pending_outbox_with replays pending message and marks it delivered" {
  let project_dir = "/tmp/choir-outbox-replay-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let recipient = @types.Agent::{
    agent_id: "main.parent",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: @types.LocalTarget::parse(
      "zellij-tab:" + terminal_session + ":parent",
    ),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(state.register_agent(recipient))
  let delivery = @message.plan_delivery(
    recipient,
    "main.leaf",
    "hello parent",
    @types.Status::Success,
  )
  let pending = @outbox.OutboxMessage::new(
    "msg-replay-1",
    "main.leaf",
    "main.parent",
    "hello parent",
    @types.Status::Success,
    delivery,
    100L,
    200L,
  )
  assert_true(
    @outbox.append_outbox_snapshot(@sys.append_file_sync, project_dir, pending),
  )
  let mut runner_calls = 0
  state.replay_pending_outbox_with(150L, runner=async fn(
    cmds : Array[@workspace.Command],
  ) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  })
  assert_eq(runner_calls, 1)
  let messages = @outbox.load_recipient_outbox(
    @sys.read_file, project_dir, "main.parent",
  )
  assert_eq(messages.length(), 1)
  let message = messages[0]
  assert_eq(message.delivery_state, @outbox.OutboxDeliveryState::Delivered)
  assert_eq(message.delivery_attempts, 1)
  assert_eq(message.last_attempt_at, Some(150L))
  assert_eq(message.last_error, None)
}

///|
async test "replay_pending_outbox_with replays pending root delivery before root re-registers" {
  let project_dir = "/tmp/choir-outbox-replay-root-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":TL") {
    Some(t) => t
    None => fail("expected parseable local target")
  }
  let pending = @outbox.OutboxMessage::new(
    "msg-root-replay-1",
    "main.leaf",
    "root",
    "agent killed by parent",
    @types.Status::Failure,
    @message.DeliveryMethod::LocalTerminalInput(
      target, "[from: main.leaf] agent killed by parent",
    ),
    100L,
    200L,
  )
  assert_true(
    @outbox.append_outbox_snapshot(@sys.append_file_sync, project_dir, pending),
  )
  let mut runner_calls = 0
  state.replay_pending_outbox_with(150L, runner=async fn(
    cmds : Array[@workspace.Command],
  ) {
    @async.sleep(0)
    runner_calls = runner_calls + cmds.length()
    let statuses = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  })
  assert_eq(runner_calls, 1)
  let messages = @outbox.load_recipient_outbox(
    @sys.read_file, project_dir, "root",
  )
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].delivery_state, @outbox.OutboxDeliveryState::Delivered)
  assert_eq(messages[0].delivery_attempts, 1)
  assert_eq(messages[0].last_attempt_at, Some(150L))
  assert_eq(messages[0].last_error, None)
}

///|
test "sweep_outbox marks expired pending messages and compacts recipient file" {
  let project_dir = "/tmp/choir-outbox-sweep-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())
  let recipient = @types.Agent::{
    agent_id: "main.parent",
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: @types.LocalTarget::parse(
      "zellij-tab:" + terminal_session + ":parent",
    ),
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Active,
  }
  ignore(state.register_agent(recipient))
  let delivery = @message.plan_delivery(
    recipient,
    "main.leaf",
    "stale note",
    @types.Status::Info,
  )
  let pending = @outbox.OutboxMessage::new(
    "msg-expire-1",
    "main.leaf",
    "main.parent",
    "stale note",
    @types.Status::Info,
    delivery,
    10L,
    20L,
  )
  let failed = pending.record_failed_attempt(15L, "temporary")
  assert_true(
    @outbox.append_outbox_snapshot(@sys.append_file_sync, project_dir, pending),
  )
  assert_true(
    @outbox.append_outbox_snapshot(@sys.append_file_sync, project_dir, failed),
  )
  state.sweep_outbox(25L)
  let messages = @outbox.load_recipient_outbox(
    @sys.read_file, project_dir, "main.parent",
  )
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].delivery_state, @outbox.OutboxDeliveryState::Expired)
  assert_eq(messages[0].delivery_attempts, 1)
  let content = @sys.read_file(
    @outbox.recipient_outbox_path(project_dir, "main.parent"),
  )
  let mut nonempty_lines = 0
  for line in content.split("\n") {
    if line.to_string().trim().to_string() != "" {
      nonempty_lines = nonempty_lines + 1
    }
  }
  assert_eq(nonempty_lines, 1)
}

///|
async test "process_poller_tick_with finalizes externally merged leaf and notifies parent" {
  let project_dir = "/tmp/choir-poller-merged-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main.tl"
  let parent_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":TL") {
    Some(target) => target
    None => fail("expected parseable parent target")
  }
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some(parent_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let leaf_id = "main.leaf"
  let leaf_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":leaf") {
    Some(target) => target
    None => fail("expected parseable leaf target")
  }
  ignore(
    state.register_agent({
      agent_id: leaf_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: "feat/merged",
      terminal_target: Some(leaf_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  @phase.apply_dev_event(
    project_dir,
    leaf_id,
    @phase.DevEvent::PRCreated(
      pr_number=21,
      url="https://gh.test/21",
      branch="feat/merged",
    ),
  )
  @phase.apply_dev_event(
    project_dir,
    leaf_id,
    @phase.DevEvent::ReviewApprovedEv(pr_number=21),
  )

  state.poller.track(
    21, leaf_id, "feat/merged", "main", "https://gh.test/21", 0L,
  )
  match state.poller.get(21) {
    Some(tracked) =>
      state.poller.restore({
        ..tracked,
        last_review_state: @poller.ReviewState::Approved,
        last_ci_rollup: @poller.CiRollupStatus::Success,
        last_sha: "sha-merged",
      })
    None => fail("expected tracked PR before poll tick")
  }

  let mut sent_parent_merge = false
  let mut closed_leaf = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    let statuses = []
    for cmd in cmds {
      if cmd.program == "choir" && cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("external merge observed") &&
          text.contains("main.leaf") {
          sent_parent_merge = true
        }
      }
      if cmd.program == "choir" &&
        cmd.args.contains("close") &&
        cmd.args.contains("zellij-tab:" + terminal_session + ":leaf") {
        closed_leaf = true
      }
      statuses.push(0)
    }
    statuses
  }

  state.process_poller_tick_with(
    1000L,
    300L,
    async fn(_pr_number, _skip_issue_comment_fetch) {
      @async.sleep(0)
      (
        true,
        @poller.ReviewState::Approved,
        "sha-merged",
        @poller.CiRollupStatus::Success,
        "",
        false,
        false,
      )
    },
    runner~,
  )

  assert_true(sent_parent_merge)
  assert_true(closed_leaf)
  assert_eq(state.poller.get(21), None)
  match @phase.read_lifecycle(project_dir, leaf_id) {
    Some(lifecycle) => {
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
      match lifecycle.workflow {
        @phase.WorkflowState::Dev(
          @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged)
        ) => ()
        _ => fail("expected dev lifecycle done with merged reason")
      }
    }
    None => fail("expected merged lifecycle on disk")
  }
  let outbox = @outbox.load_recipient_outbox(
    @sys.read_file, project_dir, parent_id,
  )
  assert_eq(outbox.length(), 1)
  assert_eq(outbox[0].delivery_state, @outbox.OutboxDeliveryState::Delivered)
  assert_true(outbox[0].body.contains("external merge observed"))
}

///|
async test "recover_state finalizes merged agent without startup parent notification" {
  let project_dir = "/tmp/choir-recovery-merged-no-notify-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))
  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "root"
  let leaf_id = "main.leaf"
  let parent : @types.Agent = {
    agent_id: @types.AgentId(parent_id),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Codex,
    parent: None,
    workspace: project_dir,
    branch: "main",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Done,
  }
  let leaf : @types.Agent = {
    agent_id: @types.AgentId(leaf_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    parent: Some(parent_id),
    workspace: project_dir,
    branch: "feat/merged",
    terminal_target: None,
    host: @types.Host::Local,
    spawn_depth: 0,
    state: @types.AgentState::Done,
  }
  assert_true(
    @phase.write_lifecycle(project_dir, {
      ..@phase.lifecycle_for_role(leaf_id, @types.Role::Dev),
      workflow: @phase.WorkflowState::Dev(
        @phase.DevLifecycle::ReviewOwned(
          pr_number=21,
          state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
        ),
      ),
    }),
  )

  let input : @runtime.RecoveryReconcileInput = {
    panes: { live: { tabs: [], panes: [] } },
    prs: {
      open_prs: [],
      polls: Map::new(),
      resolved_prs: [
        @runtime.KnownPR::{
          pr_number: 21,
          branch: "feat/merged",
          base: "main",
          url: "https://gh.test/21",
          created_sec: Some(100L),
          state: @runtime.KnownPRState::Merged,
        },
      ],
    },
    files: {
      local_agents: [
        { slug: "root", dir_name: "agents", agent: Some(parent) },
        { slug: "leaf", dir_name: "worktrees", agent: Some(leaf) },
      ],
      persisted_tracked_prs: [
        @poller.TrackedPR::{
          pr_number: 21,
          agent_id: leaf_id,
          branch: "feat/merged",
          parent_branch: "main",
          pr_url: "https://gh.test/21",
          first_seen: 50L,
          consecutive_failures: 0,
          backoff_until: 0L,
          last_review_state: @poller.ReviewState::Approved,
          last_review_bodies: "",
          last_sha: "sha-merged",
          notified_parent: true,
          last_ci_rollup: @poller.CiRollupStatus::Success,
          last_timeout_at: 0L,
          copilot_issue_comment_seen: true,
          orphan_notified: false,
          orphan_reconciling: false,
          changes_requested_since: 0L,
          stall_notified: false,
        },
      ],
    },
    recovered_at: 200L,
    prebuilt_agent_phase: None,
  }

  recover_state(state, terminal_session, input)

  let outbox = @outbox.load_recipient_outbox(
    @sys.read_file, project_dir, parent_id,
  )
  assert_eq(outbox.length(), 0)
  match @phase.read_lifecycle(project_dir, leaf_id) {
    Some(lifecycle) =>
      assert_eq(
        lifecycle.process,
        @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged),
      )
    None => fail("expected recovered merged lifecycle on disk")
  }
}
