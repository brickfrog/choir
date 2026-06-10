///|
test "parse_fork_wave_args defaults child_role to Dev" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.child_role, @types.Role::Dev)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults agent_type to Codex" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.agent_type, @types.AgentType::Codex)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args role tl" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "delegate",
    "parent_branch": "main",
    "caller_id": "root",
    "role": "tl",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.child_role, @types.Role::TL)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid role" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "role": "root",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args captures review_context" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "review_context": " plan/interpret split ",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) =>
      @debug.assert_eq(fork.review_context, Some("plan/interpret split"))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults automerge override to None" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.automerge, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults review_mode override to None" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.review_mode, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults merge_strategy override to None" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.merge_strategy, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args treats missing scaffold_commit as None" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.scaffold_commit, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses scaffold_commit message and paths" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "scaffold_commit": "{\"message\":\"chore: scaffold wave fields\",\"paths\":[\"src/server/state.mbt\",\"src/tools/new_file.mbt\"]}",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) =>
      match fork.scaffold_commit {
        Some(scaffold) => {
          assert_eq(scaffold.message, "chore: scaffold wave fields")
          @debug.assert_eq(scaffold.paths, [
            "src/server/state.mbt", "src/tools/new_file.mbt",
          ])
        }
        None => fail("expected scaffold_commit")
      }
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses review_mode iterative" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "review_mode": "iterative",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) =>
      @debug.assert_eq(fork.review_mode, Some(@types.ReviewMode::Iterative))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid review_mode" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "review_mode": "again",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args parses merge_strategy squash" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "merge_strategy": "squash",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) =>
      @debug.assert_eq(fork.merge_strategy, Some(@types.MergeStrategy::Squash))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid merge_strategy" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "merge_strategy": "again",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args parses automerge true" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "true",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.automerge, Some(true))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses automerge false" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "false",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.automerge, Some(false))
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects invalid automerge value" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "automerge": "maybe",
  })
  assert_true(@tools.parse_fork_wave_args(".", args) is Err(_))
}

///|
test "parse_fork_wave_args parses issue_id into task contract" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "issue_id": " choir-42 ",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => {
      @debug.assert_eq(fork.task_contracts[0].beads_issue_id, Some("choir-42"))
      assert_true(fork.tasks[0].contains("## BEADS ISSUE"))
      assert_true(fork.tasks[0].contains("bd --readonly show choir-42 --json"))
    }
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args supports per leaf task contracts" {
  let args = @tools.tool_args_from_map({
    "tasks": "[\"Implement A\",\"Implement B\"]",
    "parent_branch": "main",
    "caller_id": "root",
    "task_contracts": "[{\"beads_issue_id\":\"choir-leaf-a\"},{\"beads_issue_id\":\"choir-leaf-b\"}]",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => {
      assert_eq(fork.count, 2)
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
      assert_false(fork.tasks[0].contains("choir-leaf-b"))
      assert_false(fork.tasks[1].contains("choir-leaf-a"))
    }
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args threads guard_paths into wave and per-leaf contracts" {
  let args = @tools.tool_args_from_map({
    "tasks": "[\"Implement A\",\"Implement B\"]",
    "parent_branch": "main",
    "caller_id": "root",
    "verify": "moon test --target native",
    "guard_paths": "hooks/**\n.choir/hooks/hook.wasm",
    "task_contracts": "[{\"guard_paths\":[\"src/workspace/**\"]},{}]",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => {
      assert_eq(fork.count, 2)
      @debug.assert_eq(fork.task_contracts[0].guard_paths, [
        "hooks/**", ".choir/hooks/hook.wasm", "src/workspace/**",
      ])
      @debug.assert_eq(fork.task_contracts[1].guard_paths, [
        "hooks/**", ".choir/hooks/hook.wasm",
      ])
    }
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects mismatched task contracts" {
  let args = @tools.tool_args_from_map({
    "tasks": "[\"Implement A\",\"Implement B\"]",
    "parent_branch": "main",
    "caller_id": "root",
    "task_contracts": "[{\"beads_issue_id\":\"choir-leaf-a\"}]",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Err(e) => assert_true(e.message().contains("task_contracts"))
    Ok(_) => fail("expected task_contracts length error")
  }
}

///|
test "parse_fork_wave_args ignores empty issue_id" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "issue_id": "   ",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.task_contracts[0].beads_issue_id, None)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args defaults depends_on to empty array" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.depends_on.length(), 0)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses depends_on JSON-array string" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "depends_on": "[\"main.dep-a\",\"main.dep-b\"]",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.depends_on, ["main.dep-a", "main.dep-b"])
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args parses single-entry depends_on" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "depends_on": "[\"main.dep\"]",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => @debug.assert_eq(fork.depends_on, ["main.dep"])
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects non-array depends_on" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "depends_on": "\"not-an-array\"",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Err(e) => assert_true(e.message().contains("depends_on"))
    Ok(_) => fail("expected InvalidFormat for non-array depends_on")
  }
}

///|
test "parse_fork_wave_args ignores empty depends_on string" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
    "caller_id": "root",
    "depends_on": "   ",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Ok(fork) => assert_eq(fork.depends_on.length(), 0)
    Err(e) => fail("parse_fork_wave_args: " + e.message())
  }
}

///|
test "parse_fork_wave_args rejects missing caller_id" {
  let args = @tools.tool_args_from_map({
    "count": "1",
    "task": "work",
    "parent_branch": "main",
  })
  match @tools.parse_fork_wave_args(".", args) {
    Err(e) => assert_true(e.message().contains("caller_id"))
    Ok(_) => fail("expected MissingField(caller_id)")
  }
}

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
