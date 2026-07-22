///|
pub(all) struct GoalPartSchedulingRecord {
  part : @control.GoalPart
  task_contract : @control.TaskContractRevision
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalPartAdmission {
  GoalPartAdmitted
  GoalPartWaitingOnDependencies(Array[@control.PartId])
  GoalPartDependencyUnavailable(Array[@control.PartId])
  GoalPartDeferredByMutationConflict(Array[@control.PartId])
  GoalPartDeferredByCapacity
  GoalPartAlreadyInProgress
  GoalPartAlreadyTerminal
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPartSchedulingDecision {
  part_id : @control.PartId
  admission : GoalPartAdmission
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalPartSchedule {
  decisions : Array[GoalPartSchedulingDecision]
  admitted_part_ids : Array[@control.PartId]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DeterministicPromotionSelection {
  part_id : @control.PartId
  candidate_id : @control.CandidateId
  audit_receipt_id : @control.ReceiptId
  expected_goal_head_oid : @control.GitOid
} derive(Debug, Eq, ToJson, FromJson)

///|
fn sorted_scheduling_records(
  records : Array[GoalPartSchedulingRecord],
) -> Array[GoalPartSchedulingRecord] {
  let sorted = records.copy()
  sorted.sort_by(fn(left, right) { left.part.id.compare(right.part.id) })
  sorted
}

///|
fn stable_topological_records(
  records : Array[GoalPartSchedulingRecord],
) -> Result[Array[GoalPartSchedulingRecord], @types.ChoirError] {
  let remaining = sorted_scheduling_records(records)
  let ordered : Array[GoalPartSchedulingRecord] = []
  while remaining.length() > 0 {
    let mut ready_index = -1
    for index, record in remaining {
      if record.part.dependency_ids.all(fn(dependency_id) {
          ordered.any(fn(completed) { completed.part.id == dependency_id })
        }) {
        ready_index = index
        break
      }
    }
    if ready_index < 0 {
      return Err(
        @types.ChoirError::validation_error(
          "Part dependency graph has no stable topological order",
        ),
      )
    }
    ordered.push(remaining.remove(ready_index))
  }
  Ok(ordered)
}

///|
fn find_scheduling_record(
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
fn dependency_path_reaches(
  records : Array[GoalPartSchedulingRecord],
  current : @control.PartId,
  target : @control.PartId,
  visited : Array[@control.PartId],
) -> Bool {
  if current == target {
    return true
  }
  if visited.contains(current) {
    return false
  }
  let next_visited = visited.copy()
  next_visited.push(current)
  match find_scheduling_record(records, current) {
    Some(record) =>
      record.part.dependency_ids.any(fn(dependency_id) {
        dependency_path_reaches(records, dependency_id, target, next_visited)
      })
    None => false
  }
}

///|
fn validate_scheduling_records(
  records : Array[GoalPartSchedulingRecord],
) -> Result[Unit, @types.ChoirError] {
  for index = 0; index < records.length(); index = index + 1 {
    let record = records[index]
    if record.task_contract.part_id != record.part.id ||
      record.task_contract.goal_id != record.part.goal_id ||
      record.task_contract.id != record.part.task_contract_revision_id {
      return Err(
        @types.ChoirError::validation_error(
          "Part and task contract identities do not match",
        ),
      )
    }
    for other = index + 1; other < records.length(); other = other + 1 {
      if record.part.id == records[other].part.id {
        return Err(
          @types.ChoirError::validation_error("duplicate Part identity"),
        )
      }
    }
    for dependency_id in record.part.dependency_ids {
      if dependency_id == record.part.id ||
        find_scheduling_record(records, dependency_id) is None {
        return Err(
          @types.ChoirError::validation_error(
            "Part dependency is self-referential or absent",
          ),
        )
      }
      if dependency_path_reaches(records, dependency_id, record.part.id, []) {
        return Err(@types.ChoirError::validation_error("Part dependency cycle"))
      }
    }
  }
  Ok(())
}

///|
fn dependency_partition(
  records : Array[GoalPartSchedulingRecord],
  record : GoalPartSchedulingRecord,
) -> (Array[@control.PartId], Array[@control.PartId]) {
  let waiting : Array[@control.PartId] = []
  let unavailable : Array[@control.PartId] = []
  for dependency_id in record.part.dependency_ids {
    match find_scheduling_record(records, dependency_id) {
      Some(
        {
          part: { lifecycle: @control.PartLifecycle::PartIntegrated(_), .. },
          ..,
        }
      ) => ()
      Some(
        {
          part: {
            lifecycle: @control.PartLifecycle::PartBlocked(_)
            | @control.PartLifecycle::PartCanceledNotRun,
            ..,
          },
          ..,
        }
      ) => unavailable.push(dependency_id)
      Some(_) => waiting.push(dependency_id)
      None => unavailable.push(dependency_id)
    }
  }
  (waiting, unavailable)
}

///|
fn conflicting_admitted_parts(
  admitted : Array[GoalPartSchedulingRecord],
  candidate : GoalPartSchedulingRecord,
) -> Array[@control.PartId] {
  let conflicts : Array[@control.PartId] = []
  for running in admitted {
    if @control.mutation_declarations_conflict(
        running.task_contract.mutation_declaration,
        candidate.task_contract.mutation_declaration,
      ) {
      conflicts.push(running.part.id)
    }
  }
  conflicts
}

///|
fn active_mutation_reservations(
  records : Array[GoalPartSchedulingRecord],
) -> Array[GoalPartSchedulingRecord] {
  let reservations : Array[GoalPartSchedulingRecord] = []
  for record in sorted_scheduling_records(records) {
    match record.part.lifecycle {
      @control.PartLifecycle::PartExecuting(_) => reservations.push(record)
      _ => ()
    }
  }
  reservations
}

///|
pub fn schedule_goal_parts(
  records : Array[GoalPartSchedulingRecord],
  maximum_parallel_parts : Int,
) -> Result[GoalPartSchedule, @types.ChoirError] {
  if maximum_parallel_parts <= 0 {
    return Err(
      @types.ChoirError::validation_error(
        "maximum parallel Parts must be positive",
      ),
    )
  }
  match validate_scheduling_records(records) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let sorted = sorted_scheduling_records(records)
  let admitted : Array[GoalPartSchedulingRecord] = []
  let mutation_reservations = active_mutation_reservations(records)
  let active_count = mutation_reservations.length()
  let decisions : Array[GoalPartSchedulingDecision] = []
  for record in sorted {
    let admission = match record.part.lifecycle {
      @control.PartLifecycle::PartPending | @control.PartLifecycle::PartReady => {
        let (waiting, unavailable) = dependency_partition(records, record)
        if unavailable.length() > 0 {
          GoalPartDependencyUnavailable(unavailable)
        } else if waiting.length() > 0 {
          GoalPartWaitingOnDependencies(waiting)
        } else if active_count + admitted.length() >= maximum_parallel_parts {
          GoalPartDeferredByCapacity
        } else {
          let conflicts = conflicting_admitted_parts(
            mutation_reservations, record,
          )
          conflicts.append(conflicting_admitted_parts(admitted, record))
          if conflicts.length() > 0 {
            GoalPartDeferredByMutationConflict(conflicts)
          } else {
            admitted.push(record)
            GoalPartAdmitted
          }
        }
      }
      @control.PartLifecycle::PartExecuting(_)
      | @control.PartLifecycle::PartCandidate(_)
      | @control.PartLifecycle::PartVerified(_, _)
      | @control.PartLifecycle::PartAudited(_, _, _)
      | @control.PartLifecycle::PartPromoting(_, _, _) =>
        GoalPartAlreadyInProgress
      @control.PartLifecycle::PartIntegrated(_)
      | @control.PartLifecycle::PartBlocked(_)
      | @control.PartLifecycle::PartCanceledNotRun => GoalPartAlreadyTerminal
    }
    decisions.push({ part_id: record.part.id, admission })
  }
  Ok({
    decisions,
    admitted_part_ids: admitted.map(fn(record) { record.part.id }),
  })
}

///|
pub fn select_next_deterministic_promotion(
  records : Array[GoalPartSchedulingRecord],
  current_goal_head_oid : @control.GitOid,
) -> Result[DeterministicPromotionSelection?, @types.ChoirError] {
  match validate_scheduling_records(records) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let ordered = match stable_topological_records(records) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for record in ordered {
    match record.part.lifecycle {
      @control.PartLifecycle::PartIntegrated(_)
      | @control.PartLifecycle::PartBlocked(_)
      | @control.PartLifecycle::PartCanceledNotRun => continue
      @control.PartLifecycle::PartAudited(candidate_id, _, audit_receipt_id) => {
        let (waiting, unavailable) = dependency_partition(records, record)
        if waiting.length() == 0 && unavailable.length() == 0 {
          return Ok(
            Some({
              part_id: record.part.id,
              candidate_id,
              audit_receipt_id,
              expected_goal_head_oid: current_goal_head_oid,
            }),
          )
        }
        return Ok(None)
      }
      _ => return Ok(None)
    }
  }
  Ok(None)
}
