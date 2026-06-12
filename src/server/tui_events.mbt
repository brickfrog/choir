///|
/// Append one event to the TUI journal. The journal is a second sink next to
/// the logger; failures degrade to in-memory ring only and never raise.
pub fn ServerState::emit_tui_event(
  self : ServerState,
  event : @types.TuiEvent,
) -> Unit {
  ignore(self.journal.emit(event, @env.now().reinterpret_as_int64()))
}

///|
/// Install the TUI journal observers for two of the four emission choke
/// points: registry mutations and lifecycle store transitions. (The other
/// two — tool dispatch completion and the poller — are wired directly in
/// the request handler and poller tick.) Called once at daemon boot; the
/// lifecycle observer is process-wide, so tests leave it uninstalled.
pub fn ServerState::install_tui_event_observers(self : ServerState) -> Unit {
  self.registry.set_observer(fn(event) { self.emit_tui_event(event) })
  @phase.set_lifecycle_transition_observer(fn(
    agent_id,
    from_lc,
    to_lc,
    trigger
  ) {
    self.emit_tui_event(
      @types.TuiEvent::LifecycleChanged(
        agent_id~,
        from_lifecycle=from_lc.workflow_label(),
        to_lifecycle=to_lc.workflow_label(),
        trigger=trigger.to_wire_string(),
      ),
    )
  })
}

///|
fn tui_truncate(text : String, max : Int) -> String {
  let trimmed = text.trim().to_owned()
  if trimmed.length() <= max {
    trimmed
  } else {
    trimmed[:max].to_owned() + "..."
  }
}

///|
fn tui_request_is_tdd_gate(name : String) -> Bool {
  name == "tdd_intent" || name == "tdd_red_check" || name == "tdd_green_check"
}

///|
/// Pure planner: TUI events produced by one completed tool dispatch. Gate
/// violations surface as a dedicated event carrying the failing tool name.
pub fn plan_tui_dispatch_events(
  req : @types.Request,
  resp : @types.Response,
  duration_ms : Int64,
) -> Array[@types.TuiEvent] {
  if req.req_method != "tools/call" {
    return []
  }
  let events : Array[@types.TuiEvent] = []
  let agent_id = request_agent_id(req).unwrap_or("")
  let ok = resp.is_ok()
  events.push(
    @types.TuiEvent::ToolCallCompleted(
      agent_id~,
      tool=req.name,
      ok~,
      duration_ms~,
    ),
  )
  if !ok && tui_request_is_tdd_gate(req.name) {
    events.push(
      @types.TuiEvent::TddGateViolation(
        agent_id~,
        tool=req.name,
        detail=tui_truncate(resp.error_message().unwrap_or(""), 200),
      ),
    )
  }
  if ok && req.name == "track_pr" {
    match request_int_arg(req, "pr_number") {
      Some(pr_number) =>
        events.push(
          @types.TuiEvent::PrTracked(
            pr_number~,
            agent_id=req.args.get("agent_id").unwrap_or(agent_id),
            branch=req.args.get("branch").unwrap_or(""),
          ),
        )
      None => ()
    }
  }
  if ok && req.name == "file_pr" {
    match resp.ok_field("pr_number") {
      Some(raw) => {
        let pr_number = @string.parse_int(raw.trim().to_owned()) catch {
          _ => -1
        }
        if pr_number > 0 {
          events.push(
            @types.TuiEvent::PrTracked(
              pr_number~,
              agent_id~,
              branch=req.args.get("branch").unwrap_or(""),
            ),
          )
        }
      }
      None => ()
    }
  }
  events
}

///|
/// Tool dispatch completion choke point: record the last tool call on the
/// agent's registry entry (survives reconnects, snapshot-able) and emit the
/// dispatch events into the journal.
pub fn ServerState::record_tui_dispatch_completion(
  self : ServerState,
  req : @types.Request,
  resp : @types.Response,
  start_ms : UInt64,
  end_ms : UInt64,
) -> Unit {
  if req.req_method != "tools/call" {
    return
  }
  let duration_ms = (end_ms - start_ms).reinterpret_as_int64()
  match request_agent_id(req) {
    Some(agent_id) if agent_id != "" =>
      self.registry.record_last_tool_call(agent_id, {
        tool: req.name,
        ok: resp.is_ok(),
        duration_ms,
        ts_ms: end_ms.reinterpret_as_int64(),
      })
    _ => ()
  }
  for event in plan_tui_dispatch_events(req, resp, duration_ms) {
    self.emit_tui_event(event)
  }
}

///|
/// TDD phase store choke point (companion to the registry observer): emits
/// when a leaf's recorded phase actually changes.
pub fn ServerState::emit_tui_tdd_phase_changed(
  self : ServerState,
  agent_id : String,
  phase : @types.LeafTddPhase,
) -> Unit {
  self.emit_tui_event(@types.TuiEvent::TddPhaseChanged(agent_id~, phase~))
}

///|
/// Map a typed poll event (src/poller/detect.mbt) onto the journal schema.
pub fn tui_event_from_poll_event(
  event : @poller.PollEvent,
  agent_id : String,
) -> @types.TuiEvent {
  match event {
    @poller.PollEvent::PRMerged(tracked) =>
      @types.TuiEvent::PrMerged(
        pr_number=tracked.pr_number,
        agent_id=tracked.agent_id,
        branch=tracked.branch,
        merged_at_unix=tracked.merged_at_unix,
      )
    @poller.PollEvent::ReviewReceived(pr_number, body) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::ReviewReceived,
        detail=tui_truncate(body, 120),
      )
    @poller.PollEvent::ReviewCommented(pr_number, body) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::ReviewCommented,
        detail=tui_truncate(body, 120),
      )
    @poller.PollEvent::PRReady(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::PrReady,
        detail="",
      )
    @poller.PollEvent::FixesPushed(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::FixesPushed,
        detail="",
      )
    @poller.PollEvent::ReviewTimeout(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::ReviewTimeout,
        detail="",
      )
    @poller.PollEvent::CIFailed(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::CiFailed,
        detail="",
      )
    @poller.PollEvent::CIFailureCleared(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::CiFailureCleared,
        detail="",
      )
    @poller.PollEvent::CILatestHeadRollupSucceeded(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::CiSucceeded,
        detail="",
      )
    @poller.PollEvent::CopilotIssueCommentSeen(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::CopilotIssueCommentSeen,
        detail="",
      )
    @poller.PollEvent::MergeReady(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::MergeReady,
        detail="",
      )
    @poller.PollEvent::ReviewThreadsResolved(pr_number) =>
      @types.TuiEvent::PrStatusChanged(
        pr_number~,
        agent_id~,
        kind=@types.PrEventKind::ReviewThreadsResolved,
        detail="",
      )
  }
}

///|
/// Poller choke point: journal the tick's typed events, then refresh
/// `PollerVitals` (tick duration, consecutive error ticks, tracked count,
/// and `last_evt_age_sec` from the journal's latest event timestamp).
pub fn ServerState::record_tui_poller_tick(
  self : ServerState,
  pending_events : Array[@poller.PollEvent],
  pending_agent_ids : Array[String],
  tick_summary : @poller.TickSummary,
  ended_at_ms : Int64,
) -> Unit {
  for i = 0; i < pending_events.length(); i = i + 1 {
    let agent_id = if i < pending_agent_ids.length() {
      pending_agent_ids[i]
    } else {
      ""
    }
    self.emit_tui_event(tui_event_from_poll_event(pending_events[i], agent_id))
  }
  let duration_ms = @types.non_negative_i64(
    ended_at_ms - tick_summary.started_at_ms,
  )
  self.emit_tui_event(
    @types.TuiEvent::PollerTick(
      duration_ms~,
      errors=tick_summary.errors,
      tracked_prs=self.poller.tracked.length(),
    ),
  )
  self.poller_vitals = {
    last_tick_duration_ms: duration_ms,
    consecutive_errors: if tick_summary.errors > 0 {
      self.poller_vitals.consecutive_errors + 1
    } else {
      0
    },
    tracked_prs: self.poller.tracked.length(),
    last_tick_at_ms: ended_at_ms,
    last_evt_age_sec: self.journal.last_event_age_sec(ended_at_ms),
  }
}
