///|
test "default config" {
  let config = @types.Config::default()
  assert_eq(config.default_role, @types.Role::TL)
  assert_eq(config.listen_uds, ".choir/server.sock")
  assert_eq(config.listen_tcp, None)
  assert_eq(config.extra_mcp_servers_json, None)
  assert_eq(config.companions_json, None)
  assert_eq(config.plugins_json, None)
}

///|
test "Role try_parse_wire round-trips to_wire_string for all roles" {
  let roles : Array[@types.Role] = [
    @types.Role::Root,
    @types.Role::TL,
    @types.Role::Dev,
    @types.Role::Worker,
  ]
  for r in roles {
    match @types.Role::try_parse_wire(r.to_wire_string()) {
      Ok(parsed) => assert_eq(parsed, r)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "Role try_parse_wire rejects unknown strings with config_error messages" {
  match @types.Role::try_parse_wire("TL") {
    Err(e) => assert_eq(e.message(), "config error: unknown role: TL")
    Ok(_) => fail("expected unknown role error for TL")
  }
  match @types.Role::try_parse_wire("") {
    Err(e) => assert_eq(e.message(), "config error: unknown role: ")
    Ok(_) => fail("expected unknown role error for empty")
  }
}

///|
test "Role parse_wire agrees with try_parse_wire on every wire string" {
  let wires = ["root", "tl", "dev", "worker"]
  for w in wires {
    match @types.Role::try_parse_wire(w) {
      Ok(expected) => assert_eq(@types.Role::parse_wire(w), expected)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "Role parse_wire raises on unknown strings matching try_parse_wire error" {
  let unknowns = ["TL", "Worker", "", "ROOT", "unknown"]
  for s in unknowns {
    let parse_wire_result = try? @types.Role::parse_wire(s)
    match (parse_wire_result, @types.Role::try_parse_wire(s)) {
      (Err(raised), Err(expected)) =>
        assert_eq(raised.message(), expected.message())
      (Ok(_), _) => fail("parse_wire should have raised for: " + s)
      (Err(_), Ok(_)) =>
        fail("try_parse_wire returned Ok but parse_wire raised for: " + s)
    }
  }
}

///|
test "AgentType try_parse_wire accepts legacy aliases" {
  match @types.AgentType::try_parse_wire("moonpilot") {
    Ok(t) => assert_eq(t, @types.AgentType::MoonPilot)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("cursoragent") {
    Ok(t) => assert_eq(t, @types.AgentType::CursorAgent)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("") {
    Ok(t) => assert_eq(t, @types.AgentType::Unknown)
    Err(e) => fail(e.message())
  }
  match @types.AgentType::try_parse_wire("unknown") {
    Ok(t) => assert_eq(t, @types.AgentType::Unknown)
    Err(e) => fail(e.message())
  }
}

///|
test "AgentType try_parse_wire round-trips to_wire_string for all types" {
  let types : Array[@types.AgentType] = [
    @types.AgentType::Claude,
    @types.AgentType::Gemini,
    @types.AgentType::MoonPilot,
    @types.AgentType::Codex,
    @types.AgentType::CursorAgent,
    @types.AgentType::Unknown,
  ]
  for t in types {
    match @types.AgentType::try_parse_wire(t.to_wire_string()) {
      Ok(parsed) => assert_eq(parsed, t)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "AgentType try_parse_wire rejects unknown strings with config_error messages" {
  match @types.AgentType::try_parse_wire("unknown_bot") {
    Err(e) =>
      assert_eq(e.message(), "config error: unknown agent_type: unknown_bot")
    Ok(_) => fail("expected unknown agent_type")
  }
}

///|
test "AgentType parse_wire agrees with try_parse_wire on canonical and alias strings" {
  let inputs = [
    "claude", "gemini", "moon_pilot", "moonpilot", "codex", "cursor_agent", "cursoragent",
    "", "unknown",
  ]
  for s in inputs {
    match @types.AgentType::try_parse_wire(s) {
      Ok(expected) => assert_eq(@types.AgentType::parse_wire(s), expected)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "AgentType parse_wire raises on unknown strings matching try_parse_wire error" {
  let unknowns = ["Claude", "MoonPilot", "gpt4", "CODEX"]
  for s in unknowns {
    let parse_wire_result = try? @types.AgentType::parse_wire(s)
    match (parse_wire_result, @types.AgentType::try_parse_wire(s)) {
      (Err(raised), Err(expected)) =>
        assert_eq(raised.message(), expected.message())
      (Ok(_), _) => fail("parse_wire should have raised for: " + s)
      (Err(_), Ok(_)) =>
        fail("try_parse_wire returned Ok but parse_wire raised for: " + s)
    }
  }
}

///|
test "TaskContract empty helper returns empty contract" {
  let contract = @types.TaskContract::empty()
  assert_true(contract.is_empty())
  assert_eq(contract.goal, "")
  assert_eq(contract.verify.length(), 0)
}

///|
test "advisory_evaluation_result ready when review CI and threads are clear" {
  let bundle : @types.EvaluationBundle = {
    task_contract: None,
    signals: [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::CopilotIssueCommentObserved,
    ],
  }
  let result = @types.advisory_evaluation_result(bundle)
  assert_eq(result.verdict, @types.EvaluationVerdict::Ready)
  assert_true(result.summary.contains("ready"))
}

///|
test "advisory_evaluation_result ready for comment-only review when CI and threads are clear" {
  let bundle : @types.EvaluationBundle = {
    task_contract: None,
    signals: [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::CopilotIssueCommentObserved,
    ],
  }
  let result = @types.advisory_evaluation_result(bundle)
  assert_eq(result.verdict, @types.EvaluationVerdict::Ready)
  assert_true(result.summary.contains("ready"))
}

///|
test "advisory_evaluation_result needs human for comment-only review before Copilot comments arrive" {
  let bundle : @types.EvaluationBundle = {
    task_contract: None,
    signals: [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::CopilotIssueCommentUnobserved,
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
    ],
  }
  let result = @types.advisory_evaluation_result(bundle)
  match result.verdict {
    @types.EvaluationVerdict::NeedsHuman(reason~) =>
      assert_true(reason.contains("Copilot comments"))
    _ => fail("expected NeedsHuman verdict")
  }
}

///|
test "advisory_evaluation_result needs human when verify evidence is missing" {
  let bundle : @types.EvaluationBundle = {
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "ship feature",
      verify: ["moon test --target native"],
    }),
    signals: [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
    ],
  }
  let result = @types.advisory_evaluation_result(bundle)
  match result.verdict {
    @types.EvaluationVerdict::NeedsHuman(reason~) =>
      assert_true(reason.contains("local verify not observed"))
    _ => fail("expected NeedsHuman verdict")
  }
}

///|
test "advisory_evaluation_result blocks on failed verify" {
  let bundle : @types.EvaluationBundle = {
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "ship feature",
      verify: ["moon test --target native"],
    }),
    signals: [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Failed,
        details: "1 test failed",
      }),
    ],
  }
  let result = @types.advisory_evaluation_result(bundle)
  match result.verdict {
    @types.EvaluationVerdict::Blocked(reason~) =>
      assert_true(reason.contains("local verify failed"))
    _ => fail("expected Blocked verdict")
  }
}
