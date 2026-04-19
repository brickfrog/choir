///|
pub fn fork_wave_leaf_task_with_review_context(
  base_task : String,
  review_context : String?,
) -> String {
  match review_context {
    None => base_task
    Some(rc) => {
      let t = rc.trim().to_string()
      if t == "" {
        base_task
      } else {
        base_task + "\n\n## CHOIR_REVIEW_CONTEXT\n" + t + "\n"
      }
    }
  }
}

///|
/// Build [`ForkWaveSpawnPlan`] from resolved tool args and `child_spawn_depth`.
/// Uses `slugify_task` for per-leaf slugs; behavior matches the historical
/// `ToolRequest::ForkWave` inline loop in `dispatch`.
pub fn fork_wave_spawn_plan(
  fork_wave_args : ForkWaveArgs,
  child_spawn_depth : Int,
  registry : @registry.AgentRegistry?,
  project_dir : String,
  session : String,
  wave_id? : String? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> ForkWaveSpawnPlan {
  let agent_ids = StringBuilder::new()
  let skipped_ids = StringBuilder::new()
  let cmds : Array[@workspace.Command] = []
  let spawned_specs : Array[@types.SpawnSpec] = []
  let spawned_slugs : Array[String] = []
  let mut spawned_count = 0
  let mut skipped_count = 0
  let seen_slugs : Map[String, Int] = {}
  for i = 0; i < fork_wave_args.count; i = i + 1 {
    let raw_slug = if fork_wave_args.has_per_leaf_tasks {
      slugify_task(fork_wave_args.tasks[i], i)
    } else {
      fork_wave_args.slug_prefix + "-" + i.to_string()
    }
    let slug = match seen_slugs.get(raw_slug) {
      Some(count) => {
        seen_slugs.set(raw_slug, count + 1)
        raw_slug + "-" + i.to_string()
      }
      None => {
        seen_slugs.set(raw_slug, 1)
        raw_slug
      }
    }
    let agent_id = fork_wave_args.parent_branch + "." + slug
    let already_alive = match registry {
      Some(reg) =>
        try {
          match reg.get(agent_id).state {
            @types.AgentState::Active | @types.AgentState::Completing => true
            _ => false
          }
        } catch {
          _ => false
        }
      None => false
    }
    if already_alive {
      if skipped_count > 0 {
        skipped_ids.write_string(",")
      }
      skipped_ids.write_string(agent_id)
      skipped_count = skipped_count + 1
      continue
    }
    if spawned_count > 0 {
      agent_ids.write_string(",")
    }
    agent_ids.write_string(agent_id)
    spawned_count = spawned_count + 1
    spawned_slugs.push(slug)
    let leaf_task = fork_wave_leaf_task_with_review_context(
      fork_wave_args.tasks[i],
      fork_wave_args.review_context,
    )
    let task_contract = fork_wave_args.task_contracts[i]
    let spec = @types.SpawnSpec::{
      slug,
      role: fork_wave_args.child_role,
      agent_type: fork_wave_args.agent_type,
      task: leaf_task,
      task_contract: Some(task_contract),
      isolation: @types.IsolationMode::Worktree,
      parent_id: fork_wave_args.caller_id,
      parent_branch: fork_wave_args.parent_branch,
      reuse_workspace: false,
      workspace_slug: None,
      reuse_git_branch: None,
      spawn_depth: child_spawn_depth,
      automerge: fork_wave_args.automerge,
      review_mode: fork_wave_args.review_mode,
      wave_id,
    }
    spawned_specs.push(spec)
    for
      cmd in @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=fork_wave_args.parent_session_id,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      ) {
      cmds.push(cmd)
    }
  }
  {
    cmds,
    spawned_specs,
    spawned_slugs,
    spawned_count,
    skipped_count,
    agent_ids: agent_ids.to_string(),
    skipped_ids: skipped_ids.to_string(),
  }
}

///|
/// Default parent branch when the tool passed `"main"`: detect the repository
/// default via `detect_default_branch_with_capture`. Preserves prior dispatch
/// behavior.
pub async fn fork_wave_resolve_args_parent_branch(
  fork_wave_args : ForkWaveArgs,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> ForkWaveArgs {
  let resolved_parent = if fork_wave_args.parent_branch == "main" {
    detect_default_branch_with_capture(project_dir, capture)
  } else {
    fork_wave_args.parent_branch
  }
  { ..fork_wave_args, parent_branch: resolved_parent }
}

///|
/// Caller spawn_depth from the registry when present and the agent exists.
pub fn fork_wave_caller_spawn_depth_from_registry(
  registry : @registry.AgentRegistry?,
  caller_id : String,
) -> Int? {
  match registry {
    Some(reg) => Some(reg.get(caller_id).spawn_depth) catch { _ => None }
    None => None
  }
}

///|
/// Child spawn depth for `fork_wave_spawn_plan` from caller depth and leaf role.
pub fn fork_wave_child_spawn_depth(
  caller_spawn_depth : Int?,
  child_role : @types.Role,
) -> Int {
  if child_role == @types.Role::TL {
    caller_spawn_depth.unwrap_or(0) + 1
  } else {
    caller_spawn_depth.unwrap_or(0)
  }
}

///|
/// Map `interpret fork_wave_plan` result to the tool response. On
/// [`ForkWaveError::CommandFailed`], re-runs capture on the failing command
/// (typically merged stdout/stderr via `capture_command_output`, not stderr-only).
/// Preserves exact `ToolRequest::ForkWave` strings.
pub async fn fork_wave_response_from_interpret_result(
  interpret_result : Result[@types.Response, ForkWaveError],
  capture_output : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  match interpret_result {
    Ok(r) => r
    Err(CommandFailed(status~, failing_cmd~)) => {
      let detail = match failing_cmd {
        Some(cmd) => {
          let (_, output) = capture_output(cmd)
          output.trim().to_string()
        }
        None => ""
      }
      if detail != "" {
        @types.Response::Err(
          "spawn failed (exit " + status.to_string() + "): " + detail,
        )
      } else {
        @types.Response::Err("command failed with status " + status.to_string())
      }
    }
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Single entry point (from dispatch) for `fork_wave` pre-spawn / effect-phase
/// wiring: parent-branch defaulting, caller spawn-depth resolution, spawn plan,
/// scaffold gate + spawn via `interpret`, and spawn failure response mapping.
/// The `capture` injectable is shared for default-branch detection and for
/// re-capture on spawn failure. Post-spawn is [`interpret_fork_wave_post_spawn`].
pub async fn interpret_fork_wave_spawn_effect_phase(
  fork_wave_args : ForkWaveArgs,
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry?,
  capture : async (@workspace.Command) -> (Int, String),
  git_capture : async (String, Array[String]) -> String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  wave_id? : String? = None,
) -> (@types.Response, ForkWaveArgs, ForkWaveSpawnPlan) {
  let fork_wave_args = fork_wave_resolve_args_parent_branch(
    fork_wave_args, project_dir, capture,
  )
  let caller_spawn_depth = fork_wave_caller_spawn_depth_from_registry(
    registry,
    fork_wave_args.caller_id,
  )
  let child_spawn_depth = fork_wave_child_spawn_depth(
    caller_spawn_depth,
    fork_wave_args.child_role,
  )

  let spawn_plan = fork_wave_spawn_plan(
    fork_wave_args,
    child_spawn_depth,
    registry,
    project_dir,
    session,
    wave_id~,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  let plan = fork_wave_plan(
    project_dir,
    spawn_plan.cmds,
    spawn_plan.spawned_count,
    spawn_plan.skipped_count,
    spawn_plan.agent_ids,
    spawn_plan.skipped_ids,
  )
  let interpret_result = interpret(plan, git_capture~, runner~)
  let resp = fork_wave_response_from_interpret_result(interpret_result, capture)
  (resp, fork_wave_args, spawn_plan)
}

///|
fn split_spawned_agent_ids(agent_ids : String) -> Array[String] {
  let out : Array[String] = []
  for part in agent_ids.split(",") {
    let trimmed = part.trim().to_string()
    if trimmed != "" {
      out.push(trimmed)
    }
  }
  out
}

///|
pub fn allocate_wave_id(
  project_dir : String,
  slug_prefix : String,
  now_ticks : Int64,
  pid : Int,
  max_attempts? : Int = 1000,
) -> String {
  let base = generate_pending_wave_id(slug_prefix, now_ticks, pid)
  if !@sys.path_entry_exists(wave_index_path(project_dir, base)) {
    return base
  }
  let mut suffix = 1
  while suffix < max_attempts {
    let candidate = base + "-" + suffix.to_string()
    if !@sys.path_entry_exists(wave_index_path(project_dir, candidate)) {
      return candidate
    }
    suffix = suffix + 1
  }
  base + "-" + suffix.to_string()
}

///|
pub fn generate_wave_id_and_save(
  project_dir : String,
  slug_prefix : String,
  parent_branch : String,
  agent_ids : Array[String],
  now_ms : Int64,
  pid : Int,
) -> Result[String, @types.ChoirError] {
  let wave_id = allocate_wave_id(project_dir, slug_prefix, now_ms, pid)
  match
    save_wave_index(
      project_dir,
      WaveIndex::new(wave_id, parent_branch, now_ms, agent_ids),
    ) {
    Ok(_) => Ok(wave_id)
    Err(e) => Err(e)
  }
}

///|
pub fn save_fresh_spawned_wave_index(
  project_dir : String,
  wave_id : String,
  parent_branch : String,
  fork_ts_ms : Int64,
  agent_ids_csv : String,
) -> Result[Unit, @types.ChoirError] {
  save_wave_index(
    project_dir,
    WaveIndex::new(
      wave_id,
      parent_branch,
      fork_ts_ms,
      split_spawned_agent_ids(agent_ids_csv),
    ),
  )
}

///|
pub fn append_spawned_agents_to_wave_index(
  project_dir : String,
  wave_id : String,
  parent_branch : String,
  fork_ts_ms : Int64,
  agent_ids_csv : String,
) -> Result[Unit, @types.ChoirError] {
  let ids = split_spawned_agent_ids(agent_ids_csv)
  if !@sys.path_entry_exists(wave_index_path(project_dir, wave_id)) {
    match
      save_wave_index(
        project_dir,
        WaveIndex::new(wave_id, parent_branch, fork_ts_ms, []),
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  for agent_id in ids {
    match append_agent_id(project_dir, wave_id, agent_id) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(())
}

///|
/// Registry row for a spawned leaf after `fork_wave` host spawn succeeds (before
/// pane resolution overwrites `terminal_target`). Pure; matches the prior inline
/// `ToolRequest::ForkWave` upsert shape.
pub fn fork_wave_spawned_registry_agent(
  spec : @types.SpawnSpec,
  project_dir : String,
  session : String,
) -> @types.Agent {
  let agent_id = @workspace.canonical_agent_id(spec)
  let terminal_target = @workspace.local_target_for(
    session,
    spec.slug,
    spec.isolation,
  )
  {
    agent_id,
    role: spec.role,
    agent_type: spec.agent_type,
    state: @types.AgentState::Spawning,
    parent: Some(spec.parent_id),
    terminal_target: Some(terminal_target),
    host: @types.Host::Local,
    workspace: @workspace.worktree_path(
      project_dir,
      @workspace.spawn_workspace_dir_slug(spec),
    ),
    branch: @workspace.spawn_git_branch(spec),
    spawn_depth: spec.spawn_depth,
  }
}

///|
/// Ordered host-side phases for `fork_wave` after `interpret` succeeds with
/// `spawned_count > 0`. The interpreter runs this sequence.
pub(all) enum ForkWavePostSpawnHostStep {
  RegistryUpsertSpawnedSpecs
  PerSlugTeamRegisterAndTlEventAndPaneResolve
  RegistryTerminalTargetUpsertFromPanes
} derive(Debug, Eq)

///|
pub impl Show for ForkWavePostSpawnHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn fork_wave_post_spawn_host_steps() -> Array[ForkWavePostSpawnHostStep] {
  [
    ForkWavePostSpawnHostStep::RegistryUpsertSpawnedSpecs,
    ForkWavePostSpawnHostStep::PerSlugTeamRegisterAndTlEventAndPaneResolve,
    ForkWavePostSpawnHostStep::RegistryTerminalTargetUpsertFromPanes,
  ]
}

///|
/// Post-spawn registry/team/TL/pane/terminal sequence for `fork_wave` when the
/// spawn effect phase returned ok and at least one leaf was spawned. Preserves
/// ordering and defaults (including `resolve_zellij_pane_id` capture) from the
/// prior inline `ToolRequest::ForkWave` arm.
pub async fn interpret_fork_wave_post_spawn(
  fork_wave_args : ForkWaveArgs,
  spawn_plan : ForkWaveSpawnPlan,
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry?,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let resolved_pane_ids : Array[(String, String)] = []
  match registry {
    Some(reg) =>
      for spec in spawn_plan.spawned_specs {
        ignore(
          reg.upsert(
            fork_wave_spawned_registry_agent(spec, project_dir, session),
          ),
        )
      }
    None => ()
  }
  for slug in spawn_plan.spawned_slugs {
    let _ = @workspace.register_team_member(
      fork_wave_args.caller_id,
      slug,
      @config.agent_type_to_string(fork_wave_args.agent_type),
    )
    let tl_effects = @phase.plan_tl_event_for_scope(
      project_dir,
      fork_wave_args.caller_id,
      @phase.TLEvent::ChildSpawned(child_id=slug),
      registry~,
    )
    @phase.interpret_lifecycle_effects(project_dir, tl_effects, registry~)
    let agent_id = @workspace.branch_name(fork_wave_args.parent_branch, slug)
    match resolve_zellij_pane_id(session, slug, capture~) {
      Some(pane_id) => resolved_pane_ids.push((agent_id, pane_id))
      None => ()
    }
  }
  match registry {
    Some(reg) =>
      for pair in resolved_pane_ids {
        let (agent_id, pane_id) = pair
        try {
          let agent = reg.get(agent_id)
          let target = @workspace.zellij_pane_target(session, pane_id)
          ignore(reg.upsert({ ..agent, terminal_target: Some(target) }))
        } catch {
          _ => ()
        }
      }
    None => ()
  }
}
