///|
test "render_leaf_spawn_prompt builds structured sections and completion protocol" {
  let prompt = render_leaf_spawn_prompt({
    "task": "Implement agent routing",
    "read_first": "SPEC.md\nsrc/tools/dispatch.mbt",
    "steps": "Add routing metadata\nUpdate tests",
    "verify": "moon test --target native\nmoon build --target native --release",
    "done_criteria": "Routing metadata is persisted",
    "boundary": "Do not change transport behavior",
    "context": "Parent needs accurate notify_parent delivery.",
    "key_decisions": "Keep current tmux layout",
    "non_goals": "Do not redesign the protocol",
  })
  assert_true(prompt.contains("## TASK\nImplement agent routing"))
  assert_true(prompt.contains("## READ FIRST"))
  assert_true(prompt.contains("AGENTS.md"))
  assert_true(prompt.contains("1. Add routing metadata"))
  assert_true(prompt.contains("- `moon test --target native`"))
  assert_true(prompt.contains("Key decisions:"))
  assert_true(prompt.contains("Do not merge your own PR."))
  assert_true(prompt.contains("`file_pr`"))
  assert_true(prompt.contains("`notify_parent`"))
}

///|
test "render_worker_spawn_prompt uses research profile" {
  let prompt = render_worker_spawn_prompt({
    "task": "Investigate flaky tests",
    "type": "research",
    "read_first": "src/poller",
  })
  assert_true(prompt.contains("## TASK\nInvestigate flaky tests"))
  assert_true(prompt.contains("## Completion Protocol (Research Worker)"))
  assert_true(prompt.contains("Do not edit files."))
  assert_true(prompt.contains("notify_parent"))
}

///|
test "render_worker_spawn_prompt respects prompt override" {
  let prompt = render_worker_spawn_prompt({
    "prompt": "Use this exact prompt.",
    "type": "implementation",
  })
  assert_true(prompt.has_prefix("Use this exact prompt."))
  assert_true(prompt.contains("## Completion Protocol (Worker)"))
}
