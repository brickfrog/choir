///|
fn sample_issue(
  id : String,
  labels? : Array[String] = [],
  metadata? : Map[String, String] = {},
) -> @tools.BeadsIssue {
  {
    id,
    title: "Implement " + id,
    status: "open",
    assignee: "",
    notes: "verify with moon test",
    labels,
    metadata,
  }
}

///|
test "parse_beads_issues_json reads labels and metadata" {
  let parsed = @tools.parse_beads_issues_json(
    (
      #|[{"id":"choir-a","title":"A","status":"open","assignee":"","notes":"n","labels":["agent:gemini","automerge:true"],"metadata":{"review":"iterative"}}]
    ),
  )
  match parsed {
    Ok(items) => {
      assert_eq(items.length(), 1)
      assert_eq(items[0].id, "choir-a")
      assert_true(items[0].labels.contains("agent:gemini"))
      @debug.assert_eq(items[0].metadata.get("review"), Some("iterative"))
    }
    Err(e) => fail(e.message())
  }
}

///|
test "beads_route_for_issue parses label driven routing" {
  let route = @tools.beads_route_for_issue(
    sample_issue("choir-route", labels=[
      "agent:moon_pilot", "role:tl", "kind:review", "automerge:on", "review:iterative",
    ]),
  )
  @debug.assert_eq(route.agent_type, Some(@types.AgentType::MoonPilot))
  @debug.assert_eq(route.child_role, Some(@types.Role::TL))
  @debug.assert_eq(route.worker_type, Some("review"))
  @debug.assert_eq(route.automerge, Some(true))
  @debug.assert_eq(route.review_mode, Some(@types.ReviewMode::Iterative))
}

///|
test "build_beads_wave_from_issues_plan emits fork_wave json with contracts" {
  let plan = @tools.build_beads_wave_from_issues_plan(
    "choir-epic",
    "main",
    "feature/beads",
    "beads",
    [
      sample_issue("choir-a", labels=["agent:codex", "automerge:true"]),
      sample_issue("choir-b", labels=["agent:codex", "automerge:true"]),
    ],
  )
  match plan {
    Ok(p) => {
      assert_eq(p.issue_ids.join(","), "choir-a,choir-b")
      @debug.assert_eq(p.fork_wave_args.get("count"), Some(Int::to_json(2)))
      @debug.assert_eq(
        p.fork_wave_args.get("agent_type"),
        Some("codex".to_json()),
      )
      @debug.assert_eq(p.fork_wave_args.get("automerge"), Some(true.to_json()))
      match p.fork_wave_args.get("task_contracts") {
        Some(Array(items)) => {
          assert_eq(items.length(), 2)
          match items[0] {
            Object(fields) =>
              @debug.assert_eq(
                fields.get("beads_issue_id"),
                Some("choir-a".to_json()),
              )
            _ => fail("expected contract object")
          }
        }
        _ => fail("expected task contracts")
      }
    }
    Err(e) => fail(e.message())
  }
}

///|
test "build_beads_wave_from_issues_plan warns on mixed agent labels" {
  let plan = @tools.build_beads_wave_from_issues_plan(
    "choir-epic",
    "main",
    "feature/beads",
    "beads",
    [
      sample_issue("choir-a", labels=["agent:codex"]),
      sample_issue("choir-b", labels=["agent:gemini"]),
    ],
  ).unwrap()
  assert_true(plan.fork_wave_args.get("agent_type") is None)
  assert_true(plan.warnings.join("\n").contains("mixed agent labels"))
}

///|
test "beads command builders cover lifecycle gates audit merge slots and readonly" {
  let update = @tools.beads_update_spawn_command(
    "/repo",
    "choir-a",
    "feature.x",
    @types.Role::Dev,
    @types.AgentType::Codex,
    "feature/x",
    "/repo/.choir/worktrees/x",
    Some("wv-1"),
  )
  assert_eq(update.program, "bd")
  @debug.assert_eq(update.workdir, Some("/repo"))
  assert_true(update.args.contains("--set-metadata"))
  assert_true(update.args.contains("choir_wave_id=wv-1"))

  let gate = @tools.beads_gate_create_command(
    "/repo",
    "choir-a",
    "bead",
    "waiting on api",
    Some("api:api-1"),
  )
  assert_eq(
    gate.args.join(" "),
    "gate create --type bead --blocks choir-a --reason waiting on api --await-id api:api-1",
  )

  let audit = @tools.beads_audit_record_command(
    "/repo",
    Some("choir-a"),
    "tool_call",
    "spawn_worker",
    "spawned",
  )
  assert_true(audit.args.contains("--issue-id"))
  assert_true(audit.args.contains("choir-a"))

  let slot = @tools.beads_merge_slot_command("/repo", "acquire")
  assert_eq(slot.args.join(" "), "merge-slot acquire")

  let ro_cmd = @tools.beads_readonly_show_command("/repo", "choir-a")
  assert_eq(ro_cmd.args.join(" "), "--readonly show choir-a --json")
}

///|
test "beads_usage_note includes optional cost" {
  let text = @tools.beads_usage_note("main.leaf", 10, 20, 30, Some(0.42))
  assert_true(text.contains("main.leaf"))
  assert_true(text.contains("tokens_in=10"))
  assert_true(text.contains("cost_usd=0.42"))
}

///|
async test "mirror_beads_note_for_agent appends note and audit for assigned bead" {
  let tmp = "/tmp/choir-beads-note-mirror-" + @sys.get_pid().to_string()
  let worktree = tmp + "/.choir/worktrees/leaf"
  ignore(@sys.rm_rf(tmp))
  assert_true(@sys.create_dir_all(worktree + "/.choir"))
  let target : @types.LocalTarget = {
    kind: ZellijTab,
    session: "choir",
    name: "leaf",
  }
  let spec : @types.SpawnSpec = {
    slug: "leaf",
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    task: "assigned work",
    task_contract: Some({
      ..@types.TaskContract::empty(),
      goal: "assigned work",
      beads_issue_id: Some("choir-assigned"),
    }),
    isolation: @types.IsolationMode::Worktree,
    parent_id: "main.tl",
    parent_branch: "main",
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    review_mode: None,
    wave_id: None,
  }
  ignore(
    @sys.write_file_sync(
      worktree + "/.choir/config.local.toml",
      @workspace.config_local_content(spec, worktree, target),
    ),
  )
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Codex,
      parent: Some("main.tl"),
      workspace: worktree,
      branch: "main.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let seen : Array[String] = []
  let ok = @tools.mirror_beads_note_for_agent(
    tmp,
    Some(reg),
    "main.leaf",
    "Choir notify_parent: done",
    "notify_parent",
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      seen.push(cmd.args.join(" "))
      (0, "")
    },
  )
  assert_true(ok)
  let rendered = seen.join("\n")
  assert_true(rendered.contains("note choir-assigned"))
  assert_true(rendered.contains("audit record"))
  assert_true(rendered.contains("--issue-id choir-assigned"))
  ignore(@sys.rm_rf(tmp))
}
