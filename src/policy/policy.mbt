///|
pub(all) enum MergeDecision {
  MergeNow(reason~ : String)
  Wait(reason~ : String)
  Blocked(reason~ : String)
  NeedsHuman(reason~ : String)
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
fn ready_reason(required_verify : Array[String]) -> String {
  if required_verify.length() > 0 {
    "ready: review received, CI passed, threads clear, local verify passed"
  } else {
    "ready: review received, CI passed, threads clear"
  }
}

///|
pub fn decide_merge(
  task_contract : @types.TaskContract?,
  bundle : @types.EvaluationBundle,
) -> MergeDecision {
  let effective_contract = effective_task_contract(task_contract, bundle)
  let required_verify = match effective_contract {
    Some(contract) => contract.verify
    None => []
  }
  let cascade = @types.evaluation_cascade(required_verify, bundle.signals)
  match cascade {
    Ready(_) => MergeDecision::MergeNow(reason=ready_reason(required_verify))
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
  }
}

///|
pub fn MergeDecision::reason(self : MergeDecision) -> String {
  match self {
    MergeNow(reason~) => reason
    Wait(reason~) => reason
    Blocked(reason~) => reason
    NeedsHuman(reason~) => reason
  }
}
