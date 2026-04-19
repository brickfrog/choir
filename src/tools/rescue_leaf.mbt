///|
/// agent is loaded from the registry. No I/O. Error strings match historical
/// `ToolRequest::RescueLeaf` dispatch behavior.
pub(all) struct RescueLeafSpawnPlan {
  from_agent_id : String
  to_id : String
  salvage_slug : String
  git_branch : String
  spec : @types.SpawnSpec
} derive(Debug)

///|
/// Second `remove_child_from_supervisor_lifecycle` call uses `salvage_slug` when
/// it differs from the full salvaged agent id (matches inline dispatch).
pub fn rescue_leaf_remove_supervisor_alias(
  salvage_slug : String,
  from_agent_id : String,
) -> Bool {
  salvage_slug != from_agent_id
}

///|
pub fn rescue_leaf_spawn_plan(
  args : RescueLeafArgs,
  from_agent : @types.Agent,
) -> Result[RescueLeafSpawnPlan, @types.ChoirError] {
  let from_agent_id = args.from_agent_id
  if from_agent.role != @types.Role::Dev {
    return Err(
      @types.ChoirError::validation_error(
        "rescue_leaf only supports dev leaves",
      ),
    )
  }
  match from_agent.parent {
    Some(p) =>
      if p != args.caller_id {
        return Err(
          @types.ChoirError::validation_error(
            "caller_id must match the salvaged leaf parent",
          ),
        )
      }
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "salvaged leaf has no parent in registry",
        ),
      )
  }
  if !from_agent.workspace.contains(".choir/worktrees/") {
    return Err(
      @types.ChoirError::validation_error(
        "salvaged leaf has no choir worktree path to reuse",
      ),
    )
  }
  let parent_prefix = match @workspace.parent_branch(from_agent_id) {
    Some(pb) => pb
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "invalid from_agent_id (expected nested branch like parent.child)",
        ),
      )
  }
  let to_id = @workspace.branch_name(parent_prefix, args.new_slug)
  let salvage_slug = @phase.extract_slug(from_agent_id)
  let git_branch = if from_agent.branch != "" {
    from_agent.branch
  } else {
    from_agent_id
  }
  let spec = @types.SpawnSpec::{
    slug: args.new_slug,
    role: @types.Role::Dev,
    agent_type: args.agent_type,
    task: args.task,
    task_contract: Some(args.task_contract),
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: parent_prefix,
    reuse_workspace: true,
    workspace_slug: Some(salvage_slug),
    reuse_git_branch: Some(git_branch),
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  match @workspace.validate_reuse_spawn_spec(spec) {
    Err(e) => Err(@types.ChoirError::validation_error(e))
    Ok(_) => Ok({ from_agent_id, to_id, salvage_slug, git_branch, spec })
  }
}

///|
pub fn rescue_leaf_ok_response(
  to_id : String,
  from_agent_id : String,
  new_slug : String,
) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(to_id),
    "from_agent_id": String::to_json(from_agent_id),
    "slug": String::to_json(new_slug),
  })
}

///|
/// User-facing error when lifecycle handoff fails after spawn succeeded (matches
/// historical `ToolRequest::RescueLeaf` wording).
pub fn rescue_leaf_handoff_failure_message(detail : String) -> String {
  "rescue_leaf: replacement spawned but lifecycle handoff failed — manual repair may be needed: " +
  detail
}

///|
/// User-facing error when superseded lifecycle cannot be persisted (matches
/// historical dispatch wording).
pub fn rescue_leaf_superseded_persist_failure_message(
  from_agent_id : String,
) -> String {
  "failed to persist superseded lifecycle for " + from_agent_id
}

///|
/// Registry/poller guards, load salvaged agent, `rescue_leaf_spawn_plan`,
/// `spawn_commands`, `run_strict`, then the existing post-spawn interpreter.
/// Preserves historical `ToolRequest::RescueLeaf` ordering and error strings.
pub async fn interpret_rescue_leaf(
  rescue_args : RescueLeafArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
  poller_state : @poller.PollerState?,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let reg = match registry {
    Some(r) => r
    None =>
      return @types.Response::Err("agent registry unavailable for rescue_leaf")
  }
  let ps = match poller_state {
    Some(p) => p
    None => return @types.Response::Err("poller unavailable for rescue_leaf")
  }
  let from_agent = try reg.get(rescue_args.from_agent_id) catch {
    e => return tool_response_err_from_caught(e)
  } noraise {
    a => a
  }
  let plan = match rescue_leaf_spawn_plan(rescue_args, from_agent) {
    Err(e) => return @types.Response::Err(e.message())
    Ok(p) => p
  }
  let old_wave_id = read_agent_wave_id(
    project_dir,
    plan.from_agent_id,
    registry,
  )
  let plan = { ..plan, spec: { ..plan.spec, wave_id: old_wave_id } }
  let cmds = @workspace.spawn_commands(
    plan.spec,
    project_dir,
    session,
    parent_session_id=rescue_args.parent_session_id,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  match run_strict(runner, cmds, capture~) {
    Err(e) => return @types.Response::Err(e.message())
    Ok(_) => ()
  }
  interpret_rescue_leaf_post_spawn(
    rescue_args, plan, project_dir, session, reg, ps, registry,
  )
}

///|
/// Ordered host-side steps for `rescue_leaf` after `run_strict` succeeds. The
/// interpreter runs this sequence; `SupervisorRemoveChildAliasIfNeeded` may
/// no-op when `rescue_leaf_remove_supervisor_alias` is false.
pub(all) enum RescueLeafPostSpawnHostStep {
  LifecycleHandoff
  PollerTransferOwnerAndWriteState
  MarkSuperseded
  RegistryRemoveOld
  SupervisorRemoveChildFromAgent
  SupervisorRemoveChildAliasIfNeeded
  TeamRegisterMember
  TlEventChildSpawned
  PaneResolveAndUpsertTerminal
} derive(Debug, Eq)

///|
pub impl Show for RescueLeafPostSpawnHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn rescue_leaf_post_spawn_host_steps() -> Array[RescueLeafPostSpawnHostStep] {
  [
    RescueLeafPostSpawnHostStep::LifecycleHandoff,
    RescueLeafPostSpawnHostStep::PollerTransferOwnerAndWriteState,
    RescueLeafPostSpawnHostStep::MarkSuperseded,
    RescueLeafPostSpawnHostStep::RegistryRemoveOld,
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildFromAgent,
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildAliasIfNeeded,
    RescueLeafPostSpawnHostStep::TeamRegisterMember,
    RescueLeafPostSpawnHostStep::TlEventChildSpawned,
    RescueLeafPostSpawnHostStep::PaneResolveAndUpsertTerminal,
  ]
}

///|
/// Post-spawn effect sequence for `rescue_leaf` after `run_strict` succeeds:
/// lifecycle handoff, poller transfer/write, superseded mark, registry remove,
/// supervisor cleanup, team registration, TL event, pane resolution/upsert, and
/// success response. Preserves exact ordering and error behavior of the prior
/// inline `dispatch` arm.
pub async fn interpret_rescue_leaf_post_spawn(
  rescue_args : RescueLeafArgs,
  plan : RescueLeafSpawnPlan,
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  ps : @poller.PollerState,
  registry : @registry.AgentRegistry?,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  match
    @phase.handoff_dev_workflow_to_new_agent(
      project_dir,
      plan.from_agent_id,
      plan.to_id,
      @types.Role::Dev,
    ) {
    Err(e) =>
      return @types.Response::Err(
        rescue_leaf_handoff_failure_message(e.validation_detail_or_message()),
      )
    Ok(_) => ()
  }
  ignore(ps.transfer_owner(plan.from_agent_id, plan.to_id, plan.git_branch, ""))
  ignore(ps.write_state_file(project_dir))
  if !@phase.mark_agent_rescued_superseded(
      project_dir,
      plan.from_agent_id,
      @types.Role::Dev,
    ) {
    return @types.Response::Err(
      rescue_leaf_superseded_persist_failure_message(plan.from_agent_id),
    )
  }
  try reg.remove(plan.from_agent_id) catch {
    e => return tool_response_err_from_caught(e)
  } noraise {
    _ => ()
  }
  @phase.remove_child_from_supervisor_lifecycle(
    project_dir,
    rescue_args.caller_id,
    plan.from_agent_id,
  )
  if rescue_leaf_remove_supervisor_alias(plan.salvage_slug, plan.from_agent_id) {
    @phase.remove_child_from_supervisor_lifecycle(
      project_dir,
      rescue_args.caller_id,
      plan.salvage_slug,
    )
  }
  let _ = @workspace.register_team_member(
    rescue_args.caller_id,
    rescue_args.new_slug,
    @config.agent_type_to_string(rescue_args.agent_type),
  )
  let rescue_tl_effects = @phase.plan_tl_event_for_scope(
    project_dir,
    rescue_args.caller_id,
    @phase.TLEvent::ChildSpawned(child_id=rescue_args.new_slug),
    registry~,
  )
  @phase.interpret_lifecycle_effects(project_dir, rescue_tl_effects, registry~)
  let resolved_pane_ids : Array[(String, String)] = []
  match resolve_zellij_pane_id(session, rescue_args.new_slug, capture~) {
    Some(pane_id) => resolved_pane_ids.push((plan.to_id, pane_id))
    None => ()
  }
  match registry {
    Some(r2) =>
      for pair in resolved_pane_ids {
        let (agent_id, pane_id) = pair
        try {
          let agent = r2.get(agent_id)
          let target = @workspace.zellij_pane_target(session, pane_id)
          ignore(r2.upsert({ ..agent, terminal_target: Some(target) }))
        } catch {
          _ => ()
        }
      }
    None => ()
  }
  match plan.spec.wave_id {
    Some(wave_id) =>
      match
        record_rescue(project_dir, wave_id, plan.from_agent_id, plan.to_id) {
        Ok(_) => ()
        Err(e) => return @types.Response::Err(e.message())
      }
    None => ()
  }
  rescue_leaf_ok_response(plan.to_id, plan.from_agent_id, rescue_args.new_slug)
}

///|
