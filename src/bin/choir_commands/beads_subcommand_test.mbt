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
test "parse_beads_cli_args parses spec link force flag" {
  let got = parse_beads_cli_args([
    "choir", "beads", "spec-link", "choir-a", "beads-glue", "--force",
  ])
  match got {
    Ok(BeadsCliRequest::SpecLink(args)) => {
      assert_eq(args.issue_id, "choir-a")
      assert_eq(args.feature_slug, "beads-glue")
      assert_true(args.force)
    }
    _ => fail("expected spec-link args")
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
async test "run_beads_spec_link refuses missing spec file" {
  let tmp = "/tmp/choir-beads-spec-link-missing-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(tmp))
  assert_true(@sys.create_dir_all(tmp + "/.choir/context"))
  let seen : Array[String] = []
  let got = run_beads_spec_link(
    tmp,
    { issue_id: "choir-a", feature_slug: "missing", force: false },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "ok\n")
    },
  )
  ignore(@sys.rm_rf(tmp))
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        "validation error: spec file .choir/context/missing-spec.md does not exist (or is empty); refuse to link",
      )
    Ok(_) => fail("expected missing spec error")
  }
  assert_eq(seen.length(), 0)
}

///|
async test "run_beads_spec_link force allows missing spec file" {
  let tmp = "/tmp/choir-beads-spec-link-force-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(tmp))
  let seen : Array[String] = []
  let got = run_beads_spec_link(
    tmp,
    { issue_id: "choir-a", feature_slug: "future", force: true },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "ok\n")
    },
  )
  ignore(@sys.rm_rf(tmp))
  match got {
    Ok(text) => assert_eq(text, "ok\n")
    Err(e) => fail(e.message())
  }
  assert_eq(seen.length(), 1)
  assert_true(
    seen[0].contains("update choir-a --spec-id .choir/context/future-spec.md"),
  )
}

///|
async test "run_beads_spec_link succeeds for existing spec file" {
  let tmp = "/tmp/choir-beads-spec-link-existing-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(tmp))
  assert_true(@sys.create_dir_all(tmp + "/.choir/context"))
  assert_true(
    @sys.write_file_sync(tmp + "/.choir/context/beads-glue-spec.md", "# Spec\n"),
  )
  let seen : Array[String] = []
  let got = run_beads_spec_link(
    tmp,
    { issue_id: "choir-a", feature_slug: "beads-glue", force: false },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "linked\n")
    },
  )
  ignore(@sys.rm_rf(tmp))
  match got {
    Ok(text) => assert_eq(text, "linked\n")
    Err(e) => fail(e.message())
  }
  assert_eq(seen.length(), 1)
  assert_true(
    seen[0].contains(
      "update choir-a --spec-id .choir/context/beads-glue-spec.md",
    ),
  )
}

///|
async test "run_beads_doctor parses warning-prefixed ready json" {
  let got = run_beads_doctor("/repo", async fn(
    cmd : @workspace.Command,
  ) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "ready" {
      (0, "Warning: auto-export in progress\n[]")
    } else if cmd.program == "bd" {
      (0, "[]")
    } else {
      (0, "")
    }
  })
  match got {
    Ok(text) => {
      assert_true(text.contains("ready_count: 0"))
      assert_true(text.contains("in_progress_count: 0"))
    }
    Err(e) => fail(e.message())
  }
}

///|
async test "run_beads_doctor parses clean valid json" {
  let got = run_beads_doctor("/repo", async fn(
    cmd : @workspace.Command,
  ) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "ready" {
      (
        0,
        (
          #|[{"id":"choir-ready","title":"Ready","status":"open"}]
        ),
      )
    } else if cmd.program == "bd" {
      (
        0,
        (
          #|[{"id":"choir-progress","title":"Busy","status":"in_progress"}]
        ),
      )
    } else {
      (0, "")
    }
  })
  match got {
    Ok(text) => {
      assert_true(text.contains("ready_count: 1"))
      assert_true(text.contains("in_progress_count: 1"))
    }
    Err(e) => fail(e.message())
  }
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
        force: true,
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
