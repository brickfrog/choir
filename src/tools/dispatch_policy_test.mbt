///|
fn dispatch_policy_live_lifecycle() -> @phase.AgentLifecycle {
  {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Supervising(
        children=[
          {
            child_id: "main.leaf-0",
            slug: "leaf-0",
            branch: "main.leaf-0",
            agent_type: @types.AgentType::Codex,
            summary: @phase.ChildLifecycleSummary::Working,
          },
        ],
        wave=5,
      ),
    ),
    last_updated_unix_sec: 0L,
  }
}

///|
fn dispatch_policy_idle_lifecycle() -> @phase.AgentLifecycle {
  {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
    last_updated_unix_sec: 0L,
  }
}

///|
async fn dispatch_policy_git_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
    return (0, "main\n")
  }
  if cmd.program == "git" &&
    cmd.args == ["status", "--porcelain", "--untracked-files=all"] {
    return (0, " M src/tools/dispatch.mbt\n")
  }
  if cmd.program == "git" && cmd.args.length() >= 4 && cmd.args[0] == "ls-files" {
    return (0, "")
  }
  (0, "")
}

///|
async fn dispatch_policy_task_get_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "bd" && cmd.args == ["show", "safe-task", "--json"] {
    return (
      0, "{\"id\":\"safe-task\",\"title\":\"Safe Task\",\"status\":\"open\",\"assignee\":\"\",\"notes\":\"\"}",
    )
  }
  dispatch_policy_git_capture(cmd)
}

///|
fn dispatch_policy_live_reader(
  _project_dir : String,
  _caller_id : String,
) -> @phase.AgentLifecycle? {
  Some(dispatch_policy_live_lifecycle())
}

///|
fn dispatch_policy_idle_reader(
  _project_dir : String,
  _caller_id : String,
) -> @phase.AgentLifecycle? {
  Some(dispatch_policy_idle_lifecycle())
}

///|
async test "dispatch_call refuses parent branch write during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
    parent_branch_override_check=fn(_project_dir, _caller_id) { false },
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=git_commit"))
      assert_true(msg.contains("choir tl-parent-override on"))
    }
    @types.Response::Ok(_) => fail("expected policy refusal")
  }
}

///|
async test "dispatch_call lets override reach normal tool handling" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
    parent_branch_override_check=fn(_project_dir, _caller_id) { true },
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("unknown tool") || msg.contains("tool not found"),
      )
      assert_false(msg.contains("policy refused"))
    }
    @types.Response::Ok(_) => fail("test harness should not have a bash tool")
  }
}

///|
async test "dispatch_call lets no live wave reach normal tool handling" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_idle_reader,
    parent_branch_override_check=fn(_project_dir, _caller_id) { false },
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("unknown tool") || msg.contains("tool not found"),
      )
      assert_false(msg.contains("policy refused"))
    }
    @types.Response::Ok(_) => fail("test harness should not have a bash tool")
  }
}

///|
async test "dispatch_call log only mode does not refuse parent branch write" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    policy_enforcement_mode=@policy.PolicyEnforcementMode::LogOnly,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
    parent_branch_override_check=fn(_project_dir, _caller_id) { false },
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("unknown tool") || msg.contains("tool not found"),
      )
      assert_false(msg.contains("policy refused"))
    }
    @types.Response::Ok(_) => fail("test harness should not have a bash tool")
  }
}

///|
async test "dispatch_call passes through non parent branch writes" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "task_get",
      args: { "id": "safe-task", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    bd_capture=dispatch_policy_task_get_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
    parent_branch_override_check=fn(_project_dir, _caller_id) { false },
  )
  match resp {
    @types.Response::Ok(fields) =>
      match fields.get_json("task") {
        Some(Object(task)) =>
          @debug.assert_eq(
            @types.json_field_string(task, "id"),
            Some("safe-task"),
          )
        _ => fail("expected task payload")
      }
    @types.Response::Err(msg) =>
      fail("expected task_get to pass through: " + msg)
  }
}
