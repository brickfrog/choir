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
test "render_beads_doctor_report adds dirty export hint only when non clean" {
  let dirty = build_beads_doctor_report("[]", "[]", " M .beads/issues.jsonl\n").unwrap()
  let dirty_rendered = render_beads_doctor_report(dirty)
  assert_true(
    dirty_rendered.contains(
      "beads_export_dirty: true\n  ↳ run `bd dolt commit -am \"sync issues\"` to commit bd state\n",
    ),
  )
  let clean = build_beads_doctor_report("[]", "[]", "").unwrap()
  let clean_rendered = render_beads_doctor_report(clean)
  assert_true(clean_rendered.contains("beads_export_dirty: false\n"))
  assert_false(clean_rendered.contains("↳"))
}

///|
async test "run_beads_spec_link refuses missing spec file" {
  let seen : Array[String] = []
  let file_checks : Array[String] = []
  let got = run_beads_spec_link(
    "/repo",
    { issue_id: "choir-a", feature_slug: "missing", force: false },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "ok\n")
    },
    path_entry_exists=fn(path) {
      file_checks.push("entry:" + path)
      false
    },
    path_readable=fn(path) {
      file_checks.push("readable:" + path)
      false
    },
    read_file=fn(path) {
      file_checks.push("read:" + path)
      ""
    },
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        "validation error: spec file .choir/context/missing-spec.md does not exist; refuse to link without --force",
      )
    Ok(_) => fail("expected missing spec error")
  }
  assert_eq(seen.length(), 0)
  assert_eq(file_checks, ["entry:/repo/.choir/context/missing-spec.md"])
}

///|
async test "run_beads_spec_link refuses empty spec file" {
  let seen : Array[String] = []
  let file_checks : Array[String] = []
  let got = run_beads_spec_link(
    "/repo",
    { issue_id: "choir-a", feature_slug: "empty", force: false },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "ok\n")
    },
    path_entry_exists=fn(path) {
      file_checks.push("entry:" + path)
      true
    },
    path_readable=fn(path) {
      file_checks.push("readable:" + path)
      true
    },
    read_file=fn(path) {
      file_checks.push("read:" + path)
      ""
    },
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        "validation error: spec file .choir/context/empty-spec.md exists but is empty; refuse to link without --force (typically means the spec was scaffolded but not yet written)",
      )
    Ok(_) => fail("expected empty spec error")
  }
  assert_eq(seen.length(), 0)
  assert_eq(file_checks, [
    "entry:/repo/.choir/context/empty-spec.md", "readable:/repo/.choir/context/empty-spec.md",
    "read:/repo/.choir/context/empty-spec.md",
  ])
}

///|
async test "run_beads_spec_link refuses unreadable spec file" {
  let seen : Array[String] = []
  let file_checks : Array[String] = []
  let got = run_beads_spec_link(
    "/repo",
    { issue_id: "choir-a", feature_slug: "locked", force: false },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "ok\n")
    },
    path_entry_exists=fn(path) {
      file_checks.push("entry:" + path)
      true
    },
    path_readable=fn(path) {
      file_checks.push("readable:" + path)
      false
    },
    read_file=fn(path) {
      file_checks.push("read:" + path)
      ""
    },
  )
  match got {
    Err(e) =>
      assert_eq(
        e.message(),
        "validation error: spec file .choir/context/locked-spec.md exists but is unreadable; check permissions",
      )
    Ok(_) => fail("expected unreadable spec error")
  }
  assert_eq(seen.length(), 0)
  assert_eq(file_checks, [
    "entry:/repo/.choir/context/locked-spec.md", "readable:/repo/.choir/context/locked-spec.md",
  ])
}

///|
async test "run_beads_spec_link force allows missing spec file" {
  let seen : Array[String] = []
  let file_checks : Array[String] = []
  let got = run_beads_spec_link(
    "/repo",
    { issue_id: "choir-a", feature_slug: "future", force: true },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "ok\n")
    },
    path_entry_exists=fn(path) {
      file_checks.push("entry:" + path)
      false
    },
    path_readable=fn(path) {
      file_checks.push("readable:" + path)
      false
    },
    read_file=fn(path) {
      file_checks.push("read:" + path)
      ""
    },
  )
  match got {
    Ok(text) => assert_eq(text, "ok\n")
    Err(e) => fail(e.message())
  }
  assert_eq(seen.length(), 1)
  assert_eq(file_checks.length(), 0)
  assert_true(
    seen[0].contains("update choir-a --spec-id .choir/context/future-spec.md"),
  )
}

///|
async test "run_beads_spec_link succeeds for existing spec file" {
  let seen : Array[String] = []
  let file_checks : Array[String] = []
  let got = run_beads_spec_link(
    "/repo",
    { issue_id: "choir-a", feature_slug: "beads-glue", force: false },
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "linked\n")
    },
    path_entry_exists=fn(path) {
      file_checks.push("entry:" + path)
      true
    },
    path_readable=fn(path) {
      file_checks.push("readable:" + path)
      true
    },
    read_file=fn(path) {
      file_checks.push("read:" + path)
      "# Spec\n"
    },
  )
  match got {
    Ok(text) => assert_eq(text, "linked\n")
    Err(e) => fail(e.message())
  }
  assert_eq(seen.length(), 1)
  assert_eq(file_checks, [
    "entry:/repo/.choir/context/beads-glue-spec.md", "readable:/repo/.choir/context/beads-glue-spec.md",
    "read:/repo/.choir/context/beads-glue-spec.md",
  ])
  assert_true(
    seen[0].contains(
      "update choir-a --spec-id .choir/context/beads-glue-spec.md",
    ),
  )
}

///|
test "build_beads_doctor_report parses trailing ready json noise" {
  let report = build_beads_doctor_report(
    (
      #|[{"id":"choir-ready","title":"Ready","status":"open"}]
      #|warning: auto-export finished after stdout
    ),
    "[]",
    "",
  ).unwrap()
  assert_eq(report.ready_count, 1)
  assert_eq(report.in_progress_count, 0)
}

///|
async test "run_beads_doctor reports stalled in progress bead assigned to inactive agent" {
  let got = run_beads_doctor(
    "/repo",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "ready" {
        (0, "[]")
      } else if cmd.program == "bd" &&
        cmd.args.length() > 0 &&
        cmd.args[0] == "list" {
        (
          0,
          (
            #|[{"id":"choir-stalled","title":"Stalled","status":"in_progress","assignee":"main.dead-leaf","started_at":"2026-05-10T00:00:00Z"}]
          ),
        )
      } else if cmd.program == "git" {
        (0, "")
      } else {
        (1, "unexpected command")
      }
    },
    now_sec=@tempo.DateTime::parse("2026-05-10T06:30:00Z").to_unix_seconds(),
    active_agent_ids=fn(_project_dir, _in_progress_json) {
      Some(["main.live-leaf"])
    },
  )
  match got {
    Ok(text) => {
      assert_true(
        text.contains(
          "STALLED: choir-stalled (started 6h ago, assignee main.dead-leaf not in registry)",
        ),
      )
      assert_true(
        text.contains(
          "  → bd update choir-stalled --status open --assignee \"\"",
        ),
      )
    }
    Err(e) => fail(e.message())
  }
}

///|
async test "run_beads_doctor parses warning-wrapped ready json" {
  let got = run_beads_doctor("/repo", async fn(
    cmd : @workspace.Command,
  ) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "ready" {
      (
        0,
        (
          #|Warning: auto-export in progress
          #|[
          #|  {"id":"choir-ready","title":"Ready {inside string}","status":"open"}
          #|]
          #|Warning: auto-export finished after stdout
        ),
      )
    } else if cmd.program == "bd" {
      (0, "[]")
    } else {
      (0, "")
    }
  })
  match got {
    Ok(text) => {
      assert_true(text.contains("ready_count: 1"))
      assert_true(text.contains("in_progress_count: 0"))
    }
    Err(e) => fail(e.message())
  }
}

///|
async test "run_beads_doctor parses multi-line prefix warning before ready json" {
  let got = run_beads_doctor("/repo", async fn(
    cmd : @workspace.Command,
  ) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "bd" && cmd.args.length() > 0 && cmd.args[0] == "ready" {
      (
        0,
        (
          #|[beads] auto-export already running
          #|warning: .beads/issues.jsonl changed while reading
          #|[
          #|  {"id":"choir-ready","title":"Ready","status":"open"}
          #|]
        ),
      )
    } else if cmd.program == "bd" {
      (0, "[]")
    } else {
      (0, "")
    }
  })
  match got {
    Ok(text) => {
      assert_true(text.contains("ready_count: 1"))
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
