///|
pub let worker_no_handoff_tail_max_chars : Int = 2048

///|
pub let worker_no_handoff_tail_max_lines : Int = 40

///|
pub(all) enum WorkerNoHandoffDecision {
  DoNothing
  EmitStalled
} derive(Debug, Eq)

///|
pub impl Show for WorkerNoHandoffDecision with fn output(self, logger) -> Unit {
  let label = match self {
    DoNothing => "DoNothing"
    EmitStalled => "EmitStalled"
  }
  logger.write_string(label)
}

///|
pub fn worker_no_handoff_decision(
  role : @types.Role,
  idle_sec : Int64,
  handoff_delivered : Bool,
  stalled_emitted : Bool,
  idle_threshold_sec : Int64,
) -> WorkerNoHandoffDecision {
  if role != @types.Role::Worker ||
    handoff_delivered ||
    stalled_emitted ||
    idle_threshold_sec <= 0L {
    return DoNothing
  }
  if idle_sec >= idle_threshold_sec {
    EmitStalled
  } else {
    DoNothing
  }
}

///|
fn lifecycle_is_review_owned(lifecycle : @phase.WorkflowState) -> Bool {
  match lifecycle {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(..)) => true
    _ => false
  }
}

///|
fn lifecycle_is_dev_working(lifecycle : @phase.WorkflowState) -> Bool {
  match lifecycle {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::Working) => true
    _ => false
  }
}

///|
fn leaf_tdd_done(phase : @types.LeafTddPhase?) -> Bool {
  match phase {
    Some(@types.LeafTddPhase::Done) => true
    _ => false
  }
}

///|
pub fn leaf_pre_tdd_stall_decision(
  role : @types.Role,
  lifecycle : @phase.WorkflowState,
  tdd_phase : @types.LeafTddPhase?,
  idle_sec : Int64,
  handoff_delivered : Bool,
  stalled_emitted : Bool,
  idle_threshold_sec : Int64,
) -> WorkerNoHandoffDecision {
  if role != @types.Role::Dev ||
    !lifecycle_is_dev_working(lifecycle) ||
    leaf_tdd_done(tdd_phase) ||
    handoff_delivered ||
    stalled_emitted ||
    idle_threshold_sec <= 0L ||
    idle_sec < idle_threshold_sec {
    return DoNothing
  }
  EmitStalled
}

///|
pub fn leaf_no_handoff_decision(
  role : @types.Role,
  lifecycle : @phase.WorkflowState,
  gate_ready : Bool,
  idle_sec : Int64,
  handoff_delivered : Bool,
  stalled_emitted : Bool,
  idle_threshold_sec : Int64,
) -> WorkerNoHandoffDecision {
  if role != @types.Role::Dev ||
    !lifecycle_is_review_owned(lifecycle) ||
    !gate_ready ||
    handoff_delivered ||
    stalled_emitted ||
    idle_threshold_sec <= 0L ||
    idle_sec < idle_threshold_sec {
    return DoNothing
  }
  EmitStalled
}

///|
pub fn worker_no_handoff_pane_tail(screen : String) -> String {
  let lines : Array[String] = []
  for line in screen.split("\n") {
    lines.push(line.to_owned())
  }
  let start = if lines.length() > worker_no_handoff_tail_max_lines {
    lines.length() - worker_no_handoff_tail_max_lines
  } else {
    0
  }
  let selected : Array[String] = []
  for i = start; i < lines.length(); i = i + 1 {
    selected.push(lines[i])
  }
  let by_lines = selected.join("\n")
  if by_lines.length() <= worker_no_handoff_tail_max_chars {
    by_lines
  } else {
    by_lines[by_lines.length() - worker_no_handoff_tail_max_chars:].to_owned()
  }
}

///|
fn worker_no_handoff_tail_or_placeholder(screen : String) -> String {
  let tail = worker_no_handoff_pane_tail(screen).trim().to_owned()
  if tail == "" {
    "(pane tail unavailable)"
  } else {
    tail
  }
}

///|
fn leaf_tdd_phase_label(phase : @types.LeafTddPhase?) -> String {
  match phase {
    Some(value) => value.to_wire_string()
    None => "not_started"
  }
}

///|
pub fn leaf_pre_tdd_stalled_parent_message(
  slug : String,
  idle_sec : Int64,
  tdd_phase : @types.LeafTddPhase?,
  pane_tail : String,
) -> String {
  "[LEAF STALLED BEFORE TDD/file_pr] " +
  slug +
  " idle " +
  idle_sec.to_string() +
  "s while TDD phase is " +
  leaf_tdd_phase_label(tdd_phase) +
  ". Leaf must drive `tdd_intent` -> `tdd_red_check` -> `tdd_green_check` -> `file_pr`, or report a blocker with `notify_parent`. Pane tail:\n" +
  worker_no_handoff_tail_or_placeholder(pane_tail)
}

///|
pub fn leaf_stalled_no_handoff_parent_message(
  slug : String,
  idle_sec : Int64,
  pane_tail : String,
) -> String {
  "[LEAF STALLED AFTER FIX-PUSH] " +
  slug +
  " idle " +
  idle_sec.to_string() +
  "s after fix-push merge gate readiness and did not call notify_parent. Pane tail:\n" +
  worker_no_handoff_tail_or_placeholder(pane_tail)
}

///|
pub fn worker_stalled_no_handoff_message(
  worker_slug : String,
  idle_sec : Int64,
  screen : String,
) -> String {
  "[WORKER STALLED — no handoff] " +
  worker_slug +
  " idle " +
  idle_sec.to_string() +
  "s after producing output and never called notify_parent. Pane tail:\n" +
  worker_no_handoff_tail_or_placeholder(screen)
}

///|
pub fn worker_exited_without_notify_message(
  worker_slug : String,
  screen : String,
) -> String {
  "[WORKER EXITED WITHOUT NOTIFY] " +
  worker_slug +
  " exited/killed without calling notify_parent. Last pane:\n" +
  worker_no_handoff_tail_or_placeholder(screen)
}
