///|
pub(all) enum MergeDecision {
  MergeNow(reason~ : String)
  Wait(reason~ : String)
  Blocked(reason~ : String)
  NeedsHuman(reason~ : String)
  ThreadsUnresolvedButFixed(count~ : Int, head_sha~ : String)
} derive(Debug, Eq)

///|
fn effective_task_contract(
  task_contract : @types.TaskContract?,
  bundle : @types.EvaluationBundle,
) -> @types.TaskContract? {
  match task_contract {
    Some(contract) => Some(contract)
    None => bundle.task_contract
  }
}

///|
fn ready_reason(
  required_verify : Array[String],
  review_required : Bool,
) -> String {
  let review_text = if review_required {
    "review received"
  } else {
    "review skipped by policy"
  }
  if required_verify.length() > 0 {
    "ready: " +
    review_text +
    ", CI passed/no checks, threads clear, local verify passed"
  } else {
    "ready: " + review_text + ", CI passed/no checks, threads clear"
  }
}

///|
pub fn review_required_for_branch(
  skip_copilot_on_feature_branch : Bool,
  parent_branch : String,
  default_branch : String,
) -> Bool {
  let parent = parent_branch.trim().to_owned()
  let default = default_branch.trim().to_owned()
  if !skip_copilot_on_feature_branch || parent == "" || default == "" {
    true
  } else {
    parent == default
  }
}

///|
pub fn decide_merge(
  task_contract : @types.TaskContract?,
  bundle : @types.EvaluationBundle,
  review_required? : Bool = true,
) -> MergeDecision {
  let effective_contract = effective_task_contract(task_contract, bundle)
  let required_verify = match effective_contract {
    Some(contract) => contract.verify
    None => []
  }
  let cascade = @types.evaluation_cascade(
    required_verify,
    bundle.signals,
    review_required~,
  )
  match cascade {
    Ready(_) =>
      MergeDecision::MergeNow(
        reason=ready_reason(required_verify, review_required),
      )
    Blocked(reason~) => MergeDecision::Blocked(reason~)
    NeedsHuman(reason~) => MergeDecision::NeedsHuman(reason~)
    Waiting(reason~) => MergeDecision::Wait(reason~)
  }
}

///|
pub fn MergeDecision::label(self : MergeDecision) -> String {
  match self {
    MergeNow(_) => "merge_now"
    Wait(_) => "wait"
    Blocked(_) => "blocked"
    NeedsHuman(_) => "needs_human"
    ThreadsUnresolvedButFixed(..) => "threads_unresolved_but_fixed"
  }
}

///|
pub fn MergeDecision::reason(self : MergeDecision) -> String {
  match self {
    MergeNow(reason~) => reason
    Wait(reason~) => reason
    Blocked(reason~) => reason
    NeedsHuman(reason~) => reason
    ThreadsUnresolvedButFixed(count~, head_sha~) =>
      count.to_string() +
      " unresolved inline review thread(s) remain after fixes at " +
      head_sha
  }
}
