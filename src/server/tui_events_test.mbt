///|
fn tui_events_test_request(
  name : String,
  args : Map[String, Json],
) -> @types.Request {
  {
    req_method: "tools/call",
    role: @types.Role::Dev,
    name,
    args: @types.RequestArgs::from_values(args),
  }
}

///|
test "plan_tui_dispatch_events emits tool call completion" {
  let req = tui_events_test_request("notify_parent", {
    "caller_id": "main.leaf".to_json(),
  })
  let events = @server.plan_tui_dispatch_events(
    req,
    @types.Response::ok({}),
    250L,
  )
  assert_eq(events.length(), 1)
  @debug.assert_eq(
    events[0],
    @types.TuiEvent::ToolCallCompleted(
      agent_id="main.leaf",
      tool="notify_parent",
      ok=true,
      duration_ms=250L,
    ),
  )
}

///|
test "plan_tui_dispatch_events flags tdd gate violations with failing tool" {
  let req = tui_events_test_request("tdd_green_check", {
    "caller_id": "main.leaf".to_json(),
  })
  let events = @server.plan_tui_dispatch_events(
    req,
    @types.Response::Err("verify command failed: exit 1"),
    1200L,
  )
  assert_eq(events.length(), 2)
  @debug.assert_eq(
    events[1],
    @types.TuiEvent::TddGateViolation(
      agent_id="main.leaf",
      tool="tdd_green_check",
      detail="verify command failed: exit 1",
    ),
  )
}

///|
test "plan_tui_dispatch_events emits pr_tracked for track_pr" {
  let req = tui_events_test_request("track_pr", {
    "caller_id": "main.leaf",
    "agent_id": "main.leaf",
    "pr_number": (561 : Json),
    "branch": "main.leaf",
  })
  let events = @server.plan_tui_dispatch_events(
    req,
    @types.Response::ok({}),
    10L,
  )
  assert_eq(events.length(), 2)
  @debug.assert_eq(
    events[1],
    @types.TuiEvent::PrTracked(
      pr_number=561,
      agent_id="main.leaf",
      branch="main.leaf",
    ),
  )
}

///|
test "plan_tui_dispatch_events ignores non tool calls" {
  let req : @types.Request = {
    req_method: "register",
    role: @types.Role::Dev,
    name: "register",
    args: @types.RequestArgs::from_values({ "agent_id": "main.leaf".to_json() }),
  }
  let events = @server.plan_tui_dispatch_events(
    req,
    @types.Response::ok({}),
    5L,
  )
  assert_eq(events.length(), 0)
}

///|
test "plan_tui_dispatch_events ignores dashboard polling tools" {
  let snapshot_req = {
    ..tui_events_test_request("tui_snapshot", {}),
    role: @types.Role::Operator,
  }
  assert_eq(
    @server.plan_tui_dispatch_events(snapshot_req, @types.Response::ok({}), 7L).length(),
    0,
  )
  let events_req = {
    ..tui_events_test_request("tui_events_since", { "seq": "123".to_json() }),
    role: @types.Role::Operator,
  }
  assert_eq(
    @server.plan_tui_dispatch_events(events_req, @types.Response::ok({}), 8L).length(),
    0,
  )
}

///|
test "tui_event_from_poll_event maps merge and status kinds" {
  let poller_state = @poller.PollerState::new()
  poller_state.track(
    561, "main.leaf", "main.leaf", "main", "https://example.invalid/pr/561", 1779970000L,
  )
  let tracked = match poller_state.get(561) {
    Some(pr) => pr
    None => {
      fail("expected tracked PR")
      return
    }
  }
  tracked.merged_at_unix = Some(1779970100L)
  @debug.assert_eq(
    @server.tui_event_from_poll_event(
      @poller.PollEvent::PRMerged(tracked),
      "main.leaf",
    ),
    @types.TuiEvent::PrMerged(
      pr_number=561,
      agent_id="main.leaf",
      branch="main.leaf",
      merged_at_unix=Some(1779970100L),
    ),
  )
  @debug.assert_eq(
    @server.tui_event_from_poll_event(
      @poller.PollEvent::CIFailed(561),
      "main.leaf",
    ),
    @types.TuiEvent::PrStatusChanged(
      pr_number=561,
      agent_id="main.leaf",
      kind=@types.PrEventKind::CiFailed,
      detail="",
    ),
  )
}
