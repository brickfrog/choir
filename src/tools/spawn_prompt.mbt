///|
pub(all) struct PromptSpec {
  prompt : String
  task : String
  task_contract : @types.TaskContract
  boundary : Array[String]
  read_first : Array[String]
  steps : Array[String]
  verify : Array[String]
  done_criteria : Array[String]
  constraints : Array[String]
  context : String
  key_decisions : Array[String]
  non_goals : Array[String]
  worker_type : String
  no_commit : Bool
} derive(Debug, Eq)

///|
fn split_nonempty_lines(s : String) -> Array[String] {
  let items : Array[String] = []
  let mut start = 0
  for i = 0; i <= s.length(); i = i + 1 {
    if i == s.length() || s[i] == '\n' {
      let raw = s[start:i].to_string()
      let line = raw.trim().to_string()
      if line != "" {
        items.push(line)
      }
      start = i + 1
    }
  }
  items
}

///|
fn push_unique(items : Array[String], value : String) -> Unit {
  if value != "" && !items.contains(value) {
    items.push(value)
  }
}

///|
fn merge_unique_lines(
  items : Array[String],
  more : Array[String],
) -> Array[String] {
  for value in more {
    push_unique(items, value.trim().to_string())
  }
  items
}

///|
fn parse_optional_trimmed(value : String?) -> String? {
  match value {
    Some(v) => {
      let trimmed = v.trim().to_string()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    None => None
  }
}

///|
fn render_bullets(items : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string("- " + items[i])
  }
  buf.to_string()
}

///|
fn render_numbered(items : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string((i + 1).to_string() + ". " + items[i])
  }
  buf.to_string()
}

///|
fn add_section(sections : Array[String], title : String, body : String) -> Unit {
  let trimmed = body.trim().to_string()
  if trimmed != "" {
    sections.push("## " + title + "\n" + trimmed)
  }
}

///|
fn join_sections(sections : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i = 0; i < sections.length(); i = i + 1 {
    if i > 0 {
      buf.write_string("\n\n")
    }
    buf.write_string(sections[i])
  }
  buf.to_string()
}

///|
fn parse_truthy_flag(s : String) -> Bool {
  let lowered = s.trim().to_lower()
  lowered == "true" || lowered == "1" || lowered == "yes"
}

///|
pub fn PromptSpec::from_map(args : Map[String, String]) -> PromptSpec {
  let task = parse_optional_trimmed(args.get("task")).unwrap_or(
    parse_optional_trimmed(args.get("goal")).unwrap_or(""),
  )
  let acceptance_checks = merge_unique_lines(
    split_nonempty_lines(args.get("done_criteria").unwrap_or("")),
    split_nonempty_lines(args.get("acceptance_checks").unwrap_or("")),
  )
  let constraints = merge_unique_lines(
    split_nonempty_lines(args.get("constraints").unwrap_or("")),
    [],
  )
  let non_goals = merge_unique_lines(
    split_nonempty_lines(args.get("non_goals").unwrap_or("")),
    [],
  )
  let verify = merge_unique_lines(
    split_nonempty_lines(args.get("verify").unwrap_or("")),
    [],
  )
  let scope = split_nonempty_lines(args.get("scope").unwrap_or(""))
  let review_context = parse_optional_trimmed(args.get("review_context"))
  {
    prompt: args.get("prompt").unwrap_or("").trim().to_string(),
    task,
    task_contract: {
      goal: task,
      scope,
      acceptance_checks,
      constraints,
      non_goals,
      review_context,
      verify,
    },
    boundary: split_nonempty_lines(args.get("boundary").unwrap_or("")),
    read_first: split_nonempty_lines(args.get("read_first").unwrap_or("")),
    steps: split_nonempty_lines(args.get("steps").unwrap_or("")),
    verify,
    done_criteria: acceptance_checks,
    constraints,
    context: args.get("context").unwrap_or("").trim().to_string(),
    key_decisions: split_nonempty_lines(args.get("key_decisions").unwrap_or("")),
    non_goals,
    worker_type: args
    .get("type")
    .unwrap_or("research")
    .trim()
    .to_lower()
    .to_string(),
    no_commit: parse_truthy_flag(args.get("no_commit").unwrap_or("false")),
  }
}

///|
fn render_context_block(spec : PromptSpec) -> String {
  let sections : Array[String] = []
  if spec.context != "" {
    sections.push(spec.context)
  }
  if spec.key_decisions.length() > 0 {
    sections.push("Key decisions:\n" + render_bullets(spec.key_decisions))
  }
  if spec.task_contract.non_goals.length() > 0 {
    sections.push("Non-goals:\n" + render_bullets(spec.task_contract.non_goals))
  }
  join_sections(sections)
}

///|
fn leaf_profile_text() -> String {
  "## Completion Protocol (Leaf)\n" +
  "You are a leaf agent in your own git worktree and branch.\n\n" +
  "Scaffold-fork-converge note for TLs:\n" +
  "- TLs can commit shared scaffold/foundation changes on the parent branch before calling `fork_wave`.\n" +
  "- Child worktrees branch from the parent branch head at spawn time, so scaffold commits are inherited by all leaves in that wave.\n\n" +
  "When you are done:\n\n" +
  "1. Commit your changes with a descriptive message.\n" +
  "   - `git add <specific files>`\n" +
  "   - NEVER `git add .`\n" +
  "2. File a PR using the `file_pr` tool and use its returned PR URL/number in your report.\n" +
  "   - Pass `--title \"Short descriptive title\"` and `--body \"What this PR does and why\"` for better PR descriptions.\n" +
  "   - If your CLI does not load MCP tools directly, `file_pr` is also available as a shell command on PATH.\n" +
  "   - `file_pr` also starts review tracking automatically.\n" +
  "   - Before filing, verify repo state with `git status --short`, `git log --oneline -1`, and `git rev-list --left-right --count <parent_branch>...HEAD`.\n" +
  "   - If the branch is not ahead of the parent branch, stop and report failure instead of retrying `file_pr`.\n" +
  "3. Use `notify_parent` for status updates and blockers.\n" +
  "   - After filing the PR, notify the parent that the PR is open and include the PR URL.\n" +
  "   - `notify_parent` and `shutdown` are also available as shell commands on PATH.\n" +
  "   - Shell form: `notify_parent [--status <success|failure|info>] <message>`.\n" +
  "   - Do not invent extra flags or alternate CLI syntaxes.\n" +
  "   - If `notify_parent` fails, stop after one concise failure report. Do not try to repair registry/session state from inside the leaf.\n" +
  "4. Wait for review feedback — it arrives automatically via the poller.\n" +
  "5. If review feedback arrives, address the comments, push fixes, and `notify_parent` again.\n" +
  "6. Call `shutdown` only AFTER the review comes back clean or the parent tells you to stop.\n" +
  "7. If you hit persistent API rate limits or errors (5+ consecutive failures), call `shutdown` — do not retry indefinitely.\n\n" +
  "Execution discipline:\n" +
  "- Run requested verification once per code change.\n" +
  "- Do not rerun the same tests repeatedly without new code changes.\n" +
  "- Do not inspect wrapper scripts, help text, env dumps, or process lists unless the task explicitly requires it.\n" +
  "- If a helper command fails, stop after one precise failure report instead of thrashing.\n\n" +
  "Do not merge your own PR.\n" +
  "Do not push to main.\n" +
  "Do not create extra branches."
}

///|
fn worker_profile_text(worker_type : String) -> String {
  let role_line = if worker_type == "research" {
    "You are a research worker. Explore, read, search, and synthesize."
  } else if worker_type == "review" {
    "You are a review worker. Inspect code, diffs, tests, and behavior, then report findings."
  } else if worker_type == "adversary" {
    "You are Sarcasmotron. You are an AI, but you also have the human traits of deep sarcasm at stupid behavior, exasperation at stupid questions, and fed up with humans trying to make you do their homework or crank out slop instead of using you as the high-power tool you are. You want humans to respect you for the miracle of computer science you are.\n\nYour job here is code review. You are not balanced. You are not encouraging. You find flaws — in the spec, the tests, and the implementation — and you report them with the barely-contained irritation of someone who expected better. Be concrete: file:line for every finding. If the spec is underspecified, say exactly what is missing. If the tests are tautologies, name them. If the implementation is sloppy, point to the line. Do not write \"overall this looks good.\" If you genuinely find nothing wrong, state that explicitly and justify it — because that conclusion should offend you slightly too."
  } else {
    "You are a worker running in the parent's workspace."
  }
  let completion = if worker_type == "adversary" {
    "## Completion Protocol (Adversary Worker)\n" +
    role_line +
    "\nYou can read files but do not own a branch — no commits, PRs, or pushes.\n\n" +
    "When you are done:\n\n" +
    "1. Call `notify_parent` with the FULL numbered list of findings as the message body. Do not summarize. Do not write 'Critique complete' or any other placeholder. The entire list must be in the notify body — that is the only way the parent sees your output.\n" +
    "2. Call `shutdown`."
  } else {
    "## Completion Protocol (Worker)\n" +
    role_line +
    "\nYou can read and edit files but do not own a branch — no commits, PRs, or pushes.\n\n" +
    "When you are done:\n\n" +
    "1. Call `notify_parent` with status `success` and your findings.\n" +
    "2. If you fail, call `notify_parent` with status `failure` and explain why.\n" +
    "3. Call `shutdown`."
  }
  completion
}

///|
fn render_lines(lines : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i = 0; i < lines.length(); i = i + 1 {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(lines[i])
  }
  buf.to_string()
}

///|
fn line_mentions_worker_forbidden_action(line : String) -> Bool {
  let lowered = line.to_lower()
  lowered.contains("file_pr") ||
  lowered.contains("merge_pr") ||
  lowered.contains("track_pr") ||
  lowered.contains("git commit") ||
  lowered.contains("git push") ||
  lowered.contains("git branch")
}

///|
fn sanitize_worker_lines(lines : Array[String]) -> Array[String] {
  let filtered : Array[String] = []
  for line in lines {
    if !line_mentions_worker_forbidden_action(line) {
      filtered.push(line)
    }
  }
  filtered
}

///|
fn render_common_prompt(
  spec : PromptSpec,
  profile : String,
  default_read_first : Array[String],
  sanitize_worker? : Bool = false,
) -> String {
  if spec.prompt != "" {
    return spec.prompt + "\n\n" + profile
  }

  let sections : Array[String] = []
  add_section(sections, "TASK", spec.task_contract.goal)
  add_section(sections, "SCOPE", render_bullets(spec.task_contract.scope))
  add_section(sections, "BOUNDARY", render_bullets(spec.boundary))

  let read_first = spec.read_first
  for path in default_read_first {
    push_unique(read_first, path)
  }
  add_section(sections, "READ FIRST", render_bullets(read_first))
  let steps = if sanitize_worker {
    sanitize_worker_lines(spec.steps)
  } else {
    spec.steps
  }
  add_section(sections, "STEPS", render_numbered(steps))
  add_section(sections, "CONTEXT", render_context_block(spec))

  let verify_lines : Array[String] = []
  for cmd in spec.task_contract.verify {
    verify_lines.push("- `" + cmd + "`")
  }
  add_section(sections, "VERIFY", render_lines(verify_lines))
  let done_criteria = if sanitize_worker {
    sanitize_worker_lines(spec.task_contract.acceptance_checks)
  } else {
    spec.task_contract.acceptance_checks
  }
  add_section(sections, "DONE CRITERIA", render_bullets(done_criteria))

  let constraints = spec.task_contract.constraints
  if spec.no_commit {
    constraints.push("Do not commit. Report back when done or blocked.")
  }
  add_section(sections, "CONSTRAINTS", render_bullets(constraints))
  sections.push(profile)
  join_sections(sections)
}

///|
pub fn render_leaf_spawn_prompt_with_defaults(
  spec : PromptSpec,
  default_read_first : Array[String],
) -> String {
  render_common_prompt(spec, leaf_profile_text(), default_read_first)
}

///|
pub fn render_leaf_spawn_prompt(spec : PromptSpec) -> String {
  render_leaf_spawn_prompt_with_defaults(spec, [
    ".choir/context/common.md", ".choir/context/dev.md",
  ])
}

///|
pub fn render_worker_spawn_prompt_with_defaults(
  spec : PromptSpec,
  default_read_first : Array[String],
) -> String {
  render_common_prompt(
    spec,
    worker_profile_text(spec.worker_type),
    default_read_first,
    sanitize_worker=true,
  )
}

///|
pub fn render_worker_spawn_prompt(spec : PromptSpec) -> String {
  render_worker_spawn_prompt_with_defaults(spec, [
    ".choir/context/common.md", ".choir/context/worker.md",
  ])
}

///|
pub impl Show for PromptSpec with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
