///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Debug)

///|
struct ToolArgs {
  values : Map[String, Json]
}

///|
pub fn tool_args_from_map(args : Map[String, String]) -> ToolArgs {
  let values : Map[String, Json] = {}
  args.each(fn(k, v) { values.set(k, String::to_json(v)) })
  { values, }
}

///|
fn tool_args_from_request_args(args : @types.RequestArgs) -> ToolArgs {
  { values: args.to_json_map() }
}

///|
fn tool_args_get(args : ToolArgs, key : String) -> String? {
  match args.values.get(key) {
    Some(String(s)) => Some(s)
    Some(json) => Some(json.stringify())
    None => None
  }
}

///|
fn tool_args_get_json(args : ToolArgs, key : String) -> Json? {
  args.values.get(key)
}

///|
/// Parse a JSON value into an array of trimmed, non-empty strings.
///
/// AUDIT: Non-string array elements are intentionally dropped (not an
/// error). This is the LLM-input boundary for free-form text fields
/// (scope, verify, constraints, etc.). Hard-erroring on a stray non-string
/// would just force the LLM to retry and hit the same path. Strict
/// validation belongs in the task_contract schema, not here.
fn json_string_list(value : Json?) -> Array[String] {
  match value {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => {
            let trimmed = s.trim().to_owned()
            if trimmed != "" {
              out.push(trimmed)
            }
          }
          _ => ()
        }
      }
      out
    }
    Some(String(s)) => split_nonempty_lines(s)
    _ => []
  }
}

///|
fn json_optional_trimmed_string(value : Json?) -> String? {
  match value {
    Some(String(s)) => {
      let trimmed = s.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    _ => None
  }
}

///|
fn json_optional_issue_id(obj : Map[String, Json]) -> String? {
  match json_optional_trimmed_string(obj.get("beads_issue_id")) {
    Some(value) => Some(value)
    None =>
      match json_optional_trimmed_string(obj.get("bead_id")) {
        Some(value) => Some(value)
        None => json_optional_trimmed_string(obj.get("issue_id"))
      }
  }
}

///|
fn task_contract_json_bool_default_true(value : Json?) -> Bool {
  match value {
    Some(True) => true
    Some(False) => false
    Some(String(s)) => parse_default_true_bool_flag(Some(s))
    _ => true
  }
}

///|
fn task_contract_from_json_object(value : Json?) -> @types.TaskContract {
  match value {
    Some(Object(obj)) => {
      let goal = json_optional_trimmed_string(obj.get("goal")).unwrap_or(
        json_optional_trimmed_string(obj.get("task")).unwrap_or(""),
      )
      let acceptance_checks = merge_unique_lines(
        json_string_list(obj.get("acceptance_checks")),
        json_string_list(obj.get("done_criteria")),
      )
      {
        goal,
        scope: json_string_list(obj.get("scope")),
        acceptance_checks,
        constraints: json_string_list(obj.get("constraints")),
        non_goals: json_string_list(obj.get("non_goals")),
        beads_issue_id: json_optional_issue_id(obj),
        review_context: json_optional_trimmed_string(obj.get("review_context")),
        verify: json_string_list(obj.get("verify")),
        verify_satisfied_by_ci: task_contract_json_bool_default_true(
          obj.get("verify_satisfied_by_ci"),
        ),
      }
    }
    Some(String(s)) => {
      let parsed = @json.parse(s) catch {
        _ => {
          let preview_end = if s.length() < 120 { s.length() } else { 120 }
          @moontrace.warn("task contract inner parse failed", fields=[
            @moontrace.field("payload_prefix", s[:preview_end].to_owned()),
          ])
          return @types.TaskContract::empty()
        }
      }
      task_contract_from_json_object(Some(parsed))
    }
    _ => @types.TaskContract::empty()
  }
}

///|
fn merge_task_contracts(
  nested : @types.TaskContract,
  top_level : @types.TaskContract,
) -> @types.TaskContract {
  {
    goal: if top_level.goal != "" {
      top_level.goal
    } else {
      nested.goal
    },
    scope: merge_unique_lines(nested.scope, top_level.scope),
    acceptance_checks: merge_unique_lines(
      nested.acceptance_checks,
      top_level.acceptance_checks,
    ),
    constraints: merge_unique_lines(nested.constraints, top_level.constraints),
    non_goals: merge_unique_lines(nested.non_goals, top_level.non_goals),
    beads_issue_id: match top_level.beads_issue_id {
      Some(value) => Some(value)
      None => nested.beads_issue_id
    },
    review_context: match top_level.review_context {
      Some(value) => Some(value)
      None => nested.review_context
    },
    verify: merge_unique_lines(nested.verify, top_level.verify),
    verify_satisfied_by_ci: nested.verify_satisfied_by_ci &&
    top_level.verify_satisfied_by_ci,
  }
}

///|
fn tool_args_to_map(args : ToolArgs) -> Map[String, String] {
  let converted : Map[String, String] = {}
  args.values.each(fn(k, v) {
    converted.set(
      k,
      match v {
        String(s) => s
        _ => v.stringify()
      },
    )
  })
  converted
}

///|
fn prompt_spec_from_tool_args(args : ToolArgs) -> PromptSpec {
  let base = PromptSpec::from_map(tool_args_to_map(args))
  let merged_contract = merge_task_contracts(
    task_contract_from_json_object(tool_args_get_json(args, "contract")),
    base.task_contract,
  )
  {
    ..base,
    task: merged_contract.goal,
    task_contract: merged_contract,
    verify: merged_contract.verify,
    done_criteria: merged_contract.acceptance_checks,
    constraints: merged_contract.constraints,
    non_goals: merged_contract.non_goals,
  }
}

///|
fn tool_args_get_int(args : ToolArgs, key : String) -> Int? {
  match tool_args_get(args, key) {
    Some(value) => parse_int(value)
    None => None
  }
}

///|
fn tool_args_get_bool(args : ToolArgs, key : String) -> Bool {
  parse_lenient_bool_flag(key, tool_args_get(args, key).unwrap_or("false"))
}

///|
fn agent_list_includes_by_default(agent : @types.Agent) -> Bool {
  match agent.state {
    @types.AgentState::Done | @types.AgentState::Failed => false
    _ => true
  }
}

///|
fn optional_string_json(value : String?) -> Json {
  match value {
    Some(v) => String::to_json(v)
    None => @json.parse("null") catch { _ => String::to_json("") }
  }
}

///|
fn resolve_parent_for_notify(
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  caller_id : String,
) -> @types.Agent raise @types.ChoirError {
  @phase.resolve_parent_with_fallback(project_dir, session, reg, caller_id)
}

///|
fn parent_branch_policy_role_applies(role : @types.Role) -> Bool {
  role == @types.Role::Root || role == @types.Role::TL
}

///|
fn parent_branch_policy_child_terminal(
  summary : @phase.ChildLifecycleSummary,
) -> Bool {
  match summary {
    @phase.ChildLifecycleSummary::Done => true
    @phase.ChildLifecycleSummary::Failed(_) => true
    _ => false
  }
}

///|
fn parent_branch_policy_live_wave_info(
  lifecycle : @phase.AgentLifecycle?,
) -> (Bool, Int?) {
  match lifecycle {
    Some(
      {
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::Supervising(children~, wave~)
        ),
        ..,
      }
    ) => {
      for child in children {
        if !parent_branch_policy_child_terminal(child.summary) {
          return (true, Some(wave))
        }
      }
      (false, Some(wave))
    }
    Some(
      {
        workflow: @phase.WorkflowState::Supervisor(
          @phase.SupervisorLifecycle::WaveComplete(wave~, children~)
        ),
        ..,
      }
    ) => {
      for child in children {
        if !parent_branch_policy_child_terminal(child.summary) {
          return (true, Some(wave))
        }
      }
      (false, Some(wave))
    }
    _ => (false, None)
  }
}

///|
fn parent_branch_policy_caller_id(req : @types.Request) -> String {
  match req.args.get("caller_id") {
    Some(value) => value
    None =>
      match req.args.get("agent_id") {
        Some(value) => value
        None => "root"
      }
  }
}

///|
fn strip_dot_slash(path : String) -> String {
  let mut out = path
  while out.has_prefix("./") {
    out = out[2:].to_owned()
  }
  out
}

///|
fn ensure_trailing_slash(path : String) -> String {
  if path.has_suffix("/") {
    path
  } else {
    path + "/"
  }
}

///|
/// Collapse `.` and `..` path segments so a string-prefix doc classification
/// can't be fooled by `docs/../src/foo.mbt`. Leading `..` segments that can't
/// be resolved are kept (the result then fails the `docs/` / `.choir/context/`
/// doc-prefix checks, so it blocks rather than slips past).
fn normalize_path_segments(path : String) -> String {
  let out : Array[String] = []
  for raw_seg in path.split("/") {
    let seg = raw_seg.to_owned()
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if out.length() > 0 && out[out.length() - 1] != ".." {
        ignore(out.pop())
      } else {
        out.push("..")
      }
      continue
    }
    out.push(seg)
  }
  let mut result = ""
  for idx = 0; idx < out.length(); idx = idx + 1 {
    if idx > 0 {
      result = result + "/"
    }
    result = result + out[idx]
  }
  result
}

///|
/// Reduce a tool-supplied file path to a repo-relative path, or `None` if the
/// path is clearly outside the repository.
///
/// `project_dir` is whatever the caller passed (in production it is `"."`,
/// because `init` writes `project_dir = "."` and the server forwards it
/// unchanged), and `repo_toplevel` is the absolute repo root from
/// `git rev-parse --show-toplevel` when it could be resolved.
///
/// - Relative tool paths are taken as already repo-relative (choir-serve runs
///   with cwd == repo root); a leading `project_dir/` prefix is stripped if
///   present, then `.`/`..` segments are collapsed.
/// - Absolute tool paths under `repo_toplevel` (or under `project_dir` when it
///   is itself absolute and the toplevel could not be resolved) are made
///   repo-relative by stripping that root.
/// - Any other absolute path — outside the resolved root, or with no
///   resolvable root at all — is treated conservatively as in-repo (drop the
///   leading `/`, collapse segments) so source paths still block rather than
///   silently bypassing the gate. The earlier behaviour returned `None` here,
///   which let `/repo/src/foo.mbt` slip past whenever `project_dir` was the
///   production `"."`, and would also let a symlinked repo root slip past. The
///   cost is over-blocking a genuine write to an absolute path outside the
///   repo during a live wave; use `scaffold_commit` or wait for the wave to
///   finish when that happens.
fn parent_branch_policy_relative_path(
  project_dir : String,
  repo_toplevel : String?,
  path : String,
) -> String? {
  let trimmed = strip_dot_slash(path.trim().to_owned())
  if trimmed == "" {
    return None
  }
  let finish = fn(rel : String) -> String? {
    let norm = normalize_path_segments(rel)
    if norm == "" {
      None
    } else {
      Some(norm)
    }
  }
  if !trimmed.has_prefix("/") {
    let project = strip_dot_slash(project_dir.trim().to_owned())
    if project != "" && project != "/" {
      let project_prefix = ensure_trailing_slash(project)
      if trimmed.has_prefix(project_prefix) {
        return finish(trimmed[project_prefix.length():].to_owned())
      }
    }
    return finish(trimmed)
  }
  let project_dir_trimmed = project_dir.trim().to_owned()
  let root = match repo_toplevel {
    Some(top) => {
      let top = top.trim().to_owned()
      if top == "" {
        None
      } else {
        Some(top)
      }
    }
    None =>
      if project_dir_trimmed.has_prefix("/") {
        Some(project_dir_trimmed)
      } else {
        None
      }
  }
  match root {
    Some(root) =>
      if trimmed != root && trimmed.has_prefix(ensure_trailing_slash(root)) {
        finish(trimmed[ensure_trailing_slash(root).length():].to_owned())
      } else {
        // Outside the resolved root (or a symlinked-root mismatch) — be
        // conservative and treat it as in-repo so source paths still block.
        finish(trimmed[1:].to_owned())
      }
    None =>
      // No resolvable root and `project_dir` is relative — same conservative
      // in-repo treatment so source paths still block.
      finish(trimmed[1:].to_owned())
  }
}

///|
fn parent_branch_policy_git_command(
  project_dir : String,
  args : Array[String],
) -> @workspace.Command {
  { program: "git", args, workdir: Some(project_dir) }
}

///|
async fn parent_branch_policy_current_branch(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  let (exit_code, output) = capture(
    parent_branch_policy_git_command(project_dir, [
      "rev-parse", "--abbrev-ref", "HEAD",
    ]),
  )
  if exit_code != 0 {
    return None
  }
  let branch = output.trim().to_owned()
  if branch == "" {
    None
  } else {
    Some(branch)
  }
}

///|
async fn parent_branch_policy_status_paths(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Array[String] {
  let (exit_code, output) = capture(
    parent_branch_policy_git_command(project_dir, [
      "status", "--porcelain", "--untracked-files=all",
    ]),
  )
  if exit_code != 0 {
    []
  } else {
    @policy.git_status_changed_paths(output)
  }
}

///|
fn parent_branch_policy_marker_path(
  kind : @policy.ParentBranchWriteKind,
) -> String {
  ".choir/policy/" + kind.to_wire_string()
}

///|
async fn parent_branch_policy_repo_toplevel(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  let (exit_code, output) = capture(
    parent_branch_policy_git_command(project_dir, [
      "rev-parse", "--show-toplevel",
    ]),
  )
  if exit_code != 0 {
    return None
  }
  let top = output.trim().to_owned()
  if top == "" {
    None
  } else {
    Some(top)
  }
}

///|
async fn parent_branch_policy_changed_paths(
  project_dir : String,
  kind : @policy.ParentBranchWriteKind,
  capture : async (@workspace.Command) -> (Int, String),
) -> Array[String]? {
  match kind {
    @policy.ParentBranchWriteKind::FileEditOnRepoPath(path~) => {
      // ANY edit whose path resolves inside the repo is a changed path —
      // including a brand-new file (a Write of src/foo.mbt that doesn't yet
      // exist): git ls-files would return nothing for it, so a "tracked
      // only" check would let new source files slip past the gate, which is
      // why the variant is `FileEditOnRepoPath`, not `...TrackedPath`. The
      // doc-vs-source classification in decide_tl_parent_branch_write
      // decides whether it actually blocks. Only edits outside the repo
      // (rel_path is None) are exempt. The repo toplevel is needed because
      // production passes project_dir = "." while tools hand us absolute
      // paths — without it an absolute in-repo path slips past the gate; for
      // a relative tool path the toplevel is unused, so don't pay for the
      // `git rev-parse` then.
      let toplevel = if path.trim().to_owned().has_prefix("/") {
        parent_branch_policy_repo_toplevel(project_dir, capture)
      } else {
        None
      }
      match parent_branch_policy_relative_path(project_dir, toplevel, path) {
        Some(rel_path) => Some([rel_path])
        None => None
      }
    }
    @policy.ParentBranchWriteKind::GitCheckout(target~) => {
      match parent_branch_policy_current_branch(project_dir, capture) {
        Some(current) => if current == target { return None }
        None => ()
      }
      // Branch switches can rewrite the worktree with arbitrary target-branch
      // content, so classify them as non-doc even if current dirty paths are
      // doc-only or absent.
      Some([parent_branch_policy_marker_path(kind)])
    }
    @policy.ParentBranchWriteKind::Other(_) =>
      // Worktree/ref-mutating verbs (git switch/restore/rebase/merge/
      // cherry-pick/revert/clean/stash, `git checkout -- <paths>`, plus
      // rm/mv) act independently of what's currently dirty — `git switch
      // other-branch` brings in arbitrary content from another branch, `git
      // clean -fd` deletes untracked files, etc. Reusing the current `git
      // status` paths would let a TL with only doc changes run any of these
      // during a live wave. Use a marker path so the gate always blocks them,
      // the same way GitCheckout is handled.
      Some([parent_branch_policy_marker_path(kind)])
    @policy.ParentBranchWriteKind::GitResetHard =>
      // `git reset --hard <ref>` moves HEAD and overwrites the working tree
      // with arbitrary commit content — never a doc-only operation,
      // regardless of what is currently dirty. Always use a marker path.
      Some([parent_branch_policy_marker_path(kind)])
    @policy.ParentBranchWriteKind::GitCommit => {
      // In-place commit: the doc-only carve-out is intentional — a commit
      // that only touches README during a live wave is harmless. Use the
      // actual dirty paths so decide_tl_parent_branch_write can apply the
      // doc classification; fall back to a marker path when the working
      // tree is clean.
      let paths = parent_branch_policy_status_paths(project_dir, capture)
      if paths.length() > 0 {
        Some(paths)
      } else {
        Some([parent_branch_policy_marker_path(kind)])
      }
    }
    @policy.ParentBranchWriteKind::GitPush =>
      Some([parent_branch_policy_marker_path(kind)])
  }
}

///|
fn parent_branch_policy_refusal_message(
  kind : @policy.ParentBranchWriteKind,
  decision : @policy.TLParentBranchPolicyDecision,
) -> String {
  "policy refused: parent-branch write during live wave (kind=" +
  kind.to_wire_string() +
  "): " +
  decision.reason() +
  ". Use scaffold_commit or wait for the live wave to finish."
}

///|
pub async fn parent_branch_policy_gate_response(
  req : @types.Request,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
  policy_enforcement_mode? : @policy.PolicyEnforcementMode = @policy.policy_enforcement_mode,
  lifecycle_reader? : (String, String) -> @phase.AgentLifecycle? = @phase.read_lifecycle,
) -> @types.Response? {
  if policy_enforcement_mode == @policy.PolicyEnforcementMode::LogOnly {
    return None
  }
  if !parent_branch_policy_role_applies(req.role) {
    return None
  }
  let kind = match @policy.detect_parent_branch_write_kind(req) {
    Some(kind) => kind
    None => return None
  }
  let changed_paths = match
    parent_branch_policy_changed_paths(project_dir, kind, capture) {
    Some(paths) => paths
    None => return None
  }
  let caller_id = parent_branch_policy_caller_id(req)
  let lifecycle = lifecycle_reader(project_dir, caller_id)
  let (live_wave, wave) = parent_branch_policy_live_wave_info(lifecycle)
  let decision = @policy.decide_tl_parent_branch_write(
    live_wave, wave, changed_paths,
  )
  if decision.is_blocked() {
    Some(
      @types.Response::Err(parent_branch_policy_refusal_message(kind, decision)),
    )
  } else {
    None
  }
}

///|
/// Build a [`send_message`] plan that warns the parent TL when `notify_parent`
/// is blocked on review threads (best-effort; used for tests and dispatch).
fn notify_parent_blocked_parent_warn_send_plan(
  reg : @registry.AgentRegistry,
  project_dir : String,
  session : String,
  caller_id : String,
  pr_number : Int,
  gh_thread_fetch_failed : Bool,
) -> SendMessagePlan raise @types.ChoirError {
  let parent = resolve_parent_for_notify(project_dir, session, reg, caller_id)
  let body = if gh_thread_fetch_failed {
    "[NOTIFY BLOCKED] " +
    caller_id +
    " on PR #" +
    pr_number.to_string() +
    ": could not fetch review thread state (gh unavailable) — leaf is blocked and will be watchdog-killed in ~5 min if not resolved. Resolve threads or manually advance lifecycle."
  } else {
    "[NOTIFY BLOCKED] " +
    caller_id +
    " has unresolved review threads on PR #" +
    pr_number.to_string() +
    " — leaf is waiting and will be watchdog-killed in ~5 min if threads are not resolved. Resolve threads or manually advance lifecycle."
  }
  send_message_plan(
    parent.agent_id.to_string(),
    caller_id,
    body,
    @types.Status::Info,
    Some(Ok(parent)),
  )
}

///|
fn notify_parent_from_audit_on_file_pr_worker(
  registry : @registry.AgentRegistry?,
  caller_id : String,
) -> Bool {
  match registry {
    Some(reg) =>
      try {
        let agent = reg.get(caller_id)
        agent.role == @types.Role::Worker &&
        agent.parent == Some(audit_on_file_pr_internal_caller_id)
      } catch {
        _ => false
      } noraise {
        result => result
      }
    None => false
  }
}

///|
fn audit_on_file_pr_shutdown_report() -> AuditOnFilePrReport {
  {
    message: "audit worker shutdown without notify_parent report",
    status: @types.Status::Failure,
  }
}

///|
pub fn should_synthesize_tick_on_resolve(
  prior_unresolved : Int,
  after_unresolved : Int,
) -> Bool {
  prior_unresolved > after_unresolved
}

///|
fn resolve_review_thread_unresolved_counts(
  poller_state : @poller.PollerState?,
  caller_id : String,
) -> Map[Int, Int] {
  let counts : Map[Int, Int] = {}
  match poller_state {
    Some(state) =>
      state.tracked.each(fn(_pr_number, tracked) {
        if tracked.agent_id == caller_id &&
          tracked.unresolved_thread_ids_fetched {
          counts.set(tracked.pr_number, tracked.unresolved_thread_ids.length())
        }
      })
    None => ()
  }
  counts
}

///|
pub fn build_rescue_leaf_invoker(
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
  poller_state : @poller.PollerState?,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> async (RescueLeafArgs) -> @types.Response {
  async fn(rescue_args : RescueLeafArgs) -> @types.Response {
    interpret_rescue_leaf(
      rescue_args,
      project_dir,
      session,
      runner,
      capture,
      registry,
      poller_state,
      extra_mcp_servers_json~,
      shell_command~,
      listen_uds~,
      listen_tcp~,
      tcp_auth_token~,
    )
  }
}

///|
/// Server tool dispatch.
pub async fn dispatch(
  req : ToolRequest,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  bd_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout_with_stderr_on_error,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
  append_file? : (String, String) -> Bool = @sys.append_file_sync,
  read_file? : (String) -> String = @sys.read_file,
  write_file_atomic? : (String, String) -> Bool = @sys.write_file_atomic,
  delete_file? : (String) -> Bool = @sys.delete_file_sync,
  path_exists? : (String) -> Bool = @sys.path_entry_exists,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  ensure_branch_ready? : (async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  list_panes_cache? : Map[String, CachedListPanesSnapshot]? = None,
  caller_id? : String? = None,
  caller_role? : @types.Role = @types.Role::TL,
  on_resolve_review_thread? : async (Array[Int]) -> Unit = fn(_pr_numbers) {
    ()
  },
  pr_review? : Bool = true,
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
  audit_heartbeat_sec? : Int = @types.Config::default().audit_heartbeat_sec,
  audit_max_rounds? : Int = @types.Config::default().audit_max_rounds,
  goal_deliver? : async (String, @types.Status) -> Unit = goal_noop_deliver,
  goal_request_tick? : () -> Unit = goal_noop_request_tick,
  goal_nonce? : () -> String = fn() {
    @types.next_goal_nonce(@env.now().reinterpret_as_int64())
  },
  record_handoff_delivered? : (String) -> Unit = fn(_agent_id) {  },
  prepare_audit_report? : (String) -> Unit = fn(_agent_id) {  },
  record_audit_cycle_for_agent? : (String) -> Int = fn(_agent_id) { 0 },
  audit_cycle_count_for_agent? : (String) -> Int = fn(_agent_id) { 0 },
  notify_audit_started? : async (String, Int?, Int) -> Unit = async fn(
    _agent_id,
    _pr_number,
    _cycle_number,
  ) {
    @async.sleep(0)
  },
  audit_progress_reader? : (String) -> WaveStateAuditProgress? = fn(_) { None },
  audit_worker_alive? : (String) -> Bool = fn(_agent_id) { true },
  wait_for_audit_report? : async (String) -> AuditOnFilePrReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  capture_audit_on_file_pr_report? : async (String, AuditOnFilePrReport) -> Unit = async fn(
    _agent_id,
    _report,
  ) {
    @async.sleep(0)
    ()
  },
  cleanup_audit_report? : (String) -> Unit = fn(_) {  },
) -> @types.Response {
  let ensure_branch_ready = match ensure_branch_ready {
    Some(f) => f
    None =>
      (b, pb, pd) => {
        ensure_branch_ready_for_file_pr_with_capture(b, pb, pd, capture)
      }
  }
  let ensure_pr = match ensure_pr {
    Some(f) => f
    None =>
      (b, pb, pd, t, bo) => {
        ensure_pull_request_with_capture(
          b,
          pb,
          pd,
          t,
          bo,
          capture,
          poller_state~,
        )
      }
  }
  let record_verify_event = fn(
    agent_id : String,
    event : @evidence.EvidenceEvent,
  ) -> Unit {
    ignore(
      @evidence.append_agent_evidence_event(
        append_file,
        project_dir,
        agent_id,
        @env.now().reinterpret_as_int64(),
        event,
      ),
    )
  }
  match req {
    ToolRequest::Register(register_args) =>
      match registry {
        Some(reg) => {
          // Re-register must not lose stable identity metadata when a child
          // refresh comes from the parent's cwd config. Missing fields keep the
          // prior row, including agent_type; an existing leaf row refreshed as
          // Root/TL is treated as stale parent metadata. Otherwise explicit
          // register data can repair a stale registry row.
          let prior_agent : @types.Agent? = try
            reg.get(register_args.agent_id)
          catch {
            _ => None
          } noraise {
            prior => Some(prior)
          }
          let stale_parent_refresh = match prior_agent {
            Some(prior) =>
              !@types.is_supervisor_role(prior.role) &&
              @types.is_supervisor_role(register_args.role)
            None => false
          }
          let parent = match prior_agent {
            Some(prior) =>
              if stale_parent_refresh || register_args.parent is None {
                prior.parent
              } else {
                register_args.parent
              }
            None => register_args.parent
          }
          let role = match prior_agent {
            Some(prior) =>
              if stale_parent_refresh {
                prior.role
              } else {
                register_args.role
              }
            None => register_args.role
          }
          let terminal_target = match prior_agent {
            Some(prior) =>
              if stale_parent_refresh || register_args.terminal_target is None {
                prior.terminal_target
              } else {
                register_args.terminal_target
              }
            None => register_args.terminal_target
          }
          let workspace = match prior_agent {
            Some(prior) =>
              if stale_parent_refresh || register_args.workspace == "" {
                prior.workspace
              } else {
                register_args.workspace
              }
            None => register_args.workspace
          }
          let branch = match prior_agent {
            Some(prior) =>
              if stale_parent_refresh || register_args.branch == "" {
                prior.branch
              } else {
                register_args.branch
              }
            None => register_args.branch
          }
          let agent_type = match prior_agent {
            Some(prior) =>
              if stale_parent_refresh || !register_args.agent_type_explicit {
                prior.agent_type
              } else {
                register_args.agent_type
              }
            None => register_args.agent_type
          }
          let agent = @types.Agent::{
            agent_id: register_args.agent_id,
            role,
            agent_type,
            state: @types.AgentState::Active,
            parent,
            terminal_target,
            host: @types.Host::Local,
            workspace,
            branch,
            spawn_depth: register_args.spawn_depth,
          }
          let refreshed = reg.upsert(agent)
          @types.Response::ok_values({
            "status": String::to_json("registered"),
            "agent_id": String::to_json(register_args.agent_id),
            "refreshed": Bool::to_json(refreshed),
          })
        }
        None =>
          @types.Response::ok_values({ "status": String::to_json("registered") })
      }
    ToolRequest::ForkWave(fork_wave_args) => {
      match ensure_caller_can_spawn(fork_wave_args.caller_id, registry) {
        Err(e) => return @types.Response::Err(e.message())
        Ok(_) => ()
      }
      if fork_wave_args.depends_on.length() > 0 {
        match
          validate_pending_wave_deps(
            project_dir,
            registry,
            fork_wave_args.depends_on,
          ) {
          Err(e) => @types.Response::Err(e.message())
          Ok(_) => {
            let resolved_args = fork_wave_resolve_args_parent_branch(
              fork_wave_args, project_dir, capture,
            )
            let wave_id = allocate_pending_wave_id(
              project_dir,
              resolved_args.slug_prefix,
              @env.now().reinterpret_as_int64(),
              @sys.get_pid(),
            )
            let fork_ts_ms = @env.now().reinterpret_as_int64()
            let pw : PendingWave = { wave_id, args: resolved_args }
            match
              save_wave_index(
                project_dir,
                WaveIndex::new(
                  wave_id,
                  resolved_args.parent_branch,
                  fork_ts_ms,
                  [],
                ),
              ) {
              Err(e) => @types.Response::Err(e.message())
              Ok(_) =>
                if !write_pending_wave(project_dir, pw) {
                  // Rollback the wave-index reservation so a failed pending
                  // fork doesn't leave an orphan empty row visible to
                  // `choir stats` with no path to reap it.
                  ignore(@sys.rm_rf(wave_index_path(project_dir, wave_id)))
                  @types.Response::Err(
                    "failed to write pending wave: " + wave_id,
                  )
                } else {
                  fork_wave_response_with_beads_policy_warning(
                    @types.Response::ok_values({
                      "status": String::to_json("pending"),
                      "wave_id": String::to_json(wave_id),
                      "depends_on": resolved_args.depends_on.to_json(),
                    }),
                    resolved_args,
                  )
                }
            }
          }
        }
      } else {
        let fork_ts_ms = @env.now().reinterpret_as_int64()
        let wave_id = allocate_wave_id(
          project_dir,
          fork_wave_args.slug_prefix,
          fork_ts_ms,
          @sys.get_pid(),
        )
        let fork_wave_args = fork_wave_resolve_args_parent_branch(
          fork_wave_args, project_dir, capture,
        )
        match
          save_wave_index(
            project_dir,
            WaveIndex::new(wave_id, fork_wave_args.parent_branch, fork_ts_ms, []),
          ) {
          Err(e) => return @types.Response::Err(e.message())
          Ok(_) => ()
        }
        let (resp, fork_wave_args, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
          fork_wave_args,
          project_dir,
          session,
          registry,
          capture,
          git_capture,
          runner,
          extra_mcp_servers_json~,
          shell_command~,
          listen_uds~,
          listen_tcp~,
          tcp_auth_token~,
          wave_id=Some(wave_id),
        )
        // Post-spawn side effects: only run if spawn succeeded. If spawn fails,
        // the reservation remains as an empty orphan so concurrent allocation
        // still observes the wave id as consumed.
        if resp.is_ok() && spawn_plan.spawned_count > 0 {
          match
            append_spawned_agents_to_wave_index(
              project_dir,
              wave_id,
              fork_wave_args.parent_branch,
              fork_ts_ms,
              spawn_plan.agent_ids,
            ) {
            Err(e) => return @types.Response::Err(e.message())
            Ok(_) => ()
          }
          interpret_fork_wave_post_spawn(
            fork_wave_args,
            spawn_plan,
            project_dir,
            session,
            registry,
            capture~,
          )
        }
        match resp.ok_payload() {
          Some(fields) => {
            let payload = fields.to_json_map()
            payload.set("wave_id", wave_id.to_json())
            @types.Response::ok_values(payload)
          }
          None => resp
        }
      }
    }
    ToolRequest::ForkSession(session_args) => {
      let session_dir = project_dir + "/.choir/sessions/" + session_args.name
      let context_path = session_dir + "/context.json"
      let created_sec = @poller.now_sec()
      let context_json = {
          "name": session_args.name.to_json(),
          "created_sec": created_sec.to_json(),
        }
        .to_json()
        .stringify()
      if @sys.write_file_sync(context_path, context_json) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "session_dir": String::to_json(session_dir),
          "name": String::to_json(session_args.name),
        })
      } else {
        @types.Response::Err("failed to create session: " + session_args.name)
      }
    }
    ToolRequest::FilePr(file_pr_args) =>
      interpret_file_pr(
        file_pr_args,
        project_dir,
        session,
        poller_state,
        registry,
        pr_review,
        ensure_branch_ready,
        runner,
        capture,
        ensure_pr,
        caller_role~,
        record_verify_event~,
        create_dir_all~,
        write_file_atomic~,
        prepare_audit_report~,
        wait_for_audit_report~,
        cleanup_audit_report~,
        audit_heartbeat_sec~,
        audit_max_rounds~,
        record_audit_cycle_for_agent~,
        audit_cycle_count_for_agent~,
        append_file~,
        audit_worker_alive~,
        list_audit_workers=fn() {
          match registry {
            Some(reg) => {
              let entries : Array[@phase.ChildLifecycle] = []
              for agent in reg.list() {
                let agent_id = agent.agent_id.to_string()
                if reg.is_alive(agent_id).unwrap_or(false) {
                  entries.push(audit_on_file_pr_worker_entry_from_agent(agent))
                }
              }
              entries
            }
            None => []
          }
        },
        notify_audit_started~,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
        global_review_mode~,
      )
    ToolRequest::MergePr(merge_args) => {
      let resp = interpret_merge_pr(
        merge_args,
        project_dir,
        poller_state,
        mutex_registry,
        registry,
        runner,
        capture,
        append_file,
        path_exists,
        read_file~,
        write_file_atomic~,
        create_dir_all~,
        prepare_audit_report~,
        wait_for_audit_report~,
        cleanup_audit_report~,
        audit_heartbeat_sec~,
        audit_worker_alive~,
        session~,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      if resp.is_ok() {
        try_dispatch_pending_waves(
          project_dir,
          session,
          registry,
          capture,
          git_capture,
          runner,
          extra_mcp_servers_json~,
          shell_command~,
          listen_uds~,
          listen_tcp~,
          tcp_auth_token~,
        )
      }
      resp
    }
    ToolRequest::TrackPr(track_pr_args) =>
      interpret_track_pr(
        track_pr_args,
        project_dir,
        poller_state,
        @poller.now_sec(),
        registry~,
        global_review_mode~,
      )
    ToolRequest::NotifyParent(notify_args) => {
      if registry is Some(reg) {
        try {
          ignore(reg.get(notify_args.caller_id))
          match @phase.read_lifecycle(project_dir, notify_args.caller_id) {
            Some(
              { workflow: @phase.Dev(@phase.ReviewOwned(pr_number~, ..)), .. }
            )
            | Some(
              {
                workflow: @phase.Dev(
                  @phase.ExitRequestedDeferred(pr_number~, ..)
                ),
                ..,
              }
            )
            | Some(
              {
                workflow: @phase.Dev(@phase.ChangesRequested(pr_number~, ..)),
                ..,
              }
            ) => {
              let (count, thread_text) = fetch_unresolved_review_threads(
                pr_number, project_dir, capture,
              )
              if count > 0 {
                let gh_failed = thread_text == review_thread_fetch_failed_marker
                try {
                  let plan = notify_parent_blocked_parent_warn_send_plan(
                    reg,
                    project_dir,
                    session,
                    notify_args.caller_id,
                    pr_number,
                    gh_failed,
                  )
                  ignore(interpret_send_message(plan, project_dir, runner))
                } catch {
                  e =>
                    if @types.caught_error_is_agent_not_found(e) {
                      ()
                    } else {
                      raise e
                    }
                }
                if gh_failed {
                  return @types.Response::Err(
                    "notify_parent blocked: gh unavailable (could not fetch review thread state) — contact TL to manually advance lifecycle",
                  )
                }
                return @types.Response::Err(
                  "notify_parent blocked: \{count} unresolved review thread(s) on PR #\{pr_number}. Resolve all threads before notifying parent.\n\n\{thread_text}",
                )
              }
            }
            _ => ()
          }
        } catch {
          e =>
            if @types.caught_error_is_agent_not_found(e) {
              ()
            } else {
              raise e
            }
        }
      }
      if notify_parent_from_audit_on_file_pr_worker(
          registry,
          notify_args.caller_id,
        ) {
        capture_audit_on_file_pr_report(notify_args.caller_id, {
          message: notify_args.message,
          status: notify_args.status,
        })
        record_handoff_delivered(notify_args.caller_id)
        return @types.Response::ok_values({
          "status": String::to_json("notified"),
        })
      }
      let parent_resolution = match registry {
        Some(reg) =>
          Some(
            try? resolve_parent_for_notify(
              project_dir,
              session,
              reg,
              notify_args.caller_id,
            ),
          )
        None => None
      }
      match notify_parent_plan(notify_args, parent_resolution) {
        NotifyParentPlan::NoRegistry(dev_event~, response~) => {
          apply_dev_event(
            project_dir,
            notify_args.caller_id,
            dev_event,
            registry=None,
          )
          record_handoff_delivered(notify_args.caller_id)
          response
        }
        NotifyParentPlan::ParentResolveFailed(error_message~) =>
          @types.Response::Err(error_message)
        NotifyParentPlan::Deliver(
          delivery~,
          dev_event_on_success~,
          response_ok~
        ) =>
          match execute_delivery(delivery, runner, project_dir~) {
            Ok(_) => {
              apply_dev_event(
                project_dir,
                notify_args.caller_id,
                dev_event_on_success,
                registry~,
              )
              record_handoff_delivered(notify_args.caller_id)
              ignore(
                mirror_beads_note_for_agent(
                  project_dir,
                  registry,
                  notify_args.caller_id,
                  "Choir notify_parent: " + notify_args.message,
                  "notify_parent",
                  capture,
                ),
              )
              response_ok
            }
            Err(e) => @types.Response::Err(e.message())
          }
      }
    }
    ToolRequest::ReportUsage(report_args) => {
      let resp = interpret_report_usage(report_args, project_dir, registry)
      if resp.ok_field("recorded") == Some("true") {
        ignore(
          mirror_beads_note_for_agent(
            project_dir,
            registry,
            report_args.caller_id,
            beads_usage_note(
              report_args.caller_id,
              report_args.tokens_in,
              report_args.tokens_out,
              report_args.elapsed_s,
              report_args.cost_usd,
            ),
            "report_usage",
            capture,
          ),
        )
      }
      resp
    }
    ToolRequest::WaveState(wave_state_args) =>
      interpret_wave_state(
        wave_state_args,
        project_dir,
        registry,
        poller_state,
        capture~,
        audit_progress_reader~,
      )
    ToolRequest::StatusBarState(status_bar_state_args) =>
      interpret_status_bar_state(
        status_bar_state_args,
        project_dir,
        registry,
        poller_state,
        list_panes_cache~,
        list_panes_capture=async fn(list_panes_session) {
          capture_zellij_list_panes_snapshot_result(
            list_panes_session,
            capture~,
          )
        },
      )
    ToolRequest::CrystallizeSpec(crystallize_args) =>
      interpret_crystallize_spec(crystallize_args, project_dir)
    ToolRequest::WriteAuditReceipt(write_audit_args) =>
      interpret_write_audit_receipt(
        write_audit_args, project_dir, create_dir_all, write_file_atomic,
      )
    ToolRequest::SendMessage(send_args) => {
      let registry_lookup = match registry {
        Some(reg) => Some(try? reg.get(send_args.target_id))
        None => None
      }
      interpret_send_message(
        send_message_plan(
          send_args.target_id,
          send_args.sender_id,
          send_args.message,
          send_args.status,
          registry_lookup,
        ),
        project_dir,
        runner,
      )
    }
    ToolRequest::Shutdown(shutdown_args) => {
      match shutdown_args.caller_id {
        Some(caller_id) =>
          if notify_parent_from_audit_on_file_pr_worker(registry, caller_id) {
            capture_audit_on_file_pr_report(
              caller_id,
              audit_on_file_pr_shutdown_report(),
            )
          }
        _ => ()
      }
      interpret_shutdown(
        shutdown_args,
        project_dir,
        poller_state,
        registry,
        runner,
        capture=bd_capture,
      )
    }
    ToolRequest::KillAgent(kill_args) =>
      interpret_kill_agent(kill_args, registry, runner, project_dir~, capture~)
    ToolRequest::Suspend(suspend_args) =>
      interpret_suspend(suspend_args, registry, project_dir, hook_capture~)
    ToolRequest::Resume(resume_args) =>
      interpret_resume(resume_args, registry, project_dir, hook_capture~)
    ToolRequest::AgentList(args) =>
      match registry {
        Some(reg) => {
          let agents = (match args.parent_id {
            Some(id) => reg.children(id)
            None => reg.list()
          }).filter(fn(agent) {
            args.include_inactive || agent_list_includes_by_default(agent)
          })
          let agents_json : Array[Json] = []
          for agent in agents {
            let beads_issue_id = @workspace.beads_issue_id_for_agent(
              project_dir, agent,
            )
            agents_json.push(
              {
                "agent_id": agent.agent_id.0.to_json(),
                "role": agent.role.to_wire_string().to_json(),
                "agent_type": agent.agent_type.to_wire_string().to_json(),
                "beads_issue_id": optional_string_json(beads_issue_id),
                "state": agent.state.to_wire_string().to_json(),
                "parent": agent.parent.to_json(),
                "branch": agent.branch.to_json(),
                "workspace": agent.workspace.to_json(),
                "spawn_depth": agent.spawn_depth.to_json(),
              }.to_json(),
            )
          }
          @types.Response::ok_values({
            "status": "ok".to_json(),
            "agents": agents_json.to_json(),
          })
        }
        None => @types.Response::Err("no agent registry available")
      }
    ToolRequest::CancelWave(cancel_args) =>
      interpret_cancel_wave(
        cancel_args,
        caller_id,
        project_dir,
        poller_state,
        registry,
        runner,
        capture~,
      )
    // KvStore::get trims for internal gate comparisons; the kv_get MCP tool returns
    // raw bytes so agents see the exact stored value (see kv.mbt).
    ToolRequest::KvGet(key_args) => {
      let value = @sys.read_file(kv_file_path(project_dir, key_args.key))
      if value == "" {
        @types.Response::ok({ "value": "null" })
      } else {
        @types.Response::ok({ "value": value })
      }
    }
    ToolRequest::KvSet(kv_args) => {
      let path = kv_file_path(project_dir, kv_args.key)
      if write_file_atomic(path, kv_args.value) {
        @types.Response::ok({ "status": "ok" })
      } else {
        @types.Response::Err("failed to write kv file: " + path)
      }
    }
    ToolRequest::KvDelete(key_args) => {
      let path = kv_file_path(project_dir, key_args.key)
      ignore(@sys.delete_file_sync(path))
      @types.Response::ok({ "status": "ok" })
    }
    ToolRequest::KvList => handle_kv_list(project_dir, capture~)
    ToolRequest::GoalSet(goal_args) =>
      interpret_goal_set(
        goal_args,
        project_dir,
        session,
        runner,
        bd_capture,
        read_file,
        write_file_atomic,
        create_dir_all,
        @poller.now_sec(),
        goal_nonce(),
        goal_deliver~,
        goal_request_tick~,
      )
    ToolRequest::GoalClear =>
      interpret_goal_clear(project_dir, session, read_file, delete_file)
    ToolRequest::GoalStatus(goal_args) =>
      interpret_goal_status(
        goal_args,
        project_dir,
        session,
        runner,
        bd_capture,
        read_file,
        @poller.now_sec(),
      )
    ToolRequest::MutexAcquire(mutex_args) =>
      match mutex_registry {
        Some(reg) => {
          let (acquired, queue_position) = reg.acquire(
            mutex_args.name,
            mutex_args.agent_id,
            mutex_args.ttl_sec,
            @poller.now_sec(),
          )
          @types.Response::ok_values({
            "acquired": Bool::to_json(acquired),
            "queue_position": Int::to_json(queue_position),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::MutexRelease(mutex_args) =>
      match mutex_registry {
        Some(reg) => {
          let (holder, _) = reg.status(mutex_args.name)
          let was_waiting = reg.is_waiting(mutex_args.name, mutex_args.agent_id)
          let next_waiter = reg.release(
            mutex_args.name,
            mutex_args.agent_id,
            @poller.now_sec(),
          )
          let released = holder == Some(mutex_args.agent_id) || was_waiting
          @types.Response::ok_values({
            "released": Bool::to_json(released),
            "next_waiter": String::to_json(next_waiter.unwrap_or("")),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::MutexStatus(name_args) =>
      match mutex_registry {
        Some(reg) => {
          let (holder, queue) = reg.status(name_args.name)
          @types.Response::ok_values({
            "holder": String::to_json(holder.unwrap_or("")),
            "queue_length": Int::to_json(queue.length()),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::TaskList => handle_task_list(project_dir, capture=bd_capture)
    ToolRequest::TaskGet(id_args) =>
      handle_task_get(project_dir, id_args.id, capture=bd_capture)
    ToolRequest::TaskCreate(task_args) =>
      handle_task_create(project_dir, task_args, capture=bd_capture)
    ToolRequest::TaskUpdate(update_args) =>
      handle_task_update(project_dir, update_args, capture=bd_capture)
    ToolRequest::SpawnGemini(spawn_args) =>
      match ensure_caller_can_spawn(spawn_args.caller_id, registry) {
        Err(e) => @types.Response::Err(e.message())
        Ok(_) =>
          interpret_spawn_gemini(
            spawn_args,
            project_dir,
            session,
            runner,
            capture,
            extra_mcp_servers_json~,
            shell_command~,
            listen_uds~,
            listen_tcp~,
            tcp_auth_token~,
          )
      }
    ToolRequest::RescueLeaf(rescue_args) =>
      interpret_rescue_leaf(
        rescue_args,
        project_dir,
        session,
        runner,
        capture,
        registry,
        poller_state,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
    ToolRequest::SpawnRemote(spawn_args) =>
      match ensure_caller_can_spawn(spawn_args.caller_id, registry) {
        Err(e) => @types.Response::Err(e.message())
        Ok(_) =>
          interpret_spawn_remote(
            spawn_args,
            runner,
            capture,
            extra_mcp_servers_json~,
          )
      }
    ToolRequest::SpawnWorker(worker_args) =>
      interpret_spawn_worker(
        worker_args,
        project_dir,
        session,
        runner,
        capture,
        registry,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
    ToolRequest::Reply(reply_args) => {
      let id = reply_args.id
      let cancel = reply_args.cancel
      let payload = reply_args.payload
      let value = if cancel { "cancel" } else { payload }
      let key = "reply--" + id
      match validate_kv_key(key) {
        Err(e) => return @types.Response::Err(e.message())
        Ok(_) => ()
      }
      let path = kv_file_path(project_dir, key)
      if write_file_atomic(path, value) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "id": String::to_json(id),
        })
      } else {
        @types.Response::Err("failed to write reply: " + id)
      }
    }
    ToolRequest::ResolveReviewThread(resolve_args) => {
      let prior_counts = resolve_review_thread_unresolved_counts(
        poller_state,
        resolve_args.caller_id,
      )
      let result = interpret_resolve_review_thread(
        resolve_args, project_dir, capture,
      )
      if result.is_ok() {
        let after_counts : Map[Int, Int] = {}
        match poller_state {
          Some(state) =>
            for tracked in state.tracked.values() {
              if tracked.agent_id == resolve_args.caller_id &&
                tracked.unresolved_thread_ids_fetched {
                match
                  fetch_unresolved_review_thread_refs(
                    tracked.pr_number,
                    project_dir,
                    capture,
                  ) {
                  Some(refs) => {
                    after_counts.set(tracked.pr_number, refs.length())
                    state.restore({
                      ..tracked,
                      unresolved_thread_ids: refs,
                      unresolved_thread_ids_fetched: true,
                    })
                  }
                  None => ()
                }
              }
            }
          None => ()
        }
        let trigger_prs : Array[Int] = []
        prior_counts.each(fn(pr_number, prior_count) {
          match after_counts.get(pr_number) {
            Some(after_count) =>
              if should_synthesize_tick_on_resolve(prior_count, after_count) {
                trigger_prs.push(pr_number)
              }
            None => ()
          }
        })
        if trigger_prs.length() > 0 {
          on_resolve_review_thread(trigger_prs)
        }
      }
      result
    }
  }
}

///|
/// Map a caught exception to a client-facing tool error; log details when the
/// error is not a [`ChoirError`] variant (masked as `"internal error"`).
pub fn tool_response_err_from_caught(e : Error) -> @types.Response {
  if !@types.caught_error_is_choir_error(e) {
    @moontrace.warn("choir_internal_error", fields=[
      @moontrace.field("details", e.to_string()),
    ])
  }
  @types.Response::Err(@types.choir_error_message_from_caught(e))
}

///|
pub async fn handle_request(
  registry : ToolRegistry,
  req : @types.Request,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
  ensure_branch_ready? : (async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  agent_registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  list_panes_cache? : Map[String, CachedListPanesSnapshot]? = None,
  plugins_json? : String? = None,
  pr_review? : Bool = true,
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
  audit_heartbeat_sec? : Int = @types.Config::default().audit_heartbeat_sec,
  audit_max_rounds? : Int = @types.Config::default().audit_max_rounds,
  on_resolve_review_thread? : async (Array[Int]) -> Unit = fn(_pr_numbers) {
    ()
  },
  goal_deliver? : async (String, @types.Status) -> Unit = goal_noop_deliver,
  goal_request_tick? : () -> Unit = goal_noop_request_tick,
  goal_nonce? : () -> String = fn() {
    @types.next_goal_nonce(@env.now().reinterpret_as_int64())
  },
  record_handoff_delivered? : (String) -> Unit = fn(_agent_id) {  },
  prepare_audit_report? : (String) -> Unit = fn(_agent_id) {  },
  record_audit_cycle_for_agent? : (String) -> Int = fn(_agent_id) { 0 },
  audit_cycle_count_for_agent? : (String) -> Int = fn(_agent_id) { 0 },
  notify_audit_started? : async (String, Int?, Int) -> Unit = async fn(
    _agent_id,
    _pr_number,
    _cycle_number,
  ) {
    @async.sleep(0)
  },
  audit_progress_reader? : (String) -> WaveStateAuditProgress? = fn(_) { None },
  audit_worker_alive? : (String) -> Bool = fn(_agent_id) { true },
  wait_for_audit_report? : async (String) -> AuditOnFilePrReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  capture_audit_on_file_pr_report? : async (String, AuditOnFilePrReport) -> Unit = async fn(
    _agent_id,
    _report,
  ) {
    @async.sleep(0)
    ()
  },
  cleanup_audit_report? : (String) -> Unit = fn(_) {  },
  policy_enforcement_mode? : @policy.PolicyEnforcementMode = @policy.policy_enforcement_mode,
  parent_branch_lifecycle_reader? : (String, String) -> @phase.AgentLifecycle? = @phase.read_lifecycle,
  append_file? : (String, String) -> Bool = @sys.append_file_sync,
  read_file? : (String) -> String = @sys.read_file,
  write_file_atomic? : (String, String) -> Bool = @sys.write_file_atomic,
  delete_file? : (String) -> Bool = @sys.delete_file_sync,
  path_exists? : (String) -> Bool = @sys.path_entry_exists,
  hook_xdg_config_home? : String? = @exec.hook_xdg_config_home(),
  hook_home? : String = @exec.hook_home(),
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
) -> @types.Response {
  let tool_args = tool_args_from_request_args(req.args)
  let mut ran_builtin_dispatch = false
  let resp = try {
    match
      parent_branch_policy_gate_response(
        req,
        project_dir,
        capture,
        policy_enforcement_mode~,
        lifecycle_reader=parent_branch_lifecycle_reader,
      ) {
      Some(blocked) => blocked
      None => {
        ignore(registry.lookup(req.role, req.name))
        let mut hook_early : @types.Response? = None
        match
          @hooks.resolve_hook_script_path(
            project_dir,
            @hooks.HookEvent::PreToolUse.script_name(),
            hook_xdg_config_home,
            hook_home,
            path_exists,
          ) {
          Some(hook_path) => {
            let input = @hooks.HookInput::{
              event: @hooks.HookEvent::PreToolUse,
              session_id: Some(session),
              agent_id: tool_args_get(tool_args, "caller_id"),
              pr_number: None,
              pr_url: None,
              branch: None,
              parent_branch: None,
              merge_provenance: None,
              role: Some(req.role),
              tool_name: Some(req.name),
              tool_args: Some(tool_args_to_map(tool_args)),
              tool_result_status: None,
              exit_reason: None,
              suspend_reason: None,
            }
            let input_json = input.to_json_string()
            let (hook_status, output_json) = hook_capture(
              hook_path,
              input_json,
              Some(project_dir),
            )
            if hook_status < 0 {
              hook_early = Some(@types.Response::Err("hook execution failed"))
            } else if hook_status == 0 {
              match @hooks.HookResponse::from_json_string(output_json) {
                Some(res) =>
                  if !res.continue_ {
                    let msg = match res.message {
                      Some(v) => v
                      None => "hook blocked request"
                    }
                    hook_early = Some(@types.Response::Err(msg))
                  }
                None => ()
              }
            }
          }
          None => ()
        }
        match hook_early {
          Some(r) => r
          None =>
            match
              parse_tool_request(req.name, req.role, project_dir, tool_args) {
              Err(e) => @types.Response::Err(e.message())
              Ok(tool_req) => {
                let out = dispatch(
                  tool_req,
                  project_dir~,
                  session~,
                  runner~,
                  git_capture~,
                  capture~,
                  hook_capture~,
                  ensure_branch_ready~,
                  ensure_pr~,
                  extra_mcp_servers_json~,
                  shell_command~,
                  listen_uds~,
                  listen_tcp~,
                  tcp_auth_token~,
                  registry=agent_registry,
                  mutex_registry~,
                  poller_state~,
                  list_panes_cache~,
                  caller_id=tool_args_get(tool_args, "caller_id"),
                  caller_role=req.role,
                  on_resolve_review_thread~,
                  pr_review~,
                  global_review_mode~,
                  audit_heartbeat_sec~,
                  audit_max_rounds~,
                  append_file~,
                  read_file~,
                  write_file_atomic~,
                  delete_file~,
                  path_exists~,
                  create_dir_all~,
                  goal_deliver~,
                  goal_request_tick~,
                  goal_nonce~,
                  record_handoff_delivered~,
                  prepare_audit_report~,
                  record_audit_cycle_for_agent~,
                  audit_cycle_count_for_agent~,
                  notify_audit_started~,
                  audit_progress_reader~,
                  audit_worker_alive~,
                  wait_for_audit_report~,
                  capture_audit_on_file_pr_report~,
                  cleanup_audit_report~,
                )
                ran_builtin_dispatch = true
                out
              }
            }
        }
      }
    }
  } catch {
    e =>
      if @types.caught_error_is_tool_not_found(e) {
        dispatch_to_plugin(req, plugins_json)
      } else {
        tool_response_err_from_caught(e)
      }
  }
  if ran_builtin_dispatch {
    let status_tag = if resp.is_ok() { "ok" } else { "error" }
    fire_hook_async(
      @hooks.HookEvent::PostToolUse,
      {
        event: @hooks.HookEvent::PostToolUse,
        session_id: Some(session),
        agent_id: tool_args_get(tool_args, "caller_id"),
        pr_number: None,
        pr_url: None,
        branch: None,
        parent_branch: None,
        merge_provenance: None,
        role: Some(req.role),
        tool_name: Some(req.name),
        tool_args: None,
        tool_result_status: Some(status_tag),
        exit_reason: None,
        suspend_reason: None,
      },
      project_dir,
      hook_capture~,
      path_exists~,
      xdg_config_home=hook_xdg_config_home,
      home=hook_home,
    )
  }
  resp
}

///|
pub async fn fire_hook_async(
  event : @hooks.HookEvent,
  input : @hooks.HookInput,
  project_dir : String,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
  path_exists? : (String) -> Bool = @sys.path_entry_exists,
  xdg_config_home? : String? = @exec.hook_xdg_config_home(),
  home? : String = @exec.hook_home(),
) -> Unit {
  let hook_path = match
    @hooks.resolve_hook_script_path(
      project_dir,
      event.script_name(),
      xdg_config_home,
      home,
      path_exists,
    ) {
    Some(path) => path
    None => return
  }
  let input_json = input.to_json_string()
  ignore(hook_capture(hook_path, input_json, Some(project_dir)))
}

///|
fn dispatch_call_goal_gate_response(
  role : @types.Role,
  name : String,
) -> @types.Response? {
  let is_goal_tool = name == "goal_set" ||
    name == "goal_clear" ||
    name == "goal_status"
  if !is_goal_tool {
    if name.has_prefix("goal_") {
      Some(
        @types.Response::Err(@types.ChoirError::tool_not_found(name).message()),
      )
    } else {
      None
    }
  } else if role == @types.Role::Root || role == @types.Role::TL {
    None
  } else {
    Some(
      @types.Response::Err(
        @types.ChoirError::permission_denied(role.to_wire_string(), name).message(),
      ),
    )
  }
}

///|
/// CLI / test entrypoint for tool dispatch.
pub async fn dispatch_call(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  bd_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout_with_stderr_on_error,
  ensure_branch_ready? : (async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  list_panes_cache? : Map[String, CachedListPanesSnapshot]? = None,
  pr_review? : Bool = true,
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
  audit_heartbeat_sec? : Int = @types.Config::default().audit_heartbeat_sec,
  goal_deliver? : async (String, @types.Status) -> Unit = goal_noop_deliver,
  goal_request_tick? : () -> Unit = goal_noop_request_tick,
  record_handoff_delivered? : (String) -> Unit = fn(_agent_id) {  },
  prepare_audit_report? : (String) -> Unit = fn(_agent_id) {  },
  audit_progress_reader? : (String) -> WaveStateAuditProgress? = fn(_) { None },
  audit_worker_alive? : (String) -> Bool = fn(_agent_id) { true },
  wait_for_audit_report? : async (String) -> AuditOnFilePrReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  capture_audit_on_file_pr_report? : async (String, AuditOnFilePrReport) -> Unit = async fn(
    _agent_id,
    _report,
  ) {
    @async.sleep(0)
    ()
  },
  cleanup_audit_report? : (String) -> Unit = fn(_) {  },
  policy_enforcement_mode? : @policy.PolicyEnforcementMode = @policy.policy_enforcement_mode,
  parent_branch_lifecycle_reader? : (String, String) -> @phase.AgentLifecycle? = @phase.read_lifecycle,
  append_file? : (String, String) -> Bool = @sys.append_file_sync,
  read_file? : (String) -> String = @sys.read_file,
  write_file_atomic? : (String, String) -> Bool = @sys.write_file_atomic,
  delete_file? : (String) -> Bool = @sys.delete_file_sync,
  path_exists? : (String) -> Bool = @sys.path_entry_exists,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
) -> @types.Response {
  let tool_args = tool_args_from_map(call.args)
  try {
    let raw_req : @types.Request = {
      req_method: "tools/call",
      role: call.role,
      name: call.name,
      args: @types.RequestArgs::from_values(tool_args.values),
    }
    match
      parent_branch_policy_gate_response(
        raw_req,
        project_dir,
        capture,
        policy_enforcement_mode~,
        lifecycle_reader=parent_branch_lifecycle_reader,
      ) {
      Some(blocked) => blocked
      None =>
        match dispatch_call_goal_gate_response(call.role, call.name) {
          Some(blocked) => blocked
          None =>
            match
              parse_tool_request(call.name, call.role, project_dir, tool_args) {
              Err(e) => @types.Response::Err(e.message())
              Ok(tool_req) =>
                dispatch(
                  tool_req,
                  project_dir~,
                  session~,
                  runner~,
                  git_capture~,
                  capture~,
                  bd_capture~,
                  ensure_branch_ready~,
                  ensure_pr~,
                  extra_mcp_servers_json~,
                  shell_command~,
                  listen_uds~,
                  listen_tcp~,
                  tcp_auth_token~,
                  registry~,
                  mutex_registry~,
                  poller_state~,
                  list_panes_cache~,
                  caller_id=tool_args_get(tool_args, "caller_id"),
                  caller_role=call.role,
                  pr_review~,
                  global_review_mode~,
                  audit_heartbeat_sec~,
                  append_file~,
                  read_file~,
                  write_file_atomic~,
                  delete_file~,
                  path_exists~,
                  create_dir_all~,
                  goal_deliver~,
                  goal_request_tick~,
                  record_handoff_delivered~,
                  prepare_audit_report~,
                  audit_progress_reader~,
                  audit_worker_alive~,
                  wait_for_audit_report~,
                  capture_audit_on_file_pr_report~,
                  cleanup_audit_report~,
                )
            }
        }
    }
  } catch {
    e => tool_response_err_from_caught(e)
  }
}

///|
/// End-to-end TL lifecycle update: `@phase.plan_tl_event_for_scope` (read +
/// plan), then `interpret_lifecycle_effects` (persist, JSONL append when
/// applicable, optional registry sync).
pub fn apply_tl_event(
  project_dir : String,
  scope : String,
  event : @phase.TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
  let effects = @phase.plan_tl_event_for_scope(
    project_dir,
    scope,
    event,
    registry~,
  )
  @phase.interpret_lifecycle_effects(project_dir, effects, registry~)
}

///|
/// Ignores `Result` errors; on success runs the same interpret path as
/// `apply_dev_event_checked`.
pub fn apply_dev_event(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
  registry? : @registry.AgentRegistry? = None,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> Unit {
  @phase.apply_dev_event(project_dir, scope, event, registry~, review_mode~)
}

///|
pub fn current_dev_phase(
  project_dir : String,
  scope : String,
) -> @phase.DevPhase {
  @phase.current_dev_phase(project_dir, scope)
}

///|
/// Plans via `@phase.plan_dev_event_for_scope` (read + pure plan), then always
/// runs `interpret_lifecycle_effects` on success so lifecycle files and JSONL
/// match `apply_dev_event`. Pass `registry` when the agent may be registered so
/// a successful persist can refresh in-memory `Agent.state`.
pub fn apply_dev_event_checked(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Result[@phase.DevPhase, @types.ChoirError] {
  match @phase.plan_dev_event_for_scope(project_dir, scope, event) {
    Ok((phase, effects)) => {
      @phase.interpret_lifecycle_effects(project_dir, effects, registry~)
      Ok(phase)
    }
    Err(e) => Err(e)
  }
}
