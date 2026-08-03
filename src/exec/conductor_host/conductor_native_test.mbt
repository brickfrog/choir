///|
async test "native Conductor task dispatch uses typed Beads commands" {
  let commands : Array[@process_host.Command] = []
  let request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "task_create",
    args: @types.RequestArgs::from_values({
      "id": "choir-task".to_json(),
      "title": "Implement the seam".to_json(),
      "status": "in_progress".to_json(),
      "notes": "Exact context".to_json(),
    }),
  }
  let response = dispatch_native_conductor_request("/repo", request, capture=command => {
    commands.push(command)
    match command.args[0] {
      "show" => (1, "not found")
      "create" =>
        (
          0, "{\"id\":\"choir-task\",\"title\":\"Implement the seam\",\"status\":\"open\"}",
        )
      "update" =>
        (
          0, "{\"id\":\"choir-task\",\"title\":\"Implement the seam\",\"status\":\"in_progress\"}",
        )
      other => (1, "unexpected " + other)
    }
  })
  assert_true(response.is_ok())
  assert_eq(commands.length(), 3)
  assert_eq(commands[0].program, "bd")
  @debug.assert_eq(commands[0].args, [
    "show", "--id=choir-task", "--json", "--readonly",
  ])
  @debug.assert_eq(commands[1].args, [
    "create", "--title=Implement the seam", "--id=choir-task", "--force", "--type",
    "task", "--priority", "2", "--json", "--notes", "Exact context",
  ])
  @debug.assert_eq(commands[2].args, [
    "update", "--status", "in_progress", "--json", "--", "choir-task",
  ])
}

///|
async test "native Conductor preserves a flag-looking title as create data" {
  let commands : Array[@process_host.Command] = []
  let response = dispatch_native_conductor_request(
    "/repo",
    {
      req_method: @types.WireMethod::WireToolsCall,
      name: "task_create",
      args: @types.RequestArgs::from_values({
        "id": "g3n.3.2".to_json(),
        "title": "--db=/tmp/other".to_json(),
      }),
    },
    capture=command => {
      commands.push(command)
      match command.args[0] {
        "show" => (1, "not found")
        "create" =>
          (
            0, "{\"id\":\"g3n.3.2\",\"title\":\"--db=/tmp/other\",\"status\":\"open\"}",
          )
        other => (1, "unexpected " + other)
      }
    },
  )
  assert_true(response.is_ok())
  @debug.assert_eq(commands.map(fn(command) { command.args }), [
    ["show", "--id=g3n.3.2", "--json", "--readonly"],
    [
      "create", "--title=--db=/tmp/other", "--id=g3n.3.2", "--force", "--type", "task",
      "--priority", "2", "--json",
    ],
  ])
}

///|
async test "native Conductor create preflight safely returns an existing Bead" {
  let commands : Array[@process_host.Command] = []
  let response = dispatch_native_conductor_request(
    "/repo",
    {
      req_method: @types.WireMethod::WireToolsCall,
      name: "task_create",
      args: @types.RequestArgs::from_values({
        "id": "choir-existing".to_json(),
        "title": "Existing".to_json(),
      }),
    },
    capture=command => {
      commands.push(command)
      (
        0, "{\"id\":\"choir-existing\",\"title\":\"Existing\",\"status\":\"open\"}",
      )
    },
  )
  assert_true(response.is_ok())
  assert_eq(response.ok_payload().unwrap().get_bool("created"), Some(false))
  @debug.assert_eq(commands.map(fn(command) { command.args }), [
    ["show", "--id=choir-existing", "--json", "--readonly"],
  ])
}

///|
async test "native Conductor rejects unsafe direct task ids before capture" {
  let unsafe_ids = [
    "--watch",
    "--db=/tmp/other",
    "-C",
    "",
    " choir-a",
    "choir-a\u{00}next",
    "a".repeat(161),
  ]
  for tool in ["task_create", "task_get", "task_update"] {
    for id in unsafe_ids {
      let commands : Array[@process_host.Command] = []
      let values : Map[String, Json] = {
        "id": id.to_json(),
        "title": "Title".to_json(),
        "notes": "Note".to_json(),
      }
      let response = dispatch_native_conductor_request(
        "/repo",
        {
          req_method: @types.WireMethod::WireToolsCall,
          name: tool,
          args: @types.RequestArgs::from_values(values),
        },
        capture=command => {
          commands.push(command)
          (0, "[]")
        },
      )
      assert_eq(
        response.error_code(),
        Some(@types.WireErrorCode::WireValidationError),
      )
      assert_eq(commands.length(), 0)
    }
  }
}

///|
async test "native Conductor pins the Beads CLI contract" {
  let tagged = @beads_host.validate_native_beads_cli(capture=command => {
    @debug.assert_eq(command.args, ["--version"])
    (0, "bd version 1.1.0 (v1.1.0)\n")
  })
  assert_true(tagged is Ok(_))
  let official_build = @beads_host.validate_native_beads_cli(capture=_ => {
    (0, "bd version 1.1.0 (8e4e59d39)\n")
  })
  assert_true(official_build is Ok(_))
  let official_release = @beads_host.validate_native_beads_cli(capture=_ => {
    (0, "bd version 1.1.0 (8e4e59d39: HEAD@8e4e59d39f34)\n")
  })
  assert_true(official_release is Ok(_))
  let drifted = @beads_host.validate_native_beads_cli(capture=_ => {
    (0, "bd version 1.2.0 (8e4e59d39: HEAD@8e4e59d39f34)\n")
  })
  assert_true(drifted is Err(_))
  for
    malformed in [
      "bd version 1.1.0 ()", "bd version 1.1.0 (not-a-revision)", "bd version 1.1.0 (ABCDEF0)",
      "bd version 1.1.0 (8e4e59d39: HEAD@deadbeef)", "bd version 1.1.0 (8e4e59d39: head@8e4e59d39f34)",
      "bd version 1.1.0 (8e4e59d39: HEAD@8e4e59d39f34)\nextra",
    ] {
    let rejected = @beads_host.validate_native_beads_cli(capture=_ => {
      (0, malformed)
    })
    assert_true(rejected is Err(_))
  }
}

///|
async test "native Conductor maps completed tasks to closed Beads" {
  let commands : Array[@process_host.Command] = []
  let request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "task_update",
    args: @types.RequestArgs::from_values({
      "id": "choir-task".to_json(),
      "status": "done".to_json(),
    }),
  }
  let response = dispatch_native_conductor_request("/repo", request, capture=fn(
    command,
  ) {
    commands.push(command)
    (
      0, "{\"id\":\"choir-task\",\"title\":\"Implement the seam\",\"status\":\"closed\"}",
    )
  })
  assert_true(response.is_ok())
  @debug.assert_eq(commands[0].args, [
    "update", "--status", "closed", "--json", "--", "choir-task",
  ])
}

///|
async test "native Conductor can normalize a contradictory Bead contract" {
  let commands : Array[@process_host.Command] = []
  let request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "task_update",
    args: @types.RequestArgs::from_values({
      "id": "choir-contradictory".to_json(),
      "title": "Enforce import boundaries".to_json(),
      "description": "Reject only newly introduced forbidden imports.".to_json(),
      "acceptance_criteria": "Existing imports remain valid; new imports fail.".to_json(),
      "notes": "Normalized an acceptance rule that rejected its own baseline.".to_json(),
    }),
  }
  let response = dispatch_native_conductor_request("/repo", request, capture=command => {
    commands.push(command)
    (
      0, "{\"id\":\"choir-contradictory\",\"title\":\"Enforce import boundaries\",\"status\":\"open\"}",
    )
  })
  assert_true(response.is_ok())
  @debug.assert_eq(commands[0].args, [
    "update", "--title", "Enforce import boundaries", "--description", "Reject only newly introduced forbidden imports.",
    "--acceptance", "Existing imports remain valid; new imports fail.", "--notes",
    "Normalized an acceptance rule that rejected its own baseline.", "--json", "--",
    "choir-contradictory",
  ])
}

///|
async test "native Conductor no-op update delegates to option-safe get" {
  let commands : Array[@process_host.Command] = []
  let response = dispatch_native_conductor_request(
    "/repo",
    {
      req_method: @types.WireMethod::WireToolsCall,
      name: "task_update",
      args: @types.RequestArgs::from_values({ "id": "g3n.3.2".to_json() }),
    },
    capture=command => {
      commands.push(command)
      (0, "{\"id\":\"g3n.3.2\",\"title\":\"Existing\",\"status\":\"open\"}")
    },
  )
  assert_true(response.is_ok())
  @debug.assert_eq(commands.map(fn(command) { command.args }), [
    ["show", "--id=g3n.3.2", "--json", "--readonly"],
  ])
}

///|
async test "native Conductor exposes blocking Beads dependencies" {
  let commands : Array[@process_host.Command] = []
  let request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "task_get",
    args: @types.RequestArgs::from_values({ "id": "choir-parent".to_json() }),
  }
  let response = dispatch_native_conductor_request("/repo", request, capture=fn(
    command,
  ) {
    commands.push(command)
    (
      0,
      (
        #|[{
        #|  "id":"choir-parent",
        #|  "title":"Implement the parent",
        #|  "description":"Current task context",
        #|  "acceptance_criteria":"The dependency is complete",
        #|  "status":"open",
        #|  "dependency_count":2,
        #|  "dependencies":[
        #|    {"id":"choir-blocker","dependency_type":"blocks"},
        #|    {"id":"choir-origin","dependency_type":"discovered-from"}
        #|  ]
        #|}]
      ),
    )
  })
  assert_true(response.is_ok())
  @debug.assert_eq(commands[0].args, [
    "show", "--id=choir-parent", "--json", "--readonly",
  ])
  let task = response
    .ok_payload()
    .unwrap()
    .get_json("task")
    .unwrap()
    .stringify()
  assert_true(task.contains("\"description\":\"Current task context\""))
  assert_true(
    task.contains("\"acceptance_criteria\":\"The dependency is complete\""),
  )
  assert_true(task.contains("\"dependency_count\":2"))
  assert_true(task.contains("\"blocking_dependency_ids\":[\"choir-blocker\"]"))
  assert_true(task.contains("\"dependencies_loaded\":true"))
}

///|
async test "native Conductor distinguishes Beads summaries from details" {
  let commands : Array[@process_host.Command] = []
  let list_request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "task_list",
    args: @types.RequestArgs::from_values(Map([])),
  }
  let summary = dispatch_native_conductor_request("/repo", list_request, capture=command => {
    commands.push(command)
    (
      0,
      (
        #|[{"id":"choir-parent","title":"Parent","status":"open","priority":1,"issue_type":"feature","updated_at":"2026-07-26T05:01:50Z","labels":["autonomy"],"dependencies":[{"depends_on_id":"choir-blocker","type":"blocks"},{"depends_on_id":"choir-epic","type":"parent-child"}]}]
      ),
    )
  })
  assert_true(summary.is_ok())
  // Paging and ordering are decided by Choir, so the tracker is asked for the
  // whole filtered set rather than a limit that would truncate first.
  @debug.assert_eq(commands[0].args, [
    "list", "--json", "--readonly", "--flat", "--limit", "0", "--all",
  ])
  let tasks = summary
    .ok_payload()
    .unwrap()
    .get_json("tasks")
    .unwrap()
    .stringify()
  // The metadata a planner selects on now survives the read.
  assert_true(tasks.contains("\"priority\":1"))
  assert_true(tasks.contains("\"issue_type\":\"feature\""))
  assert_true(tasks.contains("\"labels\":[\"autonomy\"]"))
  assert_true(tasks.contains("\"updated_at\":\"2026-07-26T05:01:50Z\""))
  // Parent-child is retained as an edge but is not a blocker.
  assert_true(tasks.contains("\"blocking_dependency_ids\":[\"choir-blocker\"]"))
  assert_true(tasks.contains("\"depends_on_id\":\"choir-epic\""))

  let detail_request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "task_get",
    args: @types.RequestArgs::from_values({ "id": "choir-parent".to_json() }),
  }
  let incomplete = dispatch_native_conductor_request("/repo", detail_request, capture=fn(
    _,
  ) {
    (
      0,
      (
        #|[{"id":"choir-parent","title":"Parent","status":"open","dependency_count":1}]
      ),
    )
  })
  assert_true(
    incomplete
    .error_message()
    .unwrap_or("")
    .contains("omitted required dependency details"),
  )
}

///|
async test "native Conductor rejects removed dispatch" {
  let base : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: "unknown_tool",
    args: @types.RequestArgs::from_values(Map([])),
  }
  let removed = dispatch_native_conductor_request("/repo", base, capture=_ => {
    fail("removed command performed I/O")
  })
  assert_true(removed.error_message().unwrap_or("").contains("unknown tool"))
}

///|
/// A batch is a graph. Applying the half of it that happens to be valid leaves
/// a shape the planner never asked for, so a rejected item must stop the whole
/// delivery before anything is written.
async test "a rejected batch item writes nothing at all" {
  let commands : Array[@process_host.Command] = []
  let graph =
    #|[{"id":"probe-a","title":"Existing","status":"open","priority":2,"issue_type":"task","updated_at":"2026-07-26T00:00:00Z"}]
  async fn batch(items : String) {
    dispatch_native_conductor_request(
      "/repo",
      {
        req_method: @types.WireMethod::WireToolsCall,
        name: "task_batch",
        args: @types.RequestArgs::from_values({
          "items": @json.parse(items) catch {
            _ => Json::null()
          },
        }),
      },
      capture=command => {
        commands.push(command)
        (0, graph)
      },
    )
  }
  // The second item names a blocker that exists nowhere. The tracker would
  // have created the Bead and merely warned about the missing edge.
  let rejected = batch(
    (
      #|[{"id":"probe-b","intent":"create","title":"First"},
      #|{"id":"probe-c","intent":"create","title":"Second","blocked_by":["probe-nowhere"]}]
    ),
  )
  assert_true(rejected.is_ok())
  let payload = rejected.ok_payload().unwrap()
  assert_eq(payload.get("status"), Some("rejected"))
  let rendered = payload.get_json("items").unwrap().stringify()
  assert_true(rendered.contains("missing_dependency: probe-nowhere"))
  // One read of the graph, and no write of any kind.
  assert_eq(commands.length(), 1)
  @debug.assert_eq(commands[0].args[0], "list")

  // The same batch without the unresolvable edge writes both Beads and the
  // edge between them, in the direction the planner declared.
  commands.clear()
  let applied = batch(
    (
      #|[{"id":"probe-b","intent":"create","title":"First"},
      #|{"id":"probe-c","intent":"create","title":"Second","blocked_by":["probe-b"]}]
    ),
  )
  assert_true(applied.is_ok())
  assert_eq(applied.ok_payload().unwrap().get("status"), Some("ok"))
  let written = commands.map(fn(command) { command.args })
  @debug.assert_eq(written, [
    ["list", "--json", "--readonly", "--flat", "--limit", "0", "--all"],
    ["create", "--title=First", "--id=probe-b", "--json"],
    ["create", "--title=Second", "--id=probe-c", "--json"],
    ["dep", "add", "--", "probe-c", "probe-b"],
  ])
}

///|
async test "unsafe batch identifiers are rejected before the graph read" {
  for
    items in [
      "[{\"id\":\"--watch\",\"intent\":\"create\",\"title\":\"Subject\"}]", "[{\"id\":\"probe-a\",\"intent\":\"create\",\"title\":\"Parent\",\"parent\":\"-C\"}]",
      "[{\"id\":\"probe-a\",\"intent\":\"create\",\"title\":\"Blocker\",\"blocked_by\":[\"--db=/tmp/other\"]}]",
    ] {
    let commands : Array[@process_host.Command] = []
    let parsed = @json.parse(items) catch { _ => fail("invalid test JSON") }
    let response = dispatch_native_conductor_request(
      "/repo",
      {
        req_method: @types.WireMethod::WireToolsCall,
        name: "task_batch",
        args: @types.RequestArgs::from_values({ "items": parsed }),
      },
      capture=command => {
        commands.push(command)
        (0, "[]")
      },
    )
    assert_eq(
      response.error_code(),
      Some(@types.WireErrorCode::WireValidationError),
    )
    assert_eq(commands.length(), 0)
  }
}

///|
async test "WorkOrder batch delivery rereads exact applied Bead revisions" {
  let graph = @ref.new("[]")
  let commands : Array[@process_host.Command] = []
  let proposal : @command.BeadBatchProposal = {
    mutations: [
      {
        id: "planned-next",
        intent: @command.BeadMutationIntent::BeadCreateIntent,
        title: Some("Planned next"),
        description: Some("Deliver the next bounded change."),
        acceptance_criteria: Some("The focused test passes."),
        notes: None,
        priority: Some(@command.BeadPriority::BeadP1),
        issue_type: Some(@command.BeadIssueType::BeadTask),
        labels: Some(["planning"]),
        blocked_by: [],
        parent: None,
        expected_updated_at: None,
      },
    ],
  }
  let applied = @beads_host.apply_native_bead_batch("/repo", proposal, command => {
    commands.push(command)
    match command.args {
      ["list", ..] => (0, graph.val)
      ["create", "--title=Planned next", ..] => {
        graph.val = (
          #|[{"id":"planned-next","title":"Planned next","description":"Deliver the next bounded change.","acceptance_criteria":"The focused test passes.","status":"open","priority":1,"issue_type":"task","labels":["planning"],"updated_at":"2026-07-28T00:00:00Z"}]
        )
        (0, "{}")
      }
      _ => (0, "{}")
    }
  }).unwrap()
  assert_eq(applied.digest, @command.bead_batch_digest(proposal))
  assert_eq(applied.records.length(), 1)
  assert_eq(applied.records[0].updated_at, "2026-07-28T00:00:00Z")
  assert_eq(
    commands.filter(fn(command) { command.args[0] == "list" }).length(),
    2,
  )
}

///|
async test "WorkOrder batch rejects unsafe identifiers before graph capture" {
  let commands : Array[@process_host.Command] = []
  let proposal : @command.BeadBatchProposal = {
    mutations: [
      {
        id: "--watch",
        intent: @command.BeadMutationIntent::BeadCreateIntent,
        title: Some("Unsafe"),
        description: None,
        acceptance_criteria: None,
        notes: None,
        priority: None,
        issue_type: None,
        labels: None,
        blocked_by: [],
        parent: None,
        expected_updated_at: None,
      },
    ],
  }
  let result = @beads_host.apply_native_bead_batch("/repo", proposal, command => {
    commands.push(command)
    (0, "[]")
  })
  assert_true(result is Err(_))
  assert_eq(commands.length(), 0)
}

///|
/// Help in the shape the CLI prints it: one option per line, the flag first,
/// then a wrapped paragraph that names other flags in prose. The last line is
/// lifted from `--bare`'s real description, where `--append-system-prompt[-file]`
/// sits one bracket away from a flag this manifest declares.
fn conductor_help_output(flags : Array[String]) -> String {
  let lines = flags.map(fn(flag) {
    "  " + flag + " <value>   Description of the option"
  })
  lines.push(
    "      Explicitly provide context via: --system-prompt[-file], --append-system-prompt[-file], --add-dir.",
  )
  "Usage: claude [options] [command] [prompt]\n\nOptions:\n" + lines.join("\n")
}

///|
/// The Conductor launch was never checked against the Claude it launches: the
/// only assertion compared Choir's argv to itself, so it would have stayed
/// green while the installed CLI dropped a flag the launch passes.
async test "the Conductor launch is qualified against the installed CLI's help" {
  let documented = @harness.conductor_surface_flags()
    .filter(fn(flag) {
      flag.visibility
      is @harness.ConductorFlagVisibility::ConductorFlagDocumented
    })
    .map(fn(flag) { flag.name })
  let probed : Array[@process_host.Command] = []
  let qualified = validate_native_conductor_surface("/opt/claude/claude", capture=command => {
    probed.push(command)
    (0, conductor_help_output(documented))
  })
  assert_true(qualified is Ok(_))
  @debug.assert_eq(probed, [
    { program: "/opt/claude/claude", args: ["--help"], workdir: Some("/tmp") },
  ])
  let dropped = documented.filter(fn(name) { name != "--strict-mcp-config" })
  let refused = validate_native_conductor_surface("/opt/claude/claude", capture=_ => {
    (0, conductor_help_output(dropped))
  })
  match refused {
    Err(error) => {
      assert_true(error.message().contains("unqualified Conductor surface"))
      assert_true(error.message().contains("--strict-mcp-config"))
    }
    Ok(_) => fail("launched against a CLI missing a declared flag")
  }
  assert_true(
    validate_native_conductor_surface("/opt/claude/claude", capture=_ => {
      (1, conductor_help_output(documented))
    })
    is Err(_),
  )
  assert_true(
    validate_native_conductor_surface("claude", capture=_ => {
      (0, conductor_help_output(documented))
    })
    is Err(_),
  )
}

///|
test "native Claude Conductor source validation fails closed" {
  let canonicalize = fn(path : String) { Some(path) }
  let executable = fn(_ : String) { true }
  let file_mode = fn(path : String) {
    if path.has_suffix("server.sock") || path.has_suffix("credentials.json") {
      0o600
    } else {
      -1
    }
  }
  let config : NativeClaudeConductorConfig = {
    project_dir: "/repo",
    claude_executable: "/opt/claude/claude",
    choir_executable: "/opt/choir/choir",
    credential_file: "/home/provider/.claude/.credentials.json",
    daemon_socket: "/repo/.choir/run/server.sock",
    environment: {
      conductor_token: "token",
      statusline_cache_key: "conductor-42",
      workspace: "/repo",
      listen_uds: "/repo/.choir/run/server.sock",
    },
    prompt: "Use Choir.",
    lean: false,
  }
  assert_true(
    validate_native_claude_conductor_config(
      config,
      canonicalize~,
      executable~,
      file_mode~,
    )
    is Ok(_),
  )
  assert_true(
    validate_native_claude_conductor_config(
      { ..config, credential_file: "/home/provider/credential-link" },
      canonicalize=fn(path) {
        if path == "/home/provider/credential-link" {
          Some("/real/credential")
        } else {
          Some(path)
        }
      },
      executable~,
      file_mode=fn(_) { 0o600 },
    )
    is Err(_),
  )
  assert_true(
    validate_native_claude_conductor_config(
      config,
      canonicalize~,
      executable~,
      file_mode=fn(path) {
        if path.has_suffix("credentials.json") {
          0o644
        } else {
          0o600
        }
      },
    )
    is Err(_),
  )
  assert_true(
    validate_native_claude_conductor_config(
      { ..config, environment: { ..config.environment, workspace: "/other" } },
      canonicalize~,
      executable~,
      file_mode~,
    )
    is Err(_),
  )
}
