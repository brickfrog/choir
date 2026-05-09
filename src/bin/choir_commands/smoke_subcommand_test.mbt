///|
fn smoke_args() -> SmokeBeadsArgs {
  {
    issue_id: "choir-beads-live-smoke",
    slug: "beads-smoke",
    caller_id: "main",
    timeout_sec: 30,
    poll_interval_ms: 10,
    help: false,
  }
}

///|
test "parse_smoke_beads_args supports explicit canary knobs" {
  let got = parse_smoke_beads_args([
    "choir", "smoke", "beads-handoff", "--id", "choir-beads-live-smoke", "--slug",
    "beads-smoke", "--caller-id", "main", "--timeout-sec", "30", "--poll-interval-ms",
    "10",
  ]).unwrap()
  assert_eq(got.issue_id, "choir-beads-live-smoke")
  assert_eq(got.slug, "beads-smoke")
  assert_eq(got.caller_id, "main")
  assert_eq(got.timeout_sec, 30)
  assert_eq(got.poll_interval_ms, 10)
  assert_false(got.help)
}

///|
test "parse_smoke_beads_args defaults timeout to 300 seconds" {
  let got = parse_smoke_beads_args(["choir", "smoke", "beads-handoff"]).unwrap()
  assert_eq(got.timeout_sec, 300)
}

///|
test "smoke_beads_spawn_args passes beads issue id without agent_type override" {
  let args = smoke_args()
  let got = smoke_beads_spawn_args(args)
  @debug.assert_eq(got.get("caller_id"), Some("main".to_json()))
  @debug.assert_eq(got.get("slug"), Some("beads-smoke".to_json()))
  @debug.assert_eq(got.get("worker_type"), Some("research".to_json()))
  @debug.assert_eq(
    got.get("beads_issue_id"),
    Some("choir-beads-live-smoke".to_json()),
  )
  assert_false(got.contains("agent_type"))
  match got.get("contract") {
    Some(Object(contract)) =>
      @debug.assert_eq(
        contract.get("beads_issue_id"),
        Some("choir-beads-live-smoke".to_json()),
      )
    _ => fail("expected contract object")
  }
}

///|
test "git_status_only_beads_issue_export rejects unrelated paths" {
  assert_true(git_status_only_beads_issue_export(""))
  assert_true(git_status_only_beads_issue_export("M  .beads/issues.jsonl\n"))
  assert_false(
    git_status_only_beads_issue_export(
      "M  .beads/issues.jsonl\n M src/bin/choir/main.mbt\n",
    ),
  )
}

///|
fn event_line(tool : String) -> Event {
  {
    ts_ms: 1L,
    agent_id: "main.beads-smoke",
    type_: "tools.call",
    data: { "tool": tool.to_json(), "status": "ok".to_json() }.to_json(),
  }
}

///|
test "smoke_beads_events_pass accepts task_get and notify_parent without shutdown" {
  assert_true(
    smoke_beads_events_pass([
      event_line("task_get"),
      event_line("notify_parent"),
    ]),
  )
}

///|
test "smoke_beads_events_pass rejects task_get without notify_parent" {
  assert_false(smoke_beads_events_pass([event_line("task_get")]))
}

///|
test "render_smoke_beads_report includes observed metadata" {
  let rendered = render_smoke_beads_report({
    issue_id: "choir-beads-live-smoke",
    worker_id: "main.beads-smoke",
    role: "worker",
    agent_type: "codex",
    beads_issue_id: "choir-beads-live-smoke",
    worker_status: "",
    final_status: "M  .beads/issues.jsonl\n",
  })
  assert_true(rendered.contains("PASS choir smoke beads-handoff"))
  assert_true(rendered.contains("worker_id: main.beads-smoke"))
  assert_true(rendered.contains("agent_type: codex"))
  assert_true(
    rendered.contains(
      "task_get ok, notify_parent ok; shutdown observability-only after notify_parent",
    ),
  )
}

///|
fn smoke_event_jsonl() -> String {
  "{\"ts\":1,\"type\":\"tools.call\",\"agent_id\":\"main.beads-smoke\",\"data\":{\"tool\":\"task_get\",\"status\":\"ok\"}}\n" +
  "{\"ts\":2,\"type\":\"tools.call\",\"agent_id\":\"main.beads-smoke\",\"data\":{\"tool\":\"notify_parent\",\"status\":\"ok\"}}\n" +
  "{\"ts\":3,\"type\":\"lifecycle.transition\",\"agent_id\":\"main.beads-smoke\",\"data\":{\"trigger\":\"FinalizeComplete\",\"to\":\"{\\\"process\\\":[\\\"Finalized\\\",{\\\"reason\\\":\\\"Shutdown\\\"}],\\\"workflow\\\":[\\\"Worker\\\",[\\\"Done\\\",{\\\"reason\\\":\\\"Shutdown\\\"}]]}\"}}\n"
}

///|
async test "run_smoke_beads_handoff sequences tool calls and closes on pass" {
  let tmp = "/tmp/choir-smoke-beads-test-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp + "/.choir/events"))
  ignore(
    @sys.write_file_sync(
      tmp + "/.choir/events/main.beads-smoke.jsonl",
      smoke_event_jsonl(),
    ),
  )
  let seen : Array[String] = []
  let args = smoke_args()
  let report = run_smoke_beads_handoff(
    args,
    "choir-dev",
    tmp,
    capture=fn(cmd : @workspace.Command) -> (Int, String) {
      seen.push(cmd.program + " " + cmd.args.join(" "))
      if cmd.program == "git" {
        return (0, "M  .beads/issues.jsonl\n")
      }
      if cmd.program == "choir-dev" &&
        cmd.args.length() > 1 &&
        cmd.args[1] == "task_create" {
        return (0, "{\"ok\":true,\"result\":{\"status\":\"ok\"}}\n")
      }
      if cmd.program == "choir-dev" &&
        cmd.args.length() > 1 &&
        cmd.args[1] == "spawn_worker" {
        return (
          0, "{\"ok\":true,\"result\":{\"status\":\"spawned\",\"agent_id\":\"main.beads-smoke\",\"agent_ids\":\"main.beads-smoke\",\"role\":\"worker\",\"agent_type\":\"codex\",\"beads_issue_id\":\"choir-beads-live-smoke\"}}\n",
        )
      }
      if cmd.program == "bd" {
        return (0, "ok\n")
      }
      (1, "unexpected command")
    },
    sleep_fn=fn(_ms : Int) -> Unit { () },
  ).unwrap()
  assert_eq(report.worker_id, "main.beads-smoke")
  assert_eq(report.agent_type, "codex")
  assert_eq(report.beads_issue_id, "choir-beads-live-smoke")
  assert_eq(seen.length(), 7)
  assert_true(seen[0].contains("git status --short"))
  assert_true(seen[1].contains("task_create"))
  assert_true(seen[2].contains("spawn_worker"))
  assert_true(seen[4].contains("bd close choir-beads-live-smoke"))
  assert_true(seen[5].contains("bd export --output .beads/issues.jsonl"))
  assert_true(seen[6].contains("git status --short"))
  ignore(@sys.rm_rf(tmp))
}
