///|
fn default_append_file_sync(path : String, content : String) -> Bool {
  @sys.append_file_sync(path, content)
}

///|
fn default_read_file(path : String) -> String {
  @sys.read_file(path)
}

///|
fn default_write_file_atomic(path : String, content : String) -> Bool {
  @sys.write_file_atomic(path, content)
}

///|
fn default_path_exists(path : String) -> Bool {
  @sys.path_exists(path)
}

///|
pub fn agent_task_contracts_path(project_dir : String) -> String {
  project_dir + "/.choir/agent-task-contracts.json"
}

///|
fn agent_task_contracts_state_json(
  contracts : Map[String, @types.TaskContract],
) -> Json {
  {
    "version": (1).to_json(),
    "agent_task_contracts": server_reload_task_contract_entries_json(contracts),
  }.to_json()
}

///|
fn agent_task_contracts_state_string(
  contracts : Map[String, @types.TaskContract],
) -> String {
  agent_task_contracts_state_json(contracts).stringify(indent=2)
}

///|
fn agent_task_contracts_parse_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "agent-task-contracts.json parse error: " + message,
  )
}

///|
fn parse_agent_task_contracts_state_json(
  content : String,
) -> Result[Map[String, @types.TaskContract], @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ => return Err(agent_task_contracts_parse_error("invalid JSON"))
  }
  guard json is Object(root) else {
    return Err(agent_task_contracts_parse_error("expected object"))
  }
  match @types.json_field_int(root, "version") {
    Some(1) => ()
    Some(value) =>
      return Err(
        agent_task_contracts_parse_error(
          "unsupported version " + value.to_string(),
        ),
      )
    None => return Err(agent_task_contracts_parse_error("missing version"))
  }
  server_reload_parse_task_contract_map(root.get("agent_task_contracts"))
}

///|
fn ensure_audit_gate_state_initialized(
  project_dir : String,
  path_exists : (String) -> Bool,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> Result[Unit, @types.ChoirError] {
  let path = @tools.merge_pr_audit_gate_state_path(project_dir)
  if path_exists(path) {
    return Ok(())
  }
  let body = "{\"enabled_at_unix\":" + now_unix_sec().to_string() + "}\n"
  if write_file_atomic(path, body) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "server boot: could not seed audit receipt gate state at " +
        path +
        "; refusing to start without a durable grandfather boundary",
      ),
    )
  }
}

///|
fn load_poller_state_for_boot(
  project_dir : String,
  path_exists : (String) -> Bool,
  boot_read_file : (String) -> String,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> @poller.PollerState {
  let path = @poller.poller_state_path(project_dir)
  if !path_exists(path) {
    return @poller.PollerState::new()
  }
  let content = boot_read_file(path)
  if content == "" {
    return @poller.PollerState::new()
  }
  @poller.parse_poller_state_json(content) catch {
    e => {
      let quarantine_path = path + ".quarantine." + now_unix_sec().to_string()
      let error = @types.choir_error_message_from_caught(e)
      if write_file_atomic(quarantine_path, content) {
        @moontrace.warn(
          "poller_state.json parse error at boot; quarantined and starting with empty poller state",
          fields=[
            @moontrace.field("event", "poller_state_boot_parse_quarantined"),
            @moontrace.field("path", path),
            @moontrace.field("quarantine_path", quarantine_path),
            @moontrace.field("error", error),
          ],
        )
      } else {
        @moontrace.error(
          "poller_state.json parse error at boot; failed to write quarantine",
          fields=[
            @moontrace.field("event", "poller_state_boot_quarantine_failed"),
            @moontrace.field("path", path),
            @moontrace.field("quarantine_path", quarantine_path),
            @moontrace.field("error", error),
          ],
        )
      }
      @poller.PollerState::new()
    }
  }
}

///|
fn load_agent_task_contracts_for_boot(
  project_dir : String,
  path_exists : (String) -> Bool,
  boot_read_file : (String) -> String,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> Map[String, @types.TaskContract] {
  let path = agent_task_contracts_path(project_dir)
  if !path_exists(path) {
    return {}
  }
  let content = boot_read_file(path)
  if content == "" {
    return {}
  }
  match parse_agent_task_contracts_state_json(content) {
    Ok(parsed) => parsed
    Err(e) => {
      let quarantine_path = path + ".quarantine." + now_unix_sec().to_string()
      let error = e.message()
      if write_file_atomic(quarantine_path, content) {
        @moontrace.warn(
          "agent-task-contracts.json parse error at boot; quarantined and starting with empty task contracts",
          fields=[
            @moontrace.field(
              "event", "agent_task_contracts_boot_parse_quarantined",
            ),
            @moontrace.field("path", path),
            @moontrace.field("quarantine_path", quarantine_path),
            @moontrace.field("error", error),
          ],
        )
      } else {
        @moontrace.error(
          "agent-task-contracts.json parse error at boot; failed to write quarantine",
          fields=[
            @moontrace.field(
              "event", "agent_task_contracts_boot_quarantine_failed",
            ),
            @moontrace.field("path", path),
            @moontrace.field("quarantine_path", quarantine_path),
            @moontrace.field("error", error),
          ],
        )
      }
      {}
    }
  }
}

///|
fn seed_untracked_merge_boundary_if_needed(
  persisted_poller : @poller.PollerState,
  project_dir : String,
  write_file_atomic : (String, String) -> Bool,
  now_unix_sec : () -> Int64,
) -> Result[Unit, @types.ChoirError] {
  if persisted_poller.untracked_merge_boundary_unix != 0L {
    return Ok(())
  }
  persisted_poller.set_untracked_merge_boundary_unix(now_unix_sec())
  if persisted_poller.write_state_file(
      project_dir,
      write_file=write_file_atomic,
    ) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::workspace_error(
        "server boot: could not seed untracked merge boundary at " +
        @poller.poller_state_path(project_dir) +
        "; refusing to start without a durable restart boundary",
      ),
    )
  }
}

///|
pub(all) struct DisconnectContext {
  connected_sec : Int64?
  last_request_name : String?
} derive(Debug, Eq)

///|
/// Shared server state, passed to all tool handlers.
pub struct ServerState {
  config : @types.Config
  registry : @registry.AgentRegistry
  mutex_registry : @registry.MutexRegistry
  tool_registry : @tools.ToolRegistry
  poller : @poller.PollerState
  kv_store : @kv.KvStore
  run_id : String
  pending_disconnects : Map[String, Int64]
  agent_pids : Map[String, Int]
  disconnect_contexts : Map[String, DisconnectContext]
  delivery_failures : Map[String, Int]
  handoff_delivered : Map[String, Bool]
  agent_task_contracts : Map[String, @types.TaskContract]
  leaf_tdd_phases : Map[String, @types.LeafTddPhase]
  worker_no_handoff_prodded_at : Map[String, Int64]
  worker_no_handoff_stalled_emitted : Map[String, Bool]
  worker_no_handoff_exit_emitted : Map[String, Bool]
  spawn_registration_first_unseen : Map[String, Int64]
  idle_agent_warned_at_70 : Map[String, Bool]
  list_panes_cache : Map[String, @tools.CachedListPanesSnapshot]
  recent_poller_event_emissions : Map[String, Map[String, RecentEmission]]
  goal_judge : GoalJudgeState
  pane_watcher : @runtime.PaneWatcher
  recovery_provider : @runtime.RecoveryProvider
  append_file : (String, String) -> Bool
  read_file : (String) -> String
  write_file_atomic : (String, String) -> Bool
  delete_file : (String) -> Bool
}

///|
fn persist_run_id(project_dir : String, run_id : String) -> Unit {
  let choir_dir = project_dir + "/.choir"
  let path = choir_dir + "/run_id"
  ignore(@sys.create_dir_all(choir_dir))
  ignore(@sys.write_file_sync(path, run_id))
}

///|
fn normalize_run_id(content : String) -> String? {
  let run_id = content.trim().to_owned()
  if run_id == "" {
    None
  } else {
    Some(run_id)
  }
}

///|
fn init_run_id(project_dir : String) -> String {
  let run_id_path = project_dir + "/.choir/run_id"
  match normalize_run_id(@sys.read_file(run_id_path)) {
    Some(existing) => existing
    None => {
      let generated = @poller.now_sec().to_string() +
        "-" +
        @sys.get_pid().to_string()
      persist_run_id(project_dir, generated)
      generated
    }
  }
}

///|
/// Create initial server state from config.
pub fn ServerState::new(
  config : @types.Config,
  recovery_provider : @runtime.RecoveryProvider,
  path_exists? : (String) -> Bool = default_path_exists,
  write_file_atomic? : (String, String) -> Bool = default_write_file_atomic,
  now_unix_sec? : () -> Int64 = fn() {
    @env.now().reinterpret_as_int64() / 1000L
  },
  boot_read_file? : (String) -> String = default_read_file,
) -> ServerState {
  let run_id = init_run_id(config.project_dir)
  // Seed `.choir/audit-gate.json` on server boot if absent. Operators who
  // want a different grandfather boundary should pre-seed the file before
  // starting the server. merge_pr's load_gate_state fails closed if the
  // file is missing/empty/malformed once the server is running; this init
  // is the one explicit moment Choir writes the boundary itself. A write
  // failure here means the gate cannot be persisted at all — abort boot
  // rather than starting a server whose merge gate has no anchor.
  match
    ensure_audit_gate_state_initialized(
      config.project_dir,
      path_exists,
      write_file_atomic,
      now_unix_sec,
    ) {
    Ok(_) => ()
    Err(e) => abort(e.message())
  }
  let persisted_poller = load_poller_state_for_boot(
    config.project_dir,
    path_exists,
    boot_read_file,
    write_file_atomic,
    now_unix_sec,
  )
  let persisted_agent_task_contracts = load_agent_task_contracts_for_boot(
    config.project_dir,
    path_exists,
    boot_read_file,
    write_file_atomic,
    now_unix_sec,
  )
  match
    seed_untracked_merge_boundary_if_needed(
      persisted_poller,
      config.project_dir,
      write_file_atomic,
      now_unix_sec,
    ) {
    Ok(_) => ()
    Err(e) => abort(e.message())
  }
  let poller = @poller.PollerState::new()
  poller.set_untracked_merge_boundary_unix(
    persisted_poller.untracked_merge_boundary_unix,
  )
  {
    config,
    registry: @registry.AgentRegistry::new(),
    mutex_registry: @registry.MutexRegistry::new(),
    tool_registry: @tools.ToolRegistry::new(),
    poller,
    kv_store: @kv.KvStore::new(config.project_dir),
    run_id,
    pending_disconnects: {},
    agent_pids: {},
    disconnect_contexts: {},
    delivery_failures: {},
    handoff_delivered: {},
    agent_task_contracts: persisted_agent_task_contracts,
    leaf_tdd_phases: {},
    worker_no_handoff_prodded_at: {},
    worker_no_handoff_stalled_emitted: {},
    worker_no_handoff_exit_emitted: {},
    spawn_registration_first_unseen: {},
    idle_agent_warned_at_70: {},
    list_panes_cache: {},
    recent_poller_event_emissions: {},
    goal_judge: GoalJudgeState::new(),
    pane_watcher: @runtime.PaneWatcher::new(),
    recovery_provider,
    append_file: default_append_file_sync,
    read_file: default_read_file,
    write_file_atomic: default_write_file_atomic,
    delete_file: @exec.delete_file_sync,
  }
}

///|
pub fn ServerState::register_agent_pid(
  self : ServerState,
  agent_id : String,
  pid : Int,
) -> Unit {
  self.agent_pids.set(agent_id, pid)
}

///|
pub fn ServerState::forget_agent_pid(
  self : ServerState,
  agent_id : String,
) -> Int? {
  match self.agent_pids.get(agent_id) {
    Some(pid) => {
      self.agent_pids.remove(agent_id)
      ignore(
        (self.delete_file)(
          @workspace.agent_pid_file_path(self.config.project_dir, agent_id),
        ),
      )
      Some(pid)
    }
    None => None
  }
}

///|
pub fn ServerState::leaf_tdd_phase_for_agent(
  self : ServerState,
  agent_id : String,
) -> @types.LeafTddPhase? {
  self.leaf_tdd_phases.get(agent_id)
}

///|
pub fn ServerState::leaf_tdd_state_for_agent(
  self : ServerState,
  agent_id : String,
) -> @types.LeafTddState? {
  match self.leaf_tdd_phases.get(agent_id) {
    Some(phase) => Some({ phase, })
    None => None
  }
}

///|
pub fn ServerState::record_leaf_tdd_state(
  self : ServerState,
  agent_id : String,
  state : @types.LeafTddState,
) -> Unit {
  self.leaf_tdd_phases.set(agent_id, state.phase)
}

///|
fn ServerState::persist_agent_task_contracts(self : ServerState) -> Bool {
  let path = agent_task_contracts_path(self.config.project_dir)
  (self.write_file_atomic)(
    path,
    agent_task_contracts_state_string(self.agent_task_contracts),
  )
}

///|
pub fn ServerState::record_agent_task_contract(
  self : ServerState,
  agent_id : String,
  contract : @types.TaskContract?,
) -> Unit {
  if self.agent_task_contracts.contains(agent_id) {
    return
  }
  match contract {
    Some(value) => {
      self.agent_task_contracts.set(agent_id, value)
      if !self.persist_agent_task_contracts() {
        @moontrace.error(
          "agent task contracts persist failed; in-memory contract retained",
          fields=[
            @moontrace.field("event", "agent_task_contracts_persist_failed"),
            @moontrace.field(
              "path",
              agent_task_contracts_path(self.config.project_dir),
            ),
            @moontrace.field("agent_id", agent_id),
            @moontrace.field(
              "contract_count",
              self.agent_task_contracts.length(),
            ),
          ],
        )
      }
    }
    None => ()
  }
}

///|
pub fn ServerState::task_contract_for_agent(
  self : ServerState,
  agent_id : String,
) -> @types.TaskContract? {
  self.agent_task_contracts.get(agent_id)
}

///|
pub fn ServerState::with_pane_watcher(
  self : ServerState,
  pane_watcher : @runtime.PaneWatcher,
) -> ServerState {
  { ..self, pane_watcher, }
}

///|
test "ServerState::new restores persisted agent task contracts from cold boot state" {
  let project_dir = "/tmp/choir-agent-contract-boot-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let agent_id = "leaf-agent-contract-boot"
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "recover in-flight leaf",
    scope: ["src/server/state.mbt"],
    acceptance_checks: ["task_contract_for_agent returns persisted contract"],
    constraints: ["reuse reload task contract codec"],
    verify: ["moon check --target native", "moon test --target native"],
    verify_satisfied_by_ci: false,
  }
  let persisted : Map[String, @types.TaskContract] = {}
  persisted.set(agent_id, contract)
  let contracts_path = agent_task_contracts_path(project_dir)
  let contracts_content = {
      "version": (1).to_json(),
      "agent_task_contracts": server_reload_task_contract_entries_json(
        persisted,
      ),
    }
    .to_json()
    .stringify(indent=2)
  let poller_path = @poller.poller_state_path(project_dir)
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
    path_exists=fn(path) {
      path.has_suffix("/.choir/audit-gate.json") ||
      path == poller_path ||
      path == contracts_path
    },
    boot_read_file=fn(path) {
      if path == contracts_path {
        contracts_content
      } else if path == poller_path {
        "{\"untracked_merge_boundary_unix\":1779970000,\"tracked\":[]}"
      } else {
        ""
      }
    },
    write_file_atomic=fn(_path, _content) { true },
    now_unix_sec=fn() { 1779970000L },
  )

  @debug.assert_eq(state.task_contract_for_agent(agent_id), Some(contract))
  ignore(@sys.rm_rf(project_dir))
}

///|
test "record_agent_task_contract writes full map through reload task contract parser" {
  let project_dir = "/tmp/choir-agent-contract-write-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let poller_path = @poller.poller_state_path(project_dir)
  let first_contract = {
    ..@types.TaskContract::empty(),
    goal: "persist first recorded leaf",
    scope: ["src/server/state.mbt"],
    acceptance_checks: ["disk map decodes first recorded contract"],
    constraints: ["atomic whole-map rewrite"],
    verify: ["moon check --target native", "moon test --target native"],
  }
  let second_contract = {
    ..@types.TaskContract::empty(),
    goal: "persist second recorded leaf",
    scope: ["src/server/state.mbt"],
    acceptance_checks: ["disk map decodes second recorded contract"],
    constraints: ["atomic whole-map rewrite"],
    verify: ["moon check --target native", "moon test --target native"],
  }
  let writes : Array[(String, String)] = []
  let state = {
    ..ServerState::new(
      { ..@types.Config::default(), project_dir, },
      make_hermetic_recovery_provider(),
      path_exists=fn(path) {
        path.has_suffix("/.choir/audit-gate.json") || path == poller_path
      },
      boot_read_file=fn(path) {
        if path == poller_path {
          "{\"untracked_merge_boundary_unix\":1779970100,\"tracked\":[]}"
        } else {
          ""
        }
      },
      write_file_atomic=fn(_path, _content) { true },
      now_unix_sec=fn() { 1779970100L },
    ),
    write_file_atomic: fn(path, content) {
      writes.push((path, content))
      true
    },
  }

  state.record_agent_task_contract(
    "leaf-agent-contract-write-a",
    Some(first_contract),
  )
  state.record_agent_task_contract(
    "leaf-agent-contract-write-b",
    Some(second_contract),
  )

  assert_eq(writes.length(), 2)
  assert_eq(writes[1].0, agent_task_contracts_path(project_dir))
  let json = @json.parse(writes[1].1) catch {
    _ => fail("expected persisted task contracts JSON to parse")
  }
  guard json is Object(root) else {
    fail("expected persisted task contracts JSON object")
  }
  let parsed = match
    server_reload_parse_task_contract_map(root.get("agent_task_contracts")) {
    Ok(value) => value
    Err(e) => fail(e.message())
  }
  @debug.assert_eq(
    parsed.get("leaf-agent-contract-write-a"),
    Some(first_contract),
  )
  @debug.assert_eq(
    parsed.get("leaf-agent-contract-write-b"),
    Some(second_contract),
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
test "ServerState::new quarantines corrupt persisted agent task contracts" {
  let project_dir = "/tmp/choir-agent-contract-quarantine-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let contracts_path = agent_task_contracts_path(project_dir)
  let poller_path = @poller.poller_state_path(project_dir)
  let writes : Array[(String, String)] = []
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, },
    make_hermetic_recovery_provider(),
    path_exists=fn(path) {
      path.has_suffix("/.choir/audit-gate.json") ||
      path == poller_path ||
      path == contracts_path
    },
    boot_read_file=fn(path) {
      if path == contracts_path {
        "{not-json"
      } else if path == poller_path {
        "{\"untracked_merge_boundary_unix\":1779970200,\"tracked\":[]}"
      } else {
        ""
      }
    },
    write_file_atomic=fn(path, content) {
      writes.push((path, content))
      true
    },
    now_unix_sec=fn() { 1779970200L },
  )

  assert_eq(state.agent_task_contracts.length(), 0)
  assert_eq(writes.length(), 1)
  assert_eq(
    writes[0].0,
    contracts_path + ".quarantine." + 1779970200L.to_string(),
  )
  assert_eq(writes[0].1, "{not-json")
  ignore(@sys.rm_rf(project_dir))
}
