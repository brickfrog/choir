///|
test "default config" {
  let config = @types.Config::default()
  assert_eq(config.default_role, @types.Role::TL)
  assert_eq(config.listen_uds, ".choir/server.sock")
  @debug.assert_eq(config.listen_tcp, None)
  @debug.assert_eq(config.extra_mcp_servers_json, None)
  @debug.assert_eq(config.companions_json, None)
  @debug.assert_eq(config.plugins_json, None)
}

///|
test "Reviewer wire strings round-trip fixed values and named handles" {
  let cases : Array[@types.Reviewer] = [
    @types.Reviewer::None,
    @types.Reviewer::Copilot,
    @types.Reviewer::Named("octocat"),
    @types.Reviewer::Named("@maintainer"),
  ]
  for reviewer in cases {
    match @types.Reviewer::try_parse_wire(reviewer.to_wire_string()) {
      Ok(parsed) => assert_eq(parsed, reviewer)
      Err(e) => fail(e.message())
    }
  }
}

///|
test "Reviewer try_parse_wire maps non-empty custom handles to Named" {
  match @types.Reviewer::try_parse_wire("alice") {
    Ok(@types.Reviewer::Named(handle)) => assert_eq(handle, "alice")
    Ok(other) => fail("expected named reviewer, got " + other.to_wire_string())
    Err(e) => fail(e.message())
  }
  match @types.Reviewer::try_parse_wire("") {
    Err(e) => assert_true(e.message().contains("reviewer"))
    Ok(_) => fail("expected empty reviewer to be rejected")
  }
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
    let parse_wire_result = try @types.Role::parse_wire(s) catch {
      e => Err(e)
    } noraise {
      role => Ok(role)
    }
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
test "is_supervisor_role identifies only root and TL" {
  assert_true(@types.is_supervisor_role(@types.Role::Root))
  assert_true(@types.is_supervisor_role(@types.Role::TL))
  assert_false(@types.is_supervisor_role(@types.Role::Dev))
  assert_false(@types.is_supervisor_role(@types.Role::Worker))
}

///|
test "path guards reject project root and accept managed worktrees" {
  assert_true(@types.path_is_project_root_or_parent("/repo", "/repo"))
  assert_true(@types.path_is_project_root_or_parent("/repo/sub", "/repo"))
  assert_true(@types.path_is_project_root_or_parent("/repo", ""))
  assert_true(@types.path_is_project_root_or_parent("/repo", "."))
  assert_false(
    @types.path_is_project_root_or_parent(
      "/repo", "/repo/.choir/worktrees/leaf",
    ),
  )
  assert_true(
    @types.is_choir_managed_worktree_path(
      "/repo", "/repo/.choir/worktrees/leaf",
    ),
  )
  assert_true(
    @types.is_choir_managed_worktree_path(
      "/repo", "/repo/.choir/review-worktrees/main.audit-worker",
    ),
  )
  assert_true(
    @types.is_choir_managed_worktree_path(".", "./.choir/worktrees/leaf"),
  )
  assert_false(@types.is_choir_managed_worktree_path("/repo", "/repo"))
  assert_false(
    @types.is_choir_managed_worktree_path(
      "/repo", "/other/.choir/worktrees/leaf",
    ),
  )
  assert_false(
    @types.is_choir_managed_worktree_path(
      "/repo", "/repo/.choir/worktrees/../config",
    ),
  )
}

///|
test "TaskStatus accepts Beads status aliases" {
  match @types.TaskStatus::try_parse_wire("open") {
    Ok(status) => @debug.assert_eq(status, @types.TaskStatus::Todo)
    Err(e) => fail(e.message())
  }
  match @types.TaskStatus::try_parse_wire("closed") {
    Ok(status) => @debug.assert_eq(status, @types.TaskStatus::Done)
    Err(e) => fail(e.message())
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
  match @types.AgentType::try_parse_wire("agent") {
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
    "claude", "gemini", "moon_pilot", "moonpilot", "codex", "agent", "cursor_agent",
    "cursoragent", "", "unknown",
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
    let parse_wire_result = try @types.AgentType::parse_wire(s) catch {
      e => Err(e)
    } noraise {
      agent_type => Ok(agent_type)
    }
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
  assert_true(contract.verify_satisfied_by_ci)
}

///|
test "TaskContract round trips verify_satisfied_by_ci" {
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
    verify_satisfied_by_ci: false,
  }
  let json = @json.parse(contract.to_json_string()) catch {
    _ => fail("expected contract JSON to parse")
  }
  let parsed : @types.TaskContract = @json.from_json(json) catch {
    _ => fail("expected contract JSON to decode")
  }
  @debug.assert_eq(parsed, contract)
  assert_false(parsed.verify_satisfied_by_ci)
}

///|
test "TaskContract round trips guard_paths" {
  let contract = {
    ..@types.TaskContract::empty(),
    goal: "protect generated files",
    guard_paths: ["hooks/**", ".choir/hooks/hook.wasm"],
  }
  let json = @json.parse(contract.to_json_string()) catch {
    _ => fail("expected contract JSON to parse")
  }
  let parsed : @types.TaskContract = @json.from_json(json) catch {
    _ => fail("expected contract JSON to decode")
  }
  @debug.assert_eq(parsed, contract)
  @debug.assert_eq(parsed.guard_paths, ["hooks/**", ".choir/hooks/hook.wasm"])
}

///|
test "TaskContract missing verify_satisfied_by_ci decodes as true" {
  let parsed_json = @json.parse(
    (
      #|{"goal":"ship feature","scope":[],"acceptance_checks":[],"constraints":[],"non_goals":[],"beads_issue_id":null,"review_context":null,"verify":["moon test --target native"]}
    ),
  ) catch {
    _ => fail("expected legacy contract JSON to parse")
  }
  let contract : @types.TaskContract = @json.from_json(parsed_json) catch {
    _ => fail("expected legacy contract JSON to decode")
  }
  assert_eq(contract.goal, "ship feature")
  @debug.assert_eq(contract.verify, ["moon test --target native"])
  assert_true(contract.verify_satisfied_by_ci)
}

///|
test "TaskContract CI satisfaction trusts contract field for moon targets" {
  let ci_satisfied = {
    ..@types.TaskContract::empty(),
    verify: ["moon test --target wasm-gc"],
    verify_satisfied_by_ci: true,
  }
  assert_true(@types.task_contract_verify_satisfied_by_ci(ci_satisfied))
  let ci_not_satisfied = { ..ci_satisfied, verify_satisfied_by_ci: false }
  assert_false(@types.task_contract_verify_satisfied_by_ci(ci_not_satisfied))
}

///|
test "moon render suppression appends no-render to runtime moon commands" {
  assert_eq(
    @types.moon_render_suppress_command("moon test --target native"),
    "moon test --target native --no-render",
  )
  assert_eq(
    @types.moon_render_suppress_command(
      "CC=cc moon check && moon build --target native",
    ),
    "CC=cc moon check --no-render && moon build --target native --no-render",
  )
  assert_eq(
    @types.moon_render_suppress_command("moon -C subdir test --target native"),
    "moon -C subdir test --target native --no-render",
  )
  assert_eq(
    @types.moon_render_suppress_command("/usr/bin/moon test # run verify"),
    "/usr/bin/moon test --no-render # run verify",
  )
  assert_eq(
    @types.moon_render_suppress_command("moon test # comment && moon check"),
    "moon test --no-render # comment && moon check",
  )
  assert_eq(
    @types.moon_render_suppress_command(
      "./.moon/bin/moon --target wasm-gc check",
    ),
    "./.moon/bin/moon --target wasm-gc check --no-render",
  )
  assert_eq(
    @types.moon_render_suppress_command(
      "echo \"moon test\"; moon test --no-render",
    ),
    "echo \"moon test\"; moon test --no-render",
  )
}

///|
test "moon verify command normalization appends default native target only when missing" {
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon check", "moon test --target native", "echo hi"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon check --target native", "moon test --target native", "echo hi"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon test", "moon check"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon test --target native", "moon check --target native"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon check --target wasm-gc", "moon check --target=wasm-gc"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon check --target wasm-gc", "moon check --target=wasm-gc"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon test"],
      @types.MoonVerifyTarget::WasmGc,
    ),
    ["moon test --target wasm-gc"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon test && echo ok", "moon check; echo done"],
      @types.MoonVerifyTarget::Native,
    ),
    [
      "moon test --target native && echo ok", "moon check --target native; echo done",
    ],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      [
        "moon test && moon check", "echo ok | moon check", "moon test\nmoon check",
      ],
      @types.MoonVerifyTarget::Native,
    ),
    [
      "moon test --target native && moon check --target native", "echo ok | moon check --target native",
      "moon test --target native\nmoon check --target native",
    ],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon test && moon check --target js"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon test --target native && moon check --target js"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["/usr/bin/moon test # run verify"],
      @types.MoonVerifyTarget::Native,
    ),
    ["/usr/bin/moon test --target native # run verify"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon test # comment && moon check"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon test --target native # comment && moon check"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      [
        "CC=cc moon test", "A=1 B=2 moon test", "FOO=a=b moon test", "moon -C hooks test",
        "moon -Chooks test", "moon --directory hooks check", "moon -C hooks test --target wasm-gc",
        "moon -C subdir test", "moon --dry-run test",
      ],
      @types.MoonVerifyTarget::Native,
    ),
    [
      "CC=cc moon test --target native", "A=1 B=2 moon test --target native", "FOO=a=b moon test --target native",
      "moon -C hooks test", "moon -Chooks test", "moon --directory hooks check",
      "moon -C hooks test --target wasm-gc", "moon -C subdir test", "moon --dry-run test --target native",
    ],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon --target wasm-gc test", "moon --target native test"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon --target wasm-gc test", "moon --target native test"],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      [
        "echo \"moon test && moon check\"", "moon test \"literal && value\"; moon check",
        "echo 'moon test | moon check'",
      ],
      @types.MoonVerifyTarget::Native,
    ),
    [
      "echo \"moon test && moon check\"", "moon test \"literal && value\" --target native; moon check --target native",
      "echo 'moon test | moon check'",
    ],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      [
        "moon test 2>&1", "moon test 1>&2", "moon test &> out", "moon test &>> out",
        "moon test <&0",
      ],
      @types.MoonVerifyTarget::Native,
    ),
    [
      "moon test 2>&1 --target native", "moon test 1>&2 --target native", "moon test &> out --target native",
      "moon test &>> out --target native", "moon test <&0 --target native",
    ],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      [
        "moon test |& tee out", "moon test & echo done", "moon test & moon check",
      ],
      @types.MoonVerifyTarget::Native,
    ),
    [
      "moon test --target native |& tee out", "moon test --target native & echo done",
      "moon test --target native & moon check --target native",
    ],
  )
  @debug.assert_eq(
    @types.moon_verify_normalize_commands(
      ["moon test 2>&1 && moon check 1>&2"],
      @types.MoonVerifyTarget::Native,
    ),
    ["moon test 2>&1 --target native && moon check 1>&2 --target native"],
  )
  let notices = @types.moon_verify_normalization_notices(
    [" moon test ", "moon check --target native", "npm test"],
    @types.MoonVerifyTarget::WasmGc,
  )
  @debug.assert_eq(notices, [
    {
      command: "moon test",
      normalized: "moon test --target wasm-gc",
      target: @types.MoonVerifyTarget::WasmGc,
    },
  ])
  match
    @types.task_contract_with_normalized_verify(
      Some({
        ..@types.TaskContract::empty(),
        verify: ["moon check"],
        verify_satisfied_by_ci: true,
      }),
      @types.MoonVerifyTarget::WasmGc,
    ) {
    Some(contract) => {
      @debug.assert_eq(contract.verify, ["moon check --target wasm-gc"])
      assert_true(@types.task_contract_verify_satisfied_by_ci(contract))
    }
    None => fail("expected normalized task contract")
  }
  match @types.MoonVerifyTarget::try_parse_wire("bogus") {
    Err(e) =>
      assert_eq(
        e.message(),
        "config error: moon_verify_target must be \"native\", \"wasm\", \"wasm-gc\", or \"js\"",
      )
    Ok(_) => fail("expected invalid moon_verify_target to be rejected")
  }
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
test "evaluation_cascade ready with passed required verify" {
  let result = @types.evaluation_cascade(["moon test --target native"], [
    @types.EvaluationSignal::Review(
      state=@types.EvaluationReviewState::Commented,
      body="left comments",
    ),
    @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
    @types.EvaluationSignal::ThreadsObserved(count=0),
    @types.EvaluationSignal::CopilotIssueCommentObserved,
    @types.EvaluationSignal::Verify(result={
      name: "moon test --target native",
      status: @types.VerifyStatus::Passed,
      details: "satisfied by CI rollup success at head-sha",
    }),
  ])
  match result {
    @types.CascadeVerdict::Ready(_) => ()
    _ => fail("expected Ready")
  }
}

///|
test "evaluation_cascade ready with absent review when review not required" {
  let result = @types.evaluation_cascade(
    ["moon test --target native"],
    [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::None_,
        body="",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "satisfied by CI rollup success at head-sha",
      }),
    ],
    review_required=false,
  )
  match result {
    @types.CascadeVerdict::Ready(_) => ()
    _ => fail("expected Ready")
  }
}

///|
test "evaluation_cascade still waits for absent review when review required" {
  let result = @types.evaluation_cascade(
    ["moon test --target native"],
    [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::None_,
        body="",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "satisfied by CI rollup success at head-sha",
      }),
    ],
    review_required=true,
  )
  match result {
    @types.CascadeVerdict::Waiting(reason~) =>
      assert_eq(reason, "waiting for review")
    _ => fail("expected Waiting")
  }
}

///|
test "evaluation_cascade blocks changes requested even when review not required" {
  let result = @types.evaluation_cascade(
    ["moon test --target native"],
    [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::ChangesRequested,
        body="please fix",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "satisfied by CI rollup success at head-sha",
      }),
    ],
    review_required=false,
  )
  match result {
    @types.CascadeVerdict::Blocked(reason~) =>
      assert_true(reason.contains("changes requested"))
    _ => fail("expected Blocked")
  }
}

///|
test "evaluation_cascade ready for comment-only review without Copilot comment when review not required" {
  let result = @types.evaluation_cascade(
    ["moon test --target native"],
    [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::CopilotIssueCommentUnobserved,
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "satisfied by CI rollup success at head-sha",
      }),
    ],
    review_required=false,
  )
  match result {
    @types.CascadeVerdict::Ready(_) => ()
    _ => fail("expected Ready")
  }
}

///|
test "advisory_evaluation_result ready when GitHub reports no CI checks" {
  let bundle : @types.EvaluationBundle = {
    task_contract: None,
    signals: [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::NoChecks),
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
