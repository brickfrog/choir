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
  assert_true(prompt.contains("auto-notifies the parent"))
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
  assert_true(prompt.contains("## Completion Protocol (Worker)"))
  assert_true(prompt.contains("research worker"))
  assert_true(prompt.contains("do not own a branch"))
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
  assert_true(prompt.contains("## Completion Protocol (Worker)"))
}

///|
test "render_worker_spawn_prompt strips leaf-only instructions" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "task": "Investigate CLI tests",
      "steps": "Read files\nUse file_pr to submit\nRun git commit\nNotify parent",
      "done_criteria": "file_pr is called\nParent is notified\nTests pass",
      "type": "review",
    }),
  )
  assert_true(prompt.contains("## Completion Protocol (Worker)"))
  assert_true(prompt.contains("1. Read files"))
  assert_true(prompt.contains("2. Notify parent"))
  assert_false(prompt.contains("file_pr"))
  assert_false(prompt.contains("git commit"))
  assert_true(prompt.contains("- Parent is notified"))
}

///|
/// Mirrors the production call shape: `parse_fork_wave_args` et al. build
/// `default_read_first` via `@workspace.resolve_context_paths`, which emits
/// absolute paths in `problems, common, role` order. The rendered read_first
/// puts those structural entries before task-specific reads from `spec`.
test "render_leaf_spawn_prompt auto-includes problems.md via absolute defaults" {
  let spec = PromptSpec::from_map({
    "task": "Test feature",
    "read_first": "src/foo.mbt",
  })
  let problems_abs = "/repo/.choir/context/problems.md"
  let common_abs = "/repo/.choir/context/common.md"
  let dev_abs = "/repo/.choir/context/dev.md"

  // Case 1: problems.md present — absolute path lands first, task-specific
  // reads follow the structural block.
  let prompt_with = render_leaf_spawn_prompt_with_defaults(spec, [
    problems_abs, common_abs, dev_abs,
  ])
  assert_true(prompt_with.contains("## READ FIRST\n- " + problems_abs))
  assert_true(
    prompt_with.contains(
      "- " +
      problems_abs +
      "\n- " +
      common_abs +
      "\n- " +
      dev_abs +
      "\n- src/foo.mbt",
    ),
  )

  // Case 2: problems.md missing — structural block shrinks to common+role,
  // task-specific reads still follow.
  let prompt_without = render_leaf_spawn_prompt_with_defaults(spec, [
    common_abs, dev_abs,
  ])
  assert_true(prompt_without.contains("## READ FIRST\n- " + common_abs))
  assert_true(
    prompt_without.contains(
      "- " + common_abs + "\n- " + dev_abs + "\n- src/foo.mbt",
    ),
  )
  assert_false(prompt_without.contains("problems.md"))
}

///|
/// End-to-end check: write a temporary project tree with `problems.md` on disk,
/// run `@workspace.resolve_context_paths` exactly like the production callers
/// (parse.mbt:655, parse.mbt:832), feed the result into
/// `render_leaf_spawn_prompt_with_defaults`, and confirm problems.md lands
/// first in the rendered READ FIRST section.
test "resolve_context_paths → render_leaf_spawn_prompt delivers problems.md first" {
  let project_dir = "/tmp/choir-spawn-prompt-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  ignore(@sys.create_dir_all(project_dir + "/.choir/context"))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/context/problems.md",
      "# problems\n",
    ),
  )
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/context/common.md",
      "# common\n",
    ),
  )
  ignore(
    @sys.write_file_sync(project_dir + "/.choir/context/dev.md", "# dev\n"),
  )
  let defaults = @workspace.resolve_context_paths(project_dir, "dev")
  let spec = PromptSpec::from_map({
    "task": "Test feature",
    "read_first": "src/foo.mbt",
  })
  let prompt = render_leaf_spawn_prompt_with_defaults(spec, defaults)
  ignore(@sys.rm_rf(project_dir))
  assert_true(defaults.length() == 3)
  assert_true(defaults[0].has_suffix("/.choir/context/problems.md"))
  assert_true(prompt.contains("## READ FIRST\n- " + defaults[0]))
  assert_true(prompt.contains("- " + defaults[0] + "\n- " + defaults[1]))
  assert_true(prompt.contains("\n- src/foo.mbt"))
}
