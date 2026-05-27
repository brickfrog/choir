///|
/// Agent roles in the orchestration hierarchy.
pub(all) enum Role {
  Root
  TL
  Dev
  Worker
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn is_supervisor_role(role : Role) -> Bool {
  role == Role::Root || role == Role::TL
}

///|
pub impl Show for Role with fn output(self, logger) -> Unit {
  match self {
    Root => logger.write_string("Root")
    TL => logger.write_string("TL")
    Dev => logger.write_string("Dev")
    Worker => logger.write_string("Worker")
  }
}

///|
/// Types of agents the orchestrator can manage.
pub(all) enum AgentType {
  Claude
  Gemini
  MoonPilot
  Codex
  CursorAgent
  Unknown
} derive(Debug, Eq)

///|
pub impl Show for AgentType with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
/// Where an agent runs.
pub(all) enum Host {
  Local
  Remote(String)
} derive(Debug, Eq)

///|
pub impl Show for Host with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
/// Type-safe agent identifier. Prevents mixing with branch names, slugs, etc.
pub(all) struct AgentId(String) derive(Debug, Eq, Compare, Hash)

///|
pub impl Show for AgentId with fn output(self, logger) -> Unit {
  logger.write_string(self.0)
}

///|
pub fn AgentId::to_string(self : AgentId) -> String {
  self.0
}

///|
fn normalize_guard_path(path : String) -> String {
  let trimmed = path.trim().to_owned()
  if trimmed == "" {
    return ""
  }
  let absolute = trimmed.has_prefix("/")
  let out : Array[String] = []
  for raw_seg in trimmed.split("/") {
    let seg = raw_seg.to_owned()
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if out.length() > 0 && out[out.length() - 1] != ".." {
        ignore(out.pop())
      } else if !absolute {
        out.push("..")
      }
      continue
    }
    out.push(seg)
  }
  if absolute && out.length() == 0 {
    return "/"
  }
  let mut result = if absolute { "/" } else { "" }
  for i = 0; i < out.length(); i = i + 1 {
    if i > 0 {
      result = result + "/"
    }
    result = result + out[i]
  }
  result
}

///|
fn guard_path_child_prefix(path : String) -> String {
  if path == "/" {
    "/"
  } else if path.has_suffix("/") {
    path
  } else {
    path + "/"
  }
}

///|
pub fn path_is_project_root_or_parent(
  project_dir : String,
  path : String,
) -> Bool {
  let target = normalize_guard_path(path)
  if target == "" || target == "/" {
    return true
  }
  let root = normalize_guard_path(project_dir)
  if root == "" {
    return target == "" || target == "."
  }
  target == root || root.has_prefix(guard_path_child_prefix(target))
}

///|
pub fn is_choir_managed_worktree_path(
  project_dir : String,
  path : String,
) -> Bool {
  let target = normalize_guard_path(path)
  if path_is_project_root_or_parent(project_dir, target) {
    return false
  }
  let under_marker = target.has_prefix(".choir/worktrees/") ||
    target.contains("/.choir/worktrees/")
  if !under_marker {
    return false
  }
  let root = normalize_guard_path(project_dir)
  if root == "" {
    return true
  }
  let project_prefix = guard_path_child_prefix(root) + ".choir/worktrees/"
  target.has_prefix(project_prefix) || target.has_prefix(".choir/worktrees/")
}

///|
/// Agent lifecycle states.
pub(all) enum AgentState {
  Spawning
  Active
  Completing
  Done
  Failed
  /// Human-in-the-loop pause: poller and idle watchdog skip this agent.
  /// Only the TL may suspend; resume via the `resume` RPC transitions back to Active.
  Suspended
} derive(Debug, Eq)

///|
pub impl Show for AgentState with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
/// Mechanical Red/Green/Refactor gate for Dev leaves. Stored by the
/// orchestrator and checked by `file_pr`; wire strings live in
/// `role_agent_wire.mbt` alongside the other fixed domains.
pub(all) enum LeafTddPhase {
  Intent
  Red
  Green
  Refactor
  Done
} derive(Debug, Eq)

///|
/// Persisted TDD gate state for a leaf. Red/green checks resolve the
/// server-authoritative task-contract verify command before executing so the
/// leaf cannot substitute a different command.
pub(all) struct LeafTddState {
  phase : LeafTddPhase
} derive(Debug, Eq)

///|
pub impl Show for LeafTddPhase with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub(all) enum LifecycleTrigger {
  ChildSpawned
  ChildCompleted
  ChildFailed
  PRMerged
  AllChildrenDone
  OwnPRFiled
  PRCreated
  NotifyParentSuccess
  NotifyParentFailure
  ExitRequested
  MergeObserved
  ReviewReceived
  ReviewApproved
  FixesPushed
  ChildUpdated
  ChildRemoved
  TransportDisconnected
  TransportReconnected
  ExitMerged
  ExitDisconnected
  ExitShutdown
  FinalizeComplete
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ReviewMode {
  SinglePass
  Iterative
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn ReviewMode::to_wire_string(self : ReviewMode) -> String {
  match self {
    SinglePass => "single_pass"
    Iterative => "iterative"
  }
}

///|
pub impl Show for ReviewMode with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub fn ReviewMode::try_parse_wire(
  raw : String,
) -> Result[ReviewMode, ChoirError] {
  let normalized = raw.trim().to_lower().to_owned()
  match normalized {
    "single_pass" => Ok(SinglePass)
    "iterative" => Ok(Iterative)
    _ =>
      Err(
        ChoirError::config_error(
          "review_mode must be \"single_pass\" or \"iterative\"",
        ),
      )
  }
}

///|
pub(all) enum MergeStrategy {
  Merge
  Squash
  Rebase
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn MergeStrategy::to_wire_string(self : MergeStrategy) -> String {
  match self {
    Merge => "merge"
    Squash => "squash"
    Rebase => "rebase"
  }
}

///|
pub impl Show for MergeStrategy with fn output(self, logger) -> Unit {
  self.to_wire_string().output(logger)
}

///|
pub fn MergeStrategy::try_parse_wire(
  raw : String,
) -> Result[MergeStrategy, ChoirError] {
  let normalized = raw.trim().to_lower().to_owned()
  match normalized {
    "merge" => Ok(Merge)
    "squash" => Ok(Squash)
    "rebase" => Ok(Rebase)
    _ =>
      Err(
        ChoirError::config_error(
          "merge_strategy must be \"merge\", \"squash\", or \"rebase\"",
        ),
      )
  }
}

///|
pub(all) enum MoonVerifyTarget {
  Native
  Wasm
  WasmGc
  Js
} derive(Debug, Eq)

///|
pub fn MoonVerifyTarget::to_wire_string(self : MoonVerifyTarget) -> String {
  match self {
    Native => "native"
    Wasm => "wasm"
    WasmGc => "wasm-gc"
    Js => "js"
  }
}

///|
pub impl Show for MoonVerifyTarget with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
pub fn MoonVerifyTarget::try_parse_wire(
  raw : String,
) -> Result[MoonVerifyTarget, ChoirError] {
  let normalized = raw.trim().to_lower().to_owned()
  match normalized {
    "native" => Ok(Native)
    "wasm" => Ok(Wasm)
    "wasm-gc" => Ok(WasmGc)
    "js" => Ok(Js)
    _ =>
      Err(
        ChoirError::config_error(
          "moon_verify_target must be \"native\", \"wasm\", \"wasm-gc\", or \"js\"",
        ),
      )
  }
}

///|
priv struct MoonVerifyShellPart {
  segment : String
  separator : String
}

///|
priv struct MoonVerifyInvocation {
  has_explicit_target : Bool
  explicit_target_native : Bool
}

///|
fn moon_verify_segment_space(c : UInt16) -> Bool {
  c == ' ' || c == '\t' || c == '\r'
}

///|
fn moon_verify_shell_separator_end(command : String, index : Int) -> Int {
  let c = command[index]
  if c == '|' && index + 1 < command.length() && command[index + 1] == '&' {
    index + 2
  } else if (c == '&' || c == '|') &&
    index + 1 < command.length() &&
    command[index + 1] == c {
    index + 2
  } else {
    index + 1
  }
}

///|
fn moon_verify_ampersand_separator_at(command : String, index : Int) -> Bool {
  if index + 1 < command.length() && command[index + 1] == '&' {
    return true
  }
  if index > 0 {
    let prev = command[index - 1]
    if prev == '>' || prev == '<' || prev == '|' {
      return false
    }
  }
  if index + 1 < command.length() && command[index + 1] == '>' {
    return false
  }
  let prev_boundary = index == 0 ||
    moon_verify_segment_space(command[index - 1])
  let next_boundary = index + 1 == command.length() ||
    moon_verify_segment_space(command[index + 1]) ||
    command[index + 1] == '\n' ||
    command[index + 1] == ';'
  prev_boundary && next_boundary
}

///|
fn moon_verify_shell_separator_at(command : String, index : Int) -> Bool {
  let c = command[index]
  if c == '&' {
    moon_verify_ampersand_separator_at(command, index)
  } else {
    c == '\n' || c == ';' || c == '|'
  }
}

///|
fn moon_verify_shell_parts(command : String) -> Array[MoonVerifyShellPart] {
  let parts : Array[MoonVerifyShellPart] = []
  let mut in_double = false
  let mut in_single = false
  let mut segment_start = 0
  let mut i = 0
  while i < command.length() {
    let c = command[i]
    if c == '"' && !in_single {
      in_double = !in_double
    } else if c == '\'' && !in_double {
      in_single = !in_single
    } else if !in_single && !in_double {
      if moon_verify_shell_separator_at(command, i) {
        let separator_end = moon_verify_shell_separator_end(command, i)
        parts.push({
          segment: command[segment_start:i].to_owned(),
          separator: command[i:separator_end].to_owned(),
        })
        i = separator_end
        segment_start = i
        continue
      }
    }
    i = i + 1
  }
  parts.push({ segment: command[segment_start:].to_owned(), separator: "" })
  parts
}

///|
fn moon_verify_segment_tokens(segment : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut token = ""
  let mut token_active = false
  let mut in_double = false
  let mut in_single = false
  let mut i = 0
  while i < segment.length() {
    let c = segment[i]
    if c == '"' && !in_single {
      in_double = !in_double
      token_active = true
    } else if c == '\'' && !in_double {
      in_single = !in_single
      token_active = true
    } else if !in_single && !in_double && moon_verify_segment_space(c) {
      if token_active {
        tokens.push(token)
        token = ""
        token_active = false
      }
    } else {
      token = token + segment[i:i + 1].to_owned()
      token_active = true
    }
    i = i + 1
  }
  if token_active {
    tokens.push(token)
  }
  tokens
}

///|
fn moon_verify_env_name_char(c : UInt16, first : Bool) -> Bool {
  let alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
  let digit = c >= '0' && c <= '9'
  alpha || (!first && digit)
}

///|
fn moon_verify_env_name_valid(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  let mut i = 0
  while i < name.length() {
    if !moon_verify_env_name_char(name[i], i == 0) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn moon_verify_env_assignment_token(token : String) -> Bool {
  match token.split_once("=") {
    Some((name, _)) => moon_verify_env_name_valid(name.to_owned())
    None => false
  }
}

///|
fn moon_verify_global_flag_takes_value(flag : String) -> Bool {
  flag == "-C" ||
  flag == "--directory" ||
  flag == "--target" ||
  flag == "--source-dir" ||
  flag == "--target-dir" ||
  flag == "--build-dir" ||
  flag == "--config"
}

///|
fn moon_verify_target_word_kind(raw : String) -> (Bool, Bool) {
  match MoonVerifyTarget::try_parse_wire(raw) {
    Ok(Native) => (true, true)
    Ok(_) | Err(_) => (true, false)
  }
}

///|
fn moon_verify_explicit_target_kind(tokens : Array[String]) -> (Bool, Bool) {
  let mut i = 0
  while i < tokens.length() {
    let word = tokens[i]
    if word.has_prefix("--target=") {
      return moon_verify_target_word_kind(
        word["--target=".length():].to_owned(),
      )
    }
    if word == "--target" {
      if i + 1 < tokens.length() {
        return moon_verify_target_word_kind(tokens[i + 1])
      }
      return (true, false)
    }
    i = i + 1
  }
  (false, false)
}

///|
fn moon_verify_probe_segment(segment : String) -> MoonVerifyInvocation? {
  let tokens = moon_verify_segment_tokens(segment)
  let mut i = 0
  while i < tokens.length() && moon_verify_env_assignment_token(tokens[i]) {
    i = i + 1
  }
  if i >= tokens.length() || tokens[i] != "moon" {
    return None
  }
  i = i + 1
  while i < tokens.length() && tokens[i].has_prefix("-") {
    let flag = tokens[i]
    i = i + 1
    if moon_verify_global_flag_takes_value(flag) &&
      !flag.contains("=") &&
      i < tokens.length() {
      i = i + 1
    }
  }
  if i >= tokens.length() || (tokens[i] != "check" && tokens[i] != "test") {
    return None
  }
  let (has_explicit_target, explicit_target_native) = moon_verify_explicit_target_kind(
    tokens,
  )
  Some({ has_explicit_target, explicit_target_native })
}

///|
fn moon_verify_normalize_segment(
  segment : String,
  target : MoonVerifyTarget,
) -> String {
  let mut start = 0
  while start < segment.length() && moon_verify_segment_space(segment[start]) {
    start = start + 1
  }
  let mut end = segment.length()
  while end > start && moon_verify_segment_space(segment[end - 1]) {
    end = end - 1
  }
  let leading = segment[:start].to_owned()
  let body = segment[start:end].to_owned()
  let trailing = segment[end:].to_owned()
  match moon_verify_probe_segment(body) {
    Some(invocation) =>
      if !invocation.has_explicit_target {
        return leading +
          body +
          " --target " +
          target.to_wire_string() +
          trailing
      }
    None => ()
  }
  segment
}

///|
pub fn moon_verify_normalize_command(
  command : String,
  target : MoonVerifyTarget,
) -> String {
  let mut normalized = ""
  for part in moon_verify_shell_parts(command) {
    normalized = normalized +
      moon_verify_normalize_segment(part.segment, target) +
      part.separator
  }
  normalized
}

///|
fn moon_verify_segment_requires_non_native_target(segment : String) -> Bool {
  match moon_verify_probe_segment(segment) {
    Some(invocation) =>
      invocation.has_explicit_target && !invocation.explicit_target_native
    None => false
  }
}

///|
pub fn moon_verify_normalize_commands(
  commands : Array[String],
  target : MoonVerifyTarget,
) -> Array[String] {
  let normalized : Array[String] = []
  for command in commands {
    normalized.push(moon_verify_normalize_command(command, target))
  }
  normalized
}

///|
pub fn task_contract_with_normalized_verify(
  task_contract : TaskContract?,
  target : MoonVerifyTarget,
) -> TaskContract? {
  match task_contract {
    Some(contract) =>
      Some({
        ..contract,
        verify: moon_verify_normalize_commands(contract.verify, target),
        verify_satisfied_by_ci: contract.verify_satisfied_by_ci &&
        target == MoonVerifyTarget::Native,
      })
    None => None
  }
}

///|
pub fn moon_verify_commands_allow_native_ci_satisfaction(
  commands : Array[String],
) -> Bool {
  for command in commands {
    for part in moon_verify_shell_parts(command) {
      if moon_verify_segment_requires_non_native_target(part.segment) {
        return false
      }
    }
  }
  true
}

///|
pub fn LifecycleTrigger::to_wire_string(self : LifecycleTrigger) -> String {
  match self {
    ChildSpawned => "ChildSpawned"
    ChildCompleted => "ChildCompleted"
    ChildFailed => "ChildFailed"
    PRMerged => "PRMerged"
    AllChildrenDone => "AllChildrenDone"
    OwnPRFiled => "OwnPRFiled"
    PRCreated => "PRCreated"
    NotifyParentSuccess => "NotifyParentSuccess"
    NotifyParentFailure => "NotifyParentFailure"
    ExitRequested => "ExitRequested"
    MergeObserved => "MergeObserved"
    ReviewReceived => "ReviewReceived"
    ReviewApproved => "ReviewApproved"
    FixesPushed => "FixesPushed"
    ChildUpdated => "ChildUpdated"
    ChildRemoved => "ChildRemoved"
    TransportDisconnected => "TransportDisconnected"
    TransportReconnected => "TransportReconnected"
    ExitMerged => "ExitMerged"
    ExitDisconnected => "ExitDisconnected"
    ExitShutdown => "ExitShutdown"
    FinalizeComplete => "FinalizeComplete"
  }
}

///|
pub(all) enum ExitReason {
  Merged
  Disconnected
  Shutdown
} derive(Debug, Eq)

///|
pub impl Show for ExitReason with fn output(self, logger) -> Unit {
  match self {
    Merged => logger.write_string("Merged")
    Disconnected => logger.write_string("Disconnected")
    Shutdown => logger.write_string("Shutdown")
  }
}

///|
pub fn ExitReason::lifecycle_trigger(self : ExitReason) -> LifecycleTrigger {
  match self {
    Merged => ExitMerged
    Disconnected => ExitDisconnected
    Shutdown => ExitShutdown
  }
}

///|
/// Zellij target type for agent panes.
pub(all) enum TargetKind {
  ZellijTab
  ZellijPane
} derive(Debug, Eq)

///|
pub impl Show for TargetKind with fn output(self, logger) -> Unit {
  match self {
    ZellijTab => logger.write_string("ZellijTab")
    ZellijPane => logger.write_string("ZellijPane")
  }
}

///|
/// A typed terminal target — session + pane/tab identifier.
pub(all) struct LocalTarget {
  kind : TargetKind
  session : String
  name : String
} derive(Debug, Eq)

///|
pub impl Show for LocalTarget with fn output(self, logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
pub fn LocalTarget::to_string(self : LocalTarget) -> String {
  let prefix = match self.kind {
    ZellijTab => "zellij-tab:"
    ZellijPane => "zellij-pane:"
  }
  prefix + self.session + ":" + self.name
}

///|
pub fn LocalTarget::parse(target : String) -> LocalTarget? {
  let try_parse = fn(prefix : String, kind : TargetKind) -> LocalTarget? {
    match target.strip_prefix(prefix) {
      None => None
      Some(rest) =>
        match rest.split_once(":") {
          Some((session, name)) if session != "" && name != "" =>
            Some({ kind, session: session.to_owned(), name: name.to_owned() })
          _ => None
        }
    }
  }
  match try_parse("zellij-tab:", ZellijTab) {
    Some(lt) => Some(lt)
    None => try_parse("zellij-pane:", ZellijPane)
  }
}

///|
/// A managed agent in the orchestration tree.
pub(all) struct Agent {
  agent_id : AgentId
  role : Role
  agent_type : AgentType
  parent : String?
  workspace : String
  branch : String
  terminal_target : LocalTarget?
  host : Host
  state : AgentState
  /// Sub-TL nesting depth: 0 for root supervisor, 1 for a sub-TL under one TL level.
  spawn_depth : Int
} derive(Debug)

///|
/// Message status tag.
pub(all) enum Status {
  Success
  Failure
  Info
} derive(Debug, Eq)

///|
pub impl Show for Status with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
/// A message between agents.
pub(all) struct Message {
  sender : String
  recipient : String
  content : String
  status : Status?
} derive(Debug)

///|
/// A git worktree workspace.
pub(all) struct Workspace {
  path : String
  branch : String
  parent_branch : String
  host : Host
} derive(Debug)

///|
/// Isolation mode for agent workspaces.
pub(all) enum IsolationMode {
  Worktree
  Inline
  InlineDedicatedTab
  Standalone
} derive(Debug, Eq)

///|
pub impl Show for IsolationMode with fn output(self, logger) -> Unit {
  match self {
    InlineDedicatedTab => logger.write_string("inline_dedicated_tab")
    _ => self.to_repr().output(logger)
  }
}

///|
/// PR tracking state.
pub(all) enum PRStatus {
  Open
  Merged
  Closed
} derive(Debug, Eq)

///|
/// CI check status.
pub(all) enum CIStatus {
  Pending
  Passing
  Failing
} derive(Debug, Eq)

///|
/// A tracked pull request.
pub(all) struct PR {
  number : Int
  branch : String
  base : String
  status : PRStatus
  ci_status : CIStatus
} derive(Debug)

///|
/// A coordination lock.
pub(all) struct MutexLock {
  name : String
  holder : String
  acquired : Int64
  ttl : Int64
} derive(Debug)

///|
pub(all) enum TaskStatus {
  Todo
  InProgress
  Done
} derive(Debug, Eq)

///|
/// Canonical task intent passed through spawn/planning flows.
pub(all) struct TaskContract {
  goal : String
  scope : Array[String]
  acceptance_checks : Array[String]
  constraints : Array[String]
  non_goals : Array[String]
  beads_issue_id : String?
  review_context : String?
  verify : Array[String]
  verify_satisfied_by_ci : Bool
} derive(Debug, Eq, ToJson)

///|
pub impl FromJson for TaskContract with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let goal : String = match fields.get("goal") {
        Some(value) => @json.from_json(value, path=path.add_key("goal"))
        None => ""
      }
      let scope : Array[String] = match fields.get("scope") {
        Some(value) => @json.from_json(value, path=path.add_key("scope"))
        None => []
      }
      let acceptance_checks : Array[String] = match
        fields.get("acceptance_checks") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("acceptance_checks"))
        None => []
      }
      let constraints : Array[String] = match fields.get("constraints") {
        Some(value) => @json.from_json(value, path=path.add_key("constraints"))
        None => []
      }
      let non_goals : Array[String] = match fields.get("non_goals") {
        Some(value) => @json.from_json(value, path=path.add_key("non_goals"))
        None => []
      }
      let beads_issue_id : String? = match fields.get("beads_issue_id") {
        None | Some(Null) => None
        Some(value) =>
          Some(@json.from_json(value, path=path.add_key("beads_issue_id")))
      }
      let review_context : String? = match fields.get("review_context") {
        None | Some(Null) => None
        Some(value) =>
          Some(@json.from_json(value, path=path.add_key("review_context")))
      }
      let verify : Array[String] = match fields.get("verify") {
        Some(value) => @json.from_json(value, path=path.add_key("verify"))
        None => []
      }
      let verify_satisfied_by_ci : Bool = match
        fields.get("verify_satisfied_by_ci") {
        None | Some(Null) => true
        Some(value) =>
          @json.from_json(value, path=path.add_key("verify_satisfied_by_ci"))
      }
      {
        goal,
        scope,
        acceptance_checks,
        constraints,
        non_goals,
        beads_issue_id,
        review_context,
        verify,
        verify_satisfied_by_ci,
      }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "TaskContract::from_json: expected object"),
      )
  }
}

///|
pub fn task_contract_verify_satisfied_by_native_ci(
  contract : TaskContract,
) -> Bool {
  contract.verify_satisfied_by_ci &&
  moon_verify_commands_allow_native_ci_satisfaction(contract.verify)
}

///|
/// Normalized review rollup used by evaluation helpers.
pub(all) enum EvaluationReviewState {
  Unknown
  None_
  Commented
  Approved
  ChangesRequested
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Normalized CI rollup used by evaluation helpers.
pub(all) enum EvaluationCiRollup {
  Unknown
  NoChecks
  InProgress
  Success
  Failure
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum VerifyStatus {
  Passed
  Failed
  NotObserved
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct VerifyCheckResult {
  name : String
  status : VerifyStatus
  details : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Typed evidence items used by advisory evaluation.
pub(all) enum EvaluationSignal {
  Review(state~ : EvaluationReviewState, body~ : String)
  Ci(status~ : EvaluationCiRollup)
  ThreadsObserved(count~ : Int)
  ThreadsUnobserved
  CopilotIssueCommentObserved
  CopilotIssueCommentUnobserved
  Verify(result~ : VerifyCheckResult)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Grouped evidence for one advisory evaluation pass.
pub(all) struct EvaluationBundle {
  task_contract : TaskContract?
  signals : Array[EvaluationSignal]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum EvaluationVerdict {
  Ready
  Blocked(reason~ : String)
  NeedsHuman(reason~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for EvaluationVerdict with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub(all) struct EvaluationResult {
  verdict : EvaluationVerdict
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn TaskContract::empty() -> TaskContract {
  {
    goal: "",
    scope: [],
    acceptance_checks: [],
    constraints: [],
    non_goals: [],
    beads_issue_id: None,
    review_context: None,
    verify: [],
    verify_satisfied_by_ci: true,
  }
}

///|
pub fn TaskContract::is_empty(self : TaskContract) -> Bool {
  self.goal.trim().to_owned() == "" &&
  self.scope.length() == 0 &&
  self.acceptance_checks.length() == 0 &&
  self.constraints.length() == 0 &&
  self.non_goals.length() == 0 &&
  self.beads_issue_id is None &&
  self.review_context is None &&
  self.verify.length() == 0 &&
  self.verify_satisfied_by_ci
}

///|
pub fn TaskContract::to_json_string(self : TaskContract) -> String {
  self.to_json().stringify()
}

///|
pub fn evaluation_latest_review_state(
  signals : Array[EvaluationSignal],
) -> EvaluationReviewState {
  let mut latest = EvaluationReviewState::Unknown
  for signal in signals {
    match signal {
      EvaluationSignal::Review(state~, ..) => latest = state
      _ => ()
    }
  }
  latest
}

///|
pub fn evaluation_latest_ci_rollup(
  signals : Array[EvaluationSignal],
) -> EvaluationCiRollup {
  let mut latest = EvaluationCiRollup::Unknown
  for signal in signals {
    match signal {
      EvaluationSignal::Ci(status~) => latest = status
      _ => ()
    }
  }
  latest
}

///|
pub fn evaluation_latest_threads(signals : Array[EvaluationSignal]) -> Int? {
  let mut latest : Int? = None
  for signal in signals {
    match signal {
      EvaluationSignal::ThreadsObserved(count~) => latest = Some(count)
      EvaluationSignal::ThreadsUnobserved => latest = None
      _ => ()
    }
  }
  latest
}

///|
pub fn evaluation_copilot_seen(signals : Array[EvaluationSignal]) -> Bool {
  let mut seen = false
  for signal in signals {
    match signal {
      EvaluationSignal::CopilotIssueCommentObserved => seen = true
      EvaluationSignal::CopilotIssueCommentUnobserved => seen = false
      _ => ()
    }
  }
  seen
}

///|
pub fn evaluation_verify_results_for_required(
  required : Array[String],
  signals : Array[EvaluationSignal],
) -> Array[VerifyCheckResult] {
  let observed : Map[String, VerifyCheckResult] = {}
  for signal in signals {
    match signal {
      EvaluationSignal::Verify(result~) => observed.set(result.name, result)
      _ => ()
    }
  }
  let out : Array[VerifyCheckResult] = []
  for name in required {
    match observed.get(name) {
      Some(found) => out.push(found)
      None => out.push({ name, status: VerifyStatus::NotObserved, details: "" })
    }
  }
  out
}

///|
pub fn evaluation_missing_verify_names(
  results : Array[VerifyCheckResult],
) -> Array[String] {
  let out : Array[String] = []
  for result in results {
    if result.status == VerifyStatus::NotObserved {
      out.push(result.name)
    }
  }
  out
}

///|
pub fn evaluation_failed_verify_names(
  results : Array[VerifyCheckResult],
) -> Array[String] {
  let out : Array[String] = []
  for result in results {
    if result.status == VerifyStatus::Failed {
      out.push(result.name)
    }
  }
  out
}

///|
/// Shared cascade verdict used by both advisory_evaluation_result and
/// decide_merge (in policy). Single source of truth for the evaluation
/// order and blocking semantics.
pub(all) enum CascadeVerdict {
  Ready(reason~ : String)
  Blocked(reason~ : String)
  NeedsHuman(reason~ : String)
  Waiting(reason~ : String)
} derive(Debug, Eq)

///|
/// Canonical evaluation cascade. All readiness/merge decisions must go
/// through this function so the ordering and blocking rules stay in sync.
pub fn evaluation_cascade(
  verify_required : Array[String],
  signals : Array[EvaluationSignal],
) -> CascadeVerdict {
  let review = evaluation_latest_review_state(signals)
  let ci = evaluation_latest_ci_rollup(signals)
  let threads = evaluation_latest_threads(signals)
  let copilot_seen = evaluation_copilot_seen(signals)
  let verify_results = evaluation_verify_results_for_required(
    verify_required, signals,
  )
  let failed_verify = evaluation_failed_verify_names(verify_results)
  if failed_verify.length() > 0 {
    return CascadeVerdict::Blocked(
      reason="local verify failed: " + failed_verify.join(", "),
    )
  }
  if review == EvaluationReviewState::ChangesRequested {
    return CascadeVerdict::Blocked(reason="review changes requested")
  }
  match threads {
    Some(count) =>
      if count > 0 {
        return CascadeVerdict::Blocked(
          reason=count.to_string() + " unresolved inline review thread(s)",
        )
      }
    None => ()
  }
  if ci == EvaluationCiRollup::Failure {
    return CascadeVerdict::Blocked(reason="CI failing")
  }
  // AUDIT: Blocked-vs-NeedsHuman asymmetry is intentional. `verify_required`
  // is server-authoritative (sourced from bundle.task_contract.verify at
  // dispatch time); agents under evaluation cannot mutate it. "Failed"
  // means we observed the run and it failed -> hard block. "Missing" means
  // we never observed a run -> human confirms nothing silently skipped.
  // This is NOT an LLM-downgrade vector.
  let missing_verify = evaluation_missing_verify_names(verify_results)
  if missing_verify.length() > 0 {
    return CascadeVerdict::NeedsHuman(
      reason="local verify not observed: " + missing_verify.join(", "),
    )
  }
  if threads is None {
    return CascadeVerdict::NeedsHuman(reason="review threads not fetched")
  }
  if review == EvaluationReviewState::Unknown ||
    review == EvaluationReviewState::None_ {
    return CascadeVerdict::Waiting(reason="waiting for review")
  }
  if review == EvaluationReviewState::Commented && !copilot_seen {
    return CascadeVerdict::Waiting(reason="waiting for Copilot comments")
  }
  if ci == EvaluationCiRollup::Unknown || ci == EvaluationCiRollup::InProgress {
    return CascadeVerdict::Waiting(reason="waiting for CI to finish")
  }
  let ready_reason = if copilot_seen {
    "ready: no tracked blockers; Copilot issue comment observed"
  } else {
    "ready: no tracked blockers; Copilot issue comment not observed"
  }
  CascadeVerdict::Ready(reason=ready_reason)
}

///|
pub fn advisory_evaluation_result(
  bundle : EvaluationBundle,
) -> EvaluationResult {
  let verify_required = match bundle.task_contract {
    Some(contract) => contract.verify
    None => []
  }
  let cascade = evaluation_cascade(verify_required, bundle.signals)
  match cascade {
    Ready(reason~) => { verdict: EvaluationVerdict::Ready, summary: reason }
    Blocked(reason~) =>
      { verdict: EvaluationVerdict::Blocked(reason~), summary: reason }
    NeedsHuman(reason~) =>
      { verdict: EvaluationVerdict::NeedsHuman(reason~), summary: reason }
    Waiting(reason~) =>
      { verdict: EvaluationVerdict::NeedsHuman(reason~), summary: reason }
  }
}

///|
pub fn EvaluationVerdict::label(self : EvaluationVerdict) -> String {
  match self {
    Ready => "ready"
    Blocked(_) => "blocked"
    NeedsHuman(_) => "needs_human"
  }
}

///|
pub impl Show for LifecycleTrigger with fn output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}
