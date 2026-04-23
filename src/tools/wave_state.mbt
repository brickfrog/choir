///|
/// Typed per-PR snapshot used by `wave_state`.
///
/// `unresolved_threads` and `threads_fetch_error` are fail-loud: when the
/// GraphQL threads fetch fails, `unresolved_threads=None` and
/// `threads_fetch_error=Some(reason)`. Queries do not gate — they report.
pub(all) struct WaveStatePR {
  pr_number : Int
  pr_url : String
  review_state : @poller.ReviewState
  ci_rollup : @poller.CiRollupStatus
  unresolved_threads : Int?
  threads_fetch_error : String?
  copilot_issue_comment_seen : Bool
  fixes_pushed_at : Int64
  last_sha : String
  merge_gate_ready : Bool
} derive(Debug, Eq, ToJson)

///|
/// Typed per-child snapshot used by `wave_state`. Covers both Dev leaves
/// and Worker agents so silent-worker cases are observable.
pub(all) struct WaveStateChild {
  agent_id : String
  slug : String
  agent_type : @types.AgentType
  workspace : String
  branch : String
  workflow : @phase.WorkflowState
  agent_state : @types.AgentState
  last_heartbeat_ms : Int64?
  pr : WaveStatePR?
} derive(Debug, Eq, ToJson)

///|
/// Typed per-supervisor snapshot used by `wave_state`.
pub(all) struct WaveStateSupervisor {
  agent_id : String
  workflow : @phase.SupervisorLifecycle
  own_pr : WaveStatePR?
  wave : Int?
} derive(Debug, Eq, ToJson)

///|
/// Authoritative typed snapshot of the caller's supervisor + all children.
pub(all) struct WaveStateSnapshot {
  supervisor : WaveStateSupervisor
  children : Array[WaveStateChild]
  taken_at_ms : Int64
} derive(Debug, Eq, ToJson)

///|
fn wave_state_pr_from_tracked(
  tracked : @poller.TrackedPR,
  unresolved_threads : Int?,
  threads_fetch_error : String?,
  review_mode : @types.ReviewMode,
) -> WaveStatePR {
  let merge_gate_ready = @poller.tl_tracked_pr_merge_gate_snapshot_ready(
    tracked,
    unresolved_threads,
    review_mode~,
  )
  {
    pr_number: tracked.pr_number,
    pr_url: tracked.pr_url,
    review_state: tracked.last_review_state,
    ci_rollup: tracked.last_ci_rollup,
    unresolved_threads,
    threads_fetch_error,
    copilot_issue_comment_seen: tracked.copilot_issue_comment_seen,
    fixes_pushed_at: tracked.fixes_pushed_at,
    last_sha: tracked.last_sha,
    merge_gate_ready,
  }
}

///|
fn supervisor_own_pr_number(lifecycle : @phase.SupervisorLifecycle) -> Int? {
  match lifecycle {
    OwnPRFiled(number~, ..) => Some(number)
    _ => None
  }
}

///|
fn supervisor_wave(lifecycle : @phase.SupervisorLifecycle) -> Int? {
  match lifecycle {
    Supervising(wave~, ..) => Some(wave)
    WaveComplete(wave~, ..) => Some(wave)
    _ => None
  }
}

///|
fn child_tracked_pr_for_agent(
  poller_state : @poller.PollerState?,
  agent_id : String,
) -> @poller.TrackedPR? {
  match poller_state {
    Some(ps) => {
      for tracked in ps.tracked.values() {
        if tracked.agent_id == agent_id {
          return Some(tracked)
        }
      }
      None
    }
    None => None
  }
}

///|
/// Pure planner for `wave_state`. Assembles a typed snapshot from injected
/// reader capabilities:
///
/// - `lifecycle_reader`: `(agent_id) -> AgentLifecycle?` (in prod:
///   `@phase.read_lifecycle(project_dir, id)`).
/// - `threads_lookup`: `(pr_number) -> (unresolved_count?, error?)` — fail-loud.
/// - `heartbeat_reader`: `(agent_id) -> Int64?` — surfaces silent workers.
///
/// Rejects callers whose registry entry is missing and callers that are not a
/// supervisor role (Root or TL); the registry guards role at the transport
/// layer, but the planner validates again so unit tests can exercise the
/// rejection branch.
pub fn plan_wave_state(
  caller_id : String,
  registry : @registry.AgentRegistry,
  lifecycle_reader : (String) -> @phase.AgentLifecycle?,
  poller_state : @poller.PollerState?,
  threads_lookup : (Int) -> (Int?, String?),
  heartbeat_reader : (String) -> Int64?,
  review_mode : @types.ReviewMode,
  now_ms : Int64,
) -> Result[WaveStateSnapshot, @types.ChoirError] {
  let caller_agent = try? registry.get(caller_id)
  guard caller_agent is Ok(agent) else {
    return Err(@types.ChoirError::agent_not_found(caller_id))
  }
  guard agent.role == @types.Role::Root || agent.role == @types.Role::TL else {
    return Err(
      @types.ChoirError::permission_denied(
        agent.role.to_wire_string(),
        "wave_state",
      ),
    )
  }
  let caller_lifecycle = lifecycle_reader(caller_id)
  let supervisor_workflow : @phase.SupervisorLifecycle = match
    caller_lifecycle {
    Some({ workflow: @phase.Supervisor(sl), .. }) => sl
    // No persisted lifecycle yet → default to Planning; same fallback as
    // read_or_default_lifecycle for a fresh Root/TL.
    _ => @phase.SupervisorLifecycle::Planning
  }
  let own_pr = match supervisor_own_pr_number(supervisor_workflow) {
    Some(pr_number) =>
      match poller_state {
        Some(ps) =>
          match ps.get(pr_number) {
            Some(tracked) => {
              let (threads, err) = threads_lookup(pr_number)
              Some(
                wave_state_pr_from_tracked(tracked, threads, err, review_mode),
              )
            }
            None => None
          }
        None => None
      }
    None => None
  }
  let children : Array[WaveStateChild] = []
  for child in registry.children(caller_id) {
    let child_id = child.agent_id.to_string()
    let child_lifecycle = lifecycle_reader(child_id)
    let workflow : @phase.WorkflowState = match child_lifecycle {
      Some(lc) => lc.workflow
      None => @phase.default_workflow_state(child.role)
    }
    let pr = match child_tracked_pr_for_agent(poller_state, child_id) {
      Some(tracked) => {
        let (threads, err) = threads_lookup(tracked.pr_number)
        Some(wave_state_pr_from_tracked(tracked, threads, err, review_mode))
      }
      None => None
    }
    children.push({
      agent_id: child_id,
      slug: @phase.extract_slug(child_id),
      agent_type: child.agent_type,
      workspace: child.workspace,
      branch: child.branch,
      workflow,
      agent_state: child.state,
      last_heartbeat_ms: heartbeat_reader(child_id),
      pr,
    })
  }
  Ok({
    supervisor: {
      agent_id: caller_id,
      workflow: supervisor_workflow,
      own_pr,
      wave: supervisor_wave(supervisor_workflow),
    },
    children,
    taken_at_ms: now_ms,
  })
}

///|
/// No-op heartbeat reader used when no capability is wired from the server.
/// Kept as a named binding (rather than an inline lambda) so future wiring
/// that injects a real reader is a single-site change.
fn wave_state_default_heartbeat(_agent_id : String) -> Int64? {
  None
}

///|
/// Effect layer for `wave_state`. Fetches unresolved review threads per
/// tracked PR via `fetch_unresolved_review_threads`, assembles a typed
/// snapshot, and returns a JSON response. Thread-fetch errors are reported
/// (fail-loud) — they do not block the snapshot.
pub async fn interpret_wave_state(
  args : WaveStateArgs,
  project_dir : String,
  registry : @registry.AgentRegistry?,
  poller_state : @poller.PollerState?,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  heartbeat_reader? : (String) -> Int64? = wave_state_default_heartbeat,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> @types.Response {
  let reg = match registry {
    Some(r) => r
    None => return @types.Response::Err("wave_state requires an agent registry")
  }
  // Collect distinct PR numbers we need threads for: the supervisor's own PR
  // and every child's tracked PR.
  let pr_numbers : Array[Int] = []
  let add_pr = fn(n : Int) { if !pr_numbers.contains(n) { pr_numbers.push(n) } }
  let caller_lifecycle = @phase.read_lifecycle(project_dir, args.caller_id)
  match caller_lifecycle {
    Some({ workflow: @phase.Supervisor(sl), .. }) =>
      match supervisor_own_pr_number(sl) {
        Some(n) => add_pr(n)
        None => ()
      }
    _ => ()
  }
  for child in reg.children(args.caller_id) {
    let child_id = child.agent_id.to_string()
    match child_tracked_pr_for_agent(poller_state, child_id) {
      Some(tracked) => add_pr(tracked.pr_number)
      None => ()
    }
  }
  // Fetch threads for each PR; fail-loud on gh failure.
  let threads_map : Map[Int, (Int?, String?)] = {}
  for pr_number in pr_numbers {
    let (count, thread_text) = fetch_unresolved_review_threads(
      pr_number, project_dir, capture,
    )
    if thread_text == review_thread_fetch_failed_marker {
      threads_map.set(
        pr_number,
        (
          None,
          Some(
            "gh unavailable (could not fetch review thread state) for PR #" +
            pr_number.to_string(),
          ),
        ),
      )
    } else {
      threads_map.set(pr_number, (Some(count), None))
    }
  }
  let threads_lookup = fn(pr_number : Int) -> (Int?, String?) {
    match threads_map.get(pr_number) {
      Some(pair) => pair
      None => (None, Some("thread state not fetched"))
    }
  }
  let lifecycle_reader = fn(agent_id : String) -> @phase.AgentLifecycle? {
    @phase.read_lifecycle(project_dir, agent_id)
  }
  let snapshot = match
    plan_wave_state(
      args.caller_id,
      reg,
      lifecycle_reader,
      poller_state,
      threads_lookup,
      heartbeat_reader,
      review_mode,
      @env.now().reinterpret_as_int64(),
    ) {
    Ok(s) => s
    Err(e) => return @types.Response::Err(e.message())
  }
  @types.Response::ok_values({ "snapshot": snapshot.to_json() })
}
