///|
async test "native Conductor task dispatch uses typed Beads commands" {
  let commands : Array[@workspace.Command] = []
  let request : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "task_create",
    args: @types.RequestArgs::from_values({
      "id": "choir-task".to_json(),
      "title": "Implement the seam".to_json(),
      "status": "in_progress".to_json(),
      "notes": "Exact context".to_json(),
    }),
  }
  let response = dispatch_native_conductor_request("/repo", request, capture=fn(
    command,
  ) {
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
async test "native Conductor maps completed tasks to closed Beads" {
  let commands : Array[@workspace.Command] = []
  let request : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
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
async test "native Conductor rejects removed and unauthenticated dispatch" {
  let base : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "fork_wave",
    args: @types.RequestArgs::from_values(Map([])),
  }
  let removed = dispatch_native_conductor_request("/repo", base, capture=_ => {
    fail("removed command performed I/O")
  })
  assert_true(removed.error_message().unwrap_or("").contains("unknown tool"))
  let unbound = dispatch_native_conductor_request(
    "/repo",
    { ..base, name: "task_list", role: @types.Role::Worker },
    capture=_ => fail("unbound command performed I/O"),
  )
  assert_true(
    unbound.error_message().unwrap_or("").contains("Conductor required"),
  )
}
