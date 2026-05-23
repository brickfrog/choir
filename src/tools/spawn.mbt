///|
/// Reject spawn calls whose caller is in a terminal lifecycle state. A worker
/// or leaf spawned against a `Failed` / `Done` parent has no live terminal to
/// receive `notify_parent`; the worker runs to completion, calls
/// `notify_parent`, the server can't deliver, the message dies in the worker's
/// pane, and the orchestration layer never sees the result. Catch it at spawn
/// time so the caller fails loud instead of losing work silently.
///
/// Allowed states: `Spawning`, `Active`, `Completing`, `Suspended`. The synthesized
/// root TL agent (no on-disk lifecycle) is `Active` by construction so it passes.
/// `None` registry means tests / non-orchestration paths — passes.
pub fn ensure_caller_can_spawn(
  caller_id : String,
  registry : @registry.AgentRegistry?,
) -> Result[Unit, @types.ChoirError] {
  match registry {
    None => Ok(())
    Some(reg) =>
      try {
        let agent = reg.get(caller_id)
        match agent.state {
          @types.AgentState::Failed | @types.AgentState::Done =>
            Err(
              @types.ChoirError::validation_error(
                "cannot spawn: caller '" +
                caller_id +
                "' is in terminal state '" +
                agent.state.to_wire_string() +
                "'. The spawned child would have no live parent to deliver `notify_parent` results to. Re-establish the parent (e.g. by restarting the TL session and re-registering) or pick a live caller before spawning.",
              ),
            )
          _ => Ok(())
        }
      } catch {
        // Caller not in registry: synthesized root TL or unregistered fresh
        // session — both are legitimate spawn paths today; let them through.
        _ => Ok(())
      } noraise {
        result => result
      }
  }
}

///|
fn spawn_agent_state_is_terminal(state : @types.AgentState) -> Bool {
  state == @types.AgentState::Done || state == @types.AgentState::Failed
}

///|
fn ensure_no_live_spawn_agent_collision(
  tool_name : String,
  agent_id : String,
  registry : @registry.AgentRegistry?,
) -> Result[Unit, @types.ChoirError] {
  match registry {
    None => Ok(())
    Some(reg) =>
      match reg.get_opt(agent_id) {
        Some(existing) =>
          if spawn_agent_state_is_terminal(existing.state) {
            Ok(())
          } else {
            Err(
              @types.ChoirError::validation_error(
                "cannot spawn: " +
                tool_name +
                " canonical_agent_id '" +
                agent_id +
                "' collides with live registry agent in state '" +
                existing.state.to_wire_string() +
                "'. Pick a different slug or wait for the existing agent to reach done/failed before spawning.",
              ),
            )
          }
        None => Ok(())
      }
  }
}

///|
fn registry_has_agent(reg : @registry.AgentRegistry, agent_id : String) -> Bool {
  try {
    ignore(reg.get(agent_id))
    true
  } catch {
    _ => false
  } noraise {
    result => result
  }
}

///|
fn spawn_worker_parent_candidate(agent : @types.Agent) -> Bool {
  match agent.role {
    @types.Role::Root | @types.Role::TL => true
    _ => false
  }
}

///|
fn fallback_spawn_worker_parent_id(agents : Array[@types.Agent]) -> String? {
  let roots : Array[String] = []
  let tls : Array[String] = []
  for agent in agents {
    if spawn_worker_parent_candidate(agent) {
      let id = agent.agent_id.to_string()
      match agent.role {
        @types.Role::Root => roots.push(id)
        @types.Role::TL => tls.push(id)
        _ => ()
      }
    }
  }
  if roots.length() == 1 {
    Some(roots[0])
  } else if roots.length() > 1 {
    None
  } else if tls.length() == 1 {
    Some(tls[0])
  } else {
    None
  }
}

///|
/// Resolve the parent recorded for an inline worker before launching it. Fresh
/// test/non-orchestration paths with an empty registry keep the requested id;
/// live server paths normalize an unregistered caller to the registered TL/root
/// when there is one unambiguous parent.
fn resolve_spawn_worker_parent_id(
  caller_id : String,
  registry : @registry.AgentRegistry?,
  allow_audit_on_file_pr_caller? : Bool = false,
  allow_mutation_gate_caller? : Bool = false,
) -> Result[String, @types.ChoirError] {
  if caller_id == audit_on_file_pr_internal_caller_id {
    if allow_audit_on_file_pr_caller {
      return Ok(caller_id)
    }
    return Err(
      @types.ChoirError::validation_error(
        "spawn_worker caller_id '" +
        audit_on_file_pr_internal_caller_id +
        "' is reserved for internal file_pr audit workers",
      ),
    )
  }
  if caller_id == mutation_gate_internal_caller_id {
    if allow_mutation_gate_caller {
      return Ok(caller_id)
    }
    return Err(
      @types.ChoirError::validation_error(
        "spawn_worker caller_id '" +
        mutation_gate_internal_caller_id +
        "' is reserved for internal file_pr mutation-gate workers",
      ),
    )
  }
  match registry {
    None => Ok(caller_id)
    Some(reg) =>
      if registry_has_agent(reg, caller_id) {
        Ok(caller_id)
      } else {
        let agents = reg.list()
        if agents.length() == 0 {
          return Ok(caller_id)
        }
        match fallback_spawn_worker_parent_id(agents) {
          Some(parent_id) => Ok(parent_id)
          None =>
            Err(
              @types.ChoirError::validation_error(
                "spawn_worker caller_id '" +
                caller_id +
                "' is not registered; pass an agent_id that exists in the agent registry",
              ),
            )
        }
      }
  }
}

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
pub impl Show for SpawnWorkerPlan with fn output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
fn optional_response_string_json(value : String?) -> Json {
  match value {
    Some(v) => String::to_json(v)
    None => @json.parse("null") catch { _ => String::to_json("") }
  }
}

///|
fn task_contract_beads_issue_id(contract : @types.TaskContract?) -> String? {
  match contract {
    Some(c) => c.beads_issue_id
    None => None
  }
}

///|
fn spawn_response_agent_json(
  agent_id : String,
  role : @types.Role,
  agent_type : @types.AgentType,
  beads_issue_id : String?,
) -> Json {
  {
    "agent_id": String::to_json(agent_id),
    "role": String::to_json(role.to_wire_string()),
    "agent_type": String::to_json(agent_type.to_wire_string()),
    "beads_issue_id": optional_response_string_json(beads_issue_id),
  }.to_json()
}

///|
pub fn spawn_worker_ok_response(
  agent_id : String,
  agent_type : @types.AgentType,
  beads_issue_id : String?,
) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(agent_id),
    "agent_ids": String::to_json(agent_id),
    "role": String::to_json("worker"),
    "agent_type": String::to_json(agent_type.to_wire_string()),
    "beads_issue_id": optional_response_string_json(beads_issue_id),
    "agents": [
      spawn_response_agent_json(
        agent_id,
        @types.Role::Worker,
        agent_type,
        beads_issue_id,
      ),
    ].to_json(),
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
  isolation? : @types.IsolationMode = @types.IsolationMode::Inline,
) -> SpawnWorkerPlan {
  let spec = @types.SpawnSpec::{
    slug: worker_args.slug,
    role: @types.Role::Worker,
    agent_type: worker_args.agent_type,
    task: worker_args.task,
    task_contract: Some(worker_args.task_contract),
    isolation,
    parent_id: worker_args.caller_id,
    parent_branch: resolved_parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  let agent_id = @workspace.canonical_agent_id(spec)
  let terminal_target = @workspace.local_target_for(
    session,
    spec.slug,
    spec.isolation,
  )
  let workspace = match spec.isolation {
    @types.IsolationMode::Worktree =>
      @workspace.worktree_path(
        project_dir,
        @workspace.spawn_workspace_dir_slug(spec),
      )
    @types.IsolationMode::Inline => project_dir
    @types.IsolationMode::Standalone =>
      project_dir + "/.choir/agents/" + spec.slug
  }
  let registry_agent = @types.Agent::{
    agent_id,
    role: @types.Role::Worker,
    agent_type: worker_args.agent_type,
    state: @types.AgentState::Active,
    parent: Some(worker_args.caller_id),
    terminal_target: Some(terminal_target),
    host: @types.Host::Local,
    workspace,
    branch: agent_id,
    spawn_depth: 0,
  }
  {
    spec,
    agent_id,
    terminal_target,
    registry_agent,
    ok_response: spawn_worker_ok_response(
      agent_id,
      worker_args.agent_type,
      worker_args.task_contract.beads_issue_id,
    ),
  }
}

///|
async fn ensure_spawn_agy_prereqs(
  agent_type : @types.AgentType,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, String] {
  if agent_type != @types.AgentType::Gemini {
    return Ok(())
  }
  ensure_agy_binary_available(capture)
}

///|
priv enum SpawnAgySeedStep {
  Validate
  Prepare
  ColdBootstrap
  ReValidate
}

///|
fn SpawnAgySeedStep::label(self : SpawnAgySeedStep) -> String {
  match self {
    Validate => "validate"
    Prepare => "prepare"
    ColdBootstrap => "cold-bootstrap"
    ReValidate => "re-validate"
  }
}

///|
async fn run_spawn_agy_seed_command(
  step : SpawnAgySeedStep,
  cmd : @workspace.Command,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Int, String] {
  let statuses = runner([cmd]) catch {
    e =>
      return Err(
        "agy shared cache seed " +
        step.label() +
        " failed before spawn: " +
        e.to_string(),
      )
  }
  if statuses.is_empty() {
    Err(
      "agy shared cache seed " +
      step.label() +
      " failed before spawn: runner returned no status",
    )
  } else {
    Ok(statuses[0])
  }
}

///|
fn agy_seed_step_failure_message(
  step : SpawnAgySeedStep,
  status : Int,
  cmd : @workspace.Command,
  guidance : String,
  output : String,
) -> String {
  "agy shared cache seed " +
  step.label() +
  " failed; Gemini/agy spawn will continue without the warmed shared cache. " +
  guidance +
  " " +
  command_failure_message_from_output(status, cmd, output)
}

///|
async fn run_spawn_agy_seed_if_needed(
  agent_type : @types.AgentType,
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  if agent_type != @types.AgentType::Gemini {
    return None
  }
  let validate = @workspace.agy_shared_cache_validate(project_dir)
  let initial_validate = match
    run_spawn_agy_seed_command(Validate, validate, runner) {
    Ok(status) => status
    Err(msg) => return Some(msg)
  }
  if initial_validate == 0 {
    return None
  }
  if initial_validate < 0 {
    return Some(
      agy_seed_step_failure_message(
        Validate,
        1,
        validate,
        "Could not check whether the shared cache is already warm.",
        "",
      ),
    )
  }
  let prepare = @workspace.agy_shared_cache_prepare(project_dir)
  let prepare_status = match
    run_spawn_agy_seed_command(Prepare, prepare, runner) {
    Ok(status) => status
    Err(msg) => return Some(msg)
  }
  if prepare_status != 0 {
    return Some(
      agy_seed_step_failure_message(
        Prepare,
        if prepare_status < 0 {
          1
        } else {
          prepare_status
        },
        prepare,
        "Could not prepare the shared cache seed HOME and symlinks.",
        "",
      ),
    )
  }
  let bootstrap = @workspace.agy_shared_cache_cold_bootstrap(project_dir)
  let (bootstrap_status, bootstrap_output) = capture(bootstrap)
  if bootstrap_status != 0 {
    return Some(
      agy_seed_step_failure_message(
        ColdBootstrap,
        if bootstrap_status < 0 {
          1
        } else {
          bootstrap_status
        },
        bootstrap,
        "The agy warmup command did not complete.",
        bootstrap_output,
      ),
    )
  }
  let revalidate_status = match
    run_spawn_agy_seed_command(ReValidate, validate, runner) {
    Ok(status) => status
    Err(msg) => return Some(msg)
  }
  if revalidate_status != 0 {
    return Some(
      agy_seed_step_failure_message(
        ReValidate,
        if revalidate_status < 0 {
          1
        } else {
          revalidate_status
        },
        validate,
        "The warmup completed but the shared cache is still incomplete; expected non-empty ms-playwright-go node/package files and antigravity-cli-bin/webm_encoder.",
        "",
      ),
    )
  }
  None
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
  isolation? : @types.IsolationMode = @types.IsolationMode::Inline,
  allow_audit_on_file_pr_caller? : Bool = false,
  allow_mutation_gate_caller? : Bool = false,
  record_task_contract? : (String, @types.TaskContract?) -> Unit = fn(
    _agent_id,
    _contract,
  ) {
    ()
  },
) -> @types.Response {
  let normalized_args = match
    resolve_spawn_worker_parent_id(
      worker_args.caller_id,
      registry,
      allow_audit_on_file_pr_caller~,
      allow_mutation_gate_caller~,
    ) {
    Ok(parent_id) => { ..worker_args, caller_id: parent_id }
    Err(e) => return @types.Response::Err(e.message())
  }
  match ensure_caller_can_spawn(normalized_args.caller_id, registry) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  let resolved_parent_branch = detect_default_branch_with_capture(
    project_dir, capture,
  )
  let plan = spawn_worker_plan(
    normalized_args,
    resolved_parent_branch,
    session,
    project_dir,
    isolation~,
  )
  match
    ensure_no_live_spawn_agent_collision(
      "spawn_worker",
      plan.agent_id,
      registry,
    ) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  match ensure_spawn_agy_prereqs(plan.spec.agent_type, capture) {
    Ok(_) => ()
    Err(msg) => return @types.Response::Err(msg)
  }
  let seed_warning = run_spawn_agy_seed_if_needed(
    plan.spec.agent_type,
    project_dir,
    runner,
    capture,
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
      record_task_contract(plan.agent_id, plan.spec.task_contract)
      ignore(mirror_beads_spawn_for_spec(project_dir, plan.spec, capture))
      match seed_warning {
        Some(warning) => plan.ok_response.with_warning(warning)
        None => plan.ok_response
      }
    }
    Err(e) => {
      if plan.spec.isolation == @types.IsolationMode::Worktree {
        ignore(
          runner([@workspace.git_worktree_remove(plan.registry_agent.workspace)]),
        )
      }
      @types.Response::Err(e.message())
    }
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
pub impl Show for SpawnRemotePlan with fn output(self, logger) -> Unit {
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
    wave_id: None,
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
  registry? : @registry.AgentRegistry? = None,
  extra_mcp_servers_json? : String? = None,
) -> @types.Response {
  let plan = spawn_remote_plan(spawn_args)
  match
    ensure_no_live_spawn_agent_collision(
      "spawn_remote",
      @workspace.canonical_agent_id(plan.spec),
      registry,
    ) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
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
pub fn ensure_agy_migration_ready(
  agy_migration_incomplete : Bool,
) -> Result[Unit, @types.ChoirError] {
  if agy_migration_incomplete {
    Err(
      @types.ChoirError::config_error(
        "Gemini provider retired — agy migration incomplete",
      ),
    )
  } else {
    Ok(())
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
pub impl Show for SpawnGeminiPlan with fn output(self, logger) -> Unit {
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
    wave_id: None,
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
  registry? : @registry.AgentRegistry? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let plan = spawn_gemini_plan(spawn_args)
  match
    ensure_no_live_spawn_agent_collision(
      "spawn_gemini",
      @workspace.canonical_agent_id(plan.spec),
      registry,
    ) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  match ensure_spawn_agy_prereqs(plan.spec.agent_type, capture) {
    Ok(_) => ()
    Err(msg) => return @types.Response::Err(msg)
  }
  let seed_warning = run_spawn_agy_seed_if_needed(
    plan.spec.agent_type,
    project_dir,
    runner,
    capture,
  )
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
    Ok(_) =>
      match seed_warning {
        Some(warning) => plan.ok_response.with_warning(warning)
        None => plan.ok_response
      }
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure validation plus reuse [`SpawnSpec`] for `rescue_leaf` after the salvaged
