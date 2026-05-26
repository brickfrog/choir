///|
test "parse_fork_wave_args supports shared task contracts matching count" {
  let args = @tools.tool_args_from_map({
    "count": "2",
    "task": "Implement the shard",
    "parent_branch": "main",
    "caller_id": "root",
    "task_contracts": "[{\"beads_issue_id\":\"choir-leaf-a\"},{\"beads_issue_id\":\"choir-leaf-b\"}]",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => {
      assert_eq(fork.count, 2)
      assert_false(fork.has_per_leaf_tasks)
      @debug.assert_eq(
        fork.task_contracts[0].beads_issue_id,
        Some("choir-leaf-a"),
      )
      @debug.assert_eq(
        fork.task_contracts[1].beads_issue_id,
        Some("choir-leaf-b"),
      )
      assert_true(
        fork.tasks[0].contains("bd --readonly show choir-leaf-a --json"),
      )
      assert_true(
        fork.tasks[1].contains("bd --readonly show choir-leaf-b --json"),
      )
    }
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args accepts tasks without shared task or count" {
  let args = @tools.tool_args_from_map({
    "tasks": "[\"Implement A\",\"Implement B\"]",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => {
      assert_eq(fork.count, 2)
      assert_true(fork.has_per_leaf_tasks)
      assert_eq(fork.tasks.length(), 2)
      assert_eq(fork.task_contracts.length(), 2)
    }
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}
