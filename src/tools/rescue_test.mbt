///|
async test "rescue_leaf refuses non-Dev leaf" {
  let tmp = "/tmp/choir-rescue-refusal-worker"
  let reg = @registry.AgentRegistry::new()
  let tl = @types.Agent::{
    agent_id: @types.AgentId("main"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: tmp,
    branch: "main",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let worker = @types.Agent::{
    agent_id: @types.AgentId("main.w1"),
    role: @types.Role::Worker,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main"),
    workspace: tmp + "/.choir/worktrees/w1",
    branch: "main.w1",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  ignore(reg.upsert(tl))
  ignore(reg.upsert(worker))
  let a : Map[String, String] = {}
  a.set("agent_id", "main.w1")
  a.set("agent_type", "claude")
  a.set("caller_id", "main")
  let res = dispatch_call(
    ToolCall::{ role: @types.Role::TL, name: "rescue_leaf", args: a },
    project_dir=tmp,
    registry=Some(reg),
    runner=mock_registry_runner,
  )
  assert_true(not(res.is_ok()))
  match res.error_message() {
    Some(msg) => assert_true(msg.contains("nothing salvageable"))
    None => fail("expected error message")
  }
}

///|
async test "rescue_leaf happy path clears registry entry" {
  let tmp = "/tmp/choir-rescue-happy"
  let reg = @registry.AgentRegistry::new()
  let leaf_id = "main.leaf-r"
  let dev = @types.Agent::{
    agent_id: @types.AgentId(leaf_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    parent: Some("main"),
    workspace: tmp + "/.choir/worktrees/r",
    branch: leaf_id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  let tl = @types.Agent::{
    agent_id: @types.AgentId("main"),
    role: @types.Role::TL,
    agent_type: @types.AgentType::Claude,
    parent: None,
    workspace: tmp,
    branch: "main",
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
  }
  ignore(reg.upsert(tl))
  ignore(reg.upsert(dev))
  let a : Map[String, String] = {}
  a.set("agent_id", leaf_id)
  a.set("agent_type", "claude")
  a.set("caller_id", "main")
  a.set("task", "resume task")
  let res = dispatch_call(
    ToolCall::{ role: @types.Role::TL, name: "rescue_leaf", args: a },
    project_dir=tmp,
    registry=Some(reg),
    runner=mock_registry_runner,
    poller_state=Some(@poller.PollerState::new()),
  )
  assert_true(res.is_ok())
  assert_eq(res.ok_field("status"), Some("rescued"))
  assert_eq(res.ok_field("agent_id"), Some(leaf_id))
  assert_true(reg.get(leaf_id) is Err(_))
}

///|
test "tool registry lists rescue_leaf and handoff_leaf for TL" {
  let reg = @tools.ToolRegistry::new()
  assert_true(reg.lookup(@types.Role::TL, "rescue_leaf") is Ok(_))
  assert_true(reg.lookup(@types.Role::TL, "handoff_leaf") is Ok(_))
}
