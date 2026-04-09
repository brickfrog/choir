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
fn latest_review_state(
  signals : Array[@types.EvaluationSignal],
) -> @types.EvaluationReviewState {
  let mut latest = @types.EvaluationReviewState::Unknown
  for signal in signals {
    match signal {
      @types.EvaluationSignal::Review(state~, ..) => latest = state
      _ => ()
    }
  }
  latest
}

///|
fn latest_ci_rollup(
  signals : Array[@types.EvaluationSignal],
) -> @types.EvaluationCiRollup {
  let mut latest = @types.EvaluationCiRollup::Unknown
  for signal in signals {
    match signal {
      @types.EvaluationSignal::Ci(status~) => latest = status
      _ => ()
    }
  }
  latest
}

///|
fn latest_threads(signals : Array[@types.EvaluationSignal]) -> Int? {
  let mut latest : Int? = None
  for signal in signals {
    match signal {
      @types.EvaluationSignal::ThreadsObserved(count~) => latest = Some(count)
      @types.EvaluationSignal::ThreadsUnobserved => latest = None
      _ => ()
    }
  }
  latest
}

///|
fn latest_copilot_seen(signals : Array[@types.EvaluationSignal]) -> Bool {
  let mut seen = false
  for signal in signals {
    match signal {
      @types.EvaluationSignal::CopilotIssueCommentObserved => seen = true
      @types.EvaluationSignal::CopilotIssueCommentUnobserved => seen = false
      _ => ()
    }
  }
  seen
}

///|
fn verify_results_for_required(
  required : Array[String],
  signals : Array[@types.EvaluationSignal],
) -> Array[@types.VerifyCheckResult] {
  let observed : Map[String, @types.VerifyCheckResult] = {}
  for signal in signals {
    match signal {
      @types.EvaluationSignal::Verify(result~) =>
        observed.set(result.name, result)
      _ => ()
    }
  }
  let out : Array[@types.VerifyCheckResult] = []
  for name in required {
    match observed.get(name) {
      Some(found) => out.push(found)
      None =>
        out.push({ name, status: @types.VerifyStatus::NotObserved, details: "" })
    }
  }
  out
}

///|
fn missing_verify_names(
  results : Array[@types.VerifyCheckResult],
) -> Array[String] {
  let out : Array[String] = []
  for result in results {
    if result.status == @types.VerifyStatus::NotObserved {
      out.push(result.name)
    }
  }
  out
}

///|
fn failed_verify_names(
  results : Array[@types.VerifyCheckResult],
) -> Array[String] {
  let out : Array[String] = []
  for result in results {
    if result.status == @types.VerifyStatus::Failed {
      out.push(result.name)
    }
  }
  out
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
  let review = latest_review_state(bundle.signals)
  let ci = latest_ci_rollup(bundle.signals)
  let threads = latest_threads(bundle.signals)
  let copilot_seen = latest_copilot_seen(bundle.signals)
  let required_verify = match effective_contract {
    Some(contract) => contract.verify
    None => []
  }
  let verify_results = verify_results_for_required(
    required_verify,
    bundle.signals,
  )
  let failed_verify = failed_verify_names(verify_results)
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
  let missing_verify = missing_verify_names(verify_results)
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
