///|
pub let wave_state_schema_version : Int = 1

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
  mergeable : @poller.Mergeable
  merge_state_status : @poller.MergeStateStatus
  merged_at_unix : Int64?
  unresolved_threads : Int?
  threads_fetch_error : String?
  copilot_issue_comment_seen : Bool
  fixes_pushed_at : Int64
  last_sha : String
  merge_gate_ready : Bool
} derive(Debug, Eq)

///|
fn wave_state_optional_int64_to_json(value : Int64?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => null
  }
}

///|
fn wave_state_int64_from_json(
  value : Json,
  path : @json.JsonPath,
) -> Int64 raise @json.JsonDecodeError {
  match value {
    Number(n, ..) => {
      let v = n.to_int64()
      if v.to_double() == n {
        v
      } else {
        raise @json.JsonDecodeError((path, "wave_state: expected integer"))
      }
    }
    String(_) => @json.from_json(value, path~)
    _ => raise @json.JsonDecodeError((path, "wave_state: expected integer"))
  }
}

///|
fn wave_state_optional_int64_from_json(
  value : Json,
  path : @json.JsonPath,
) -> Int64? raise @json.JsonDecodeError {
  match value {
    Null => None
    _ => Some(wave_state_int64_from_json(value, path))
  }
}

///|
fn wave_state_optional_int_from_json(
  value : Json,
  path : @json.JsonPath,
) -> Int? raise @json.JsonDecodeError {
  match value {
    Null => None
    _ => Some(@json.from_json(value, path~))
  }
}

///|
fn wave_state_optional_string_from_json(
  value : Json,
  path : @json.JsonPath,
) -> String? raise @json.JsonDecodeError {
  match value {
    Null => None
    _ => Some(@json.from_json(value, path~))
  }
}

///|
fn wave_state_review_state_from_json(
  value : Json,
  path : @json.JsonPath,
) -> @poller.ReviewState raise @json.JsonDecodeError {
  match value {
    String("none") => @poller.ReviewState::None_
    String("approved") => @poller.ReviewState::Approved
    String("changes_requested") => @poller.ReviewState::ChangesRequested
    String("commented") => @poller.ReviewState::Commented
    _ =>
      raise @json.JsonDecodeError(
        (
          path, "WaveStatePR::from_json: expected review_state none/approved/changes_requested/commented",
        ),
      )
  }
}

///|
fn wave_state_ci_rollup_from_json(
  value : Json,
  path : @json.JsonPath,
) -> @poller.CiRollupStatus raise @json.JsonDecodeError {
  match value {
    String("unknown") => @poller.CiRollupStatus::Unknown
    String("no_checks") => @poller.CiRollupStatus::NoChecks
    String("in_progress") => @poller.CiRollupStatus::InProgress
    String("success") => @poller.CiRollupStatus::Success
    String("failure") => @poller.CiRollupStatus::Failure
    _ =>
      raise @json.JsonDecodeError(
        (
          path, "WaveStatePR::from_json: expected ci_rollup unknown/no_checks/in_progress/success/failure",
        ),
      )
  }
}

///|
fn wave_state_mergeable_from_json(
  value : Json,
  path : @json.JsonPath,
) -> @poller.Mergeable raise @json.JsonDecodeError {
  match value {
    String("mergeable") => @poller.Mergeable::Mergeable
    String("conflicting") => @poller.Mergeable::Conflicting
    String("unknown") => @poller.Mergeable::Unknown
    _ =>
      raise @json.JsonDecodeError(
        (
          path, "WaveStatePR::from_json: expected mergeable mergeable/conflicting/unknown",
        ),
      )
  }
}

///|
fn wave_state_merge_state_status_from_json(
  value : Json,
  path : @json.JsonPath,
) -> @poller.MergeStateStatus raise @json.JsonDecodeError {
  match value {
    String("clean") => @poller.MergeStateStatus::Clean
    String("unstable") => @poller.MergeStateStatus::Unstable
    String("blocked") => @poller.MergeStateStatus::Blocked
    String("has_hooks") => @poller.MergeStateStatus::HasHooks
    String("behind") => @poller.MergeStateStatus::Behind
    String("unknown") => @poller.MergeStateStatus::Unknown
    String("dirty") => @poller.MergeStateStatus::Dirty
    _ =>
      raise @json.JsonDecodeError(
        (
          path, "WaveStatePR::from_json: expected merge_state_status clean/unstable/blocked/has_hooks/behind/unknown/dirty",
        ),
      )
  }
}

///|
fn wave_state_agent_state_from_json(
  value : Json,
  path : @json.JsonPath,
) -> @types.AgentState raise @json.JsonDecodeError {
  match value {
    String(s) =>
      match @types.AgentState::try_parse_wire(s) {
        Ok(state) => state
        Err(e) =>
          raise @json.JsonDecodeError(
            (path, "WaveStateChild::from_json: " + e.message()),
          )
      }
    _ =>
      raise @json.JsonDecodeError(
        (path, "WaveStateChild::from_json: expected agent_state string"),
      )
  }
}

///|
pub impl ToJson for WaveStatePR with fn to_json(self) -> Json {
  let obj : Map[String, Json] = {
    "pr_number": self.pr_number.to_json(),
    "pr_url": self.pr_url.to_json(),
    "review_state": self.review_state.to_json(),
    "ci_rollup": self.ci_rollup.to_json(),
    "mergeable": self.mergeable.to_json(),
    "merge_state_status": self.merge_state_status.to_json(),
    "merged_at_unix": wave_state_optional_int64_to_json(self.merged_at_unix),
    "copilot_issue_comment_seen": self.copilot_issue_comment_seen.to_json(),
    "fixes_pushed_at": self.fixes_pushed_at.to_json(),
    "last_sha": self.last_sha.to_json(),
    "merge_gate_ready": self.merge_gate_ready.to_json(),
  }
  match self.unresolved_threads {
    Some(v) => obj.set("unresolved_threads", v.to_json())
    None => ()
  }
  match self.threads_fetch_error {
    Some(v) => obj.set("threads_fetch_error", v.to_json())
    None => ()
  }
  obj.to_json()
}

///|
pub impl FromJson for WaveStatePR with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let pr_number : Int = match fields.get("pr_number") {
        Some(value) => @json.from_json(value, path=path.add_key("pr_number"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("pr_number"),
              "WaveStatePR::from_json: missing field pr_number",
            ),
          )
      }
      let pr_url : String = match fields.get("pr_url") {
        Some(value) => @json.from_json(value, path=path.add_key("pr_url"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("pr_url"),
              "WaveStatePR::from_json: missing field pr_url",
            ),
          )
      }
      let review_state : @poller.ReviewState = match
        fields.get("review_state") {
        Some(value) =>
          wave_state_review_state_from_json(value, path.add_key("review_state"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("review_state"),
              "WaveStatePR::from_json: missing field review_state",
            ),
          )
      }
      let ci_rollup : @poller.CiRollupStatus = match fields.get("ci_rollup") {
        Some(value) =>
          wave_state_ci_rollup_from_json(value, path.add_key("ci_rollup"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("ci_rollup"),
              "WaveStatePR::from_json: missing field ci_rollup",
            ),
          )
      }
      let mergeable : @poller.Mergeable = match fields.get("mergeable") {
        Some(value) =>
          wave_state_mergeable_from_json(value, path.add_key("mergeable"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("mergeable"),
              "WaveStatePR::from_json: missing field mergeable",
            ),
          )
      }
      let merge_state_status : @poller.MergeStateStatus = match
        fields.get("merge_state_status") {
        Some(value) =>
          wave_state_merge_state_status_from_json(
            value,
            path.add_key("merge_state_status"),
          )
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("merge_state_status"),
              "WaveStatePR::from_json: missing field merge_state_status",
            ),
          )
      }
      let merged_at_unix : Int64? = match fields.get("merged_at_unix") {
        Some(value) =>
          wave_state_optional_int64_from_json(
            value,
            path.add_key("merged_at_unix"),
          )
        None => None
      }
      let unresolved_threads : Int? = match fields.get("unresolved_threads") {
        Some(value) =>
          wave_state_optional_int_from_json(
            value,
            path.add_key("unresolved_threads"),
          )
        None => None
      }
      let threads_fetch_error : String? = match
        fields.get("threads_fetch_error") {
        Some(value) =>
          wave_state_optional_string_from_json(
            value,
            path.add_key("threads_fetch_error"),
          )
        None => None
      }
      let copilot_issue_comment_seen : Bool = match
        fields.get("copilot_issue_comment_seen") {
        Some(value) =>
          @json.from_json(
            value,
            path=path.add_key("copilot_issue_comment_seen"),
          )
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("copilot_issue_comment_seen"),
              "WaveStatePR::from_json: missing field copilot_issue_comment_seen",
            ),
          )
      }
      let fixes_pushed_at : Int64 = match fields.get("fixes_pushed_at") {
        Some(value) =>
          wave_state_int64_from_json(value, path.add_key("fixes_pushed_at"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("fixes_pushed_at"),
              "WaveStatePR::from_json: missing field fixes_pushed_at",
            ),
          )
      }
      let last_sha : String = match fields.get("last_sha") {
        Some(value) => @json.from_json(value, path=path.add_key("last_sha"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("last_sha"),
              "WaveStatePR::from_json: missing field last_sha",
            ),
          )
      }
      let merge_gate_ready : Bool = match fields.get("merge_gate_ready") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("merge_gate_ready"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("merge_gate_ready"),
              "WaveStatePR::from_json: missing field merge_gate_ready",
            ),
          )
      }
      {
        pr_number,
        pr_url,
        review_state,
        ci_rollup,
        mergeable,
        merge_state_status,
        merged_at_unix,
        unresolved_threads,
        threads_fetch_error,
        copilot_issue_comment_seen,
        fixes_pushed_at,
        last_sha,
        merge_gate_ready,
      }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "WaveStatePR::from_json: expected object"),
      )
  }
}

///|
/// Typed per-child snapshot used by `wave_state`. Covers both Dev leaves
/// and Worker agents so silent-worker cases are observable.
pub(all) struct WaveStateChild {
  agent_id : String
  slug : String
  agent_type : @types.AgentType
  beads_issue_id : String?
  workspace : String
  branch : String
  workflow : @phase.WorkflowState
  agent_state : @types.AgentState
  tdd_phase : @types.LeafTddPhase?
  last_heartbeat_ms : Int64?
  transcript_idle_sec : Int64?
  pr : WaveStatePR?
} derive(Debug, Eq, ToJson)

///|
pub impl FromJson for WaveStateChild with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let agent_id : String = match fields.get("agent_id") {
        Some(value) => @json.from_json(value, path=path.add_key("agent_id"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("agent_id"),
              "WaveStateChild::from_json: missing field agent_id",
            ),
          )
      }
      let slug : String = match fields.get("slug") {
        Some(value) => @json.from_json(value, path=path.add_key("slug"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("slug"),
              "WaveStateChild::from_json: missing field slug",
            ),
          )
      }
      let agent_type : @types.AgentType = match fields.get("agent_type") {
        Some(value) => @json.from_json(value, path=path.add_key("agent_type"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("agent_type"),
              "WaveStateChild::from_json: missing field agent_type",
            ),
          )
      }
      let beads_issue_id : String? = match fields.get("beads_issue_id") {
        Some(value) =>
          wave_state_optional_string_from_json(
            value,
            path.add_key("beads_issue_id"),
          )
        None => None
      }
      let workspace : String = match fields.get("workspace") {
        Some(value) => @json.from_json(value, path=path.add_key("workspace"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("workspace"),
              "WaveStateChild::from_json: missing field workspace",
            ),
          )
      }
      let branch : String = match fields.get("branch") {
        Some(value) => @json.from_json(value, path=path.add_key("branch"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("branch"),
              "WaveStateChild::from_json: missing field branch",
            ),
          )
      }
      let workflow : @phase.WorkflowState = match fields.get("workflow") {
        Some(value) => @json.from_json(value, path=path.add_key("workflow"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("workflow"),
              "WaveStateChild::from_json: missing field workflow",
            ),
          )
      }
      let agent_state : @types.AgentState = match fields.get("agent_state") {
        Some(value) =>
          wave_state_agent_state_from_json(value, path.add_key("agent_state"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("agent_state"),
              "WaveStateChild::from_json: missing field agent_state",
            ),
          )
      }
      let tdd_phase : @types.LeafTddPhase? = match fields.get("tdd_phase") {
        Some(Null) => None
        Some(value) =>
          Some(@json.from_json(value, path=path.add_key("tdd_phase")))
        None => None
      }
      let last_heartbeat_ms : Int64? = match fields.get("last_heartbeat_ms") {
        Some(value) =>
          wave_state_optional_int64_from_json(
            value,
            path.add_key("last_heartbeat_ms"),
          )
        None => None
      }
      let transcript_idle_sec : Int64? = match
        fields.get("transcript_idle_sec") {
        Some(value) =>
          wave_state_optional_int64_from_json(
            value,
            path.add_key("transcript_idle_sec"),
          )
        None => None
      }
      let pr : WaveStatePR? = match fields.get("pr") {
        Some(Null) => None
        Some(value) => Some(@json.from_json(value, path=path.add_key("pr")))
        None => None
      }
      {
        agent_id,
        slug,
        agent_type,
        beads_issue_id,
        workspace,
        branch,
        workflow,
        agent_state,
        tdd_phase,
        last_heartbeat_ms,
        transcript_idle_sec,
        pr,
      }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "WaveStateChild::from_json: expected object"),
      )
  }
}

///|
/// Typed per-supervisor snapshot used by `wave_state`.
pub(all) struct WaveStateSupervisor {
  agent_id : String
  beads_issue_id : String?
  workflow : @phase.SupervisorLifecycle
  own_pr : WaveStatePR?
  wave : Int?
} derive(Debug, Eq, ToJson)

///|
pub impl FromJson for WaveStateSupervisor with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let agent_id : String = match fields.get("agent_id") {
        Some(value) => @json.from_json(value, path=path.add_key("agent_id"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("agent_id"),
              "WaveStateSupervisor::from_json: missing field agent_id",
            ),
          )
      }
      let beads_issue_id : String? = match fields.get("beads_issue_id") {
        Some(value) =>
          wave_state_optional_string_from_json(
            value,
            path.add_key("beads_issue_id"),
          )
        None => None
      }
      let workflow : @phase.SupervisorLifecycle = match fields.get("workflow") {
        Some(value) => @json.from_json(value, path=path.add_key("workflow"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("workflow"),
              "WaveStateSupervisor::from_json: missing field workflow",
            ),
          )
      }
      let own_pr : WaveStatePR? = match fields.get("own_pr") {
        Some(Null) => None
        Some(value) => Some(@json.from_json(value, path=path.add_key("own_pr")))
        None => None
      }
      let wave : Int? = match fields.get("wave") {
        Some(value) =>
          wave_state_optional_int_from_json(value, path.add_key("wave"))
        None => None
      }
      { agent_id, beads_issue_id, workflow, own_pr, wave }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "WaveStateSupervisor::from_json: expected object"),
      )
  }
}

///|
/// Authoritative typed snapshot of the caller's supervisor + relevant children.
pub(all) struct WaveStateSnapshot {
  schema_version : Int
  supervisor : WaveStateSupervisor
  children : Array[WaveStateChild]
  taken_at_ms : Int64
} derive(Debug, Eq)

///|
pub fn WaveStateSnapshot::to_json_map(
  self : WaveStateSnapshot,
) -> Map[String, Json] {
  let children : Array[Json] = []
  for child in self.children {
    children.push(child.to_json())
  }
  {
    "schema_version": self.schema_version.to_json(),
    "supervisor": self.supervisor.to_json(),
    "children": children.to_json(),
    "taken_at_ms": self.taken_at_ms.to_json(),
  }
}

///|
pub impl ToJson for WaveStateSnapshot with fn to_json(self) -> Json {
  self.to_json_map().to_json()
}

///|
pub impl FromJson for WaveStateSnapshot with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let schema_version : Int = match fields.get("schema_version") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("schema_version"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("schema_version"),
              "WaveStateSnapshot::from_json: missing field schema_version",
            ),
          )
      }
      if schema_version != wave_state_schema_version {
        raise @json.JsonDecodeError(
          (
            path.add_key("schema_version"),
            "WaveStateSnapshot::from_json: expected schema_version 1",
          ),
        )
      }
      let supervisor : WaveStateSupervisor = match fields.get("supervisor") {
        Some(value) => @json.from_json(value, path=path.add_key("supervisor"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("supervisor"),
              "WaveStateSnapshot::from_json: missing field supervisor",
            ),
          )
      }
      let children : Array[WaveStateChild] = match fields.get("children") {
        Some(value) => @json.from_json(value, path=path.add_key("children"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("children"),
              "WaveStateSnapshot::from_json: missing field children",
            ),
          )
      }
      let taken_at_ms : Int64 = match fields.get("taken_at_ms") {
        Some(value) =>
          wave_state_int64_from_json(value, path.add_key("taken_at_ms"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("taken_at_ms"),
              "WaveStateSnapshot::from_json: missing field taken_at_ms",
            ),
          )
      }
      { schema_version, supervisor, children, taken_at_ms }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "WaveStateSnapshot::from_json: expected object"),
      )
  }
}

///|
fn wave_state_pr_from_tracked(
  tracked : @poller.TrackedPR,
  unresolved_threads : Int?,
  threads_fetch_error : String?,
  task_contract : @types.TaskContract?,
  verify_results : Array[@types.VerifyCheckResult],
  missing_task_contract_blocks : Bool,
  reviewer : @types.Reviewer,
  skip_copilot_on_feature_branch : Bool,
  default_branch : String,
  audit_receipt_state : @types.AuditReceiptState,
) -> WaveStatePR {
  let merge_gate_ready = if missing_task_contract_blocks &&
    task_contract is None &&
    tracked.agent_id != "root" {
    false
  } else {
    match
      @poller.merge_policy_decision_for_tracked_pr(
        tracked,
        unresolved_threads,
        task_contract~,
        review_mode=tracked.review_mode,
        verify_results~,
        reviewer~,
        skip_copilot_on_feature_branch~,
        default_branch~,
        audit_receipt_state~,
      ) {
      @policy.MergeDecision::MergeNow(_) => true
      _ => false
    }
  }
  {
    pr_number: tracked.pr_number,
    pr_url: tracked.pr_url,
    review_state: tracked.last_review_state,
    ci_rollup: tracked.last_ci_rollup,
    mergeable: tracked.mergeable,
    merge_state_status: tracked.merge_state_status,
    merged_at_unix: tracked.merged_at_unix,
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
fn supervisor_child_id_set(
  lifecycle : @phase.SupervisorLifecycle,
) -> Map[String, Bool]? {
  match lifecycle {
    Supervising(children~, ..) | WaveComplete(children~, ..) => {
      let ids : Map[String, Bool] = {}
      for child in children {
        ids.set(child.child_id, true)
      }
      Some(ids)
    }
    _ => None
  }
}

///|
fn supervisor_workflow_for_wave_state(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle?,
  now_sec : Int64,
) -> @phase.SupervisorLifecycle {
  match lifecycle {
    // Long-running root TL kept Active by the choir-serve process — the
    // Connected + UnexpectedDisconnect combination is the kqv.4 mislabel,
    // not a real failure. Match synthesized root TLs (Role::TL with a
    // user-<pid>-<nanos> id), and only mask the UnexpectedDisconnect when
    // last_updated_unix_sec is recent or unknown — if the heartbeat is stale,
    // the disconnect
    // labelling is probably accurate and we should not suppress it.
    Some(
      {
        process: @phase.ProcessState::Connected,
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Failed(
            reason=@phase.FailureReason::UnexpectedDisconnect
          )
        ),
        last_updated_unix_sec: last_updated,
        ..,
      }
    ) if agent.state == @types.AgentState::Active &&
      (
        agent.agent_id.to_string() == "root" ||
        @phase.is_root_tl_shaped_agent_id(agent.agent_id.to_string())
      ) &&
      wave_state_root_tl_heartbeat_is_recent_or_unknown(last_updated, now_sec) =>
      @phase.SupervisorLifecycle::Planning
    Some({ workflow: @phase.WorkflowState::Supervisor(sl), .. }) => sl
    // No persisted lifecycle yet -> default to Planning; same fallback as
    // read_or_default_lifecycle for a fresh TL.
    _ => @phase.SupervisorLifecycle::Planning
  }
}

///|
/// Threshold (in seconds) beyond which the wave_state long-running-root
/// exemption no longer applies — if last_updated_unix_sec is older than this,
/// the UnexpectedDisconnect labelling is probably real and should not be
/// masked. Generous (1 hour) because root TLs idle for long stretches between
/// waves and we don't want to mis-flag a quiet but live root.
let wave_state_root_tl_recent_heartbeat_sec : Int64 = 3600L

///|
/// Returns true when the root TL's heartbeat is either unknown
/// (`last_updated_unix_sec == 0`, e.g. legacy lifecycle KV from before this
/// field landed) or recent enough that we trust the agent is alive.
fn wave_state_root_tl_heartbeat_is_recent_or_unknown(
  last_updated_unix_sec : Int64,
  now_sec : Int64,
) -> Bool {
  if last_updated_unix_sec <= 0L {
    return true
  }
  now_sec - last_updated_unix_sec <= wave_state_root_tl_recent_heartbeat_sec
}

///|
fn agent_state_is_terminal(state : @types.AgentState) -> Bool {
  state == @types.AgentState::Done || state == @types.AgentState::Failed
}

///|
fn wave_state_should_include_child(
  child : @types.Agent,
  current_child_ids : Map[String, Bool]?,
) -> Bool {
  let child_id = child.agent_id.to_string()
  match current_child_ids {
    Some(ids) =>
      match ids.get(child_id) {
        Some(true) => true
        _ => !agent_state_is_terminal(child.state)
      }
    None => !agent_state_is_terminal(child.state)
  }
}

///|
/// Build a single `agent_id -> TrackedPR` index from the poller state in one
/// linear pass. Callers then do O(1) lookups per child instead of rescanning
/// `ps.tracked.values()` on every child (which is O(children × trackedPRs)).
/// If multiple tracked PRs share an agent_id, the last one in iteration order
/// wins — matches the previous per-child scan, which also returned whichever
/// hit first.
fn index_tracked_by_agent(
  poller_state : @poller.PollerState?,
) -> Map[String, @poller.TrackedPR] {
  let by_agent : Map[String, @poller.TrackedPR] = {}
  match poller_state {
    Some(ps) =>
      for tracked in ps.tracked.values() {
        by_agent.set(tracked.agent_id, tracked)
      }
    None => ()
  }
  by_agent
}

///|
fn wave_state_default_beads_issue_reader(_agent : @types.Agent) -> String? {
  None
}

///|
fn wave_state_default_tdd_phase(_agent_id : String) -> @types.LeafTddPhase? {
  None
}

///|
fn wave_state_default_task_contract_reader(
  _agent_id : String,
) -> @types.TaskContract? {
  None
}

///|
fn wave_state_default_verify_results_reader(
  _tracked : @poller.TrackedPR,
  _contract : @types.TaskContract,
) -> Array[@types.VerifyCheckResult] {
  []
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
/// Children are limited to the current supervisor wave plus any nonterminal
/// registry children, so old Done/Failed rows do not dominate the snapshot.
///
/// Rejects callers whose registry entry is missing and callers that are not a
/// supervisor role (TL); the registry guards role at the transport
/// layer, but the planner validates again so unit tests can exercise the
/// rejection branch.
pub fn plan_wave_state(
  caller_id : String,
  registry : @registry.AgentRegistry,
  lifecycle_reader : (String) -> @phase.AgentLifecycle?,
  poller_state : @poller.PollerState?,
  threads_lookup : (Int) -> (Int?, String?),
  heartbeat_reader : (String) -> Int64?,
  now_ms : Int64,
  beads_issue_reader? : (@types.Agent) -> String? = wave_state_default_beads_issue_reader,
  tdd_phase_reader? : (String) -> @types.LeafTddPhase? = wave_state_default_tdd_phase,
  transcript_idle_reader? : (@types.Agent) -> Int64? = wave_state_default_transcript_idle,
  task_contract_reader? : (String) -> @types.TaskContract? = wave_state_default_task_contract_reader,
  verify_results_reader? : (@poller.TrackedPR, @types.TaskContract) -> Array[
    @types.VerifyCheckResult,
  ] = wave_state_default_verify_results_reader,
  missing_task_contract_blocks? : Bool = false,
  reviewer? : @types.Reviewer = @types.Config::default().pr_policy.reviewer,
  skip_copilot_on_feature_branch? : Bool = false,
  default_branch? : String = "",
  audit_receipt_lookup? : (Int) -> @types.AuditReceiptState = fn(_) {
    @types.AuditReceiptState::NotRequired
  },
) -> Result[WaveStateSnapshot, @types.ChoirError] {
  guard registry.get_opt(caller_id) is Some(agent) else {
    return Err(@types.ChoirError::agent_not_found(caller_id))
  }
  guard agent.role == @types.Role::TL else {
    return Err(
      @types.ChoirError::permission_denied(
        agent.role.to_wire_string(),
        "wave_state",
      ),
    )
  }
  let caller_lifecycle = lifecycle_reader(caller_id)
  let now_sec = now_ms / 1000L
  let supervisor_workflow = supervisor_workflow_for_wave_state(
    agent, caller_lifecycle, now_sec,
  )
  let own_pr = match supervisor_own_pr_number(supervisor_workflow) {
    Some(pr_number) =>
      match poller_state {
        Some(ps) =>
          match ps.get(pr_number) {
            Some(tracked) => {
              let (threads, err) = threads_lookup(pr_number)
              let task_contract = task_contract_reader(tracked.agent_id)
              let verify_results = match task_contract {
                Some(contract) => verify_results_reader(tracked, contract)
                None => []
              }
              Some(
                wave_state_pr_from_tracked(
                  tracked,
                  threads,
                  err,
                  task_contract,
                  verify_results,
                  missing_task_contract_blocks,
                  reviewer,
                  skip_copilot_on_feature_branch,
                  default_branch,
                  audit_receipt_lookup(pr_number),
                ),
              )
            }
            None => None
          }
        None => None
      }
    None => None
  }
  let tracked_by_agent = index_tracked_by_agent(poller_state)
  let current_child_ids = supervisor_child_id_set(supervisor_workflow)
  let children : Array[WaveStateChild] = []
  for child in registry.children(caller_id) {
    if !wave_state_should_include_child(child, current_child_ids) {
      continue
    }
    let child_id = child.agent_id.to_string()
    let child_lifecycle = lifecycle_reader(child_id)
    let workflow : @phase.WorkflowState = match child_lifecycle {
      Some(lc) => lc.workflow
      None => @phase.default_workflow_state(child.role)
    }
    let pr = match tracked_by_agent.get(child_id) {
      Some(tracked) => {
        let (threads, err) = threads_lookup(tracked.pr_number)
        let task_contract = task_contract_reader(tracked.agent_id)
        let verify_results = match task_contract {
          Some(contract) => verify_results_reader(tracked, contract)
          None => []
        }
        Some(
          wave_state_pr_from_tracked(
            tracked,
            threads,
            err,
            task_contract,
            verify_results,
            missing_task_contract_blocks,
            reviewer,
            skip_copilot_on_feature_branch,
            default_branch,
            audit_receipt_lookup(tracked.pr_number),
          ),
        )
      }
      None => None
    }
    children.push({
      agent_id: child_id,
      slug: @phase.extract_slug(child_id),
      agent_type: child.agent_type,
      beads_issue_id: beads_issue_reader(child),
      workspace: child.workspace,
      branch: child.branch,
      workflow,
      agent_state: child.state,
      tdd_phase: tdd_phase_reader(child_id),
      last_heartbeat_ms: heartbeat_reader(child_id),
      transcript_idle_sec: transcript_idle_reader(child),
      pr,
    })
  }
  Ok({
    schema_version: wave_state_schema_version,
    supervisor: {
      agent_id: caller_id,
      beads_issue_id: beads_issue_reader(agent),
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
fn wave_state_default_transcript_idle(_agent : @types.Agent) -> Int64? {
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
  capture~ : async (@workspace.Command) -> (Int, String),
  read_file~ : (String) -> String,
  path_exists~ : (String) -> Bool,
  heartbeat_reader? : (String) -> Int64? = wave_state_default_heartbeat,
  tdd_phase_reader? : (String) -> @types.LeafTddPhase? = wave_state_default_tdd_phase,
  transcript_idle_reader? : (@types.Agent) -> Int64? = wave_state_default_transcript_idle,
  task_contract_reader? : (String) -> @types.TaskContract? = wave_state_default_task_contract_reader,
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
  reviewer? : @types.Reviewer = @types.Config::default().pr_policy.reviewer,
  skip_copilot_on_feature_branch? : Bool = @types.Config::default().pr_policy.skip_copilot_on_feature_branch,
) -> @types.Response {
  let reg = match registry {
    Some(r) => r
    None => return @types.Response::Err("wave_state requires an agent registry")
  }
  // Single index of tracked PRs keyed by agent_id; shared by PR-number
  // collection below and by `plan_wave_state` (which calls it again — but the
  // build is a fixed O(trackedPRs) cost and we'd have to re-run it anyway on
  // the pure side, so duplicated work is bounded by the size of poller state,
  // not the child fan-out).
  let tracked_by_agent = index_tracked_by_agent(poller_state)
  // Collect distinct PR numbers we need threads for: the supervisor's own PR
  // and every child's tracked PR.
  let pr_numbers : Array[Int] = []
  let add_pr = fn(n : Int) { if !pr_numbers.contains(n) { pr_numbers.push(n) } }
  let caller_lifecycle = @phase.read_lifecycle(project_dir, args.caller_id)
  let now_sec_for_filter = @env.now().reinterpret_as_int64() / 1000L
  let supervisor_workflow_for_filter = try reg.get(args.caller_id) catch {
    _ => @phase.SupervisorLifecycle::Planning
  } noraise {
    agent =>
      supervisor_workflow_for_wave_state(
        agent, caller_lifecycle, now_sec_for_filter,
      )
  }
  match supervisor_own_pr_number(supervisor_workflow_for_filter) {
    Some(n) => add_pr(n)
    None => ()
  }
  let current_child_ids = supervisor_child_id_set(
    supervisor_workflow_for_filter,
  )
  for child in reg.children(args.caller_id) {
    if !wave_state_should_include_child(child, current_child_ids) {
      continue
    }
    let child_id = child.agent_id.to_string()
    match tracked_by_agent.get(child_id) {
      Some(tracked) => add_pr(tracked.pr_number)
      None => ()
    }
  }
  // Resolve owner/repo once per snapshot so the per-PR graphql loop does not
  // spawn `gh repo view` N times. If resolution fails, every PR reports
  // fail-loud without further gh calls.
  let owner_repo = if pr_numbers.length() > 0 {
    fetch_gh_repo_owner_name_bounded(project_dir, capture)
  } else {
    None
  }
  // Fetch threads for each PR; fail-loud on gh failure.
  let threads_map : Map[Int, (Int?, String?)] = {}
  for pr_number in pr_numbers {
    match owner_repo {
      Some((owner, repo)) => {
        let (count, thread_text) = fetch_unresolved_review_threads_with_repo(
          pr_number, owner, repo, project_dir, capture,
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
      None =>
        threads_map.set(
          pr_number,
          (
            None,
            Some(
              "gh unavailable (could not resolve owner/repo) for PR #" +
              pr_number.to_string(),
            ),
          ),
        )
    }
  }
  let threads_lookup = fn(pr_number : Int) -> (Int?, String?) {
    match threads_map.get(pr_number) {
      Some(pair) => pair
      None => (None, Some("thread state not fetched"))
    }
  }
  let default_branch = detect_default_branch_with_capture(project_dir, capture)
  let audit_receipt_map : Map[Int, @types.AuditReceiptState] = {}
  for pr_number in pr_numbers {
    match poller_state {
      Some(ps) =>
        match ps.get(pr_number) {
          Some(tracked) =>
            audit_receipt_map.set(
              pr_number,
              audit_receipt_advisory_state_for_tracked_pr(
                project_dir,
                tracked.parent_branch,
                default_branch,
                tracked.last_sha,
                tracked.first_seen,
                capture,
                read_file,
                path_exists,
              ),
            )
          None => ()
        }
      None => ()
    }
  }
  let audit_receipt_lookup = fn(pr_number : Int) -> @types.AuditReceiptState {
    match audit_receipt_map.get(pr_number) {
      Some(state) => state
      None => @types.AuditReceiptState::NotRequired
    }
  }
  let lifecycle_reader = fn(agent_id : String) -> @phase.AgentLifecycle? {
    @phase.read_lifecycle(project_dir, agent_id)
  }
  let beads_issue_reader = fn(agent : @types.Agent) -> String? {
    @workspace.beads_issue_id_for_agent(project_dir, agent)
  }
  let normalized_task_contract_reader = fn(
    agent_id : String,
  ) -> @types.TaskContract? {
    @types.task_contract_with_normalized_verify(
      task_contract_reader(agent_id),
      moon_verify_target,
    )
  }
  let verify_results_reader = fn(
    tracked : @poller.TrackedPR,
    contract : @types.TaskContract,
  ) -> Array[@types.VerifyCheckResult] {
    @evidence.verify_results_for_required_at_head_with_ci(
      project_dir,
      tracked.agent_id,
      contract.verify,
      tracked.last_sha,
      @types.task_contract_verify_satisfied_by_ci(contract),
      ci_rollup=@poller.evaluation_ci_rollup_from_snapshot(
        tracked.last_ci_rollup,
      ),
    )
  }
  let snapshot = match
    plan_wave_state(
      args.caller_id,
      reg,
      lifecycle_reader,
      poller_state,
      threads_lookup,
      heartbeat_reader,
      @env.now().reinterpret_as_int64(),
      beads_issue_reader~,
      tdd_phase_reader~,
      transcript_idle_reader~,
      task_contract_reader=normalized_task_contract_reader,
      verify_results_reader~,
      missing_task_contract_blocks=true,
      reviewer~,
      skip_copilot_on_feature_branch~,
      default_branch~,
      audit_receipt_lookup~,
    ) {
    Ok(s) => s
    Err(e) => return @types.Response::Err(e.message())
  }
  @types.Response::ok_values({ "snapshot": snapshot.to_json() })
}
