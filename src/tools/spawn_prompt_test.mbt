///|
fn marker_index(haystack : String, marker : String) -> Int {
  match haystack.find(marker) {
    Some(i) => i
    None => -1
  }
}

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
  assert_true(prompt.contains("Do not merge your own PR"))
  assert_true(prompt.contains("file_pr"))
  assert_true(prompt.contains("tdd_intent"))
  assert_true(prompt.contains("tdd_red_check"))
  assert_true(prompt.contains("tdd_green_check"))
  assert_true(prompt.contains("TDD phase is Done"))
  assert_true(prompt.contains("`notify_parent`"))
  assert_true(prompt.contains("shell commands on PATH"))
  assert_true(
    prompt.contains("notify_parent [--status <success|failure|info>] <message>"),
  )
  assert_true(prompt.contains("If `notify_parent` fails, stop"))
  assert_true(prompt.contains("auto-notifies the parent"))
  assert_true(prompt.contains("git rev-list --left-right --count"))
  assert_true(prompt.contains("branch is not ahead of the parent branch"))
  assert_true(prompt.contains("Call `shutdown`"))
  assert_true(prompt.contains("source of truth for review state"))
  assert_true(prompt.contains("Run verification once per code change"))
  assert_true(prompt.contains("do not rerun the same tests"))
}

///|
test "render spawn prompts keep stable profile before volatile task body" {
  let leaf_prompt = render_leaf_spawn_prompt(
    PromptSpec::from_map({ "task": "Implement volatile leaf task" }),
  )
  let leaf_profile = marker_index(leaf_prompt, "## Completion Protocol (Leaf)")
  let leaf_task = marker_index(
    leaf_prompt, "## TASK\nImplement volatile leaf task",
  )
  assert_true(leaf_profile >= 0)
  assert_true(leaf_task >= 0)
  assert_true(leaf_profile < leaf_task)

  let worker_prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "task": "Investigate volatile worker task",
      "type": "research",
    }),
  )
  let worker_profile = marker_index(
    worker_prompt, "## Completion Protocol (Worker)",
  )
  let worker_task = marker_index(
    worker_prompt, "## TASK\nInvestigate volatile worker task",
  )
  assert_true(worker_profile >= 0)
  assert_true(worker_task >= 0)
  assert_true(worker_profile < worker_task)
}

///|
test "render_leaf_spawn_prompt includes review handling and bounded gh" {
  let prompt = render_leaf_spawn_prompt(
    PromptSpec::from_map({ "task": "Fix review feedback" }),
  )
  assert_true(prompt.contains("Review handling:"))
  assert_true(prompt.contains("source of truth for review state"))
  assert_true(prompt.contains("Do not run your own `gh api ... reviewThreads`"))
  assert_true(prompt.contains("`gh-bounded` wrapper"))
  assert_true(prompt.contains("A `gh` timeout is not a blocker"))
  assert_true(prompt.contains("resolve_my_review_threads"))
  assert_false(prompt.contains("resolveReviewThread"))

  let file_pr_exit = match prompt.find("Do not exit after file_pr") {
    Some(i) => i
    None => fail("missing file_pr exit block")
  }
  let review_handling = match prompt.find("Review handling:") {
    Some(i) => i
    None => fail("missing review handling block")
  }
  let execution_discipline = match prompt.find("Execution discipline:") {
    Some(i) => i
    None => fail("missing execution discipline block")
  }
  assert_true(file_pr_exit < review_handling)
  assert_true(review_handling < execution_discipline)
}

///|
test "render_leaf_spawn_prompt normalizes verify with configured moon target" {
  let project_dir = "/tmp/choir-spawn-prompt-verify-target-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  assert_true(
    @sys.write_file_sync(
      project_dir + "/.choir/config.toml",
      "moon_verify_target = \"wasm-gc\"\n",
    ),
  )

  let spec = PromptSpec::from_map({
    "task": "Verify target-sensitive prompt",
    "verify": "moon test\nmoon check --target native\necho ok",
  })
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  let prompt = render_leaf_spawn_prompt_with_defaults(spec, [], project_dir~)
  @moontrace.clear_subscriber()

  ignore(@sys.rm_rf(project_dir))
  assert_true(prompt.contains("- `moon test --target wasm-gc`"))
  assert_true(prompt.contains("- `moon check --target native`"))
  assert_true(prompt.contains("- `echo ok`"))
  assert_false(prompt.contains("- `moon test`"))
  @debug.assert_eq(spec.task_contract.verify, [
    "moon test --target wasm-gc", "moon check --target native", "echo ok",
  ])
  assert_true(
    captured
    .iter()
    .any(fn(event) {
      event.level == @moontrace.Level::Warn &&
      event.message == "moon verify command normalized"
    }),
  )
}

///|
test "render_leaf_spawn_prompt loads profile from project prompt file" {
  let project_dir = "/tmp/choir-spawn-prompt-profile-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir/prompts/profiles"))
  assert_true(
    @sys.write_file_sync(
      project_dir + "/.choir/prompts/profiles/leaf.md",
      "LOCAL LEAF PROFILE\n",
    ),
  )

  let prompt = render_leaf_spawn_prompt_with_defaults(
    PromptSpec::from_map({ "task": "Use local profile" }),
    [],
    project_dir~,
  )

  ignore(@sys.rm_rf(project_dir))
  assert_true(prompt.contains("LOCAL LEAF PROFILE\n"))
  assert_false(prompt.contains("Do not merge your own PR."))
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
  assert_true(prompt.contains("read files only"))
  assert_true(prompt.contains("do not own a branch"))
  assert_true(prompt.contains("notify_parent"))
}

///|
test "render_worker_spawn_prompt loads review profile from project prompt file" {
  let project_dir = "/tmp/choir-spawn-prompt-worker-profile-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir/prompts/profiles"))
  assert_true(
    @sys.write_file_sync(
      project_dir + "/.choir/prompts/profiles/worker-review.md",
      "LOCAL REVIEW PROFILE\n",
    ),
  )

  let prompt = render_worker_spawn_prompt_with_defaults(
    PromptSpec::from_map({ "task": "Review prompt loader", "type": "review" }),
    [],
    project_dir~,
  )

  ignore(@sys.rm_rf(project_dir))
  assert_true(prompt.contains("LOCAL REVIEW PROFILE\n"))
  assert_false(prompt.contains("research worker"))
}

///|
test "render_worker_spawn_prompt uses read-only review profile by default" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({ "task": "Review command wrappers", "type": "review" }),
  )
  assert_true(prompt.contains("review worker"))
  assert_true(prompt.contains("read files only"))
  assert_false(prompt.contains("isolated write-capable review worker"))
  assert_false(prompt.contains("read and edit files inside this isolated"))
}

///|
test "render_worker_spawn_prompt uses write-capable review profile for worktree isolation" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({ "task": "Review command wrappers", "type": "review" }),
    worker_isolation=Some(@types.IsolationMode::Worktree),
  )
  assert_true(prompt.contains("isolated write-capable review worker"))
  assert_true(prompt.contains("read and edit files inside this isolated"))
  assert_false(prompt.contains("read files only"))
}

///|
test "render_worker_spawn_prompt includes shell discipline" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({ "task": "Review command wrappers", "type": "review" }),
  )
  assert_true(prompt.contains("Shell discipline:"))
  assert_true(prompt.contains("committed project paths"))
  assert_true(prompt.contains("Do not walk `~/.moon`"))
  assert_true(prompt.contains("`node_modules/`"))
  assert_true(prompt.contains("`timeout 30s`"))
  assert_true(prompt.contains("`bash-bounded` wrapper"))
  assert_false(prompt.contains("## Shell command discipline"))
}

///|
test "render_leaf_spawn_prompt includes beads issue section" {
  let prompt = render_leaf_spawn_prompt(
    PromptSpec::from_map({
      "task": "Fix race",
      "beads_issue_id": " choir-poller-state-race ",
    }),
  )
  assert_true(prompt.contains("## BEADS ISSUE"))
  assert_true(prompt.contains("- choir-poller-state-race"))
  assert_true(
    prompt.contains("bd --readonly show choir-poller-state-race --json"),
  )
  let worker = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "task": "Read issue only",
      "beads_issue_id": "choir-poller-state-race",
    }),
  )
  assert_true(worker.contains("do not mutate Beads unless"))
}

///|
test "render_worker_spawn_prompt respects prompt override" {
  let prompt = render_worker_spawn_prompt(
    PromptSpec::from_map({
      "prompt": "Use this exact prompt.",
      "type": "review",
    }),
  )
  let profile = marker_index(prompt, "## Completion Protocol (Worker)")
  let override_prompt = marker_index(prompt, "Use this exact prompt.")
  assert_true(profile >= 0)
  assert_true(override_prompt >= 0)
  assert_true(profile < override_prompt)
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
