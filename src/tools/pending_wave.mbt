///|
/// Persistent record for a `fork_wave` deferred until its `depends_on` agents
/// merge. Stored at `.choir/kv/pending-wave--<wave_id>` until either the deps
/// resolve (spawn + delete) or one fails (delete + write `failed-wave--<id>`).
pub(all) struct PendingWave {
  wave_id : String
  args : ForkWaveArgs
} derive(Debug, Eq)

///|
pub impl Show for PendingWave with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn pending_wave_kv_key(wave_id : String) -> String {
  "pending-wave--" + wave_id
}

///|
pub fn failed_wave_kv_key(wave_id : String) -> String {
  "failed-wave--" + wave_id
}

///|
pub fn pending_wave_kv_path(project_dir : String, wave_id : String) -> String {
  project_dir + "/.choir/kv/" + pending_wave_kv_key(wave_id)
}

///|
pub fn failed_wave_kv_path(project_dir : String, wave_id : String) -> String {
  project_dir + "/.choir/kv/" + failed_wave_kv_key(wave_id)
}

///|
/// Build the deterministic base of a pending wave id.
///
/// `now_ticks` should be `@env.now().reinterpret_as_int64()` — the high
/// resolution clock; second-resolution would collide if the same TL fired
/// two `fork_wave` calls with the same `slug_prefix` within one second.
/// `pid` differentiates servers if two run on the same host.
///
/// Even at this resolution, a same-process loop could in principle still
/// collide; `allocate_pending_wave_id` resolves that by probing the KV
/// directory and adding a counter suffix on collision.
pub fn generate_pending_wave_id(
  slug_prefix : String,
  now_ticks : Int64,
  pid : Int,
) -> String {
  slug_prefix + "-" + now_ticks.to_string() + "-" + pid.to_string()
}

///|
/// Generate a wave id whose `pending-wave--<id>` file does not yet exist.
/// Probes `pending_wave_kv_path` and appends an integer suffix until the
/// path is free, so concurrent or fast-fire `fork_wave` calls cannot
/// overwrite an existing pending entry. Bounded retry — gives up after
/// `max_attempts` and falls back to the suffixed candidate (existence
/// would still mean the call site loses the race, which is preferable to
/// looping forever).
pub fn allocate_pending_wave_id(
  project_dir : String,
  slug_prefix : String,
  now_ticks : Int64,
  pid : Int,
  max_attempts? : Int = 1000,
) -> String {
  let base = generate_pending_wave_id(slug_prefix, now_ticks, pid)
  if !@sys.path_entry_exists(pending_wave_kv_path(project_dir, base)) {
    return base
  }
  let mut suffix = 1
  while suffix < max_attempts {
    let candidate = base + "-" + suffix.to_string()
    if !@sys.path_entry_exists(pending_wave_kv_path(project_dir, candidate)) {
      return candidate
    }
    suffix = suffix + 1
  }
  base + "-" + suffix.to_string()
}

///|
fn json_optional_string(value : String?) -> Json {
  match value {
    Some(s) => s.to_json()
    None => ().to_json()
  }
}

///|
fn json_optional_bool(value : Bool?) -> Json {
  match value {
    Some(b) => b.to_json()
    None => ().to_json()
  }
}

///|
fn json_optional_review_mode(value : @types.ReviewMode?) -> Json {
  match value {
    Some(m) => m.to_wire_string().to_json()
    None => ().to_json()
  }
}

///|
/// Serialize [`ForkWaveArgs`] to a JSON object keyed by field name. Enums use
/// their `to_wire_string` form; optionals use `null`. The shape is intentionally
/// stable across server restarts.
pub fn fork_wave_args_to_json(args : ForkWaveArgs) -> Json {
  let task_contracts_json : Array[Json] = []
  for tc in args.task_contracts {
    task_contracts_json.push(tc.to_json())
  }
  let map : Map[String, Json] = {
    "count": args.count.to_json(),
    "tasks": args.tasks.to_json(),
    "task_contracts": task_contracts_json.to_json(),
    "has_per_leaf_tasks": args.has_per_leaf_tasks.to_json(),
    "parent_branch": args.parent_branch.to_json(),
    "caller_id": args.caller_id.to_json(),
    "slug_prefix": args.slug_prefix.to_json(),
    "agent_type": args.agent_type.to_wire_string().to_json(),
    "child_role": args.child_role.to_wire_string().to_json(),
    "parent_session_id": json_optional_string(args.parent_session_id),
    "review_context": json_optional_string(args.review_context),
    "automerge": json_optional_bool(args.automerge),
    "review_mode": json_optional_review_mode(args.review_mode),
    "depends_on": args.depends_on.to_json(),
  }
  map.to_json()
}

///|
fn parse_json_string_array(value : Json?) -> Array[String] {
  match value {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
fn parse_json_optional_string(value : Json?) -> String? {
  match value {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn parse_json_optional_bool(value : Json?) -> Bool? {
  match value {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn parse_task_contract_json(j : Json) -> @types.TaskContract {
  let tc : @types.TaskContract = @json.from_json(j) catch {
    _ => return @types.TaskContract::empty()
  }
  tc
}

///|
fn parse_fork_wave_args_json(j : Json) -> ForkWaveArgs? {
  let obj = match j {
    Object(m) => m
    _ => return None
  }
  let count = match obj.get("count") {
    Some(Number(n, ..)) => n.to_int()
    _ => return None
  }
  let tasks = parse_json_string_array(obj.get("tasks"))
  let task_contracts : Array[@types.TaskContract] = []
  match obj.get("task_contracts") {
    Some(Array(items)) =>
      for item in items {
        task_contracts.push(parse_task_contract_json(item))
      }
    _ => ()
  }
  let has_per_leaf_tasks = match obj.get("has_per_leaf_tasks") {
    Some(True) => true
    _ => false
  }
  let parent_branch = match
    parse_json_optional_string(obj.get("parent_branch")) {
    Some(s) => s
    None => return None
  }
  let caller_id = match parse_json_optional_string(obj.get("caller_id")) {
    Some(s) => s
    None => return None
  }
  let slug_prefix = match parse_json_optional_string(obj.get("slug_prefix")) {
    Some(s) => s
    None => return None
  }
  let agent_type = match parse_json_optional_string(obj.get("agent_type")) {
    Some(s) =>
      match @types.AgentType::try_parse_wire(s) {
        Ok(t) => t
        Err(_) => return None
      }
    None => return None
  }
  let child_role = match parse_json_optional_string(obj.get("child_role")) {
    Some(s) =>
      match @types.Role::try_parse_wire(s) {
        Ok(r) => r
        Err(_) => return None
      }
    None => return None
  }
  let parent_session_id = parse_json_optional_string(
    obj.get("parent_session_id"),
  )
  let review_context = parse_json_optional_string(obj.get("review_context"))
  let automerge = parse_json_optional_bool(obj.get("automerge"))
  let review_mode = match parse_json_optional_string(obj.get("review_mode")) {
    Some(s) =>
      match @config.parse_review_mode(s) {
        Ok(m) => Some(m)
        Err(_) => None
      }
    None => None
  }
  let depends_on = parse_json_string_array(obj.get("depends_on"))
  Some({
    count,
    tasks,
    task_contracts,
    has_per_leaf_tasks,
    parent_branch,
    caller_id,
    slug_prefix,
    agent_type,
    child_role,
    parent_session_id,
    review_context,
    automerge,
    review_mode,
    depends_on,
  })
}

///|
pub fn pending_wave_to_json_string(pw : PendingWave) -> String {
  let map : Map[String, Json] = {
    "wave_id": pw.wave_id.to_json(),
    "args": fork_wave_args_to_json(pw.args),
  }
  map.to_json().stringify()
}

///|
pub fn parse_pending_wave(content : String) -> PendingWave? {
  let json = @json.parse(content) catch { _ => return None }
  let obj = match json {
    Object(m) => m
    _ => return None
  }
  let wave_id = match parse_json_optional_string(obj.get("wave_id")) {
    Some(s) => s
    None => return None
  }
  let args_json = match obj.get("args") {
    Some(j) => j
    None => return None
  }
  match parse_fork_wave_args_json(args_json) {
    Some(args) => Some({ wave_id, args })
    None => None
  }
}

///|
pub fn write_pending_wave(project_dir : String, pw : PendingWave) -> Bool {
  @sys.write_file_atomic(
    pending_wave_kv_path(project_dir, pw.wave_id),
    pending_wave_to_json_string(pw),
  )
}

///|
pub fn delete_pending_wave(project_dir : String, wave_id : String) -> Unit {
  ignore(@sys.delete_file_sync(pending_wave_kv_path(project_dir, wave_id)))
}

///|
pub fn write_failed_wave_marker(
  project_dir : String,
  wave_id : String,
  reason : String,
) -> Bool {
  let map : Map[String, Json] = {
    "wave_id": wave_id.to_json(),
    "reason": reason.to_json(),
  }
  @sys.write_file_atomic(
    failed_wave_kv_path(project_dir, wave_id),
    map.to_json().stringify(),
  )
}

///|
/// Full paths of `.choir/kv/pending-wave--*` entries for `project_dir`.
pub fn list_pending_wave_paths(project_dir : String) -> Array[String] {
  let kv_dir = project_dir + "/.choir/kv"
  if !@sys.path_entry_exists(kv_dir) {
    return []
  }
  let out : Array[String] = []
  for name in @sys.list_dir(kv_dir) {
    if name.has_prefix("pending-wave--") {
      out.push(kv_dir + "/" + name)
    }
  }
  out
}

///|
pub fn read_pending_wave_from_path(path : String) -> PendingWave? {
  let content = @sys.read_file(path)
  if content == "" {
    return None
  }
  parse_pending_wave(content)
}

///|
pub fn read_pending_wave(
  project_dir : String,
  wave_id : String,
) -> PendingWave? {
  read_pending_wave_from_path(pending_wave_kv_path(project_dir, wave_id))
}

///|
pub fn read_all_pending_waves(project_dir : String) -> Array[PendingWave] {
  let out : Array[PendingWave] = []
  for path in list_pending_wave_paths(project_dir) {
    match read_pending_wave_from_path(path) {
      Some(pw) => out.push(pw)
      None => ()
    }
  }
  out
}

///|
/// Delete any `pending-wave--*` file whose contents do not parse as a
/// [`PendingWave`]. Such an orphan would otherwise keep the statusline
/// `⧗N` counter elevated (it counts by filename prefix) while never being
/// dispatched (the dispatcher filters by parse success). Empty files
/// — the partial-write or zero-byte case — are treated the same.
///
/// Returns the basenames of the files that were removed (handy for logs
/// and tests).
pub fn reap_unparseable_pending_waves(project_dir : String) -> Array[String] {
  let removed : Array[String] = []
  for path in list_pending_wave_paths(project_dir) {
    let content = @sys.read_file(path)
    let parseable = if content == "" {
      false
    } else {
      parse_pending_wave(content) is Some(_)
    }
    if !parseable {
      ignore(@sys.delete_file_sync(path))
      let basename = match path.rev_find("/") {
        Some(idx) => path[idx + 1:].to_string()
        None => path
      }
      @sys.write_stderr(
        "pending wave entry unparseable, removing: " + path + "\n",
      )
      removed.push(basename)
    }
  }
  removed
}

///|
/// Where a single dep stands relative to the pending wave that names it.
///
/// `Merged` — `Dev(Done(reason=Merged))`. The dep's PR is on the parent
///            branch and the wave is free to spawn (subject to other deps).
/// `Failed` — Dev workflow `Failed(_)` or `Done` with a non-`Merged` reason
///            (shutdown, rescue, recovered-done, etc.) — the dep is gone and
///            its PR will not land. Process-level `Failed(_)` also counts.
/// `Pending` — anything else, including missing lifecycle (not yet spawned).
pub(all) enum DepStatus {
  Merged
  Failed
  Pending
} derive(Debug, Eq)

///|
pub fn dep_status_for_lifecycle(lc : @phase.AgentLifecycle) -> DepStatus {
  match lc.workflow {
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::Done(reason=@phase.FinalizeReason::Merged)
    ) => DepStatus::Merged
    @phase.WorkflowState::Dev(@phase.DevLifecycle::Done(_)) => DepStatus::Failed
    @phase.WorkflowState::Dev(@phase.DevLifecycle::Failed(_)) =>
      DepStatus::Failed
    _ =>
      match lc.process {
        @phase.ProcessState::Failed(_) => DepStatus::Failed
        _ => DepStatus::Pending
      }
  }
}

///|
pub fn dep_status(project_dir : String, dep_id : String) -> DepStatus {
  match @phase.read_lifecycle(project_dir, dep_id) {
    None => DepStatus::Pending
    Some(lc) => dep_status_for_lifecycle(lc)
  }
}

///|
/// Aggregate evaluation of a pending wave against its deps:
///   - `ReadyToSpawn` — every dep is `Merged`.
///   - `FailedDep(dep_id)` — at least one dep is `Failed` (first match wins).
///   - `Wait` — at least one dep is still `Pending` and none failed.
pub(all) enum PendingWaveDecision {
  ReadyToSpawn
  FailedDep(String)
  Wait
} derive(Debug, Eq)

///|
pub impl Show for PendingWaveDecision with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn evaluate_pending_wave(
  project_dir : String,
  pw : PendingWave,
) -> PendingWaveDecision {
  let mut any_pending = false
  let mut failed_dep : String? = None
  for dep in pw.args.depends_on {
    if failed_dep is Some(_) {
      continue
    }
    match dep_status(project_dir, dep) {
      DepStatus::Merged => ()
      DepStatus::Failed => failed_dep = Some(dep)
      DepStatus::Pending => any_pending = true
    }
  }
  match failed_dep {
    Some(dep) => PendingWaveDecision::FailedDep(dep)
    None =>
      if any_pending {
        PendingWaveDecision::Wait
      } else {
        PendingWaveDecision::ReadyToSpawn
      }
  }
}

///|
/// A pending wave whose deps include `dep_id`. Used by `kill_agent` to
/// propagate failure when a dep is killed before its PR merges.
pub fn pending_waves_naming_dep(
  project_dir : String,
  dep_id : String,
) -> Array[PendingWave] {
  let out : Array[PendingWave] = []
  for pw in read_all_pending_waves(project_dir) {
    for dep in pw.args.depends_on {
      if dep == dep_id {
        out.push(pw)
        break
      }
    }
  }
  out
}

///|
/// Role of `dep_id` per KV state, preferring the registry (live truth) and
/// falling back to the on-disk lifecycle file. `None` means no record exists.
pub fn lookup_dep_role(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  dep_id : String,
) -> @types.Role? {
  match registry {
    Some(reg) =>
      try {
        return Some(reg.get(dep_id).role)
      } catch {
        _ => ()
      }
    None => ()
  }
  match @phase.read_lifecycle(project_dir, dep_id) {
    Some(lc) => Some(lc.role)
    None => None
  }
}

///|
/// Only `Dev` leaves own branches and file PRs, so only their
/// `Dev(Done(Merged))` signal can move a pending wave forward.
/// `dep_status_for_lifecycle` pattern-matches exclusively on
/// `WorkflowState::Dev(_)` — every other role (`TL`, `Root`, `Worker`) falls
/// through to `Pending` forever with no watchdog, no retry bound. Reject them
/// all at validation time so the config error surfaces at `fork_wave` instead
/// of silently stalling the wave.
fn is_valid_dep_role(role : @types.Role) -> Bool {
  match role {
    @types.Role::Dev => true
    @types.Role::Worker => false
    @types.Role::TL => false
    @types.Role::Root => false
  }
}

///|
/// Validate every entry in `depends_on` is an existing leaf agent id (per the
/// spec). Rejects unknown ids, empty entries, and non-leaf roles (TL / Root)
/// since those never transition to the `Merged` state the pending-wave
/// dispatcher waits on. Returns a `ConfigError` naming the first offender.
pub fn validate_pending_wave_deps(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  depends_on : Array[String],
) -> Result[Unit, @types.ChoirError] {
  for dep in depends_on {
    if dep.trim() == "" {
      return Err(
        @types.ChoirError::config_error("depends_on contains empty entry"),
      )
    }
    match lookup_dep_role(project_dir, registry, dep) {
      None =>
        return Err(
          @types.ChoirError::config_error("unknown depends_on agent_id: " + dep),
        )
      Some(role) =>
        if !is_valid_dep_role(role) {
          return Err(
            @types.ChoirError::config_error(
              "depends_on entries must be dev leaves; " +
              dep +
              " has role=" +
              role.to_wire_string() +
              " (only `dev` is satisfied by `Dev(Done(Merged))`)",
            ),
          )
        }
    }
  }
  Ok(())
}

///|
/// `[DEP FAILED]` notify body for the parent of a pending wave.
pub fn dep_failed_notify_message(wave_id : String, dep_id : String) -> String {
  "[DEP FAILED] wave " + wave_id + " — dep failed: " + dep_id
}

///|
/// Effectful failed-dep handler: write `failed-wave--<id>` marker, delete the
/// pending entry, then best-effort `send_message` to the wave's recorded
/// `caller_id` parent. Each step is independent so a notify failure does not
/// strand the failed marker.
pub async fn mark_pending_wave_failed(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  pw : PendingWave,
  dep_id : String,
) -> Unit {
  ignore(
    write_failed_wave_marker(project_dir, pw.wave_id, "dep failed: " + dep_id),
  )
  delete_pending_wave(project_dir, pw.wave_id)
  let lookup = match registry {
    Some(reg) => Some(try? reg.get(pw.args.caller_id))
    None => None
  }
  let plan = send_message_plan(
    pw.args.caller_id,
    "server",
    dep_failed_notify_message(pw.wave_id, dep_id),
    @types.Status::Info,
    lookup,
  )
  ignore(interpret_send_message(plan, project_dir, runner))
}

///|
/// Scan `.choir/kv/pending-wave--*` and dispatch each according to
/// `evaluate_pending_wave`:
///   - `ReadyToSpawn` → spawn via the standard fork_wave host pipeline and
///     delete the pending entry.
///   - `FailedDep`    → write `failed-wave--<id>`, delete pending, notify the
///     wave's recorded parent.
///   - `Wait`         → leave the entry on disk for a later trigger.
/// Called after `merge_pr` succeeds (a likely point for new ready waves) and
/// after the failed-dep `kill_agent` propagation.
pub async fn try_dispatch_pending_waves(
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
) -> Unit {
  // Sweep orphans first so a malformed `pending-wave--*` file does not stay
  // forever counted by the statusline (which scans by filename prefix) while
  // never being dispatchable through `read_all_pending_waves` (which filters
  // by parse success).
  ignore(reap_unparseable_pending_waves(project_dir))
  for pw in read_all_pending_waves(project_dir) {
    match evaluate_pending_wave(project_dir, pw) {
      PendingWaveDecision::Wait => ()
      PendingWaveDecision::FailedDep(dep) =>
        mark_pending_wave_failed(project_dir, registry, runner, pw, dep)
      PendingWaveDecision::ReadyToSpawn => {
        let (resp, resolved_args, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
          pw.args,
          project_dir,
          session,
          registry,
          capture,
          git_capture,
          runner,
          extra_mcp_servers_json~,
          shell_command~,
          listen_uds~,
          listen_tcp~,
          tcp_auth_token~,
          wave_id=Some(pw.wave_id),
        )
        if resp.is_ok() && spawn_plan.spawned_count > 0 {
          match
            append_spawned_agents_to_wave_index(
              project_dir,
              pw.wave_id,
              resolved_args.parent_branch,
              @env.now().reinterpret_as_int64(),
              spawn_plan.agent_ids,
            ) {
            Err(e) =>
              @moontrace.warn("pending_wave_index_append_failed", fields=[
                @moontrace.field("wave_id", pw.wave_id),
                @moontrace.field("error", e.message()),
              ])
            Ok(_) => ()
          }
          interpret_fork_wave_post_spawn(
            resolved_args,
            spawn_plan,
            project_dir,
            session,
            registry,
            capture~,
          )
          delete_pending_wave(project_dir, pw.wave_id)
        } else if resp.is_ok() {
          // Spawn returned ok but no leaves spawned (all skipped as already
          // active). Still consume the pending entry so it doesn't loop.
          delete_pending_wave(project_dir, pw.wave_id)
        }
        // On error, leave the pending entry so a later trigger can retry.
      }
    }
  }
}
