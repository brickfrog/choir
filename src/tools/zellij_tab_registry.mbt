///|
/// Persistent registry of choir-created zellij tabs, keyed by owning agent id.
/// Lives at `.choir/state/zellij-tabs.json`, written at tab-creation time (the
/// spawn interpretation seam) for every worktree-backed agent tab choir spawns.
///
/// The init-time reap (`choir init`) uses this registry instead of a name-shape
/// heuristic: it closes a tab ONLY when the registry recorded it AND its owning
/// agent's lifecycle is terminal AND the agent is not recovered AND its worktree
/// is gone. A tab absent from the registry (a user's own tab — `v1.0.0`,
/// `package.json`, `my.feature.branch`) is therefore never touched.
///
/// I/O discipline mirrors `wave_index.mbt`: direct `@sys` read/write is allowed
/// in this tools-layer module; the pure planner [`plan_zellij_tab_reaps`] does
/// no I/O (worktree existence is injected).
pub(all) struct ZellijTabEntry {
  agent_id : String
  session : String
  /// Zellij tab name choir created (the spawn slug).
  tab_name : String
  /// Recorded worktree path of the owning agent. The reap planner uses this to
  /// confirm the tab is choir-managed and that its worktree is gone.
  workspace : String
  created_ts : Int64
} derive(Debug, Eq)

///|
pub(all) struct ZellijTabRegistry {
  tabs : Map[String, ZellijTabEntry]
} derive(Debug, Eq)

///|
pub fn ZellijTabRegistry::new() -> ZellijTabRegistry {
  { tabs: {} }
}

///|
pub fn zellij_tab_registry_path(project_dir : String) -> String {
  project_dir + "/.choir/state/zellij-tabs.json"
}

///|
fn zellij_tab_entry_to_json(e : ZellijTabEntry) -> Json {
  let obj : Map[String, Json] = {
    "agent_id": e.agent_id.to_json(),
    "session": e.session.to_json(),
    "tab_name": e.tab_name.to_json(),
    "workspace": e.workspace.to_json(),
    "created_ts": Json::number(e.created_ts.to_double()),
  }
  obj.to_json()
}

///|
pub fn render_zellij_tab_registry_json(reg : ZellijTabRegistry) -> String {
  let tabs_obj : Map[String, Json] = {}
  for k, v in reg.tabs {
    tabs_obj.set(k, zellij_tab_entry_to_json(v))
  }
  let root : Map[String, Json] = { "tabs": tabs_obj.to_json() }
  root.to_json().stringify()
}

///|
fn parse_zellij_tab_entry(v : Json) -> Result[ZellijTabEntry, @types.ChoirError] {
  guard v is Object(obj) else {
    return Err(
      @types.ChoirError::config_error("zellij tab entry must be an object"),
    )
  }
  let agent_id = match obj.get("agent_id") {
    Some(String(s)) => s
    _ =>
      return Err(
        @types.ChoirError::config_error("zellij tab entry missing 'agent_id'"),
      )
  }
  let session = match obj.get("session") {
    Some(String(s)) => s
    _ =>
      return Err(
        @types.ChoirError::config_error("zellij tab entry missing 'session'"),
      )
  }
  let tab_name = match obj.get("tab_name") {
    Some(String(s)) => s
    _ =>
      return Err(
        @types.ChoirError::config_error("zellij tab entry missing 'tab_name'"),
      )
  }
  let workspace = match obj.get("workspace") {
    Some(String(s)) => s
    _ =>
      return Err(
        @types.ChoirError::config_error("zellij tab entry missing 'workspace'"),
      )
  }
  let created_ts = match obj.get("created_ts") {
    Some(Number(n, ..)) => n.to_int64()
    _ =>
      return Err(
        @types.ChoirError::config_error("zellij tab entry missing 'created_ts'"),
      )
  }
  Ok({ agent_id, session, tab_name, workspace, created_ts })
}

///|
pub fn parse_zellij_tab_registry_json(
  s : String,
) -> Result[ZellijTabRegistry, @types.ChoirError] {
  let parsed = @json.parse(s) catch {
    e =>
      return Err(
        @types.ChoirError::config_error(
          "malformed zellij tab registry JSON: " + e.to_string(),
        ),
      )
  }
  guard parsed is Object(obj) else {
    return Err(
      @types.ChoirError::config_error("zellij tab registry must be an object"),
    )
  }
  let tabs : Map[String, ZellijTabEntry] = {}
  match obj.get("tabs") {
    Some(Object(t)) =>
      for k, v in t {
        match parse_zellij_tab_entry(v) {
          Ok(entry) => tabs.set(k, entry)
          Err(e) => return Err(e)
        }
      }
    None => ()
    _ =>
      return Err(
        @types.ChoirError::config_error(
          "zellij tab registry 'tabs' must be an object",
        ),
      )
  }
  Ok({ tabs, })
}

///|
/// Forgiving read for the reaper/recorder: a missing or malformed registry
/// yields an empty registry rather than an error. A UI-cleanup reap must never
/// fail or mis-reap because of a corrupt file; an absent registry simply means
/// "nothing to reap".
pub fn load_zellij_tab_registry(project_dir : String) -> ZellijTabRegistry {
  let path = zellij_tab_registry_path(project_dir)
  if !@sys.path_exists(path) {
    return ZellijTabRegistry::new()
  }
  let body = @sys.read_file(path)
  match parse_zellij_tab_registry_json(body) {
    Ok(reg) => reg
    Err(_) => ZellijTabRegistry::new()
  }
}

///|
pub fn save_zellij_tab_registry(
  project_dir : String,
  reg : ZellijTabRegistry,
) -> Result[Unit, @types.ChoirError] {
  let dir = project_dir + "/.choir/state"
  if !@sys.create_dir_all(dir) {
    return Err(@types.ChoirError::workspace_error("failed to create " + dir))
  }
  let path = zellij_tab_registry_path(project_dir)
  let tmp_path = path +
    ".tmp." +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let body = render_zellij_tab_registry_json(reg)
  if !@sys.write_file_sync(tmp_path, body) {
    return Err(
      @types.ChoirError::workspace_error("failed to write " + tmp_path),
    )
  }
  if !@sys.rename_file_sync(tmp_path, path) {
    ignore(@sys.rm_rf(tmp_path))
    return Err(
      @types.ChoirError::workspace_error(
        "failed to rename " + tmp_path + " -> " + path,
      ),
    )
  }
  Ok(())
}

///|
/// Record (or overwrite) the tab for `agent_id`. Idempotent per agent: a
/// re-spawn of the same agent id replaces its entry. Call this at the spawn
/// interpretation seam, after the tab command has been launched.
pub fn record_zellij_tab(
  project_dir : String,
  agent_id : String,
  session : String,
  tab_name : String,
  workspace : String,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> Result[Unit, @types.ChoirError] {
  let reg = load_zellij_tab_registry(project_dir)
  reg.tabs.set(agent_id, {
    agent_id,
    session,
    tab_name,
    workspace,
    created_ts: now_ms,
  })
  save_zellij_tab_registry(project_dir, reg)
}

///|
/// Drop the tab entry for `agent_id`. Idempotent — absent ids are a no-op.
pub fn forget_zellij_tab(
  project_dir : String,
  agent_id : String,
) -> Result[Unit, @types.ChoirError] {
  let reg = load_zellij_tab_registry(project_dir)
  if !reg.tabs.contains(agent_id) {
    return Ok(())
  }
  reg.tabs.remove(agent_id)
  save_zellij_tab_registry(project_dir, reg)
}

///|
/// Record the zellij tab for a freshly-spawned spec at the spawn interpretation
/// seam (call after the tab command has launched). Only worktree-isolated agents
/// get a registry entry — those are the tabs whose worktree existence the init
/// reap uses as the liveness signal. Inline agents share an existing tab, and the
/// root Server/TL supervisor tabs run in the root checkout (no worktree); both are
/// outside this registry by design and are reaped by reserved name, not here.
pub fn record_spawned_zellij_tab(
  project_dir : String,
  session : String,
  spec : @types.SpawnSpec,
) -> Result[Unit, @types.ChoirError] {
  if spec.isolation != @types.IsolationMode::Worktree {
    return Ok(())
  }
  record_zellij_tab(
    project_dir,
    @workspace.canonical_agent_id(spec),
    session,
    spec.slug,
    @workspace.spawn_workspace_path(project_dir, spec),
  )
}

///|
fn lifecycle_is_terminal_for(
  lifecycles : Array[@phase.AgentLifecycle],
  agent_id : String,
) -> Bool {
  for lifecycle in lifecycles {
    if lifecycle.agent_id == agent_id {
      return lifecycle.process.is_terminal()
    }
  }
  false
}

///|
fn recovered_agent_ids_contains(
  recovered_agents : Array[@types.Agent],
  agent_id : String,
) -> Bool {
  for agent in recovered_agents {
    if agent.agent_id.to_string() == agent_id {
      return true
    }
  }
  false
}

///|
/// Pure reap planner — mirrors `plan_stale_lifecycle_reaps`
/// (src/runtime/recovery.mbt). Returns the registry tabs that are safe to close.
///
/// A registry tab is closed ONLY when ALL hold:
///   1. its owning agent's lifecycle is terminal (`ProcessState::is_terminal`),
///   2. the agent is NOT in `recovered_agents` (still live after recovery), and
///   3. its worktree is choir-managed AND gone (`!worktree_exists`).
///
/// Anything that fails a check is left alone. A user tab never reaches this
/// planner (it is absent from the registry); a live or recovered agent's tab is
/// kept by checks 1–2; a still-present worktree keeps the tab by check 3.
/// `worktree_exists` is injected so this stays pure and unit-testable — no I/O.
pub fn plan_zellij_tab_reaps(
  entries : Array[ZellijTabEntry],
  recovered_agents : Array[@types.Agent],
  lifecycles : Array[@phase.AgentLifecycle],
  project_dir : String,
  worktree_exists : (String) -> Bool,
) -> Array[ZellijTabEntry] {
  let out : Array[ZellijTabEntry] = []
  for entry in entries {
    // 1. owning agent's lifecycle must be present AND terminal.
    if !lifecycle_is_terminal_for(lifecycles, entry.agent_id) {
      continue
    }
    // 2. agent must not be live after recovery.
    if recovered_agent_ids_contains(recovered_agents, entry.agent_id) {
      continue
    }
    // 3. workspace must be a choir-managed worktree that is now gone.
    if !@types.is_choir_managed_worktree_path(project_dir, entry.workspace) {
      continue
    }
    if worktree_exists(entry.workspace) {
      continue
    }
    out.push(entry)
  }
  out
}
