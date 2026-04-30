///|
fn statusline_read_all_stdin() -> String {
  let buf = StringBuilder::new()
  for ;; {
    match @sys.read_stdin_line(65536) {
      Some(line) => {
        buf.write_string(line)
        buf.write_string("\n")
      }
      None => break
    }
  }
  buf.to_string()
}

///|
fn statusline_json_string(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn statusline_json_number(obj : Map[String, Json], key : String) -> Double {
  match obj.get(key) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn statusline_json_object(
  obj : Map[String, Json],
  key : String,
) -> Map[String, Json] {
  match obj.get(key) {
    Some(Object(m)) => m
    _ => {}
  }
}

///|
priv struct StatuslinePrSummary {
  body : String
  has_automerge : Bool
}

///|
/// Full paths of entries in `.choir/kv` whose basename starts with `prefix`.
/// Replaces the former `find -maxdepth 1 -type f -name <prefix>*` subprocess;
/// both call sites (`lifecycle--`, `children--`) use prefix matching so the
/// glob shape was already strictly `prefix*`.
fn statusline_kv_files_with_prefix(
  project_dir : String,
  prefix : String,
) -> Array[String] {
  let kv_dir = project_dir + "/.choir/kv"
  if !@sys.path_entry_exists(kv_dir) {
    return []
  }
  let files : Array[String] = []
  for name in @sys.list_dir(kv_dir) {
    if name.has_prefix(prefix) {
      files.push(kv_dir + "/" + name)
    }
  }
  files
}

///|
fn statusline_list_lifecycle_files(project_dir : String) -> Array[String] {
  statusline_kv_files_with_prefix(project_dir, "lifecycle--")
}

///|
fn statusline_collect_child_ids(project_dir : String) -> Map[String, Bool] {
  let paths = statusline_kv_files_with_prefix(project_dir, "children--")
  let ids : Map[String, Bool] = {}
  for path in paths {
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    let json = @json.parse(content) catch { _ => continue }
    let arr = match json {
      Array(items) => items
      _ => continue
    }
    for item in arr {
      match item {
        Object(child) =>
          match child.get("id") {
            Some(String(id)) => ids.set(id, true)
            _ => ()
          }
        _ => ()
      }
    }
  }
  ids
}

///|
/// Append a 10-char block bar for the given percentage with a dim label.
/// Green < 50%, yellow 50-79%, red >= 80%.
fn statusline_render_bar(
  out : StringBuilder,
  pct : Int,
  label : String,
) -> Unit {
  let filled = pct / 10
  let color = if pct >= 80 {
    "\u001b[31m"
  } else if pct >= 50 {
    "\u001b[33m"
  } else {
    "\u001b[32m"
  }
  out.write_string(color)
  for i = 0; i < 10; i = i + 1 {
    if i < filled {
      out.write_string("▓")
    } else {
      out.write_string("░")
    }
  }
  out.write_string("\u001b[0m ")
  out.write_string(pct.to_string())
  out.write_string("\u001b[2m% ")
  out.write_string(label)
  out.write_string("\u001b[0m")
}

///|
/// Parse `.git/HEAD` synchronously. Returns the branch name (e.g. `main`,
/// `feature/xyz`) or a short 7-char hash when HEAD is detached. Empty string
/// if `.git/HEAD` is unreadable.
fn statusline_git_branch(project_dir : String) -> String {
  let head = @sys.read_file(project_dir + "/.git/HEAD")
  if head == "" {
    return ""
  }
  let trimmed = head.trim().to_owned()
  if trimmed.has_prefix("ref: refs/heads/") {
    trimmed[16:].to_owned()
  } else if trimmed.length() >= 7 {
    trimmed[0:7].to_owned()
  } else {
    trimmed
  }
}

///|
/// True when any `tl-parent-override--*` sentinel exists in `.choir/kv`.
fn statusline_override_active(project_dir : String) -> Bool {
  statusline_kv_files_with_prefix(project_dir, "tl-parent-override--").length() >
  0
}

///|
fn statusline_count_agents(project_dir : String) -> (Int, Int, Int, Int, Int) {
  let child_ids = statusline_collect_child_ids(project_dir)
  let files = statusline_list_lifecycle_files(project_dir)
  let mut working = 0
  let mut review = 0
  let mut changes = 0
  let mut failed = 0
  let mut done = 0
  for path in files {
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    let json = @json.parse(content) catch { _ => continue }
    let obj = match json {
      Object(m) => m
      _ => continue
    }
    let agent_id = statusline_json_string(obj, "agent_id")
    // If children files exist, only count tracked agents
    if child_ids.length() > 0 && agent_id != "" && !child_ids.contains(agent_id) {
      continue
    }
    let workflow = statusline_json_object(obj, "workflow")
    let state = statusline_json_object(workflow, "state")
    let tag = statusline_json_string(state, "tag")
    match tag {
      "Working" => working = working + 1
      "ReviewOwned" | "ExitRequestedDeferred" => review = review + 1
      "ChangesRequested" => changes = changes + 1
      "Failed" => failed = failed + 1
      "Done" => done = done + 1
      _ => ()
    }
  }
  (working, review, changes, failed, done)
}

///|
test "statusline_kv_files_with_prefix detects pending-wave entries" {
  let project_dir = "/tmp/choir-statusline-pending-wave-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/pending-wave--w1",
      "{\"wave_id\":\"w1\"}",
    ),
  )
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/pending-wave--w2",
      "{\"wave_id\":\"w2\"}",
    ),
  )
  ignore(
    @sys.write_file_sync(project_dir + "/.choir/kv/lifecycle--main--leaf", "{}"),
  )
  let paths = statusline_kv_files_with_prefix(project_dir, "pending-wave--")
  ignore(@sys.rm_rf(project_dir))
  assert_eq(paths.length(), 2)
}

///|
test "statusline_count_agents matches child ids using lifecycle content agent_id" {
  let project_dir = "/tmp/choir-statusline-agent-id-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/kv"))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/lifecycle--main--leaf",
      "{\"agent_id\":\"main.leaf\",\"workflow\":{\"state\":{\"tag\":\"Working\"}}}",
    ),
  )
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/kv/children--root",
      "[{\"id\":\"main.leaf\"}]",
    ),
  )
  let (working, review, changes, failed, done) = statusline_count_agents(
    project_dir,
  )
  ignore(@sys.rm_rf(project_dir))
  assert_eq((working, review, changes, failed, done), (1, 0, 0, 0, 0))
}

///|
fn statusline_test_tracked_pr(
  pr_number : Int,
  agent_id : String,
) -> @poller.TrackedPR {
  {
    pr_number,
    agent_id,
    branch: "work/" + @phase.extract_slug(agent_id),
    parent_branch: "main",
    pr_url: "https://ex/pr/" + pr_number.to_string(),
    first_seen: 0L,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: true,
    orphan_notified: false,
    orphan_reconciling: false,
    changes_requested_since: 0L,
    stall_notified: false,
    fixes_pushed_at: 0L,
  }
}

///|
test "statusline_pr_summary distinguishes manual and automerge merge-ready PRs" {
  let project_dir = "/tmp/choir-statusline-pr-summary-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  assert_true(@sys.create_dir_all(project_dir + "/.choir/worktrees/leaf-auto"))
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/config.toml",
      "automerge = false\n",
    ),
  )
  ignore(
    @sys.write_file_sync(
      @workspace.worktree_path(project_dir, "leaf-auto") + "/config.local.toml",
      "automerge = true\n",
    ),
  )
  let manual = statusline_test_tracked_pr(81, "main.leaf-manual")
  let auto = statusline_test_tracked_pr(82, "main.leaf-auto")
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/poller_state.json",
      "[" + manual.to_json() + "," + auto.to_json() + "]",
    ),
  )
  let summary = statusline_pr_summary(project_dir)
  ignore(@sys.rm_rf(project_dir))
  assert_true(summary.body.contains("#81M"))
  assert_true(summary.body.contains("#82A"))
  assert_true(summary.has_automerge)
}

///|
fn statusline_global_config(project_dir : String) -> @types.Config {
  match
    @config.parse_config(@sys.read_file(project_dir + "/.choir/config.toml")) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }
}

///|
fn statusline_local_config(
  project_dir : String,
  agent_id : String,
) -> @types.LocalConfig? {
  let path = @workspace.worktree_path(
      project_dir,
      @phase.extract_slug(agent_id),
    ) +
    "/config.local.toml"
  let content = @sys.read_file(path)
  if content == "" {
    return None
  }
  match @config.parse_local_config(content) {
    Ok(cfg) => Some(cfg)
    Err(_) => None
  }
}

///|
fn statusline_effective_merge_mode(
  project_dir : String,
  config : @types.Config,
  agent_id : String,
) -> (@poller.MergeOperatorMode, @types.TaskContract?) {
  match statusline_local_config(project_dir, agent_id) {
    Some(local_cfg) =>
      (
        @poller.merge_operator_mode_from_automerge(
          local_cfg.automerge.unwrap_or(config.automerge),
        ),
        local_cfg.task_contract,
      )
    None => (@poller.merge_operator_mode_from_automerge(config.automerge), None)
  }
}

///|
fn statusline_pr_token(
  project_dir : String,
  tracked : @poller.TrackedPR,
  merge_mode : @poller.MergeOperatorMode,
  task_contract : @types.TaskContract?,
) -> String {
  ignore(project_dir)
  ignore(task_contract)
  let n = tracked.pr_number.to_string()
  if @poller.tl_tracked_pr_merge_gate_snapshot_ready(tracked, Some(0)) {
    return match merge_mode {
      @poller.MergeOperatorMode::Manual => "\u001b[32m#\{n}M\u001b[0m"
      @poller.MergeOperatorMode::Automerge => "\u001b[36m#\{n}A\u001b[0m"
      @poller.MergeOperatorMode::Mixed => "\u001b[36m#\{n}?\u001b[0m"
    }
  }
  if tracked.last_review_state == @poller.ReviewState::ChangesRequested ||
    tracked.last_ci_rollup == @poller.CiRollupStatus::Failure {
    return "\u001b[35m#\{n}!\u001b[0m"
  }
  match tracked.last_review_state {
    @poller.ReviewState::Approved => "\u001b[32m#\{n}\u001b[0m"
    _ => "#\{n}"
  }
}

///|
fn statusline_pr_summary(project_dir : String) -> StatuslinePrSummary {
  let tracked_prs = @poller.read_state_file(project_dir)
  if tracked_prs.length() == 0 {
    return { body: "", has_automerge: false }
  }
  for i = 0; i < tracked_prs.length(); i = i + 1 {
    for j = i + 1; j < tracked_prs.length(); j = j + 1 {
      if tracked_prs[i].pr_number > tracked_prs[j].pr_number {
        let tmp = tracked_prs[i]
        tracked_prs[i] = tracked_prs[j]
        tracked_prs[j] = tmp
      }
    }
  }
  let config = statusline_global_config(project_dir)
  let parts = StringBuilder::new()
  let mut first = true
  let mut has_automerge = false
  for tracked in tracked_prs {
    let (merge_mode, task_contract) = statusline_effective_merge_mode(
      project_dir,
      config,
      tracked.agent_id,
    )
    if merge_mode == @poller.MergeOperatorMode::Automerge {
      has_automerge = true
    }
    if !first {
      parts.write_string(" ")
    }
    first = false
    parts.write_string(
      statusline_pr_token(project_dir, tracked, merge_mode, task_contract),
    )
  }
  { body: parts.to_string(), has_automerge }
}

///|
fn statusline_run() -> Unit {
  let input = statusline_read_all_stdin()
  let json = @json.parse(input) catch {
    _ => @json.parse("{}") catch { _ => return }
  }
  let root = match json {
    Object(m) => m
    _ => return
  }
  let rate_obj = statusline_json_object(root, "rate_limits")
  let week_obj = statusline_json_object(rate_obj, "seven_day")
  let week_pct = statusline_json_number(week_obj, "used_percentage").to_int()
  let five_obj = statusline_json_object(rate_obj, "five_hour")
  let five_pct = statusline_json_number(five_obj, "used_percentage").to_int()
  let cwd = match root.get("cwd") {
    Some(String(s)) => s
    _ => "."
  }
  let project_dir = cwd
  let has_choir = @sys.read_file(project_dir + "/.choir/config.toml") != ""
  let out = StringBuilder::new()

  let sep = "\u001b[2m │ \u001b[0m"

  // Branch segment: feature/* gets a distinguishing prefix; main/master plain.
  let branch = statusline_git_branch(project_dir)
  if branch != "" {
    if branch.has_prefix("feature/") {
      out.write_string("\u001b[2m↪ \u001b[0m\u001b[36m")
      out.write_string(branch)
      out.write_string("\u001b[0m")
    } else {
      out.write_string("\u001b[36m")
      out.write_string(branch)
      out.write_string("\u001b[0m")
    }
    out.write_string(sep)
  }

  // Context bars: 5h and 7d windows, 10-char block bars side by side.
  statusline_render_bar(out, five_pct, "5h")
  out.write_string("  ")
  statusline_render_bar(out, week_pct, "7d")
  if !has_choir {
    @sys.write_stdout(out.to_string())
    return
  }

  // Leaf state glyphs — show only nonzero counts.
  let (working, review, changes, failed, _done) = statusline_count_agents(
    project_dir,
  )
  let pending_waves = statusline_kv_files_with_prefix(
    project_dir, "pending-wave--",
  ).length()
  let total = working + review + changes + failed
  if total > 0 || pending_waves > 0 {
    out.write_string(sep)
    let mut need_sep = false
    if working > 0 {
      out.write_string("\u001b[33m●")
      out.write_string(working.to_string())
      out.write_string("\u001b[0m")
      need_sep = true
    }
    if review > 0 {
      if need_sep {
        out.write_string(" ")
      }
      out.write_string("\u001b[32m◐")
      out.write_string(review.to_string())
      out.write_string("\u001b[0m")
      need_sep = true
    }
    if changes > 0 {
      if need_sep {
        out.write_string(" ")
      }
      out.write_string("\u001b[35m◆")
      out.write_string(changes.to_string())
      out.write_string("\u001b[0m")
      need_sep = true
    }
    if failed > 0 {
      if need_sep {
        out.write_string(" ")
      }
      out.write_string("\u001b[31m✗")
      out.write_string(failed.to_string())
      out.write_string("\u001b[0m")
      need_sep = true
    }
    if pending_waves > 0 {
      if need_sep {
        out.write_string(" ")
      }
      // Dim blue ⧗ — queued waves waiting on dep merges (Feature 1).
      out.write_string("\u001b[2;34m⧗")
      out.write_string(pending_waves.to_string())
      out.write_string("\u001b[0m")
    }
  }

  // Override warning — bright so the TL can't miss it.
  if statusline_override_active(project_dir) {
    out.write_string(sep)
    out.write_string("\u001b[1;31m⚠ override\u001b[0m")
  }
  let pr_summary = statusline_pr_summary(project_dir)
  if pr_summary.body != "" {
    out.write_string(sep)
    out.write_string(pr_summary.body)
  }
  if pr_summary.has_automerge {
    out.write_string(" \u001b[36mam\u001b[0m")
  }
  @sys.write_stdout(out.to_string())
}
