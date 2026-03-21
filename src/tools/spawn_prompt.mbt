///|
pub(all) struct PromptSpec {
  prompt : String
  task : String
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
} derive(Show, Eq)

///|
fn split_nonempty_lines(s : String) -> Array[String] {
  let items : Array[String] = []
  let mut start = 0
  for i = 0; i <= s.length(); i = i + 1 {
    if i == s.length() || s[i] == '\n' {
      let raw = s[start:i].to_string() catch { _ => "" }
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
  if value != "" && not(items.contains(value)) {
    items.push(value)
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
  {
    prompt: args.get("prompt").unwrap_or("").trim().to_string(),
    task: args.get("task").unwrap_or(""),
    boundary: split_nonempty_lines(args.get("boundary").unwrap_or("")),
    read_first: split_nonempty_lines(args.get("read_first").unwrap_or("")),
    steps: split_nonempty_lines(args.get("steps").unwrap_or("")),
    verify: split_nonempty_lines(args.get("verify").unwrap_or("")),
    done_criteria: split_nonempty_lines(args.get("done_criteria").unwrap_or("")),
    constraints: split_nonempty_lines(args.get("constraints").unwrap_or("")),
    context: args.get("context").unwrap_or("").trim().to_string(),
    key_decisions: split_nonempty_lines(args.get("key_decisions").unwrap_or("")),
    non_goals: split_nonempty_lines(args.get("non_goals").unwrap_or("")),
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
  if spec.non_goals.length() > 0 {
    sections.push("Non-goals:\n" + render_bullets(spec.non_goals))
  }
  join_sections(sections)
}

///|
fn leaf_profile_text() -> String {
  "## Completion Protocol (Leaf)\n" +
  "You are a leaf agent in your own git worktree and branch.\n\n" +
  "When you are done:\n\n" +
  "1. Commit your changes with a descriptive message.\n" +
  "   - `git add <specific files>`\n" +
  "   - NEVER `git add .`\n" +
  "2. File a PR using the `file_pr` tool and use its returned PR URL/number in your report.\n" +
  "   - If your CLI does not load MCP tools directly, `file_pr` is also available as a shell command on PATH.\n" +
  "   - `file_pr` also starts review tracking automatically.\n" +
  "3. Use `notify_parent` for status updates and blockers.\n" +
  "   - After filing the PR, notify the parent that the PR is open and include the PR URL.\n" +
  "   - `notify_parent` and `shutdown` are also available as shell commands on PATH.\n" +
  "4. After the PR is open, remain available in the session for review feedback, follow-up fixes, and merge coordination.\n" +
  "   - PR creation is not the end of the task.\n" +
  "   - Do not call `shutdown` immediately after opening the PR.\n" +
  "   - Only shut down when the parent explicitly releases you, the PR is merged, or you are blocked and have reported that.\n\n" +
  "Do not merge your own PR.\n" +
  "Do not push to main.\n" +
  "Do not create extra branches."
}

///|
fn worker_profile_text(worker_type : String) -> String {
  if worker_type == "research" {
    "## Completion Protocol (Research Worker)\n" +
    "You are a research worker. Explore, read, search, and synthesize.\n\n" +
    "When you are done:\n\n" +
    "1. Call `notify_parent` with status `success` and your findings.\n" +
    "2. If you fail, call `notify_parent` with status `failure` and explain why.\n\n" +
    "Do not edit files.\n" +
    "Do not commit, push, or file PRs."
  } else if worker_type == "review" {
    "## Completion Protocol (Review Worker)\n" +
    "You are a review worker. Inspect code, diffs, tests, and behavior, then report findings.\n\n" +
    "When you are done:\n\n" +
    "1. Call `notify_parent` with status `success` and your review findings.\n" +
    "2. If you fail, call `notify_parent` with status `failure` and explain why.\n\n" +
    "Do not edit files.\n" +
    "Do not commit, push, or file PRs."
  } else {
    "## Completion Protocol (Worker)\n" +
    "You are an ephemeral worker in the parent's directory and branch.\n\n" +
    "If upstream instructions mention commits, branches, PRs, or PR-tracking tools, ignore those parts.\n" +
    "Workers do not own branches or PRs.\n\n" +
    "When you are done:\n\n" +
    "1. Call `notify_parent` with status `success` and a detailed summary.\n" +
    "2. If you fail, call `notify_parent` with status `failure` and explain why.\n\n" +
    "Do not commit, push, or file PRs.\n" +
    "Do not create or switch branches."
  }
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
  lowered.contains("pr") ||
  lowered.contains("pull request") ||
  lowered.contains("file_pr") ||
  lowered.contains("merge_pr") ||
  lowered.contains("track_pr") ||
  lowered.contains("commit") ||
  lowered.contains("push") ||
  lowered.contains("branch")
}

///|
fn sanitize_worker_lines(lines : Array[String]) -> Array[String] {
  let filtered : Array[String] = []
  for line in lines {
    if not(line_mentions_worker_forbidden_action(line)) {
      filtered.push(line)
    }
  }
  filtered
}

///|
fn render_common_prompt(
  spec : PromptSpec,
  profile : String,
  include_agents_md : Bool,
  sanitize_worker? : Bool = false,
) -> String {
  if spec.prompt != "" {
    return spec.prompt + "\n\n" + profile
  }

  let sections : Array[String] = []
  add_section(sections, "TASK", spec.task)
  add_section(sections, "BOUNDARY", render_bullets(spec.boundary))

  let read_first = spec.read_first
  if include_agents_md {
    push_unique(read_first, "AGENTS.md")
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
  for cmd in spec.verify {
    verify_lines.push("- `" + cmd + "`")
  }
  add_section(sections, "VERIFY", render_lines(verify_lines))
  let done_criteria = if sanitize_worker {
    sanitize_worker_lines(spec.done_criteria)
  } else {
    spec.done_criteria
  }
  add_section(sections, "DONE CRITERIA", render_bullets(done_criteria))

  let constraints = spec.constraints
  if spec.no_commit {
    constraints.push("Do not commit. Report back when done or blocked.")
  }
  add_section(sections, "CONSTRAINTS", render_bullets(constraints))
  sections.push(profile)
  join_sections(sections)
}

///|
pub fn render_leaf_spawn_prompt(spec : PromptSpec) -> String {
  render_common_prompt(spec, leaf_profile_text(), true)
}

///|
pub fn render_worker_spawn_prompt(spec : PromptSpec) -> String {
  render_common_prompt(
    spec,
    worker_profile_text(spec.worker_type),
    true,
    sanitize_worker=true,
  )
}
