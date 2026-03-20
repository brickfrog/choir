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
fn render_context_block(args : Map[String, String]) -> String {
  let sections : Array[String] = []
  let context = args.get("context").unwrap_or("").trim().to_string()
  if context != "" {
    sections.push(context)
  }

  let key_decisions = split_nonempty_lines(
    args.get("key_decisions").unwrap_or(""),
  )
  if key_decisions.length() > 0 {
    sections.push("Key decisions:\n" + render_bullets(key_decisions))
  }

  let non_goals = split_nonempty_lines(args.get("non_goals").unwrap_or(""))
  if non_goals.length() > 0 {
    sections.push("Non-goals:\n" + render_bullets(non_goals))
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
  "   - `file_pr` also starts review tracking automatically.\n" +
  "3. Use `notify_parent` for status updates and blockers.\n\n" +
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
  } else {
    "## Completion Protocol (Worker)\n" +
    "You are an ephemeral worker in the parent's directory and branch.\n\n" +
    "When you are done:\n\n" +
    "1. Call `notify_parent` with status `success` and a detailed summary.\n" +
    "2. If you fail, call `notify_parent` with status `failure` and explain why.\n\n" +
    "Do not commit, push, or file PRs.\n" +
    "Do not create or switch branches."
  }
}

///|
fn render_common_prompt(
  args : Map[String, String],
  profile : String,
  include_agents_md : Bool,
) -> String {
  let prompt_override = args.get("prompt").unwrap_or("").trim().to_string()
  if prompt_override != "" {
    return prompt_override + "\n\n" + profile
  }

  let sections : Array[String] = []
  add_section(sections, "TASK", args.get("task").unwrap_or(""))

  let boundary = split_nonempty_lines(args.get("boundary").unwrap_or(""))
  add_section(sections, "BOUNDARY", render_bullets(boundary))

  let read_first = split_nonempty_lines(args.get("read_first").unwrap_or(""))
  if include_agents_md {
    push_unique(read_first, "AGENTS.md")
  }
  add_section(sections, "READ FIRST", render_bullets(read_first))

  let steps = split_nonempty_lines(args.get("steps").unwrap_or(""))
  add_section(sections, "STEPS", render_numbered(steps))

  let context = render_context_block(args)
  add_section(sections, "CONTEXT", context)

  let verify = split_nonempty_lines(args.get("verify").unwrap_or(""))
  let verify_lines : Array[String] = []
  for cmd in verify {
    verify_lines.push("- `" + cmd + "`")
  }
  add_section(sections, "VERIFY", render_lines(verify_lines))

  let done_criteria = split_nonempty_lines(
    args.get("done_criteria").unwrap_or(""),
  )
  add_section(sections, "DONE CRITERIA", render_bullets(done_criteria))

  let constraints = split_nonempty_lines(args.get("constraints").unwrap_or(""))
  if parse_truthy_flag(args.get("no_commit").unwrap_or("false")) {
    constraints.push("Do not commit. Report back when done or blocked.")
  }
  add_section(sections, "CONSTRAINTS", render_bullets(constraints))

  sections.push(profile)
  join_sections(sections)
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
pub fn render_leaf_spawn_prompt(args : Map[String, String]) -> String {
  render_common_prompt(args, leaf_profile_text(), true)
}

///|
pub fn render_worker_spawn_prompt(args : Map[String, String]) -> String {
  let worker_type = args
    .get("type")
    .unwrap_or("implementation")
    .trim()
    .to_lower()
    .to_string()
  render_common_prompt(args, worker_profile_text(worker_type), true)
}
