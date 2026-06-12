///|
fn test_snapshot_agent(
  agent_id : String,
  role : @types.Role,
  state : @types.AgentState,
) -> @types.TuiSnapshotAgent {
  {
    agent_id,
    role,
    agent_type: @types.AgentType::Codex,
    parent: None,
    workspace: "/tmp/ws/" + agent_id,
    branch: agent_id,
    terminal_target: Some("zellij-tab:choir:" + agent_id),
    state,
    spawn_depth: 1,
    alive: true,
    lifecycle: "dev:working",
    lifecycle_updated_unix: Some(1779970000L),
    tdd_phase: Some(@types.LeafTddPhase::Green),
    last_tool_call: Some({
      tool: "file_pr",
      ok: true,
      duration_ms: 45100L,
      ts_ms: 1779970000000L,
    }),
    beads_issue_id: Some("ch-1"),
    status: @types.TuiAgentStatusFields::empty(),
  }
}

///|
fn test_snapshot() -> @types.TuiSnapshot {
  {
    schema_version: @types.tui_snapshot_schema_version,
    taken_at_ms: 1779970200000L,
    wave: {
      run_id: "1779960000-42",
      wave: Some(2),
      integration_branch: "main",
      started_at_unix: Some(1779960000L),
      supervisor_id: Some("root-tl"),
    },
    agents: [
      test_snapshot_agent(
        "root-tl",
        @types.Role::Root,
        @types.AgentState::Active,
      ),
      test_snapshot_agent(
        "main.leaf-a",
        @types.Role::Dev,
        @types.AgentState::Active,
      ),
    ],
    prs: [
      {
        pr_number: 561,
        agent_id: "main.leaf-a",
        branch: "main.leaf-a",
        parent_branch: "main",
        pr_url: "https://example.invalid/pr/561",
        review_state: "approved",
        ci_rollup: "success",
        mergeable: "mergeable",
        merge_state_status: "clean",
        unresolved_threads: Some(0),
        merged_at_unix: None,
        copilot_issue_comment_seen: true,
        copilot_skipped_reason: Some("skipped (feature br main.tl)"),
        merge_gate_ready: true,
        consecutive_failures: 0,
        backoff_until: 0L,
        fixes_pushed_at: 0L,
      },
    ],
    prs_as_of_ms: 1779970190000L,
    beads: [
      {
        issue_id: "ch-1",
        status: "in_progress",
        title: "reviewer policy",
        assignee: "main.leaf-a",
        blocks: ["ch-2"],
      },
    ],
    beads_as_of_ms: Some(1779970180000L),
    poller: {
      last_tick_duration_ms: 11700L,
      consecutive_errors: 0,
      tracked_prs: 1,
      last_tick_at_ms: 1779970190000L,
      last_evt_age_sec: Some(4L),
    },
    journal_seq: 10L,
    recent_events: [
      {
        seq: 10L,
        ts_ms: 1779970190000L,
        event: @types.TuiEvent::PollerTick(
          duration_ms=11700L,
          errors=0,
          tracked_prs=1,
        ),
      },
    ],
  }
}

///|
fn envelope(seq : Int64, event : @types.TuiEvent) -> @types.TuiEventEnvelope {
  { seq, ts_ms: 1779970200000L + seq * 1000L, event }
}

///|
fn loaded_model() -> @tui.Model {
  let (model, _) = @tui.update_model(
    @tui.Model::initial(),
    @tui.Msg::SnapshotLoaded(test_snapshot()),
  )
  model
}

///|
test "snapshot load seeds the model and cursor" {
  let model = loaded_model()
  assert_eq(model.cursor, 10L)
  assert_eq(model.ordered_agents().length(), 2)
  assert_eq(model.ordered_prs().length(), 1)
  @debug.assert_eq(model.conn, @tui.ConnState::Connected)
}

///|
test "poll tick fetches snapshot when connecting and events when connected" {
  let initial = @tui.Model::initial()
  let (_, effects) = @tui.update_model(initial, @tui.Msg::PollTick(1000L))
  @debug.assert_eq(effects, [@tui.TuiEffect::FetchSnapshot])
  let model = loaded_model()
  let (_, effects2) = @tui.update_model(model, @tui.Msg::PollTick(2000L))
  @debug.assert_eq(effects2, [@tui.TuiEffect::FetchEvents(10L)])
}

///|
test "events fold updates agents, prs, and alarms; old seqs are ignored" {
  let model = loaded_model()
  let (next, _) = @tui.update_model(
    model,
    @tui.Msg::EventsBatch(
      events=[
        // Stale seq (≤ snapshot seq): must be discarded.
        envelope(
          9L,
          @types.TuiEvent::AgentStateChanged(
            agent_id="main.leaf-a",
            state=@types.AgentState::Done,
          ),
        ),
        envelope(
          11L,
          @types.TuiEvent::ToolCallCompleted(
            agent_id="main.leaf-a",
            tool="tdd_green_check",
            ok=false,
            duration_ms=1200L,
          ),
        ),
        envelope(
          12L,
          @types.TuiEvent::AgentStateChanged(
            agent_id="main.leaf-a",
            state=@types.AgentState::Failed,
          ),
        ),
        envelope(
          13L,
          @types.TuiEvent::PrStatusChanged(
            pr_number=561,
            agent_id="main.leaf-a",
            kind=@types.PrEventKind::CiFailed,
            detail="",
          ),
        ),
      ],
      latest_seq=13L,
      stale=false,
    ),
  )
  assert_eq(next.cursor, 13L)
  match next.agents.get("main.leaf-a") {
    Some(agent) => {
      // Stale seq-9 Done was discarded; seq-12 Failed applied.
      @debug.assert_eq(agent.state, @types.AgentState::Failed)
      match agent.last_tool_call {
        Some(call) => {
          assert_eq(call.tool, "tdd_green_check")
          assert_eq(call.ok, false)
        }
        None => fail("expected last tool call updated")
      }
    }
    None => fail("expected leaf in model")
  }
  match next.prs.get(561) {
    Some(pr) => assert_eq(pr.ci_rollup, "failure")
    None => fail("expected pr in model")
  }
  // Alarms escalate to tab 0 and badge the owning tabs.
  assert_true(next.alarms.length() >= 2)
  assert_true(next.ui.badge_agents)
  assert_true(next.ui.badge_prs)
}

///|
test "stale cursor triggers re-snapshot" {
  let model = loaded_model()
  let (next, effects) = @tui.update_model(
    model,
    @tui.Msg::EventsBatch(events=[], latest_seq=99L, stale=true),
  )
  @debug.assert_eq(effects, [@tui.TuiEffect::FetchSnapshot])
  @debug.assert_eq(next.conn, @tui.ConnState::Connecting)
}

///|
test "full batch drains immediately" {
  let model = loaded_model()
  let events : Array[@types.TuiEventEnvelope] = []
  for i = 0; i < @tui.tui_events_batch_limit; i = i + 1 {
    events.push(
      envelope(
        11L + i.to_int64(),
        @types.TuiEvent::AgentHeartbeat(agent_id="main.leaf-a"),
      ),
    )
  }
  let (next, effects) = @tui.update_model(
    model,
    @tui.Msg::EventsBatch(
      events~,
      latest_seq=10L + @tui.tui_events_batch_limit.to_int64(),
      stale=false,
    ),
  )
  @debug.assert_eq(effects, [@tui.TuiEffect::FetchEvents(next.cursor)])
}

///|
test "conn error backs off and reconnect re-snapshots" {
  let model = loaded_model()
  let (down, _) = @tui.update_model(
    { ..model, now_ms: 5000L },
    @tui.Msg::ConnError("daemon unreachable"),
  )
  match down.conn {
    @tui.ConnState::Disconnected(_) => ()
    _ => fail("expected disconnected state")
  }
  // Before the backoff expires: no effect.
  let (_, quiet) = @tui.update_model(down, @tui.Msg::PollTick(5100L))
  assert_eq(quiet.length(), 0)
  // After the backoff expires: reconnect goes through a full snapshot.
  let (_, effects) = @tui.update_model(down, @tui.Msg::PollTick(99000L))
  @debug.assert_eq(effects, [@tui.TuiEffect::FetchSnapshot])
}

///|
test "merge keybinding requires confirmation then sends the daemon command" {
  let model = loaded_model()
  let (armed, effects0) = @tui.update_model(
    model,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Char('m')),
  )
  assert_eq(effects0.length(), 0)
  @debug.assert_eq(
    armed.ui.pending,
    Some(@tui.PendingAction::ConfirmMerge(561)),
  )
  let (_, effects) = @tui.update_model(
    armed,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Char('y')),
  )
  @debug.assert_eq(effects, [@tui.TuiEffect::SendMerge(561)])
  // 'n' cancels instead.
  let (cancelled, none_effects) = @tui.update_model(
    armed,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Char('n')),
  )
  assert_eq(none_effects.length(), 0)
  @debug.assert_eq(cancelled.ui.pending, None)
}

///|
test "enter focuses the selected leaf's zellij pane" {
  let model = loaded_model()
  let (moved, _) = @tui.update_model(
    model,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Char('j')),
  )
  assert_eq(moved.ui.overview_sel, 1)
  let (_, effects) = @tui.update_model(
    moved,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Special("enter")),
  )
  @debug.assert_eq(effects, [
    @tui.TuiEffect::FocusPane("zellij-tab:choir:main.leaf-a"),
  ])
}

///|
test "tab key cycles tabs and clears badges" {
  let model = loaded_model()
  let badged = { ..model, ui: { ..model.ui, badge_beads: true } }
  // Tab → next tab (beads), clearing its badge; shift-tab → back.
  let (on_beads, _) = @tui.update_model(
    badged,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Special("tab")),
  )
  @debug.assert_eq(on_beads.ui.active_tab, @tui.Tab::Beads)
  assert_eq(on_beads.ui.badge_beads, false)
  let (back, _) = @tui.update_model(
    on_beads,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Modified("shift", "tab")),
  )
  @debug.assert_eq(back.ui.active_tab, @tui.Tab::Overview)
  let (cycled, _) = @tui.update_model(
    on_beads,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Char(']')),
  )
  @debug.assert_eq(cycled.ui.active_tab, @tui.Tab::Agents)
  let (quit_model, quit_effects) = @tui.update_model(
    cycled,
    @tui.Msg::KeyInput(@pippa.KeyMsg::Char('q')),
  )
  assert_true(quit_model.quit)
  @debug.assert_eq(quit_effects, [@tui.TuiEffect::QuitApp])
}

///|
test "overview render shows mockup landmarks at fixed width" {
  let model = { ..loaded_model(), now_ms: 1779970300000L }
  let rendered = @pippa.strip_ansi(@tui.view_model(model))
  assert_true(rendered.contains("choir"))
  assert_true(rendered.contains("WAVE 2"))
  assert_true(rendered.contains("leaves"))
  assert_true(rendered.contains("merge queue"))
  assert_true(rendered.contains("main.leaf-a"))
  assert_true(rendered.contains("file_pr ok 45.1s"))
  assert_true(rendered.contains("●●●○ green"))
  assert_true(rendered.contains("#561"))
  // Copilot skips are shown explicitly — never silent.
  assert_true(rendered.contains("copilot: skipped (feature br main.tl)"))
  assert_true(rendered.contains("active 2"))
  assert_true(rendered.contains("tracked_prs 1"))
  assert_true(rendered.contains("uds: connected"))
  assert_true(rendered.contains("? help"))
}

///|
test "disconnected vitals render a red warning and unknown event age" {
  let initial = { ..@tui.Model::initial(), now_ms: 1000L }
  let (down, _) = @tui.update_model(initial, @tui.Msg::ConnError("daemon gone"))
  let rendered = @pippa.strip_ansi(@tui.view_model(down))
  assert_true(rendered.contains("⚠ uds: disconnected"))
  assert_true(rendered.contains("⚠ last_evt_age unknown"))
}

///|
test "log filter narrows by agent" {
  let model = loaded_model()
  let (with_events, _) = @tui.update_model(
    model,
    @tui.Msg::EventsBatch(
      events=[
        envelope(
          11L,
          @types.TuiEvent::ToolCallCompleted(
            agent_id="main.leaf-a",
            tool="file_pr",
            ok=true,
            duration_ms=100L,
          ),
        ),
        envelope(
          12L,
          @types.TuiEvent::ToolCallCompleted(
            agent_id="other.leaf",
            tool="notify_parent",
            ok=true,
            duration_ms=100L,
          ),
        ),
      ],
      latest_seq=12L,
      stale=false,
    ),
  )
  let filtered = {
    ..with_events,
    ui: {
      ..with_events.ui,
      active_tab: @tui.Tab::Log,
      filter: "agent=other.leaf",
    },
  }
  let rendered = @pippa.strip_ansi(@tui.view_model(filtered))
  assert_true(rendered.contains("notify_parent"))
  assert_true(!rendered.contains("file_pr ok"))
}
