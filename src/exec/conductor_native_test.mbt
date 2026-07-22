///|
async test "native Conductor task dispatch uses typed Beads commands" {
  let commands : Array[@exec.Command] = []
  let request : @types.Request = {
    req_method: "tools/call",
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
  let commands : Array[@exec.Command] = []
  let request : @types.Request = {
    req_method: "tools/call",
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
async test "native Conductor exposes blocking Beads dependencies" {
  let commands : Array[@exec.Command] = []
  let request : @types.Request = {
    req_method: "tools/call",
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
  let commands : Array[@exec.Command] = []
  let list_request : @types.Request = {
    req_method: "tools/call",
    name: "task_list",
    args: @types.RequestArgs::from_values(Map([])),
  }
  let summary = dispatch_native_conductor_request("/repo", list_request, capture=command => {
    commands.push(command)
    (
      0,
      (
        #|[{"id":"choir-parent","title":"Parent","status":"open","dependency_count":1}]
      ),
    )
  })
  assert_true(summary.is_ok())
  @debug.assert_eq(commands[0].args, ["list", "--json", "--all", "--readonly"])
  let tasks = summary
    .ok_payload()
    .unwrap()
    .get_json("tasks")
    .unwrap()
    .stringify()
  assert_true(tasks.contains("\"dependency_count\":1"))
  assert_true(tasks.contains("\"dependencies_loaded\":false"))

  let detail_request : @types.Request = {
    req_method: "tools/call",
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
    {
      id: @migration.migration_bead_id(contract_ref, stable_key, kind),
      idempotency_key: @migration.migration_bead_idempotency_key(
        contract_ref, stable_key, kind,
      ),
      stable_key,
      migration_contract_ref: contract_ref,
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
  let commands : Array[@exec.Command] = []
  let capture = async fn(command : @exec.Command) -> (Int, String) {
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
  let commands : Array[@exec.Command] = []
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
    req_method: "tools/call",
    name: "unknown_tool",
    args: @types.RequestArgs::from_values(Map([])),
  }
  let removed = dispatch_native_conductor_request("/repo", base, capture=_ => {
    fail("removed command performed I/O")
  })
  assert_true(removed.error_message().unwrap_or("").contains("unknown tool"))
}
