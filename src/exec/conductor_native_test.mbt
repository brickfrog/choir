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
  @debug.assert_eq(commands[1].args, [
    "create", "Implement the seam", "--id", "choir-task", "--force", "--type", "task",
    "--priority", "2", "--json", "--notes", "Exact context",
  ])
  @debug.assert_eq(commands[2].args, [
    "update", "choir-task", "--status", "in_progress", "--json",
  ])
}

///|
async test "native Conductor pins the Beads CLI contract" {
  let admitted = validate_native_beads_cli(capture=command => {
    @debug.assert_eq(command.args, ["--version"])
    (0, "bd version 1.1.0 (v1.1.0)\n")
  })
  assert_true(admitted is Ok(_))
  let drifted = validate_native_beads_cli(capture=_ => {
    (0, "bd version 1.2.0 (v1.2.0)\n")
  })
  assert_true(drifted is Err(_))
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
    "update", "choir-task", "--status", "closed", "--json",
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
    "update", "choir-contradictory", "--title", "Enforce import boundaries", "--description",
    "Reject only newly introduced forbidden imports.", "--acceptance", "Existing imports remain valid; new imports fail.",
    "--notes", "Normalized an acceptance rule that rejected its own baseline.", "--json",
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
    "show", "choir-parent", "--json", "--readonly",
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
fn migration_materialization_proposals() -> Array[
  @migration.MigrationBeadProposal,
] {
  let contract_ref : @control.MigrationContractRef = {
    contract_id: @control.MigrationContractId("materialize-contract"),
    migration_lineage_id: @control.MigrationLineageId("materialize-lineage"),
    revision: 1,
    contract_artifact_digest: @control.Digest(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ),
  }
  let verification : @control.VerificationSpec = {
    id: @control.VerificationSpecId("materialize-check"),
    version: 1,
    digest: @control.Digest(
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ),
    process_spec_digest: @control.Digest(
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    ),
  }
  let kind = @migration.MigrationBeadKind::MigrationImplementationBead(
    @migration.AgentAssistedReason::SemanticJudgment,
  )
  let make = fn(
    key : String,
    path : String,
    dependencies : Array[@migration.MigrationBeadId],
  ) -> @migration.MigrationBeadProposal {
    let stable_key = @migration.InventoryStableKey(key)
    let scope = @migration.MigrationBeadScope::MigrationProductionBead
    {
      id: @migration.migration_bead_id(contract_ref, stable_key, scope, kind),
      idempotency_key: @migration.migration_bead_idempotency_key(
        contract_ref, stable_key, scope, kind,
      ),
      stable_key,
      migration_contract_ref: contract_ref,
      scope,
      kind,
      title: "Migrate " + key,
      ownership_claim: @migration.MigrationOwnershipClaim("owner-" + key),
      source_paths: [@control.RepoPath(path)],
      blocking_dependency_ids: dependencies,
      verification_specs: [verification],
    }
  }
  let blocker = make("unit-a", "src/a.mbt", [])
  [make("unit-b", "src/b.mbt", [blocker.id]), blocker]
}

///|
fn migration_materialized_task_json(
  proposal : @migration.MigrationBeadProposal,
  title? : String? = None,
) -> String {
  let content = native_migration_bead_content(proposal)
  {
    "id": content.id.to_json(),
    "title": title.unwrap_or(content.title).to_json(),
    "description": content.description.to_json(),
    "acceptance_criteria": content.acceptance_criteria.to_json(),
    "notes": content.notes.to_json(),
    "status": "open".to_json(),
    "dependency_count": content.blocking_dependency_ids.length().to_json(),
    "dependencies": content.blocking_dependency_ids
    .map(fn(id) {
      { "id": id.to_json(), "dependency_type": "blocks".to_json() }.to_json()
    })
    .to_json(),
  }
  .to_json()
  .stringify(indent=0)
}

///|
async test "migration Beads materialize dependency-first and replay exactly" {
  let proposals = migration_materialization_proposals()
  let created : Array[String] = []
  let commands : Array[@process_host.Command] = []
  let capture : async (@process_host.Command) -> (Int, String) = command => {
    commands.push(command)
    if command.args[0] == "create" {
      created.push(command.args[3])
      return (0, "{}")
    }
    let id = command.args[1]
    let proposal = proposals.filter(fn(candidate) { candidate.id.0 == id })[0]
    if created.contains(id) {
      (0, migration_materialized_task_json(proposal))
    } else {
      (1, "not found")
    }
  }
  let first = materialize_native_migration_beads("/repo", proposals, capture~).unwrap()
  assert_eq(first.created_ids.length(), 2)
  assert_eq(first.adopted_ids, [])
  let blocker = proposals.filter(fn(proposal) {
      proposal.stable_key == @migration.InventoryStableKey("unit-a")
    })[0]
  let dependent = proposals.filter(fn(proposal) {
      proposal.stable_key == @migration.InventoryStableKey("unit-b")
    })[0]
  assert_eq(created, [blocker.id.0, dependent.id.0])
  let command_count = commands.length()
  let replayed = materialize_native_migration_beads(
    "/repo",
    proposals,
    capture~,
  ).unwrap()
  assert_eq(replayed.created_ids, [])
  assert_eq(replayed.adopted_ids, first.bead_ids)
  assert_true(
    commands[command_count:].all(fn(command) { command.args[0] == "show" }),
  )
}

///|
async test "migration Bead conflict blocks before any mutation" {
  let proposals = migration_materialization_proposals()
  let commands : Array[@process_host.Command] = []
  let result = materialize_native_migration_beads("/repo", proposals, capture=fn(
    command,
  ) {
    commands.push(command)
    let id = command.args[1]
    let proposal = proposals.filter(fn(candidate) { candidate.id.0 == id })[0]
    (0, migration_materialized_task_json(proposal, title=Some("conflict")))
  })
  assert_true(result is Err(_))
  assert_true(commands.all(fn(command) { command.args[0] == "show" }))
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
    ["create", "First", "--id", "probe-b", "--json"],
    ["create", "Second", "--id", "probe-c", "--json"],
    ["dep", "add", "probe-c", "probe-b"],
  ])
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
  let applied = apply_native_bead_batch("/repo", proposal, command => {
    commands.push(command)
    match command.args {
      ["list", ..] => (0, graph.val)
      ["create", "Planned next", ..] => {
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
  let probed : Array[@harness.HarnessProbeProcess] = []
  let qualified = validate_native_conductor_surface(probe=spec => {
    probed.push(spec)
    Ok({ exit_code: 0, output: conductor_help_output(documented) })
  })
  assert_true(qualified is Ok(_))
  // The fixed declaration probe, so no argv or executable is caller-supplied.
  @debug.assert_eq(probed, [
    {
      surface: @harness.ProviderSurface::ClaudeCli,
      command: @harness.HarnessProbeCommand::ProbeMainHelp,
    },
  ])
  // The failure this exists to catch.
  let dropped = documented.filter(fn(name) { name != "--strict-mcp-config" })
  let refused = validate_native_conductor_surface(probe=_ => {
    Ok({ exit_code: 0, output: conductor_help_output(dropped) })
  })
  match refused {
    Err(error) => {
      assert_true(error.message().contains("unqualified Conductor surface"))
      assert_true(error.message().contains("--strict-mcp-config"))
    }
    Ok(_) => fail("launched against a CLI missing a declared flag")
  }
  // Help that could not be read is not a qualification even when the text that
  // came back would have satisfied every flag, and neither is a CLI that is
  // not installed at all.
  assert_true(
    validate_native_conductor_surface(probe=_ => {
      Ok({ exit_code: 1, output: conductor_help_output(documented) })
    })
    is Err(_),
  )
  assert_true(
    validate_native_conductor_surface(probe=_ => {
      Err(
        @types.ChoirError::transport_error(
          "provider probe executable unavailable",
        ),
      )
    })
    is Err(_),
  )
}
