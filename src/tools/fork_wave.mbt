///|
pub fn fork_wave_leaf_task_with_review_context(
  base_task : String,
  review_context : String?,
) -> String {
  match review_context {
    None => base_task
    Some(rc) => {
      let t = rc.trim().to_owned()
      if t == "" {
        base_task
      } else {
        base_task + "\n\n## CHOIR_REVIEW_CONTEXT\n" + t + "\n"
      }
    }
  }
}

///|
pub fn agy_binary_unavailable_message() -> String {
  "agy binary not found or not executable on PATH; Gemini provider requires the agy CLI binary. The Antigravity IDE / antigravity binary is not supported."
}

///|
pub async fn ensure_agy_binary_available(
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, String] {
  let (code, _) = capture({ program: "agy", args: ["--help"], workdir: None })
  if code == 0 {
    Ok(())
  } else {
    Err(agy_binary_unavailable_message())
  }
}

///|
fn empty_fork_wave_spawn_plan() -> ForkWaveSpawnPlan {
  {
    cmds: [],
    spawn_launch_bindings: [],
    spawned_specs: [],
    spawned_slugs: [],
    spawned_count: 0,
    skipped_count: 0,
    agent_ids: "",
    skipped_ids: "",
  }
}

///|
fn record_fork_wave_spawn_credentials(
  registry : @registry.AgentRegistry?,
  spawned_specs : Array[@types.SpawnSpec],
  agent_tokens : Array[String],
) -> Unit {
  match registry {
    Some(_) =>
      for i = 0; i < spawned_specs.length(); i = i + 1 {
        if i >= agent_tokens.length() {
          continue
        }
        let spec = spawned_specs[i]
        record_spawn_credential_for_agent(
          registry,
          @workspace.canonical_agent_id(spec),
          spec.role,
          agent_tokens[i],
        )
      }
    None => ()
  }
}

///|
fn fork_wave_launched_agent_ids(
  bindings : Array[SpawnLaunchCommandBinding],
  statuses : Array[Int],
) -> Map[String, Bool] {
  let launched : Map[String, Bool] = {}
  for binding in bindings {
    if binding.command_index >= 0 &&
      binding.command_index < statuses.length() &&
      statuses[binding.command_index] == 0 {
      launched.set(binding.agent_id, true)
    }
  }
  launched
}

///|
fn remove_fork_wave_unlaunched_spawn_credentials(
  registry : @registry.AgentRegistry?,
  spawned_specs : Array[@types.SpawnSpec],
  launched_agent_ids : Map[String, Bool],
) -> Unit {
  match registry {
    Some(_) =>
      for spec in spawned_specs {
        let agent_id = @workspace.canonical_agent_id(spec)
        if !launched_agent_ids.get(agent_id).unwrap_or(false) {
          remove_spawn_credential_for_agent(registry, agent_id)
        }
      }
    None => ()
  }
}

///|
fn fork_wave_test_args(child_role : @types.Role) -> ForkWaveArgs {
  {
    count: 1,
    tasks: ["t"],
    task_contracts: [
      {
        ..@types.TaskContract::empty(),
        goal: "t",
        verify: ["moon test --target native"],
      },
    ],
    has_per_leaf_tasks: false,
    parent_branch: "main",
    caller_id: "main.tl",
    slug_prefix: "leaf",
    agent_type: @types.AgentType::Codex,
    child_role,
    parent_session_id: None,
    review_context: None,
    automerge: None,
    review_mode: None,
    merge_strategy: None,
    model: None,
    depends_on: [],
    scaffold_commit: None,
  }
}

///|
fn fork_wave_test_commands_contain(
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
test "fork_wave spawn plan exports and records authoritative credential role" {
  let reg = @registry.AgentRegistry::new()
  let args = fork_wave_test_args(@types.Role::TL)
  let plan = fork_wave_spawn_plan(args, 1, Some(reg), "/repo", "sess", agent_tokens=[
    "fork-token-a",
  ])
  assert_true(fork_wave_test_commands_contain(plan.cmds, "CHOIR_AGENT_TOKEN"))
  assert_true(fork_wave_test_commands_contain(plan.cmds, "fork-token-a"))
  record_fork_wave_spawn_credentials(Some(reg), plan.spawned_specs, [
    "fork-token-a",
  ])
  let agent_id = @workspace.canonical_agent_id(plan.spawned_specs[0])
  match reg.credential_for_agent(agent_id) {
    Some(credential) => {
      assert_eq(credential.role, @types.Role::TL)
      assert_eq(credential.token, "fork-token-a")
    }
    None => fail("expected fork_wave spawn credential")
  }
}

///|
async test "fork_wave partial spawn failure preserves launched child credential" {
  let reg = @registry.AgentRegistry::new()
  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    let statuses : Array[Int] = []
    for _ in cmds {
      statuses.push(0)
    }
    statuses
  }
  let launch_count : Array[Int] = [0]
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if spawn_launch_command_is_observable(cmd) {
      launch_count[0] = launch_count[0] + 1
      if launch_count[0] == 1 {
        return (0, "")
      }
      return (27, "second launch failed")
    }
    (0, "")
  }
  let git_capture = async fn(
    _program : String,
    _args : Array[String],
  ) -> String {
    @async.sleep(0)
    ""
  }
  let mint_agent_token = async fn() -> Result[String, @types.ChoirError] {
    @async.sleep(0)
    Ok("fork-token-fail")
  }
  let (resp, _, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
    {
      ..fork_wave_test_args(@types.Role::Dev),
      count: 2,
      tasks: ["a", "b"],
      task_contracts: [
        { ..@types.TaskContract::empty(), goal: "a", verify: ["true"] },
        { ..@types.TaskContract::empty(), goal: "b", verify: ["true"] },
      ],
      parent_branch: "feature/parent",
    },
    "/repo",
    "sess",
    Some(reg),
    capture,
    git_capture,
    runner,
    mint_agent_token=Some(mint_agent_token),
    read_file=fn(_) { "" },
  )
  match resp {
    @types.Response::Err(_) => ()
    @types.Response::Ok(_) => fail("expected fork_wave spawn failure")
  }
  assert_eq(spawn_plan.spawned_count, 2)
  assert_eq(launch_count[0], 2)
  let first_agent_id = @workspace.canonical_agent_id(
    spawn_plan.spawned_specs[0],
  )
  let second_agent_id = @workspace.canonical_agent_id(
    spawn_plan.spawned_specs[1],
  )
  match reg.credential_for_agent(first_agent_id) {
    Some(credential) => assert_eq(credential.token, "fork-token-fail")
    None => fail("expected launched child credential to be preserved")
  }
  @debug.assert_eq(reg.credential_for_agent(second_agent_id), None)
}

///|
fn fork_wave_verify_has_nonempty_command(commands : Array[String]) -> Bool {
  for command in commands {
    if command.trim() != "" {
      return true
    }
  }
  false
}

///|
pub let fork_wave_choir_lint_verify_command : String = "moon run src/bin/choir_lint --target native"

///|
fn fork_wave_segment_starts_choir_lint_run(segment : String) -> Bool {
  let prefix = "moon run src/bin/choir_lint"
  let trimmed = segment.trim().to_owned()
  trimmed == prefix || trimmed.has_prefix(prefix + " ")
}

///|
fn fork_wave_verify_has_choir_lint_command(commands : Array[String]) -> Bool {
  for command in commands {
    let tokens = tdd_command_tokens(command)
    let mut segment = ""
    for token in tokens {
      if tdd_token_is_shell_separator(token) {
        if fork_wave_segment_starts_choir_lint_run(segment) {
          return true
        }
        segment = ""
      } else {
        segment = if segment == "" { token } else { segment + " " + token }
      }
    }
    if fork_wave_segment_starts_choir_lint_run(segment) {
      return true
    }
  }
  false
}

///|
fn fork_wave_verify_with_choir_lint(commands : Array[String]) -> Array[String] {
  let verify : Array[String] = []
  for command in commands {
    verify.push(command)
  }
  verify.push(fork_wave_choir_lint_verify_command)
  verify
}

///|
pub fn fork_wave_task_contract_with_verify_default(
  task_contract : @types.TaskContract,
  project_verify_cmd? : String? = None,
  choir_lint_available? : Bool = false,
) -> @types.TaskContract {
  let with_project_verify = if fork_wave_verify_has_nonempty_command(
      task_contract.verify,
    ) {
    task_contract
  } else {
    match project_verify_cmd {
      Some(command) => {
        let trimmed = command.trim().to_owned()
        if trimmed == "" {
          task_contract
        } else {
          { ..task_contract, verify: [trimmed] }
        }
      }
      None => task_contract
    }
  }
  if !choir_lint_available ||
    !fork_wave_verify_has_nonempty_command(with_project_verify.verify) ||
    fork_wave_verify_has_choir_lint_command(with_project_verify.verify) {
    with_project_verify
  } else {
    {
      ..with_project_verify,
      verify: fork_wave_verify_with_choir_lint(with_project_verify.verify),
    }
  }
}

///|
pub fn fork_wave_validate_resolved_task_contracts(
  fork_wave_args : ForkWaveArgs,
  wave_id? : String? = None,
) -> Result[Unit, @types.ChoirError] {
  if fork_wave_args.count > fork_wave_args.tasks.length() {
    return Err(
      @types.ChoirError::validation_error(
        "fork_wave refused to spawn: task count " +
        fork_wave_args.count.to_string() +
        " exceeds resolved tasks length " +
        fork_wave_args.tasks.length().to_string(),
      ),
    )
  }
  if fork_wave_args.count > fork_wave_args.task_contracts.length() {
    return Err(
      @types.ChoirError::validation_error(
        "fork_wave refused to spawn: task count " +
        fork_wave_args.count.to_string() +
        " exceeds resolved task_contracts length " +
        fork_wave_args.task_contracts.length().to_string(),
      ),
    )
  }
  if fork_wave_args.child_role != @types.Role::Dev {
    return Ok(())
  }
  let seen_slugs : Map[String, Int] = {}
  for i = 0; i < fork_wave_args.count; i = i + 1 {
    if i >= fork_wave_args.task_contracts.length() ||
      !fork_wave_verify_has_nonempty_command(
        fork_wave_args.task_contracts[i].verify,
      ) {
      let slug = fork_wave_slug_for_index(
        fork_wave_args, i, seen_slugs, wave_id,
      )
      let agent_id = fork_wave_args.parent_branch + "." + slug
      return Err(
        @types.ChoirError::validation_error(
          "fork_wave refused to spawn leaf " +
          i.to_string() +
          " (" +
          agent_id +
          "): resolved task contract has no verify command. Pass a wave-level `verify` command, include `verify` in that leaf's task_contract, or set [project].verify_cmd in .choir/config.toml before spawning.",
        ),
      )
    }
  }
  Ok(())
}

///|
fn fork_wave_slug_for_index(
  fork_wave_args : ForkWaveArgs,
  index : Int,
  seen_slugs : Map[String, Int],
  wave_id : String?,
) -> String {
  let flat_prefix = flat_slug_prefix(fork_wave_args.slug_prefix)
  let wave_discriminator = fork_wave_discriminator(flat_prefix, wave_id)
  let raw_slug = if fork_wave_args.has_per_leaf_tasks {
    let task_slug = slugify_task(fork_wave_args.tasks[index], index)
    let human_slug = if flat_prefix == "wave" {
      task_slug
    } else {
      flat_prefix + "-" + task_slug
    }
    match wave_discriminator {
      Some(discriminator) => human_slug + "-" + discriminator
      None => human_slug
    }
  } else {
    match wave_discriminator {
      Some(discriminator) =>
        flat_prefix + "-" + discriminator + "-" + index.to_string()
      None => flat_prefix + "-" + index.to_string()
    }
  }
  // Disambiguate against previously EMITTED slugs (the map keys), not just the
  // raw slug, so a later leaf whose raw slug equals an earlier leaf's
  // disambiguated slug (e.g. tasks ["a b", "a b", "a b 1"]) still receives a
  // unique final slug instead of silently colliding branches/worktrees/tabs.
  let mut candidate = raw_slug
  let mut suffix = index
  for ;; {
    match seen_slugs.get(candidate) {
      None => break
      Some(_) => {
        candidate = raw_slug + "-" + suffix.to_string()
        suffix = suffix + 1
      }
    }
  }
  seen_slugs.set(candidate, 1)
  candidate
}

///|
fn fork_wave_discriminator(flat_prefix : String, wave_id : String?) -> String? {
  match wave_id {
    None => None
    Some(id) => {
      if id == "" {
        return None
      }
      let redundant_prefix = flat_prefix + "-"
      if id.has_prefix(redundant_prefix) &&
        id.length() > redundant_prefix.length() {
        Some(id[redundant_prefix.length():id.length()].to_owned())
      } else {
        Some(id)
      }
    }
  }
}

///|
fn ensure_fork_wave_spawn_ids_do_not_collide(
  fork_wave_args : ForkWaveArgs,
  registry : @registry.AgentRegistry?,
  wave_id? : String? = None,
) -> Result[Unit, @types.ChoirError] {
  match registry {
    None => Ok(())
    Some(_) => {
      let seen_slugs : Map[String, Int] = {}
      for i = 0; i < fork_wave_args.count; i = i + 1 {
        let slug = fork_wave_slug_for_index(
          fork_wave_args, i, seen_slugs, wave_id,
        )
        let agent_id = fork_wave_args.parent_branch + "." + slug
        match
          ensure_no_live_spawn_agent_collision("fork_wave", agent_id, registry) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      Ok(())
    }
  }
}

///|
/// Build [`ForkWaveSpawnPlan`] from resolved tool args and `child_spawn_depth`.
/// Uses `slugify_task` for per-leaf slugs. Live registry collision rejection
/// happens before planning in `interpret_fork_wave_spawn_effect_phase`; terminal
/// registry rows are reusable and do not affect the plan.
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
  agent_tokens? : Array[String] = [],
  project_config_content? : String = "",
) -> ForkWaveSpawnPlan {
  ignore(registry)
  let agent_ids = StringBuilder::new()
  let cmds : Array[@workspace.Command] = []
  let spawn_launch_bindings : Array[SpawnLaunchCommandBinding] = []
  let spawned_specs : Array[@types.SpawnSpec] = []
  let spawned_slugs : Array[String] = []
  let mut spawned_count = 0
  let seen_slugs : Map[String, Int] = {}
  let model = @workspace.resolve_agent_model_from_config_content(
    project_config_content,
    fork_wave_args.agent_type,
    fork_wave_args.child_role,
    fork_wave_args.model,
  )
  for i = 0; i < fork_wave_args.count; i = i + 1 {
    let slug = fork_wave_slug_for_index(fork_wave_args, i, seen_slugs, wave_id)
    let agent_id = fork_wave_args.parent_branch + "." + slug
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
      merge_strategy: fork_wave_args.merge_strategy,
      wave_id,
    }
    spawned_specs.push(spec)
    let agent_token = if i < agent_tokens.length() {
      Some(agent_tokens[i])
    } else {
      None
    }
    let leaf_cmds = @workspace.spawn_commands(
      spec,
      project_dir,
      session,
      parent_session_id=fork_wave_args.parent_session_id,
      extra_mcp_servers_json~,
      shell_command~,
      listen_uds~,
      listen_tcp~,
      tcp_auth_token~,
      agent_token~,
      project_config_content~,
      model~,
    )
    for
      binding in spawn_launch_command_bindings_for_agent(
        agent_id,
        cmds.length(),
        leaf_cmds,
      ) {
      spawn_launch_bindings.push(binding)
    }
    for cmd in leaf_cmds {
      cmds.push(cmd)
    }
  }
  {
    cmds,
    spawn_launch_bindings,
    spawned_specs,
    spawned_slugs,
    spawned_count,
    skipped_count: 0,
    agent_ids: agent_ids.to_string(),
    skipped_ids: "",
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
pub fn fork_wave_missing_beads_policy_warning(
  fork_wave_args : ForkWaveArgs,
) -> String? {
  let requires_beads = fork_wave_args.count > 1 ||
    fork_wave_args.parent_branch.has_prefix("feature/")
  if !requires_beads {
    return None
  }
  let missing : Array[String] = []
  for i = 0; i < fork_wave_args.count; i = i + 1 {
    let missing_issue = if i < fork_wave_args.task_contracts.length() {
      fork_wave_args.task_contracts[i].beads_issue_id is None
    } else {
      true
    }
    if missing_issue {
      missing.push("leaf " + (i + 1).to_string())
    }
  }
  if missing.length() == 0 {
    return None
  }
  let scope = if fork_wave_args.parent_branch.has_prefix("feature/") {
    "feature-branch fork_wave"
  } else {
    "multi-leaf fork_wave"
  }
  Some(
    "beads policy warning: " +
    scope +
    " is missing beads_issue_id for " +
    missing.join(", ") +
    ". Create child Beads issues first and pass per-leaf task_contracts=[{\"beads_issue_id\":\"<child-id>\"}, ...].",
  )
}

///|
pub fn fork_wave_response_with_beads_policy_warning(
  resp : @types.Response,
  fork_wave_args : ForkWaveArgs,
) -> @types.Response {
  match fork_wave_missing_beads_policy_warning(fork_wave_args) {
    Some(warning) => resp.with_warning(warning)
    None => resp
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
  cmds? : Array[@workspace.Command] = [],
  captured_outputs? : Map[Int, String] = {},
) -> @types.Response {
  match interpret_result {
    Ok(r) => r
    Err(CommandFailed(status~, failing_cmd~)) => {
      let detail = match failing_cmd {
        Some(cmd) =>
          match captured_output_for_command(cmd, cmds, captured_outputs) {
            Some(output) => output.trim().to_owned()
            None => {
              let (_, output) = capture_output(cmd)
              output.trim().to_owned()
            }
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
    Err(ScaffoldCommandFailed(status~, failing_cmd~)) => {
      // Do NOT re-run the failing scaffold command to capture its output:
      // `git add` / `git commit` / `git push` are side-effectful and a
      // second run could succeed (leaving the repo mutated unexpectedly)
      // OR multiply state (extra commit/push). Report the failing argv
      // and exit status without re-execution; the operator can inspect
      // the repo state directly.
      let argv_detail = match failing_cmd {
        Some(cmd) => " (argv: " + cmd.program + " " + cmd.args.join(" ") + ")"
        None => ""
      }
      @types.Response::Err(
        "scaffold_commit command failed with status " +
        status.to_string() +
        argv_detail,
      )
    }
    Err(
      ScaffoldCompensationFailed(
        pre_scaffold_sha~,
        original_error~,
        status~,
        failing_cmd~
      )
    ) => {
      let argv_detail = match failing_cmd {
        Some(cmd) => " (argv: " + cmd.program + " " + cmd.args.join(" ") + ")"
        None => ""
      }
      @types.Response::Err(
        ScaffoldCompensationFailed(
          pre_scaffold_sha~,
          original_error~,
          status~,
          failing_cmd~,
        ).message() +
        argv_detail,
      )
    }
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
fn captured_output_for_command(
  cmd : @workspace.Command,
  cmds : Array[@workspace.Command],
  captured_outputs : Map[Int, String],
) -> String? {
  for i = 0; i < cmds.length(); i = i + 1 {
    if same_command(cmds[i], cmd) {
      match captured_outputs.get(i) {
        Some(output) => return Some(output)
        None => ()
      }
    }
  }
  None
}

///|
fn fork_wave_response_with_spawn_metadata(
  resp : @types.Response,
  spawned_specs : Array[@types.SpawnSpec],
) -> @types.Response {
  if spawned_specs.length() == 0 {
    return resp
  }
  match resp {
    @types.Response::Ok(fields) => {
      let values = fields.to_json_map()
      let agents : Array[Json] = []
      for spec in spawned_specs {
        agents.push(
          spawn_response_agent_json(
            @workspace.canonical_agent_id(spec),
            spec.role,
            spec.agent_type,
            task_contract_beads_issue_id(spec.task_contract),
          ),
        )
      }
      let first = spawned_specs[0]
      values.set("role", String::to_json(first.role.to_wire_string()))
      values.set(
        "agent_type",
        String::to_json(first.agent_type.to_wire_string()),
      )
      if spawned_specs.length() == 1 {
        values.set(
          "beads_issue_id",
          optional_response_string_json(
            task_contract_beads_issue_id(first.task_contract),
          ),
        )
      }
      values.set("agents", agents.to_json())
      @types.Response::ok_values(values)
    }
    _ => resp
  }
}

///|
fn same_optional_workdir(left : String?, right : String?) -> Bool {
  match (left, right) {
    (None, None) => true
    (Some(a), Some(b)) => a == b
    _ => false
  }
}

///|
fn same_command(left : @workspace.Command, right : @workspace.Command) -> Bool {
  left.program == right.program &&
  left.args == right.args &&
  same_optional_workdir(left.workdir, right.workdir)
}

///|
fn same_command_array(
  left : Array[@workspace.Command],
  right : Array[@workspace.Command],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i = 0; i < left.length(); i = i + 1 {
    if !same_command(left[i], right[i]) {
      return false
    }
  }
  true
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
  read_file? : (String) -> String = @sys.read_file,
  mint_agent_token? : (async () -> Result[String, @types.ChoirError])? = None,
  record_spawn_launch_diagnostic? : (SpawnLaunchDiagnostic) -> Unit = fn(_) {
    ()
  },
) -> (@types.Response, ForkWaveArgs, ForkWaveSpawnPlan) {
  let fork_wave_args = fork_wave_resolve_args_parent_branch(
    fork_wave_args, project_dir, capture,
  )
  match
    ensure_fork_wave_spawn_ids_do_not_collide(
      fork_wave_args,
      registry,
      wave_id~,
    ) {
    Ok(_) => ()
    Err(e) =>
      return (
        @types.Response::Err(e.message()),
        fork_wave_args,
        empty_fork_wave_spawn_plan(),
      )
  }
  let caller_spawn_depth = fork_wave_caller_spawn_depth_from_registry(
    registry,
    fork_wave_args.caller_id,
  )
  let child_spawn_depth = fork_wave_child_spawn_depth(
    caller_spawn_depth,
    fork_wave_args.child_role,
  )
  match fork_wave_validate_resolved_task_contracts(fork_wave_args, wave_id~) {
    Ok(_) => ()
    Err(e) =>
      return (
        @types.Response::Err(e.message()),
        fork_wave_args,
        empty_fork_wave_spawn_plan(),
      )
  }
  let agent_tokens : Array[String] = []
  for _i = 0; _i < fork_wave_args.count; _i = _i + 1 {
    match mint_spawn_agent_token(capture, mint_agent_token) {
      Ok(token) => agent_tokens.push(token)
      Err(e) =>
        return (
          @types.Response::Err(e.message()),
          fork_wave_args,
          empty_fork_wave_spawn_plan(),
        )
    }
  }

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
    agent_tokens~,
    project_config_content=read_project_config_toml(project_dir, read_file~),
  )
  let mut seed_warning : String? = None
  if fork_wave_args.agent_type == @types.AgentType::Gemini &&
    spawn_plan.spawned_count > 0 {
    match ensure_agy_binary_available(capture) {
      Ok(_) => ()
      Err(msg) =>
        return (
          @types.Response::Err(msg),
          fork_wave_args,
          empty_fork_wave_spawn_plan(),
        )
    }
    seed_warning = run_spawn_agy_seed_if_needed(
      fork_wave_args.agent_type,
      project_dir,
      runner,
      capture,
    )
  }
  record_fork_wave_spawn_credentials(
    registry,
    spawn_plan.spawned_specs,
    agent_tokens,
  )
  let plan = fork_wave_plan(
    project_dir,
    spawn_plan.cmds,
    spawn_plan.spawned_count,
    spawn_plan.skipped_count,
    spawn_plan.agent_ids,
    spawn_plan.skipped_ids,
    scaffold_commit=fork_wave_args.scaffold_commit,
    parent_branch=fork_wave_args.parent_branch,
  )
  let spawn_launch_captured_outputs : Map[Int, String] = {}
  let spawn_launch_statuses : Array[Int] = []
  let spawn_runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    @async.sleep(0)
    if !same_command_array(cmds, spawn_plan.cmds) {
      return runner(cmds)
    }
    let (statuses, captured_outputs) = run_commands_with_spawn_launch_capture(
      spawn_plan.spawn_launch_bindings,
      cmds,
      runner,
      capture,
      record_spawn_launch_diagnostic,
    )
    for status in statuses {
      spawn_launch_statuses.push(status)
    }
    for index, output in captured_outputs {
      spawn_launch_captured_outputs.set(index, output)
    }
    statuses
  }
  let interpret_result = interpret(plan, git_capture~, runner=spawn_runner)
  let resp = fork_wave_response_from_interpret_result(
    interpret_result,
    capture,
    cmds=spawn_plan.cmds,
    captured_outputs=spawn_launch_captured_outputs,
  )
  if !resp.is_ok() {
    remove_fork_wave_unlaunched_spawn_credentials(
      registry,
      spawn_plan.spawned_specs,
      fork_wave_launched_agent_ids(
        spawn_plan.spawn_launch_bindings,
        spawn_launch_statuses,
      ),
    )
  }
  match wave_id {
    Some(id) =>
      if resp.is_ok() && spawn_plan.spawned_count > 0 {
        let baseline_sha = fork_wave_capture_baseline_sha(
          project_dir,
          fork_wave_args.parent_branch,
          git_capture,
        )
        if baseline_sha != "" {
          ignore(record_wave_baseline_sha(project_dir, id, baseline_sha))
        }
      }
    None => ()
  }
  let resp = fork_wave_response_with_beads_policy_warning(
    fork_wave_response_with_spawn_metadata(resp, spawn_plan.spawned_specs),
    fork_wave_args,
  )
  let resp = match seed_warning {
    Some(warning) => resp.with_warning(warning)
    None => resp
  }
  (resp, fork_wave_args, spawn_plan)
}

///|
fn split_spawned_agent_ids(agent_ids : String) -> Array[String] {
  let out : Array[String] = []
  for part in agent_ids.split(",") {
    let trimmed = part.trim().to_owned()
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
pub impl Show for ForkWavePostSpawnHostStep with fn output(self, logger) -> Unit {
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
/// ordering and defaults (including `resolve_zellij_tab_terminal_target` capture) from the
/// prior inline `ToolRequest::ForkWave` arm.
pub async fn interpret_fork_wave_post_spawn(
  fork_wave_args : ForkWaveArgs,
  spawn_plan : ForkWaveSpawnPlan,
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry?,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  record_task_contract? : (String, @types.TaskContract?) -> Unit = fn(
    _agent_id,
    _contract,
  ) {
    ()
  },
) -> Unit {
  let resolved_pane_ids : Array[(String, String)] = []
  let live_collision_ids : Map[String, Bool] = {}
  match registry {
    Some(reg) =>
      for spec in spawn_plan.spawned_specs {
        let agent_id = @workspace.canonical_agent_id(spec)
        match
          ensure_no_live_spawn_agent_collision("fork_wave", agent_id, registry) {
          Ok(_) => ()
          Err(_) => {
            live_collision_ids.set(agent_id, true)
            continue
          }
        }
        ignore(
          reg.upsert(
            fork_wave_spawned_registry_agent(spec, project_dir, session),
          ),
        )
        record_task_contract(agent_id, spec.task_contract)
      }
    None => ()
  }
  for spec in spawn_plan.spawned_specs {
    let agent_id = @workspace.canonical_agent_id(spec)
    let slug = spec.slug
    match live_collision_ids.get(agent_id) {
      Some(true) => continue
      _ => ()
    }
    let _ = @workspace.register_team_member(
      fork_wave_args.caller_id,
      slug,
      @config.agent_type_to_string(fork_wave_args.agent_type),
    )
    let tl_effects = @phase.plan_tl_event_for_scope(
      project_dir,
      fork_wave_args.caller_id,
      @phase.TLEvent::ChildSpawned(
        child_id=agent_id,
        agent_type=fork_wave_args.agent_type,
      ),
      registry~,
    )
    @phase.interpret_lifecycle_effects(project_dir, tl_effects, registry~)
    match resolve_zellij_tab_terminal_target(session, slug, capture~) {
      Some(pane_id) => resolved_pane_ids.push((agent_id, pane_id))
      None =>
        @moontrace.warn(
          "spawned leaf produced no resolvable zellij tab/pane after launch; likely causes: zellij new-tab no-op / immediate agent exit",
          fields=[
            @moontrace.field("event", "spawn_no_zellij_tab"),
            @moontrace.field("agent_id", agent_id),
            @moontrace.field("slug", slug),
            @moontrace.field("session", session),
          ],
        )
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
  for spec in spawn_plan.spawned_specs {
    let agent_id = @workspace.canonical_agent_id(spec)
    match live_collision_ids.get(agent_id) {
      Some(true) => continue
      _ => ()
    }
    ignore(mirror_beads_spawn_for_spec(project_dir, spec, capture))
  }
}
