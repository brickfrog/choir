///|
fn effort_test_config(
  default? : String? = None,
  dev? : String? = None,
  worker? : String? = None,
  tl? : String? = None,
) -> @types.AgentEffortConfig {
  { default, dev, worker, tl }
}

///|
fn effort_test_config_with_effort(
  agent_type : @types.AgentType,
  effort : @types.AgentEffortConfig,
) -> @types.Config {
  let efforts : Map[String, @types.AgentEffortConfig] = {}
  efforts.set(agent_type.to_wire_string(), effort)
  { ..@types.Config::default(), effort: efforts }
}

///|
fn effort_test_spawn_spec(agent_type : @types.AgentType) -> @types.SpawnSpec {
  @types.SpawnSpec::{
    slug: "test-slug",
    role: @types.Role::Worker,
    agent_type,
    task: "audit work",
    task_contract: None,
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    wave_id: None,
  }
}

///|
fn effort_test_launch_body(cmd : @workspace.Command) -> String raise {
  assert_eq(cmd.program, "setsid")
  assert_eq(cmd.args[0], "bash")
  assert_eq(cmd.args[1], "-c")
  cmd.args[2]
}

///|
test "resolve_agent_effort follows override role default none cascade" {
  let cfg = effort_test_config_with_effort(
    @types.AgentType::Codex,
    effort_test_config(default=Some("medium"), worker=Some("high")),
  )
  @debug.assert_eq(
    @workspace.resolve_agent_effort(
      cfg,
      @types.AgentType::Codex,
      @types.Role::Worker,
      Some("low"),
    ),
    Some("low"),
  )
  @debug.assert_eq(
    @workspace.resolve_agent_effort(
      cfg,
      @types.AgentType::Codex,
      @types.Role::Worker,
      None,
    ),
    Some("high"),
  )
  @debug.assert_eq(
    @workspace.resolve_agent_effort(
      cfg,
      @types.AgentType::Codex,
      @types.Role::Dev,
      None,
    ),
    Some("medium"),
  )
  @debug.assert_eq(
    @workspace.resolve_agent_effort(
      @types.Config::default(),
      @types.AgentType::Codex,
      @types.Role::Worker,
      None,
    ),
    None,
  )
}

///|
test "agent_launch_command emits codex effort flag and keeps model flag" {
  let cmd = @workspace.agent_launch_command(
    effort_test_spawn_spec(@types.AgentType::Codex),
    "/path",
    model=Some("codex-audit"),
    effort=Some("high"),
  )
  let body = effort_test_launch_body(cmd)
  assert_true(body.contains("--model"))
  assert_true(body.contains("codex-audit"))
  assert_true(body.contains("-c"))
  assert_true(body.contains("model_reasoning_effort=high"))
}

///|
test "agent_launch_command omits effort flag when unset or non-codex" {
  let codex = @workspace.agent_launch_command(
    effort_test_spawn_spec(@types.AgentType::Codex),
    "/path",
  )
  assert_false(
    effort_test_launch_body(codex).contains("model_reasoning_effort="),
  )

  let claude = @workspace.agent_launch_command(
    effort_test_spawn_spec(@types.AgentType::Claude),
    "/path",
    effort=Some("high"),
  )
  assert_false(
    effort_test_launch_body(claude).contains("model_reasoning_effort=high"),
  )
}
