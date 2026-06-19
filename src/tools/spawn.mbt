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
pub fn read_project_config_toml(
  project_dir : String,
  read_file? : (String) -> String = @sys.read_file,
) -> String {
  read_file(project_dir + "/.choir/config.toml")
}

///|
fn spawn_agent_token_hex_char(ch : Char) -> Bool {
  (ch >= '0' && ch <= '9') ||
  (ch >= 'a' && ch <= 'f') ||
  (ch >= 'A' && ch <= 'F')
}

///|
fn parse_spawn_agent_token_output(output : String) -> String? {
  let buf = StringBuilder::new()
  for ch in output {
    if spawn_agent_token_hex_char(ch) {
      buf.write_char(ch)
    } else if ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' {
      ()
    } else {
      return None
    }
  }
  let token = buf.to_string()
  if token.length() == 64 {
    Some(token)
  } else {
    None
  }
}

///|
pub fn spawn_agent_token_command() -> @workspace.Command {
  {
    program: "od",
    args: ["-An", "-tx1", "-N32", "/dev/urandom"],
    workdir: None,
  }
}

///|
async fn mint_spawn_agent_token_with_capture(
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (code, output) = capture(spawn_agent_token_command())
  if code == 0 {
    match parse_spawn_agent_token_output(output) {
      Some(token) => return Ok(token)
      None => ()
    }
  }
  Err(
    @types.ChoirError::workspace_error("failed to mint spawn agent credential"),
  )
}

///|
pub async fn mint_spawn_agent_token(
  capture : async (@workspace.Command) -> (Int, String),
  override_mint : (async () -> Result[String, @types.ChoirError])?,
) -> Result[String, @types.ChoirError] {
  match override_mint {
    Some(mint) => mint()
    None => mint_spawn_agent_token_with_capture(capture)
  }
}

///|
fn record_spawn_credential_for_agent(
  registry : @registry.AgentRegistry?,
  agent_id : String,
  role : @types.Role,
  token : String,
) -> Unit {
  match registry {
    Some(reg) =>
      reg.record_spawn_credential(agent_id, @registry.AgentCredential::{
        role,
        token,
      })
    None => ()
  }
}

///|
fn remove_spawn_credential_for_agent(
  registry : @registry.AgentRegistry?,
  agent_id : String,
) -> Unit {
  match registry {
    Some(reg) => reg.remove_spawn_credential(agent_id)
    None => ()
  }
}

///|
fn spawn_test_token_is_hex(token : String) -> Bool {
  if token.length() < 64 {
    return false
  }
  for ch in token {
    if !((ch >= '0' && ch <= '9') ||
      (ch >= 'a' && ch <= 'f') ||
      (ch >= 'A' && ch <= 'F')) {
      return false
    }
  }
  true
}

///|
async test "spawn agent token source uses urandom and preserves uniqueness" {
  let entropy_command = spawn_agent_token_command()
  assert_eq(entropy_command.program, "od")
  assert_true(entropy_command.args.contains("-N32"))
  assert_true(entropy_command.args.contains("/dev/urandom"))
  let mut calls = 0
  let capture = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    calls = calls + 1
    if calls == 1 {
      (
        0, "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 10 21 32 43 54 65 76 87 98 a9 ba cb dc ed fe 0f\n",
      )
    } else {
      (
        0, "ff ee dd cc bb aa 99 88 77 66 55 44 33 22 11 00 0f fe ed dc cb ba a9 98 87 76 65 54 43 32 21 10\n",
      )
    }
  }
  let first = mint_spawn_agent_token_with_capture(capture)
  let second = mint_spawn_agent_token_with_capture(capture)
  match (first, second) {
    (Ok(a), Ok(b)) => {
      assert_true(spawn_test_token_is_hex(a))
      assert_true(spawn_test_token_is_hex(b))
      assert_true(a != b)
    }
    (Err(e), _) => fail("first token mint failed: " + e.message())
    (_, Err(e)) => fail("second token mint failed: " + e.message())
  }
}

///|
async test "spawn agent token parser rejects malformed od output" {
  let malformed = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (
      0, "garbage 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 10 21 32 43 54 65 76 87 98 a9 ba cb dc ed fe 0f\n",
    )
  }
  match mint_spawn_agent_token_with_capture(malformed) {
    Ok(token) => fail("malformed token output minted: " + token)
    Err(_) => ()
  }

  let extra_hex = async fn(_cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    (
      0, "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 10 21 32 43 54 65 76 87 98 a9 ba cb dc ed fe 0f aa\n",
    )
  }
  match mint_spawn_agent_token_with_capture(extra_hex) {
    Ok(token) => fail("extra token output minted: " + token)
    Err(_) => ()
  }
}

///|
test "spawn credential helper records plan role and token" {
  let reg = @registry.AgentRegistry::new()
  let worker_args : WorkerSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "worker-a",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: Some("main"),
    isolation: None,
  }
  let plan = spawn_worker_plan(worker_args, "main", "sess", "/repo")
  record_spawn_credential_for_agent(
    Some(reg),
    plan.agent_id,
    plan.registry_agent.role,
    "worker-token-a",
  )
  match reg.credential_for_agent(plan.agent_id) {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::Worker)
      assert_eq(credential.token, "worker-token-a")
    }
    None => fail("expected worker spawn credential")
  }
}

///|
fn spawn_test_commands_contain(
  cmds : Array[@workspace.Command],
  needle : String,
) -> Bool {
  for cmd in cmds {
    for arg in cmd.args {
      if arg.contains(needle) {
        return true
      }
    }
  }
  false
}

///|
async test "interpret_spawn_worker records credential and exports token" {
  let reg = @registry.AgentRegistry::new()
  let seen_cmds : Array[@workspace.Command] = []
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses : Array[Int] = []
    for cmd in cmds {
      seen_cmds.push(cmd)
      statuses.push(0)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    seen_cmds.push(cmd)
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      (0, "origin/main\n")
    } else {
      (0, "")
    }
  }
  let mint_agent_token = async fn() -> Result[String, @types.ChoirError] {
    @async.sleep(0)
    Ok("worker-token-a")
  }
  let worker_args : WorkerSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "worker-a",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: Some("main"),
    isolation: None,
  }
  let resp = interpret_spawn_worker(
    worker_args,
    "/repo",
    "sess",
    runner,
    capture,
    Some(reg),
    mint_agent_token=Some(mint_agent_token),
    read_file=fn(_) { "" },
  )
  match resp {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("spawn_worker failed: " + msg)
  }
  match reg.credential_for_agent("main.worker-a") {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::Worker)
      assert_eq(credential.token, "worker-token-a")
    }
    None => fail("expected recorded spawn credential")
  }
  assert_true(
    spawn_test_commands_contain(seen_cmds, "CHOIR_AGENT_TOKEN=worker-token-a"),
  )
}

///|
async test "interpret_spawn_worker removes credential when launch fails" {
  let reg = @registry.AgentRegistry::new()
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses : Array[Int] = []
    for _ in cmds {
      statuses.push(1)
    }
    statuses
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" &&
      cmd.args == ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"] {
      (0, "origin/main\n")
    } else {
      (0, "launch failed")
    }
  }
  let mint_agent_token = async fn() -> Result[String, @types.ChoirError] {
    @async.sleep(0)
    Ok("worker-token-fail")
  }
  let worker_args : WorkerSpawnArgs = {
    task: "t",
    task_contract: { ..@types.TaskContract::empty(), goal: "t" },
    caller_id: "main.tl",
    slug: "worker-fail",
    agent_type: @types.AgentType::Codex,
    worker_kind: WorkerKind::Research,
    parent_branch: Some("main"),
    isolation: None,
  }
  let resp = interpret_spawn_worker(
    worker_args,
    "/repo",
    "sess",
    runner,
    capture,
    Some(reg),
    mint_agent_token=Some(mint_agent_token),
    read_file=fn(_) { "" },
  )
  match resp {
    @types.Response::Err(_) => ()
    @types.Response::Ok(_) => fail("expected launch failure")
  }
  @debug.assert_eq(reg.credential_for_agent("main.worker-fail"), None)
}

///|
test "spawn diagnostics redact agent token log lines" {
  let redacted = spawn_launch_sanitized_stderr_tail(
    "launch failed CHOIR_AGENT_TOKEN=secret-token-value",
  )
  assert_true(redacted.contains("CHOIR_AGENT_TOKEN=[REDACTED]"))
  assert_false(redacted.contains("secret-token-value"))
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
    @types.Role::TL => true
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
      if id == "root" {
        roots.push(id)
      } else {
        tls.push(id)
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
) -> Result[String, @types.ChoirError] {
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
fn spawn_worker_effective_isolation(
  worker_args : WorkerSpawnArgs,
  requested_isolation : @types.IsolationMode,
) -> @types.IsolationMode {
  worker_args.isolation.unwrap_or(requested_isolation)
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
  isolation? : @types.IsolationMode = @types.IsolationMode::InlineDedicatedTab,
) -> SpawnWorkerPlan {
  let isolation = spawn_worker_effective_isolation(worker_args, isolation)
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
    merge_strategy: None,
    wave_id: None,
  }
  let agent_id = @workspace.canonical_agent_id(spec)
  let terminal_target = @workspace.local_target_for(
    session,
    spec.slug,
    spec.isolation,
  )
  let workspace = @workspace.spawn_workspace_path(project_dir, spec)
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
async fn resolve_spawn_worker_parent_branch(
  worker_args : WorkerSpawnArgs,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  match worker_args.isolation {
    Some(@types.IsolationMode::Worktree) => {
      if worker_args.worker_kind != WorkerKind::Review {
        return Err(
          @types.ChoirError::validation_error(
            "spawn_worker isolation=worktree is only supported for type=review write-capable audit workers",
          ),
        )
      }
      match worker_args.parent_branch {
        Some(branch) if branch.trim() != "" => Ok(branch.trim().to_owned())
        _ =>
          Err(
            @types.ChoirError::validation_error(
              "spawn_worker isolation=worktree requires explicit parent_branch target ref; refusing to infer review target from the root checkout",
            ),
          )
      }
    }
    _ => Ok(detect_default_branch_with_capture(project_dir, capture))
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
  read_file? : (String) -> String = @sys.read_file,
  isolation? : @types.IsolationMode = @types.IsolationMode::InlineDedicatedTab,
  record_task_contract? : (String, @types.TaskContract?) -> Unit = fn(
    _agent_id,
    _contract,
  ) {
    ()
  },
  mint_agent_token? : (async () -> Result[String, @types.ChoirError])? = None,
  record_spawn_launch_diagnostic? : (SpawnLaunchDiagnostic) -> Unit = fn(_) {
    ()
  },
) -> @types.Response {
  let normalized_args = match
    resolve_spawn_worker_parent_id(worker_args.caller_id, registry) {
    Ok(parent_id) => { ..worker_args, caller_id: parent_id }
    Err(e) => return @types.Response::Err(e.message())
  }
  match ensure_caller_can_spawn(normalized_args.caller_id, registry) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
  }
  let resolved_parent_branch = match
    resolve_spawn_worker_parent_branch(normalized_args, project_dir, capture) {
    Ok(branch) => branch
    Err(e) => return @types.Response::Err(e.message())
  }
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
  let agent_token = match mint_spawn_agent_token(capture, mint_agent_token) {
    Ok(token) => token
    Err(e) => return @types.Response::Err(e.message())
  }
  record_spawn_credential_for_agent(
    registry,
    plan.agent_id,
    plan.registry_agent.role,
    agent_token,
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
    agent_token=Some(agent_token),
    project_config_content=read_project_config_toml(project_dir, read_file~),
  )
  let spawn_launch_bindings = spawn_launch_command_bindings_for_agent(
    plan.agent_id,
    0,
    cmds,
  )
  match
    run_strict(
      runner,
      cmds,
      capture~,
      spawn_launch_bindings~,
      record_spawn_launch_diagnostic~,
    ) {
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
      remove_spawn_credential_for_agent(registry, plan.agent_id)
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
    merge_strategy: None,
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
  mint_agent_token? : (async () -> Result[String, @types.ChoirError])? = None,
  record_spawn_launch_diagnostic? : (SpawnLaunchDiagnostic) -> Unit = fn(_) {
    ()
  },
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
  let agent_token = match mint_spawn_agent_token(capture, mint_agent_token) {
    Ok(token) => token
    Err(e) => return @types.Response::Err(e.message())
  }
  record_spawn_credential_for_agent(
    registry,
    @workspace.canonical_agent_id(plan.spec),
    plan.spec.role,
    agent_token,
  )
  let cmds = @workspace.remote_spawn_commands(
    plan.spec,
    spawn_args.ssh_target,
    spawn_args.repo_url,
    spawn_args.tcp_addr,
    parent_session_id=spawn_args.parent_session_id,
    extra_mcp_servers_json~,
    agent_token=Some(agent_token),
  )
  let spawn_launch_bindings = if cmds.length() == 0 {
    []
  } else {
    [
      SpawnLaunchCommandBinding::{
        agent_id: @workspace.canonical_agent_id(plan.spec),
        command_index: cmds.length() - 1,
      },
    ]
  }
  match
    run_strict(
      runner,
      cmds,
      capture~,
      spawn_launch_bindings~,
      record_spawn_launch_diagnostic~,
    ) {
    Ok(_) => plan.ok_response
    Err(e) => {
      remove_spawn_credential_for_agent(
        registry,
        @workspace.canonical_agent_id(plan.spec),
      )
      @types.Response::Err(e.message())
    }
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
    merge_strategy: None,
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
  read_file? : (String) -> String = @sys.read_file,
  mint_agent_token? : (async () -> Result[String, @types.ChoirError])? = None,
  record_spawn_launch_diagnostic? : (SpawnLaunchDiagnostic) -> Unit = fn(_) {
    ()
  },
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
  let agent_token = match mint_spawn_agent_token(capture, mint_agent_token) {
    Ok(token) => token
    Err(e) => return @types.Response::Err(e.message())
  }
  record_spawn_credential_for_agent(
    registry,
    @workspace.canonical_agent_id(plan.spec),
    plan.spec.role,
    agent_token,
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
    agent_token=Some(agent_token),
    project_config_content=read_project_config_toml(project_dir, read_file~),
  )
  let spawn_launch_bindings = spawn_launch_command_bindings_for_agent(
    @workspace.canonical_agent_id(plan.spec),
    0,
    cmds,
  )
  match
    run_strict(
      runner,
      cmds,
      capture~,
      spawn_launch_bindings~,
      record_spawn_launch_diagnostic~,
    ) {
    Ok(_) =>
      match seed_warning {
        Some(warning) => plan.ok_response.with_warning(warning)
        None => plan.ok_response
      }
    Err(e) => {
      remove_spawn_credential_for_agent(
        registry,
        @workspace.canonical_agent_id(plan.spec),
      )
      @types.Response::Err(e.message())
    }
  }
}

///|
/// Pure validation plus reuse [`SpawnSpec`] for `rescue_leaf` after the salvaged
