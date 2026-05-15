///|
pub let worker_no_handoff_prod_text : String = "You appear finished but have not called `notify_parent` — your printed output is not the handoff. Call `notify_parent --status success|failure '<your full report>'` now, then `shutdown`."

///|
pub let worker_no_handoff_tail_max_chars : Int = 2048

///|
pub let worker_no_handoff_tail_max_lines : Int = 40

///|
pub(all) enum WorkerNoHandoffDecision {
  DoNothing
  Prod
  EmitStalled
} derive(Debug, Eq)

///|
pub impl Show for WorkerNoHandoffDecision with output(self, logger) -> Unit {
  let label = match self {
    DoNothing => "DoNothing"
    Prod => "Prod"
    EmitStalled => "EmitStalled"
  }
  logger.write_string(label)
}

///|
pub fn worker_no_handoff_decision(
  role : @types.Role,
  idle_sec : Int64,
  handoff_delivered : Bool,
  prodded : Bool,
  stalled_emitted : Bool,
  prod_sec : Int64,
  escalate_sec : Int64,
) -> WorkerNoHandoffDecision {
  if role != @types.Role::Worker || handoff_delivered || prod_sec <= 0L {
    return DoNothing
  }
  if !prodded {
    if idle_sec >= prod_sec {
      Prod
    } else {
      DoNothing
    }
  } else if escalate_sec > 0L && !stalled_emitted && idle_sec >= escalate_sec {
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
pub fn leaf_no_handoff_decision(
  role : @types.Role,
  lifecycle : @phase.WorkflowState,
  gate_ready : Bool,
  idle_sec : Int64,
  handoff_delivered : Bool,
  prodded : Bool,
  stalled_emitted : Bool,
  prod_sec : Int64,
  escalate_sec : Int64,
) -> WorkerNoHandoffDecision {
  if role != @types.Role::Dev ||
    !lifecycle_is_review_owned(lifecycle) ||
    !gate_ready ||
    handoff_delivered ||
    prod_sec <= 0L ||
    idle_sec < prod_sec {
    return DoNothing
  }
  if !prodded {
    Prod
  } else if !stalled_emitted && idle_sec >= prod_sec + escalate_sec {
    EmitStalled
  } else {
    DoNothing
  }
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
pub fn leaf_stalled_no_handoff_prod_message(slug : String) -> String {
  "[LEAF POST-FIX-PUSH HANDOFF] " +
  slug +
  ": You pushed fixes and the merge gate is ready. Call `notify_parent --status success` once with a short summary, then stand down. Do not idle waiting for more events."
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
