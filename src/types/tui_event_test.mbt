///|
fn tui_event_roundtrip(event : @types.TuiEvent) -> Unit raise {
  let envelope : @types.TuiEventEnvelope = {
    seq: 42L,
    ts_ms: 1779970000123L,
    event,
  }
  let line = envelope.to_jsonl_line()
  assert_true(line.has_suffix("\n"))
  match @types.parse_tui_event_envelope_line(line) {
    Ok(parsed) => @debug.assert_eq(parsed, envelope)
    Err(e) => fail("roundtrip failed: " + e.message())
  }
}

///|
test "tui event envelope roundtrips every variant" {
  tui_event_roundtrip(
    @types.TuiEvent::AgentRegistered(
      agent_id="main.leaf-a",
      role=@types.Role::Dev,
      agent_type=@types.AgentType::Codex,
      parent=Some("main.tl"),
      workspace="/tmp/project/.choir/worktrees/leaf-a",
      branch="main.leaf-a",
      terminal_target=Some("zellij-pane:choir:leaf-a"),
      state=@types.AgentState::Active,
      spawn_depth=1,
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::AgentRegistered(
      agent_id="root",
      role=@types.Role::Root,
      agent_type=@types.AgentType::Claude,
      parent=None,
      workspace="/tmp/project",
      branch="main",
      terminal_target=None,
      state=@types.AgentState::Spawning,
      spawn_depth=0,
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::AgentStateChanged(
      agent_id="main.leaf-a",
      state=@types.AgentState::Suspended,
    ),
  )
  tui_event_roundtrip(@types.TuiEvent::AgentRemoved(agent_id="main.leaf-a"))
  tui_event_roundtrip(@types.TuiEvent::AgentHeartbeat(agent_id="main.leaf-a"))
  tui_event_roundtrip(
    @types.TuiEvent::LifecycleChanged(
      agent_id="main.leaf-a",
      from_lifecycle="working",
      to_lifecycle="review_owned",
      trigger="own_pr_filed",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::TddPhaseChanged(
      agent_id="main.leaf-a",
      phase=@types.LeafTddPhase::Green,
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::TddGateViolation(
      agent_id="main.leaf-a",
      tool="tdd_green_check",
      detail="verify command failed",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::ToolCallCompleted(
      agent_id="main.leaf-a",
      tool="file_pr",
      ok=true,
      duration_ms=45100L,
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::PrTracked(
      pr_number=561,
      agent_id="main.leaf-a",
      branch="main.leaf-a",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::PrStatusChanged(
      pr_number=561,
      agent_id="main.leaf-a",
      kind=@types.PrEventKind::CiFailed,
      detail="rollup failure",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::PrMerged(
      pr_number=561,
      agent_id="main.leaf-a",
      branch="main.leaf-a",
      merged_at_unix=Some(1779970001L),
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::PrMerged(
      pr_number=562,
      agent_id="main.leaf-b",
      branch="main.leaf-b",
      merged_at_unix=None,
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::PollerTick(duration_ms=11700L, errors=0, tracked_prs=1),
  )
  tui_event_roundtrip(
    @types.TuiEvent::MessageQueued(
      recipient_id="main.leaf-a",
      sender_id="poller",
      message_id="msg-1",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::MessageDelivered(
      recipient_id="main.leaf-a",
      message_id="msg-1",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::BeadSummaryChanged(
      issue_id="ch-101",
      status="in_progress",
      title="reviewer policy",
    ),
  )
  tui_event_roundtrip(
    @types.TuiEvent::LogLine(
      level=@types.TuiLogLevel::TuiWarn,
      agent_id="main.leaf-a",
      tool="merge_pr",
      message="policy blocked",
    ),
  )
  tui_event_roundtrip(@types.TuiEvent::DaemonShutdown(reason="exit_requested"))
}

///|
test "tui event envelope rejects malformed lines" {
  match @types.parse_tui_event_envelope_line("") {
    Ok(_) => fail("expected empty-line error")
    Err(_) => ()
  }
  match @types.parse_tui_event_envelope_line("{not json") {
    Ok(_) => fail("expected invalid-json error")
    Err(_) => ()
  }
  match
    @types.parse_tui_event_envelope_line(
      "{\"seq\":1,\"ts_ms\":2,\"type\":\"no_such_event\",\"data\":{}}",
    ) {
    Ok(_) => fail("expected unknown-type error")
    Err(_) => ()
  }
  match
    @types.parse_tui_event_envelope_line(
      "{\"ts_ms\":2,\"type\":\"agent_removed\",\"data\":{\"agent_id\":\"a\"}}",
    ) {
    Ok(_) => fail("expected missing-seq error")
    Err(_) => ()
  }
}

///|
test "tool call record json roundtrips" {
  let record : @types.ToolCallRecord = {
    tool: "tdd_green_check",
    ok: false,
    duration_ms: 1200L,
    ts_ms: 1779970000123L,
  }
  match @types.parse_tool_call_record_json(record.to_json()) {
    Ok(parsed) => @debug.assert_eq(parsed, record)
    Err(e) => fail("roundtrip failed: " + e.message())
  }
}

///|
test "poller vitals json roundtrips including unknown last_evt_age" {
  let vitals : @types.PollerVitals = {
    last_tick_duration_ms: 11700L,
    consecutive_errors: 2,
    tracked_prs: 3,
    last_tick_at_ms: 1779970000123L,
    last_evt_age_sec: Some(4L),
  }
  match @types.parse_poller_vitals_json(vitals.to_json()) {
    Ok(parsed) => @debug.assert_eq(parsed, vitals)
    Err(e) => fail("roundtrip failed: " + e.message())
  }
  let unknown : @types.PollerVitals = {
    ..@types.PollerVitals::initial(),
    last_evt_age_sec: None,
  }
  match @types.parse_poller_vitals_json(unknown.to_json()) {
    Ok(parsed) => @debug.assert_eq(parsed.last_evt_age_sec, None)
    Err(e) => fail("roundtrip failed: " + e.message())
  }
}
