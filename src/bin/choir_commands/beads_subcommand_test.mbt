///|
test "parse_beads_cli_args parses wave-from execution flags" {
  let got = parse_beads_cli_args([
    "choir", "beads", "wave-from", "choir-epic", "--caller-id", "main.tl", "--parent-branch",
    "feature/beads", "--slug-prefix", "beads", "--execute",
  ])
  match got {
    Ok(BeadsCliRequest::WaveFrom(args)) => {
      assert_eq(args.parent_id, "choir-epic")
      assert_eq(args.caller_id, "main.tl")
      assert_eq(args.parent_branch, "feature/beads")
      assert_eq(args.slug_prefix, "beads")
      assert_true(args.execute)
    }
    _ => fail("expected wave-from args")
  }
}

///|
test "parse_beads_cli_args parses cross bead gate" {
  let got = parse_beads_cli_args([
    "choir", "beads", "gate", "choir-ui", "bead", "waiting on api", "--await-id",
    "api:api-123",
  ])
  match got {
    Ok(BeadsCliRequest::Gate(args)) => {
      assert_eq(args.issue_id, "choir-ui")
      assert_eq(args.gate_type, "bead")
      assert_eq(args.reason, "waiting on api")
      @debug.assert_eq(args.await_id, Some("api:api-123"))
    }
    _ => fail("expected gate args")
  }
}

///|
async test "run_beads_wave_from renders fork_wave plan from ready children" {
  let seen : Array[String] = []
  let output = run_beads_wave_from(
    {
      parent_id: "choir-epic",
      caller_id: "main.tl",
      parent_branch: "feature/beads",
      slug_prefix: "beads",
      execute: false,
    },
    "/repo",
    "choir",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (
        0,
        (
          #|[{"id":"choir-a","title":"A","status":"open","notes":"n","labels":["agent:codex","automerge:true"]}]
        ),
      )
    },
  )
  match output {
    Ok(text) => {
      assert_true(seen[0].contains("ready --json --parent choir-epic"))
      assert_true(text.contains("\"fork_wave\""))
      assert_true(text.contains("\"beads_issue_id\":\"choir-a\""))
      assert_true(text.contains("\"agent_type\":\"codex\""))
      assert_true(text.contains("\"automerge\":true"))
    }
    Err(e) => fail(e.message())
  }
}

///|
async test "run_beads_wave_from execute invokes choir tool fork_wave" {
  let seen : Array[String] = []
  let output = run_beads_wave_from(
    {
      parent_id: "choir-epic",
      caller_id: "main.tl",
      parent_branch: "feature/beads",
      slug_prefix: "beads",
      execute: true,
    },
    "/repo",
    "/bin/choir",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.program + " " + cmd.args.join(" "))
      if cmd.program == "bd" {
        (
          0,
          (
            #|[{"id":"choir-a","title":"A","status":"open","notes":"","labels":[]}]
          ),
        )
      } else {
        (0, "{\"ok\":true}\n")
      }
    },
  )
  match output {
    Ok(text) => {
      assert_eq(text, "{\"ok\":true}\n")
      assert_true(seen.join("\n").contains("tool fork_wave"))
      assert_true(seen.join("\n").contains("\"beads_issue_id\":\"choir-a\""))
    }
    Err(e) => fail(e.message())
  }
}

///|
test "build_beads_doctor_report flags export and unrelated dirty paths" {
  let report = build_beads_doctor_report(
    (
      #|[{"id":"choir-ready","title":"Ready","status":"open"}]
    ),
    (
      #|[{"id":"choir-progress","title":"Busy","status":"in_progress"}]
    ),
    " M .beads/issues.jsonl\n M src/tools/foo.mbt\n",
  ).unwrap()
  assert_eq(report.ready_count, 1)
  assert_eq(report.in_progress_count, 1)
  assert_true(report.beads_export_dirty)
  assert_eq(report.unrelated_dirty_paths, ["src/tools/foo.mbt"])
  let rendered = render_beads_doctor_report(report)
  assert_true(rendered.contains("ready_count: 1"))
  assert_true(rendered.contains("- src/tools/foo.mbt"))
}

///|
async test "run_beads_cli_request proxies gate merge slot and spec link commands" {
  let seen : Array[String] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    seen.push(cmd.args.join(" "))
    (0, "ok\n")
  }
  ignore(
    run_beads_cli_request(
      BeadsCliRequest::Gate({
        issue_id: "choir-a",
        gate_type: "human",
        reason: "needs review",
        await_id: None,
      }),
      "/repo",
      "choir",
      capture,
    ),
  )
  ignore(
    run_beads_cli_request(
      BeadsCliRequest::MergeSlot("acquire"),
      "/repo",
      "choir",
      capture,
    ),
  )
  ignore(
    run_beads_cli_request(
      BeadsCliRequest::SpecLink({
        issue_id: "choir-a",
        feature_slug: "beads-glue",
      }),
      "/repo",
      "choir",
      capture,
    ),
  )
  let rendered = seen.join("\n")
  assert_true(rendered.contains("gate create --type human --blocks choir-a"))
  assert_true(rendered.contains("merge-slot acquire"))
  assert_true(
    rendered.contains(
      "update choir-a --spec-id .choir/context/beads-glue-spec.md",
    ),
  )
}
