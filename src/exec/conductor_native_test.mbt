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
  @debug.assert_eq(commands[0].args, [
    "list", "--json", "--all", "--readonly",
  ])
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
