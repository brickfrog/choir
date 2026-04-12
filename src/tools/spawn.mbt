///|
/// Pure plan for `spawn_worker` after default-branch resolution: spawn spec,
/// canonical id, terminal target, registry upsert row, and success response.
pub(all) struct SpawnWorkerPlan {
  spec : @types.SpawnSpec
  agent_id : String
  terminal_target : @types.LocalTarget
  registry_agent : @types.Agent
  ok_response : @types.Response
}

///|
pub impl Show for SpawnWorkerPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub fn spawn_worker_ok_response(agent_id : String) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(agent_id),
    "agent_ids": String::to_json(agent_id),
  })
}

///|
/// Build [`SpawnWorkerPlan`] from tool args and resolved parent branch (from
/// [`detect_default_branch_with_capture`] or an injected value in tests).
pub fn spawn_worker_plan(
  worker_args : WorkerSpawnArgs,
  resolved_parent_branch : String,
  session : String,
  project_dir : String,
) -> SpawnWorkerPlan {
  let spec = @types.SpawnSpec::{
    slug: worker_args.slug,
    role: @types.Role::Worker,
    agent_type: worker_args.agent_type,
    task: worker_args.task,
    task_contract: Some(worker_args.task_contract),
    isolation: @types.IsolationMode::Inline,
    parent_id: worker_args.caller_id,
    parent_branch: resolved_parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: None,
  }
  let agent_id = @workspace.canonical_agent_id(spec)
  let terminal_target = @workspace.local_target_for(
    session,
    spec.slug,
    spec.isolation,
  )
  let registry_agent = @types.Agent::{
    agent_id,
    role: @types.Role::Worker,
    agent_type: worker_args.agent_type,
    state: @types.AgentState::Active,
    parent: Some(worker_args.caller_id),
    terminal_target: Some(terminal_target),
    host: @types.Host::Local,
    workspace: project_dir,
    branch: agent_id,
    spawn_depth: 0,
  }
  {
    spec,
    agent_id,
    terminal_target,
    registry_agent,
    ok_response: spawn_worker_ok_response(agent_id),
  }
}

///|
/// `spawn_worker` host path: resolve default branch, build plan, spawn
/// commands, registry upsert, success response. Preserves historical
/// `ToolRequest::SpawnWorker` control flow while keeping `dispatch` as a thin caller.
pub async fn interpret_spawn_worker(
  worker_args : WorkerSpawnArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let resolved_parent_branch = detect_default_branch_with_capture(
    project_dir, capture,
  )
  let plan = spawn_worker_plan(
    worker_args, resolved_parent_branch, session, project_dir,
  )
  let cmds = @workspace.spawn_commands(
    plan.spec,
    project_dir,
    session,
    parent_session_id=None,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  match run_strict(runner, cmds, capture~) {
    Ok(_) => {
      match registry {
        Some(reg) => ignore(reg.upsert(plan.registry_agent))
        None => ()
      }
      plan.ok_response
    }
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure plan for `spawn_remote`: fixed Dev/Claude worktree spec and success JSON
/// (agent id, slug, ssh host). The interpreter runs `remote_spawn_commands` then
/// `run_strict`.
pub(all) struct SpawnRemotePlan {
  spec : @types.SpawnSpec
  ok_response : @types.Response
}

///|
pub impl Show for SpawnRemotePlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub fn spawn_remote_plan(args : RemoteSpawnArgs) -> SpawnRemotePlan {
  let spec = @types.SpawnSpec::{
    slug: args.slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: args.task,
    task_contract: Some(args.task_contract),
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: args.parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: None,
  }
  let ok_response = @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(
      @workspace.branch_name(args.parent_branch, args.slug),
    ),
    "slug": String::to_json(args.slug),
    "host": String::to_json(args.ssh_target),
  })
  { spec, ok_response }
}

///|
/// Remote spawn path: plan, `remote_spawn_commands`, `run_strict`. Preserves
/// `ToolRequest::SpawnRemote` control flow while keeping `dispatch` thin.
pub async fn interpret_spawn_remote(
  spawn_args : RemoteSpawnArgs,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  extra_mcp_servers_json? : String? = None,
) -> @types.Response {
  let plan = spawn_remote_plan(spawn_args)
  let cmds = @workspace.remote_spawn_commands(
    plan.spec,
    spawn_args.ssh_target,
    spawn_args.repo_url,
    spawn_args.tcp_addr,
    parent_session_id=spawn_args.parent_session_id,
    extra_mcp_servers_json~,
  )
  match run_strict(runner, cmds, capture~) {
    Ok(_) => plan.ok_response
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure plan for `spawn_gemini`: fixed Dev/Gemini worktree spec and success JSON
/// (`status`, `agent_id`, `slug`). The interpreter runs `spawn_commands` then
/// `run_strict`.
pub(all) struct SpawnGeminiPlan {
  spec : @types.SpawnSpec
  ok_response : @types.Response
}

///|
pub impl Show for SpawnGeminiPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub fn spawn_gemini_plan(args : SpawnGeminiArgs) -> SpawnGeminiPlan {
  let spec = @types.SpawnSpec::{
    slug: args.slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: args.task,
    task_contract: Some(args.task_contract),
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: args.parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    chainlink_issue_id: None,
  }
  let ok_response = @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(
      @workspace.branch_name(args.parent_branch, args.slug),
    ),
    "slug": String::to_json(args.slug),
  })
  { spec, ok_response }
}

///|
/// Local Gemini leaf spawn: plan, `spawn_commands`, `run_strict`. Preserves
/// `ToolRequest::SpawnGemini` control flow while keeping `dispatch` thin.
pub async fn interpret_spawn_gemini(
  spawn_args : SpawnGeminiArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let plan = spawn_gemini_plan(spawn_args)
  let cmds = @workspace.spawn_commands(
    plan.spec,
    project_dir,
    session,
    parent_session_id=spawn_args.parent_session_id,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  match run_strict(runner, cmds, capture~) {
    Ok(_) => plan.ok_response
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure validation plus reuse [`SpawnSpec`] for `rescue_leaf` after the salvaged
