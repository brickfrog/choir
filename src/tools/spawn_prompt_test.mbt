///|
test "render_leaf_spawn_prompt builds structured sections and completion protocol" {
  let prompt = render_leaf_spawn_prompt(
    PromptSpec::from_map({
      "task": "Implement agent routing",
      "read_first": ".choir/context/common.md\nsrc/tools/dispatch.mbt",
      "steps": "Add routing metadata\nUpdate tests",
      "verify": "moon test --target native\nmoon build --target native --release",
      "done_criteria": "Routing metadata is persisted",
      "boundary": "Do not change transport behavior",
      "context": "Parent needs accurate notify_parent delivery.",
      "key_decisions": "Keep current tmux layout",
      "non_goals": "Do not redesign the protocol",
    }),
  )
  assert_true(prompt.contains("## TASK\nImplement agent routing"))
  assert_true(prompt.contains("## READ FIRST"))
  assert_true(prompt.contains(".choir/context/common.md"))
  assert_true(prompt.contains(".choir/context/dev.md"))
  assert_true(prompt.contains("1. Add routing metadata"))
  assert_true(prompt.contains("- `moon test --target native`"))
  assert_true(prompt.contains("Key decisions:"))
  assert_true(prompt.contains("Do not merge your own PR."))
  assert_true(prompt.contains("`file_pr`"))
  assert_true(prompt.contains("`notify_parent`"))
  assert_true(prompt.contains("shell command on PATH"))
  assert_true(
    prompt.contains("notify_parent [--status <success|failure|info>] <message>"),
  )
  assert_true(prompt.contains("If `notify_parent` fails, stop"))
  assert_true(prompt.contains("Do not invent extra flags"))
  assert_true(prompt.contains("git rev-list --left-right --count"))
  assert_true(prompt.contains("branch is not ahead of the parent branch"))
  assert_true(prompt.contains("Call `shutdown`"))
  assert_true(prompt.contains("Wait for review feedback"))
  assert_true(
    prompt.contains("Run requested verification once per code change"),
  )
  assert_true(prompt.contains("Do not rerun the same tests repeatedly"))
}

///|
test "render_worker_spawn_prompt uses research profile" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "task": "Investigate flaky tests",
      "type": "research",
      "read_first": "src/poller",
    }),
  )
  assert_true(prompt.contains("## TASK\nInvestigate flaky tests"))
  assert_true(prompt.contains("## Completion Protocol (Research Worker)"))
  assert_true(prompt.contains("Do not edit files."))
  assert_true(prompt.contains("notify_parent"))
}

///|
test "render_worker_spawn_prompt respects prompt override" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "prompt": "Use this exact prompt.",
      "type": "review",
    }),
  )
  assert_true(prompt.has_prefix("Use this exact prompt."))
  assert_true(prompt.contains("## Completion Protocol (Review Worker)"))
}

///|
test "render_worker_spawn_prompt strips leaf-only instructions" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "task": "Investigate CLI tests",
      "steps": "Read files\nFile a PR through Choir\nCommit your changes\nNotify parent",
      "done_criteria": "PR is filed\nParent is notified\nTests pass",
      "type": "review",
    }),
  )
  assert_true(prompt.contains("## Completion Protocol (Review Worker)"))
  assert_true(prompt.contains("1. Read files"))
  assert_true(prompt.contains("2. Notify parent"))
  assert_false(prompt.contains("File a PR through Choir"))
  assert_false(prompt.contains("Commit your changes"))
  assert_false(prompt.contains("- PR is filed"))
  assert_true(prompt.contains("- Parent is notified"))
}
