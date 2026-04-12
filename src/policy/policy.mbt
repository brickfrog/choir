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
  let review = @types.evaluation_latest_review_state(bundle.signals)
  let ci = @types.evaluation_latest_ci_rollup(bundle.signals)
  let threads = @types.evaluation_latest_threads(bundle.signals)
  let copilot_seen = @types.evaluation_copilot_seen(bundle.signals)
  let required_verify = match effective_contract {
    Some(contract) => contract.verify
    None => []
  }
  let verify_results = @types.evaluation_verify_results_for_required(
    required_verify,
    bundle.signals,
  )
  let failed_verify = @types.evaluation_failed_verify_names(verify_results)
  if failed_verify.length() > 0 {
    let reason = "local verify failed: " + failed_verify.join(", ")
    return MergeDecision::Blocked(reason~)
  }
  if review == @types.EvaluationReviewState::ChangesRequested {
    return MergeDecision::Blocked(reason="review changes requested")
  }
  match threads {
    Some(count) =>
      if count > 0 {
        return MergeDecision::Blocked(
          reason=count.to_string() + " unresolved inline review thread(s)",
        )
      }
    None => ()
  }
  if ci == @types.EvaluationCiRollup::Failure {
    return MergeDecision::Blocked(reason="CI failing")
  }
  let missing_verify = @types.evaluation_missing_verify_names(verify_results)
  if missing_verify.length() > 0 {
    let reason = "local verify not observed: " + missing_verify.join(", ")
    return MergeDecision::NeedsHuman(reason~)
  }
  if threads is None {
    return MergeDecision::NeedsHuman(reason="review threads not fetched")
  }
  if review == @types.EvaluationReviewState::Unknown ||
    review == @types.EvaluationReviewState::None_ {
    return MergeDecision::Wait(reason="waiting for review")
  }
  if review == @types.EvaluationReviewState::Commented && !copilot_seen {
    return MergeDecision::Wait(reason="waiting for Copilot comments")
  }
  if ci == @types.EvaluationCiRollup::Unknown ||
    ci == @types.EvaluationCiRollup::InProgress {
    return MergeDecision::Wait(reason="waiting for CI to finish")
  }
  MergeDecision::MergeNow(reason=ready_reason(required_verify))
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
