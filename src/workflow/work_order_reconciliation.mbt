///|
fn work_order_reconciliation_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("WorkOrder reconciliation: " + detail)
}

///|
fn work_order_child_index(
  record : WorkOrderRecord,
  goal_id : @control.GoalId,
) -> Int? {
  for index, binding in record.child_goals {
    if binding.goal_id == goal_id {
      return Some(index)
    }
  }
  None
}

///|
fn work_order_delivery_evidence(
  execution : GoalExecutionRecord,
  pull_request : GoalPullRequestRecord,
) -> WorkOrderDeliveryEvidence? {
  guard execution.state == GoalExecutionState::GoalExecutionSucceeded &&
    pull_request.goal_id == execution.goal.id &&
    pull_request.repository_id == execution.repository_id &&
    pull_request.intent.goal_id == execution.goal.id &&
    pull_request.intent.state == PullRequestIntentState::PullRequestReceipted &&
    pull_request.receipt is Some(receipt) &&
    receipt.intent_id == pull_request.intent.id &&
    receipt.expected_head_oid == pull_request.intent.expected_head_oid &&
    receipt.observed_head_oid == pull_request.intent.expected_head_oid &&
    receipt.observed_marker_state ==
    PullRequestMarkerState::PullRequestMarkerExact &&
    receipt.remote_pull_request_id ==
    pull_request.intent.canonical_remote_pull_request_id.unwrap_or(
      receipt.remote_pull_request_id,
    ) else {
    return None
  }
  let boundary = match pull_request.intent.delivery_policy.mode {
    @types.PullRequestDeliveryMode::PullRequestReviewOnly =>
      if receipt.observed_remote_state !=
        RemotePullRequestState::RemotePullRequestOpen ||
        pull_request.intent.document.draft {
        return None
      } else {
        WorkOrderDeliveryBoundary::WorkOrderReviewReadyPullRequest
      }
    @types.PullRequestDeliveryMode::PullRequestAutoMerge =>
      if receipt.observed_remote_state !=
        RemotePullRequestState::RemotePullRequestMerged {
        return None
      } else {
        WorkOrderDeliveryBoundary::WorkOrderExactMergedPullRequest
      }
  }
  Some({
    boundary,
    remote_pull_request_id: receipt.remote_pull_request_id,
    observed_head_oid: receipt.observed_head_oid,
    observed_remote_state: receipt.observed_remote_state,
    receipt_digest: @storage.artifact_digest(
      @utf8.encode(receipt.to_json().stringify(indent=0)),
    ),
  })
}

///|
pub fn record_work_order_child_delivery(
  record : WorkOrderRecord,
  goal_id : @control.GoalId,
  evidence : WorkOrderDeliveryEvidence,
  now : Int64,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  let index = match work_order_child_index(record, goal_id) {
    Some(value) => value
    None => return Err(work_order_reconciliation_error("child is unbound"))
  }
  let binding = record.child_goals[index]
  if binding.outcome != WorkOrderChildOutcome::WorkOrderChildActive {
    return Ok(record)
  }
  let children = record.child_goals.copy()
  children[index] = {
    ..binding,
    outcome: WorkOrderChildOutcome::WorkOrderChildDelivered,
    delivery_evidence: Some(evidence),
    delivery_accounted: true,
  }
  let budget = match
    record_work_order_delivery(
      record.budget,
      binding.primary_target_ids.length(),
      binding.primary_target_ids.length() +
      binding.prerequisite_closure_ids.length(),
    ) {
    Ok(value) => record_work_order_stop(value, now)
    Err(error) => return Err(error)
  }
  let lifecycle = match budget.stopped {
    Some(reason) => WorkOrderLifecycle::WorkOrderStopped(reason)
    None => record.lifecycle
  }
  Ok({
    ..record,
    child_goals: children,
    budget,
    lifecycle,
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn reconcile_work_order_child(
  record : WorkOrderRecord,
  execution : GoalExecutionRecord,
  pull_request : GoalPullRequestRecord?,
  now : Int64,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  let index = match work_order_child_index(record, execution.goal.id) {
    Some(value) => value
    None => return Err(work_order_reconciliation_error("child is unbound"))
  }
  let binding = record.child_goals[index]
  if binding.outcome != WorkOrderChildOutcome::WorkOrderChildActive {
    return Ok(record)
  }
  match execution.state {
    GoalExecutionState::GoalExecutionSucceeded => {
      let evidence = match
        pull_request.bind(fn(value) {
          work_order_delivery_evidence(execution, value)
        }) {
        Some(value) => value
        None =>
          return Err(
            work_order_reconciliation_error(
              "successful Goal lacks exact delivery evidence",
            ),
          )
      }
      return record_work_order_child_delivery(
        record,
        execution.goal.id,
        evidence,
        now,
      )
    }
    GoalExecutionState::GoalExecutionCanceled => {
      let cause = match execution.cancellation_request {
        Some(request) => request.cause
        None =>
          return Err(
            work_order_reconciliation_error("canceled Goal has no cause"),
          )
      }
      return record_work_order_child_disposition(
        record,
        execution.goal.id,
        WorkOrderChildOutcome::WorkOrderChildCanceled(cause),
        now,
      )
    }
    _ => return Ok(record)
  }
}

///|
pub fn record_work_order_child_disposition(
  record : WorkOrderRecord,
  goal_id : @control.GoalId,
  outcome : WorkOrderChildOutcome,
  now : Int64,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  if outcome == WorkOrderChildOutcome::WorkOrderChildActive ||
    outcome == WorkOrderChildOutcome::WorkOrderChildDelivered {
    return Err(work_order_reconciliation_error("disposition is not terminal"))
  }
  let index = match work_order_child_index(record, goal_id) {
    Some(value) => value
    None => return Err(work_order_reconciliation_error("child is unbound"))
  }
  let binding = record.child_goals[index]
  if binding.outcome != WorkOrderChildOutcome::WorkOrderChildActive {
    return Ok(record)
  }
  let children = record.child_goals.copy()
  children[index] = {
    ..binding,
    outcome,
    delivery_evidence: None,
    delivery_accounted: false,
  }
  let integrity = match outcome {
    WorkOrderChildCanceled(
      GoalCancellationCause::GoalCancellationPartBlocked(
        _,
        @control.PartBlockReason::PartIntegrityBlocked
      )
    ) => true
    _ => false
  }
  let budget = if integrity {
    match
      record_work_order_integrity_stop(
        record.budget,
        @storage.artifact_digest(
          @utf8.encode(outcome.to_json().stringify(indent=0)),
        ),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    record_work_order_stop(record.budget, now)
  }
  let lifecycle = match budget.stopped {
    Some(reason) => WorkOrderLifecycle::WorkOrderStopped(reason)
    None => record.lifecycle
  }
  Ok({
    ..record,
    child_goals: children,
    budget,
    lifecycle,
    durable_version: record.durable_version + 1,
  })
}
