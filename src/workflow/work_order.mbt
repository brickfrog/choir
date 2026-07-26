///|
/// Which Beads a delivered quota counts. A WorkOrder that asks for "five Beads"
/// means five of the Beads it named, not five of anything the dependency
/// closure dragged in — but both are reported so the difference is visible.
pub(all) enum WorkOrderQuotaBasis {
  WorkOrderPrimaryTargets
  WorkOrderDependencyClosure
} derive(Debug, Eq, Compare, ToJson, FromJson)

///|
/// A resolved stop condition. Every duration is already absolute here: relative
/// durations are resolved exactly once at acceptance so replay cannot move the
/// deadline.
pub(all) enum WorkOrderStopPolicy {
  WorkOrderStopAtDeadline(Int64)
  WorkOrderStopAtDeliveredQuota(WorkOrderQuotaBasis, Int)
  WorkOrderStopWhenNoEligibleWork(Int)
  WorkOrderStopWhenNoFurtherFindings(Int)
  WorkOrderStopAtSafetyCeiling(Int)
  /// First condition to hold wins. Nesting is rejected: a stop policy is a flat
  /// list of conditions so the winning reason is always unambiguous.
  WorkOrderStopAtFirstOf(Array[WorkOrderStopPolicy])
} derive(Debug, Eq, ToJson, FromJson)

///|
/// What an operator asked for, before acceptance resolves it. A relative
/// duration exists only in this type; it never reaches durable state.
pub(all) enum WorkOrderStopRequest {
  WorkOrderRequestRelativeSeconds(Int64)
  WorkOrderRequestAbsoluteDeadline(Int64)
  WorkOrderRequestDeliveredQuota(WorkOrderQuotaBasis, Int)
  WorkOrderRequestNoEligibleWork(Int)
  WorkOrderRequestNoFurtherFindings(Int)
  WorkOrderRequestSafetyCeiling(Int)
  WorkOrderRequestFirstOf(Array[WorkOrderStopRequest])
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Why a WorkOrder stopped admitting new work. These are distinct terminal
/// answers, not one generic "budget exhausted".
pub(all) enum WorkOrderStopReason {
  WorkOrderDeadlineReached
  WorkOrderQuotaSatisfied(WorkOrderQuotaBasis, Int)
  WorkOrderNoEligibleWorkRemains
  WorkOrderNoFurtherFindingsRemain
  WorkOrderSafetyCeilingReached
  WorkOrderFatalIntegrityStop(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// What happens to work already in flight when the budget stops admitting new
/// work. Draining lets an authorized effect reach its declared safe boundary;
/// the cutoff variant installs the existing durable cancellation cutoff instead.
pub(all) enum WorkOrderCutoffPolicy {
  WorkOrderDrainToSafeBoundary
  WorkOrderInstallCancellationCutoff
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Durable progress counters. Only delivered work counts: attempts, canceled
/// Goals, open automatic-merge pull requests, and skipped items are deliberately
/// absent, because a quota that counts them is not a quota of delivered Beads.
pub(all) struct WorkOrderCounters {
  delivered_primary_targets : Int
  delivered_dependency_closure : Int
  agentic_takes_started : Int
  consecutive_idle_rounds : Int
  consecutive_findings_free_rounds : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderBudget {
  accepted_at : Int64
  stop_policy : WorkOrderStopPolicy
  cutoff_policy : WorkOrderCutoffPolicy
  counters : WorkOrderCounters
  stopped : WorkOrderStopReason?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum WorkOrderAdmission {
  WorkOrderAdmitsNewWork
  WorkOrderExhausted(WorkOrderStopReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
fn work_order_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("WorkOrder budget: " + detail)
}

///|
/// Largest representable epoch second. Adding a relative duration past this is
/// an overflow, not a deadline in the far future.
let work_order_maximum_instant : Int64 = 9223372036854775807L

///|
pub fn initial_work_order_counters() -> WorkOrderCounters {
  {
    delivered_primary_targets: 0,
    delivered_dependency_closure: 0,
    agentic_takes_started: 0,
    consecutive_idle_rounds: 0,
    consecutive_findings_free_rounds: 0,
  }
}

///|
fn resolve_work_order_stop_request(
  request : WorkOrderStopRequest,
  accepted_at : Int64,
  nested : Bool,
) -> Result[WorkOrderStopPolicy, @types.ChoirError] {
  match request {
    WorkOrderRequestRelativeSeconds(seconds) => {
      if seconds <= 0L {
        return Err(work_order_error("relative duration is not positive"))
      }
      if seconds > work_order_maximum_instant - accepted_at {
        return Err(work_order_error("relative duration overflows its deadline"))
      }
      Ok(WorkOrderStopAtDeadline(accepted_at + seconds))
    }
    WorkOrderRequestAbsoluteDeadline(instant) =>
      if instant <= accepted_at {
        Err(work_order_error("absolute deadline is not in the future"))
      } else {
        Ok(WorkOrderStopAtDeadline(instant))
      }
    WorkOrderRequestDeliveredQuota(basis, count) =>
      if count <= 0 {
        Err(work_order_error("delivered quota is not positive"))
      } else {
        Ok(WorkOrderStopAtDeliveredQuota(basis, count))
      }
    WorkOrderRequestNoEligibleWork(rounds) =>
      if rounds <= 0 {
        Err(work_order_error("idle round bound is not positive"))
      } else {
        Ok(WorkOrderStopWhenNoEligibleWork(rounds))
      }
    WorkOrderRequestNoFurtherFindings(rounds) =>
      if rounds <= 0 {
        Err(work_order_error("findings-free round bound is not positive"))
      } else {
        Ok(WorkOrderStopWhenNoFurtherFindings(rounds))
      }
    WorkOrderRequestSafetyCeiling(takes) =>
      if takes <= 0 {
        Err(work_order_error("safety ceiling is not positive"))
      } else {
        Ok(WorkOrderStopAtSafetyCeiling(takes))
      }
    WorkOrderRequestFirstOf(requests) => {
      if nested {
        return Err(work_order_error("compound stop policies do not nest"))
      }
      if requests.length() == 0 {
        return Err(work_order_error("compound stop policy is empty"))
      }
      let resolved : Array[WorkOrderStopPolicy] = []
      for entry in requests {
        match resolve_work_order_stop_request(entry, accepted_at, true) {
          Ok(value) => resolved.push(value)
          Err(error) => return Err(error)
        }
      }
      Ok(WorkOrderStopAtFirstOf(resolved))
    }
  }
}

///|
/// Resolve a requested stop policy exactly once, at acceptance, against an
/// injected clock reading. The result is fully absolute, so persisting it and
/// replaying it yields the identical deadline no matter when replay runs.
pub fn accept_work_order_budget(
  request : WorkOrderStopRequest,
  cutoff_policy : WorkOrderCutoffPolicy,
  accepted_at : Int64,
) -> Result[WorkOrderBudget, @types.ChoirError] {
  if accepted_at <= 0L {
    return Err(work_order_error("acceptance time is invalid"))
  }
  let stop_policy = match
    resolve_work_order_stop_request(request, accepted_at, false) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    accepted_at,
    stop_policy,
    cutoff_policy,
    counters: initial_work_order_counters(),
    stopped: None,
  })
}

///|
fn work_order_condition_reached(
  policy : WorkOrderStopPolicy,
  counters : WorkOrderCounters,
  now : Int64,
) -> WorkOrderStopReason? {
  match policy {
    WorkOrderStopAtDeadline(instant) =>
      if now >= instant {
        Some(WorkOrderDeadlineReached)
      } else {
        None
      }
    WorkOrderStopAtDeliveredQuota(basis, count) => {
      let delivered = match basis {
        WorkOrderPrimaryTargets => counters.delivered_primary_targets
        WorkOrderDependencyClosure => counters.delivered_dependency_closure
      }
      if delivered >= count {
        Some(WorkOrderQuotaSatisfied(basis, delivered))
      } else {
        None
      }
    }
    WorkOrderStopWhenNoEligibleWork(rounds) =>
      if counters.consecutive_idle_rounds >= rounds {
        Some(WorkOrderNoEligibleWorkRemains)
      } else {
        None
      }
    WorkOrderStopWhenNoFurtherFindings(rounds) =>
      if counters.consecutive_findings_free_rounds >= rounds {
        Some(WorkOrderNoFurtherFindingsRemain)
      } else {
        None
      }
    WorkOrderStopAtSafetyCeiling(takes) =>
      if counters.agentic_takes_started >= takes {
        Some(WorkOrderSafetyCeilingReached)
      } else {
        None
      }
    WorkOrderStopAtFirstOf(policies) => {
      for entry in policies {
        match work_order_condition_reached(entry, counters, now) {
          Some(reason) => return Some(reason)
          None => ()
        }
      }
      None
    }
  }
}

///|
/// The budget gate for the authority seam. Reconciliation, delivery
/// observation, and safety cleanup call nothing here and continue past the
/// deadline; this answers exactly one question — may a new agentic Take start?
pub fn work_order_admits_new_work(
  budget : WorkOrderBudget,
  now : Int64,
) -> WorkOrderAdmission {
  match budget.stopped {
    Some(reason) => return WorkOrderExhausted(reason)
    None => ()
  }
  match work_order_condition_reached(budget.stop_policy, budget.counters, now) {
    Some(reason) => WorkOrderExhausted(reason)
    None => WorkOrderAdmitsNewWork
  }
}

///|
/// Latch the stop reason durably. A latched budget stays stopped across
/// restart even if a counter or clock reading would no longer reach the
/// condition, so a WorkOrder can never resurrect itself.
pub fn record_work_order_stop(
  budget : WorkOrderBudget,
  now : Int64,
) -> WorkOrderBudget {
  match work_order_admits_new_work(budget, now) {
    WorkOrderAdmitsNewWork => budget
    WorkOrderExhausted(reason) =>
      match budget.stopped {
        Some(_) => budget
        None => { ..budget, stopped: Some(reason) }
      }
  }
}

///|
/// Stop a WorkOrder on evidence no budget condition can express: a fatal
/// integrity failure. It latches like any other stop reason.
pub fn record_work_order_integrity_stop(
  budget : WorkOrderBudget,
  evidence : @control.Digest,
) -> Result[WorkOrderBudget, @types.ChoirError] {
  if @storage.validate_digest(evidence) is Err(_) {
    return Err(work_order_error("integrity stop evidence is invalid"))
  }
  match budget.stopped {
    Some(_) => Ok(budget)
    None =>
      Ok({ ..budget, stopped: Some(WorkOrderFatalIntegrityStop(evidence)) })
  }
}

///|
/// Record one delivered Goal against the WorkOrder. Delivery is the only event
/// that advances a quota, and it also resets the idle counter because the
/// WorkOrder demonstrably still had eligible work.
pub fn record_work_order_delivery(
  budget : WorkOrderBudget,
  primary_targets : Int,
  dependency_closure : Int,
) -> Result[WorkOrderBudget, @types.ChoirError] {
  if primary_targets < 0 ||
    dependency_closure < 0 ||
    dependency_closure < primary_targets {
    return Err(work_order_error("delivered Bead counts are inconsistent"))
  }
  Ok({
    ..budget,
    counters: {
      ..budget.counters,
      delivered_primary_targets: budget.counters.delivered_primary_targets +
      primary_targets,
      delivered_dependency_closure: budget.counters.delivered_dependency_closure +
      dependency_closure,
      consecutive_idle_rounds: 0,
    },
  })
}

///|
/// Record that one agentic Take started. The safety ceiling counts starts, not
/// successes, so a WorkOrder that keeps failing still stops.
pub fn record_work_order_agentic_take(
  budget : WorkOrderBudget,
) -> WorkOrderBudget {
  {
    ..budget,
    counters: {
      ..budget.counters,
      agentic_takes_started: budget.counters.agentic_takes_started + 1,
    },
  }
}

///|
/// Record one planning round that found nothing to do, or that produced no new
/// findings. A round that found work resets the matching counter.
pub fn record_work_order_round(
  budget : WorkOrderBudget,
  eligible_work_found : Bool,
  findings_found : Bool,
) -> WorkOrderBudget {
  {
    ..budget,
    counters: {
      ..budget.counters,
      consecutive_idle_rounds: if eligible_work_found {
        0
      } else {
        budget.counters.consecutive_idle_rounds + 1
      },
      consecutive_findings_free_rounds: if findings_found {
        0
      } else {
        budget.counters.consecutive_findings_free_rounds + 1
      },
    },
  }
}

///|
pub fn work_order_budget_bytes(budget : WorkOrderBudget) -> Bytes {
  @utf8.encode(budget.to_json().stringify(indent=0))
}

///|
pub fn decode_work_order_budget(
  content : Bytes,
) -> Result[WorkOrderBudget, @types.ChoirError] {
  let json = @json.parse(@utf8.decode_lossy(content)) catch {
    _ => return Err(work_order_error("budget is not valid JSON"))
  }
  let budget : WorkOrderBudget = @json.from_json(json) catch {
    _ => return Err(work_order_error("budget has the wrong schema"))
  }
  if budget.accepted_at <= 0L {
    return Err(work_order_error("budget acceptance time is invalid"))
  }
  Ok(budget)
}
