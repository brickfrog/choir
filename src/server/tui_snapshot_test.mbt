///|
fn tui_snapshot_test_state(label : String) -> @server.ServerState {
  let project_dir = "/tmp/choir-tui-snapshot-" +
    label +
    "-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  @server.ServerState::new(
    { ..@types.Config::default(), project_dir, },
    @server.make_hermetic_recovery_provider(),
    path_exists=fn(path) { path.has_suffix("/.choir/audit-gate.json") },
    boot_read_file=fn(_path) { "" },
    write_file_atomic=fn(_path, _content) { true },
    now_unix_sec=fn() { 1779970000L },
  )
}

///|
fn tui_snapshot_test_agent(
  agent_id : String,
  role : @types.Role,
  parent : String?,
  branch : String,
) -> @types.Agent {
  {
    agent_id,
    role,
    agent_type: @types.AgentType::Codex,
    parent,
    workspace: "/tmp/ws/" + agent_id,
    branch,
    terminal_target: @types.LocalTarget::parse("zellij-pane:choir:" + agent_id),
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 1,
  }
}

///|
test "build_tui_snapshot assembles agents, wave, prs, vitals, and journal tail" {
  let state = tui_snapshot_test_state("assemble")
  ignore(
    state.registry.upsert(
      tui_snapshot_test_agent("root-tl", @types.Role::Root, None, "main"),
    ),
  )
  ignore(
    state.registry.upsert(
      tui_snapshot_test_agent(
        "main.leaf-a",
        @types.Role::Dev,
        Some("root-tl"),
        "main.leaf-a",
      ),
    ),
  )
  state.registry.record_last_tool_call("main.leaf-a", {
    tool: "file_pr",
    ok: true,
    duration_ms: 45100L,
    ts_ms: 1779970001000L,
  })
  state.record_leaf_tdd_state("main.leaf-a", { phase: @types.LeafTddPhase::Green })
  state.poller.track(
    561,
    "main.leaf-a",
    "main.leaf-a",
    "main",
    "https://example.invalid/pr/561",
    1779970000L,
  )
  // Journal some events so seq and the recent slice are non-trivial.
  state.emit_tui_event(@types.TuiEvent::AgentHeartbeat(agent_id="main.leaf-a"))
  state.emit_tui_event(
    @types.TuiEvent::PollerTick(duration_ms=100L, errors=0, tracked_prs=1),
  )
  let lifecycle_reader = fn(agent_id : String) -> @phase.AgentLifecycle? {
    if agent_id == "root-tl" {
      Some({
        agent_id,
        role: @types.Role::Root,
        process: @phase.ProcessState::Connected,
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(wave=2, children=[]),
        ),
        last_updated_unix_sec: 1779970100L,
      })
    } else {
      None
    }
  }
  let snapshot = state.build_tui_snapshot(
    1779970200000L,
    lifecycle_reader=Some(lifecycle_reader),
  )
  assert_eq(snapshot.schema_version, @types.tui_snapshot_schema_version)
  @debug.assert_eq(snapshot.wave.wave, Some(2))
  assert_eq(snapshot.wave.integration_branch, "main")
  @debug.assert_eq(snapshot.wave.supervisor_id, Some("root-tl"))
  assert_eq(snapshot.agents.length(), 2)
  let mut leaf : @types.TuiSnapshotAgent? = None
  for agent in snapshot.agents {
    if agent.agent_id == "main.leaf-a" {
      leaf = Some(agent)
    }
  }
  match leaf {
    Some(agent) => {
      @debug.assert_eq(agent.tdd_phase, Some(@types.LeafTddPhase::Green))
      match agent.last_tool_call {
        Some(record) => assert_eq(record.tool, "file_pr")
        None => fail("expected last tool call on leaf")
      }
      @debug.assert_eq(
        agent.terminal_target,
        Some("zellij-pane:choir:main.leaf-a"),
      )
      assert_eq(agent.lifecycle, "dev:working")
    }
    None => fail("expected leaf agent in snapshot")
  }
  assert_eq(snapshot.prs.length(), 1)
  let pr = snapshot.prs[0]
  assert_eq(pr.pr_number, 561)
  assert_eq(pr.agent_id, "main.leaf-a")
  // Threads were never fetched by the poller: unknown, not zero.
  @debug.assert_eq(pr.unresolved_threads, None)
  // No task contract recorded: merge gate blocked for non-root.
  assert_eq(pr.merge_gate_ready, false)
  // Journal: tdd event + heartbeat + poller tick + bead-free emissions.
  assert_true(snapshot.journal_seq >= 2L)
  assert_true(snapshot.recent_events.length() >= 2)
  match snapshot.poller.last_evt_age_sec {
    Some(_) => ()
    None => fail("expected last_evt_age_sec from journal")
  }
}

///|
test "tui_events_since handler serves cursored batches and rejects missing seq" {
  let state = tui_snapshot_test_state("events")
  state.emit_tui_event(@types.TuiEvent::AgentHeartbeat(agent_id="a"))
  state.emit_tui_event(@types.TuiEvent::AgentHeartbeat(agent_id="b"))
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Operator,
    name: "tui_events_since",
    args: @types.RequestArgs::from_values({ "seq": (0 : Json) }),
  }
  let resp = state.handle_tui_events_since_request(req)
  assert_true(resp.is_ok())
  match resp.ok_payload() {
    Some(fields) => {
      assert_eq(fields.get("stale"), Some("false"))
      match fields.get_json("events") {
        Some(Array(events)) => assert_eq(events.length(), 2)
        _ => fail("expected events array")
      }
      // Int64 serializes as a JSON string on the wire.
      @debug.assert_eq(fields.get("latest_seq"), Some("2"))
    }
    None => fail("expected ok payload")
  }
  let missing : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Operator,
    name: "tui_events_since",
    args: @types.RequestArgs::from_values({}),
  }
  assert_true(!state.handle_tui_events_since_request(missing).is_ok())
}

///|
test "tui handlers enforce the operator allowlist via the tool registry" {
  let state = tui_snapshot_test_state("roles")
  let dev_req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name: "tui_events_since",
    args: @types.RequestArgs::from_values({ "seq": (0 : Json) }),
  }
  let resp = state.handle_tui_events_since_request(dev_req)
  match resp.error_message() {
    Some(message) => assert_true(message.contains("cannot call"))
    None => fail("expected permission denial for dev role")
  }
}

///|
async fn tui_snapshot_test_bd_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "ready" {
    return (
      0, "[{\"id\":\"ch-1\",\"title\":\"reviewer policy\",\"status\":\"ready\"}]",
    )
  }
  if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "list" {
    return (
      0, "[{\"id\":\"ch-2\",\"title\":\"tui spike\",\"status\":\"in_progress\",\"assignee\":\"main.leaf-a\"}]",
    )
  }
  (1, "")
}

///|
async test "tui_snapshot handler refreshes bead cache and serves snapshot json" {
  let state = tui_snapshot_test_state("handler")
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::Operator,
    name: "tui_snapshot",
    args: @types.RequestArgs::from_values({}),
  }
  let resp = state.handle_tui_snapshot_request(
    req,
    capture=tui_snapshot_test_bd_capture,
    bd_capture=tui_snapshot_test_bd_capture,
  )
  assert_true(resp.is_ok())
  match resp.ok_payload() {
    Some(fields) =>
      match fields.get_json("snapshot") {
        Some(snapshot_json) =>
          match @types.parse_tui_snapshot_json(snapshot_json) {
            Ok(snapshot) => {
              assert_eq(snapshot.beads.length(), 2)
              assert_eq(snapshot.beads[0].issue_id, "ch-1")
              assert_eq(snapshot.beads[1].status, "in_progress")
              match snapshot.beads_as_of_ms {
                Some(_) => ()
                None => fail("expected bead cache staleness timestamp")
              }
            }
            Err(e) => fail("snapshot roundtrip failed: " + e.message())
          }
        None => fail("expected snapshot json")
      }
    None => fail("expected ok payload")
  }
}
