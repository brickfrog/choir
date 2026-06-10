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
      let raw = s[start:i].to_owned()
      let line = raw.trim().to_owned()
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
  let merged : Array[String] = []
  for value in items {
    push_unique(merged, value.trim().to_owned())
  }
  for value in more {
    push_unique(merged, value.trim().to_owned())
  }
  merged
}

///|
fn parse_optional_trimmed(value : String?) -> String? {
  match value {
    Some(v) => {
      let trimmed = v.trim().to_owned()
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
fn parse_issue_id(args : Map[String, String]) -> String? {
  match parse_optional_trimmed(args.get("beads_issue_id")) {
    Some(value) => Some(value)
    None =>
      match parse_optional_trimmed(args.get("bead_id")) {
        Some(value) => Some(value)
        None => parse_optional_trimmed(args.get("issue_id"))
      }
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
  let trimmed = body.trim().to_owned()
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
fn parse_default_true_bool_flag(value : String?) -> Bool {
  match value {
    None => true
    Some(raw) => {
      let lowered = raw.trim().to_lower()
      if lowered == "" {
        return true
      }
      if lowered == "false" ||
        lowered == "0" ||
        lowered == "no" ||
        lowered == "off" {
        return false
      }
      lowered == "true" || lowered == "1" || lowered == "yes" || lowered == "on"
    }
  }
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
  let guard_paths = merge_unique_lines(
    split_nonempty_lines(args.get("guard_paths").unwrap_or("")),
    [],
  )
  let verify = merge_unique_lines(
    split_nonempty_lines(args.get("verify").unwrap_or("")),
    [],
  )
  let scope = split_nonempty_lines(args.get("scope").unwrap_or(""))
  let beads_issue_id = parse_issue_id(args)
  let review_context = parse_optional_trimmed(args.get("review_context"))
  {
    prompt: args.get("prompt").unwrap_or("").trim().to_owned(),
    task,
    task_contract: {
      goal: task,
      scope,
      acceptance_checks,
      constraints,
      non_goals,
      guard_paths,
      beads_issue_id,
      review_context,
      verify,
      verify_satisfied_by_ci: parse_default_true_bool_flag(
        args.get("verify_satisfied_by_ci"),
      ),
    },
    boundary: split_nonempty_lines(args.get("boundary").unwrap_or("")),
    read_first: split_nonempty_lines(args.get("read_first").unwrap_or("")),
    steps: split_nonempty_lines(args.get("steps").unwrap_or("")),
    verify,
    done_criteria: acceptance_checks,
    constraints,
    context: args.get("context").unwrap_or("").trim().to_owned(),
    key_decisions: split_nonempty_lines(args.get("key_decisions").unwrap_or("")),
    non_goals,
    worker_type: args
    .get("type")
    .unwrap_or("research")
    .trim()
    .to_lower()
    .to_owned(),
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
fn render_beads_issue(id : String) -> String {
  render_bullets([
    id,
    "Use `task_get` or `bd --readonly show " +
    id +
    " --json` before implementation if the prompt does not include enough issue context.",
  ])
}

///|
fn leaf_profile_text(project_dir : String) -> String {
  @prompts.load_prompt(@prompts.PromptName::LeafProfile, project_dir)
}

///|
fn worker_profile_name(
  worker_type : String,
  worker_isolation : @types.IsolationMode?,
) -> @prompts.PromptName {
  match (worker_type, worker_isolation) {
    ("review", Some(@types.IsolationMode::Worktree)) =>
      @prompts.PromptName::WorkerReviewWrite
    ("review", _) => @prompts.PromptName::WorkerReview
    _ => @prompts.PromptName::WorkerResearch
  }
}

///|
fn worker_profile_text(
  worker_type : String,
  project_dir : String,
  worker_isolation : @types.IsolationMode?,
) -> String {
  @prompts.load_prompt(
    worker_profile_name(worker_type, worker_isolation),
    project_dir,
  )
}

///|
fn prompt_project_base(project_dir : String) -> String {
  if project_dir == "" {
    "."
  } else {
    project_dir
  }
}

///|
let prompt_moon_verify_target_cache : @ref.Ref[
  Map[String, @types.MoonVerifyTarget],
] = @ref.new({})

///|
fn prompt_moon_verify_target_uncached(
  project_dir : String,
) -> @types.MoonVerifyTarget {
  let content = @sys.read_file(project_dir + "/.choir/config.toml")
  if content == "" {
    return @types.Config::default().moon_verify_target
  }
  match @config.parse_config(content) {
    Ok(config) => config.moon_verify_target
    Err(_) => @types.Config::default().moon_verify_target
  }
}

///|
fn prompt_moon_verify_target(project_dir : String) -> @types.MoonVerifyTarget {
  let project_dir = prompt_project_base(project_dir)
  match prompt_moon_verify_target_cache.val.get(project_dir) {
    Some(value) => value
    None => {
      let value = prompt_moon_verify_target_uncached(project_dir)
      prompt_moon_verify_target_cache.val.set(project_dir, value)
      value
    }
  }
}

///|
fn warn_moon_verify_normalization(
  context : String,
  notice : @types.MoonVerifyNormalizationNotice,
) -> Unit {
  @moontrace.warn("moon verify command normalized", fields=[
    @moontrace.field("event", "moon_verify_command_normalized"),
    @moontrace.field("context", context),
    @moontrace.field("command", notice.command),
    @moontrace.field("normalized", notice.normalized),
    @moontrace.field("moon_verify_target", notice.target.to_wire_string()),
  ])
}

///|
fn normalize_prompt_task_contract(
  task_contract : @types.TaskContract,
  moon_verify_target : @types.MoonVerifyTarget,
) -> @types.TaskContract {
  for
    notice in @types.moon_verify_normalization_notices(
      task_contract.verify,
      moon_verify_target,
    ) {
    warn_moon_verify_normalization("spawn_prompt", notice)
  }
  let normalized = @types.task_contract_with_normalized_verify(
    Some(task_contract),
    moon_verify_target,
  ).unwrap_or(task_contract)
  // Spawn parsing records the same contract after rendering the prompt. Keep
  // that caller-visible verify list aligned with the prompt's VERIFY section.
  for i = 0; i < task_contract.verify.length(); i = i + 1 {
    task_contract.verify[i] = normalized.verify[i]
  }
  normalized
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
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
) -> String {
  if spec.prompt != "" {
    return spec.prompt + "\n\n" + profile
  }

  let sections : Array[String] = []
  add_section(sections, "TASK", spec.task_contract.goal)
  match spec.task_contract.beads_issue_id {
    Some(id) => add_section(sections, "BEADS ISSUE", render_beads_issue(id))
    None => ()
  }
  add_section(sections, "SCOPE", render_bullets(spec.task_contract.scope))
  add_section(sections, "BOUNDARY", render_bullets(spec.boundary))

  // Structural context (resolved via `@workspace.resolve_context_paths`, which
  // iterates `problems`, `common`, `role` in that order) lands before
  // task-specific reads so every leaf sees problems.md first regardless of
  // what the TL put in `spec.read_first`.
  let read_first : Array[String] = []
  for path in default_read_first {
    push_unique(read_first, path)
  }
  for path in spec.read_first {
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

  let task_contract = normalize_prompt_task_contract(
    spec.task_contract,
    moon_verify_target,
  )
  let verify_lines : Array[String] = []
  for cmd in task_contract.verify {
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
  project_dir? : String = ".",
  moon_verify_target? : @types.MoonVerifyTarget? = None,
) -> String {
  let resolved_moon_verify_target = moon_verify_target.unwrap_or(
    prompt_moon_verify_target(project_dir),
  )
  render_common_prompt(
    spec,
    leaf_profile_text(project_dir),
    default_read_first,
    moon_verify_target=resolved_moon_verify_target,
  )
}

///|
pub fn render_leaf_spawn_prompt(
  spec : PromptSpec,
  moon_verify_target? : @types.MoonVerifyTarget? = None,
) -> String {
  render_leaf_spawn_prompt_with_defaults(
    spec,
    [".choir/context/common.md", ".choir/context/dev.md"],
    moon_verify_target~,
  )
}

///|
pub fn render_worker_spawn_prompt_with_defaults(
  spec : PromptSpec,
  default_read_first : Array[String],
  project_dir? : String = ".",
  moon_verify_target? : @types.MoonVerifyTarget? = None,
  worker_isolation? : @types.IsolationMode? = None,
) -> String {
  let resolved_moon_verify_target = moon_verify_target.unwrap_or(
    prompt_moon_verify_target(project_dir),
  )
  render_common_prompt(
    spec,
    worker_profile_text(spec.worker_type, project_dir, worker_isolation),
    default_read_first,
    sanitize_worker=true,
    moon_verify_target=resolved_moon_verify_target,
  )
}

///|
pub fn render_worker_spawn_prompt(
  spec : PromptSpec,
  moon_verify_target? : @types.MoonVerifyTarget? = None,
  worker_isolation? : @types.IsolationMode? = None,
) -> String {
  render_worker_spawn_prompt_with_defaults(
    spec,
    [".choir/context/common.md", ".choir/context/worker.md"],
    moon_verify_target~,
    worker_isolation~,
  )
}
