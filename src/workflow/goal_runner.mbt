///|
pub(all) struct GoalRunnerAdapters {
  advance_part : async (GoalPartSchedulingRecord) -> Result[
    GoalPartSchedulingRecord,
    @types.ChoirError,
  ]
  read_goal_head : async () -> Result[@control.GitOid, @types.ChoirError]
  promote_part : async (
    GoalPartSchedulingRecord,
    DeterministicPromotionSelection,
  ) -> Result[GoalPartSchedulingRecord, @types.ChoirError]
  resume_promotion : async (GoalPartSchedulingRecord) -> Result[
    GoalPartSchedulingRecord,
    @types.ChoirError,
  ]
}

///|
pub(all) enum GoalRunOutcome {
  GoalRunSucceeded
  GoalRunBlocked
  GoalRunPaused
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalRunResult {
  records : Array[GoalPartSchedulingRecord]
  promotion_order : Array[@control.PartId]
  outcome : GoalRunOutcome
} derive(Debug, Eq)

///|
fn goal_runner_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Goal runner: " + detail)
}

///|
fn same_part_contract(
  expected : GoalPartSchedulingRecord,
  observed : GoalPartSchedulingRecord,
) -> Bool {
  expected.task_contract == observed.task_contract &&
  expected.part.id == observed.part.id &&
  expected.part.goal_id == observed.part.goal_id &&
  expected.part.dependency_ids == observed.part.dependency_ids &&
  expected.part.task_contract_revision_id ==
  observed.part.task_contract_revision_id
}

///|
fn valid_advance_result(
  expected : GoalPartSchedulingRecord,
  observed : GoalPartSchedulingRecord,
) -> Bool {
  if !same_part_contract(expected, observed) {
    return false
  }
  match observed.part.lifecycle {
    @control.PartLifecycle::PartAudited(_, _, _)
    | @control.PartLifecycle::PartBlocked(_) => true
    _ => false
  }
}

///|
fn valid_promotion_result(
  expected : GoalPartSchedulingRecord,
  observed : GoalPartSchedulingRecord,
) -> Bool {
  if !same_part_contract(expected, observed) {
    return false
  }
  match observed.part.lifecycle {
    @control.PartLifecycle::PartAudited(_, _, _)
    | @control.PartLifecycle::PartPromoting(_, _, _)
    | @control.PartLifecycle::PartIntegrated(_)
    | @control.PartLifecycle::PartBlocked(_) => true
    _ => false
  }
}

///|
fn replace_goal_record(
  records : Array[GoalPartSchedulingRecord],
  replacement : GoalPartSchedulingRecord,
) -> Result[Array[GoalPartSchedulingRecord], @types.ChoirError] {
  let updated = records.copy()
  for index = 0; index < updated.length(); index = index + 1 {
    if updated[index].part.id == replacement.part.id {
      updated[index] = replacement
      return Ok(updated)
    }
  }
  Err(goal_runner_error("Part result has no scheduling record"))
}

///|
fn find_goal_record(
  records : Array[GoalPartSchedulingRecord],
  part_id : @control.PartId,
) -> GoalPartSchedulingRecord? {
  for record in records {
    if record.part.id == part_id {
      return Some(record)
    }
  }
  None
}

///|
fn ordered_active_records(
  records : Array[GoalPartSchedulingRecord],
  admitted_part_ids : Array[@control.PartId],
) -> Array[GoalPartSchedulingRecord] {
  let selected : Array[GoalPartSchedulingRecord] = []
  for record in records {
    let active = match record.part.lifecycle {
      @control.PartLifecycle::PartExecuting(_)
      | @control.PartLifecycle::PartCandidate(_)
      | @control.PartLifecycle::PartVerified(_, _) => true
      _ => false
    }
    if active || admitted_part_ids.contains(record.part.id) {
      selected.push(record)
    }
  }
  selected.sort_by(fn(left, right) { left.part.id.compare(right.part.id) })
  selected
}

///|
async fn advance_goal_records(
  records : Array[GoalPartSchedulingRecord],
  selected : Array[GoalPartSchedulingRecord],
  adapters : GoalRunnerAdapters,
) -> Result[Array[GoalPartSchedulingRecord], @types.ChoirError] {
  @async.with_task_group(async fn(group) {
    let tasks = selected.map(fn(record) {
      group.spawn(async fn() { (adapters.advance_part)(record) })
    })
    let mut updated = records
    for index = 0; index < tasks.length(); index = index + 1 {
      let observed = match tasks[index].wait() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let expected = selected[index]
      if !valid_advance_result(expected, observed) {
        return Err(
          goal_runner_error("Part executor returned an invalid transition"),
        )
      }
      updated = match replace_goal_record(updated, observed) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    Ok(updated)
  })
}

///|
fn goal_records_succeeded(records : Array[GoalPartSchedulingRecord]) -> Bool {
  records.length() > 0 &&
  records.all(fn(record) {
    record.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)
  })
}

///|
fn goal_records_have_failure(records : Array[GoalPartSchedulingRecord]) -> Bool {
  records.any(fn(record) {
    record.part.lifecycle is @control.PartLifecycle::PartBlocked(_) ||
    record.part.lifecycle is @control.PartLifecycle::PartCanceledNotRun
  })
}

///|
fn goal_records_have_audited(records : Array[GoalPartSchedulingRecord]) -> Bool {
  records.any(fn(record) {
    record.part.lifecycle is @control.PartLifecycle::PartAudited(_, _, _)
  })
}

///|
fn promoting_record(
  records : Array[GoalPartSchedulingRecord],
) -> Result[GoalPartSchedulingRecord?, @types.ChoirError] {
  let promoting : Array[GoalPartSchedulingRecord] = []
  for record in records {
    if record.part.lifecycle is @control.PartLifecycle::PartPromoting(_, _, _) {
      promoting.push(record)
    }
  }
  promoting.sort_by(fn(left, right) { left.part.id.compare(right.part.id) })
  match promoting {
    [] => Ok(None)
    [record] => Ok(Some(record))
    _ => Err(goal_runner_error("multiple Parts hold promotion state"))
  }
}

///|
pub async fn run_goal_parts(
  records : Array[GoalPartSchedulingRecord],
  maximum_parallel_parts : Int,
  adapters : GoalRunnerAdapters,
) -> Result[GoalRunResult, @types.ChoirError] {
  if records.length() == 0 {
    return Err(goal_runner_error("Goal has no Parts"))
  }
  let mut current = records
  let promotion_order : Array[@control.PartId] = []
  while true {
    if goal_records_succeeded(current) {
      return Ok({ records: current, promotion_order, outcome: GoalRunSucceeded })
    }
    let recovering = match promoting_record(current) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match recovering {
      Some(record) => {
        let observed = match (adapters.resume_promotion)(record) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if !valid_promotion_result(record, observed) {
          return Err(
            goal_runner_error("promotion recovery returned an invalid state"),
          )
        }
        if observed == record {
          return Ok({
            records: current,
            promotion_order,
            outcome: GoalRunPaused,
          })
        }
        current = match replace_goal_record(current, observed) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if observed.part.lifecycle is @control.PartLifecycle::PartIntegrated(_) {
          promotion_order.push(observed.part.id)
        }
        continue
      }
      None => ()
    }
    let schedule = match schedule_goal_parts(current, maximum_parallel_parts) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let selected = ordered_active_records(current, schedule.admitted_part_ids)
    if selected.length() > 0 {
      current = match advance_goal_records(current, selected, adapters) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      continue
    }
    if !goal_records_have_audited(current) {
      let outcome = if goal_records_have_failure(current) {
        GoalRunBlocked
      } else {
        GoalRunPaused
      }
      return Ok({ records: current, promotion_order, outcome })
    }
    let head = match (adapters.read_goal_head)() {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let selection = match select_next_deterministic_promotion(current, head) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match selection {
      Some(selected_promotion) => {
        let record = match
          find_goal_record(current, selected_promotion.part_id) {
          Some(value) => value
          None => return Err(goal_runner_error("selected Part is absent"))
        }
        let observed = match
          (adapters.promote_part)(record, selected_promotion) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if !valid_promotion_result(record, observed) {
          return Err(
            goal_runner_error("promoter returned an invalid transition"),
          )
        }
        if observed == record {
          return Ok({
            records: current,
            promotion_order,
            outcome: GoalRunPaused,
          })
        }
        current = match replace_goal_record(current, observed) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if observed.part.lifecycle is @control.PartLifecycle::PartIntegrated(_) {
          promotion_order.push(observed.part.id)
        }
        continue
      }
      None => {
        let outcome = if goal_records_have_failure(current) {
          GoalRunBlocked
        } else {
          GoalRunPaused
        }
        return Ok({ records: current, promotion_order, outcome })
      }
    }
  } nobreak {
    Err(goal_runner_error("Goal runner stopped unexpectedly"))
  }
}
