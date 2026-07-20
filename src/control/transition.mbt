///|
fn invalid_transition(machine : String, detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "invalid " + machine + " transition: " + detail,
  )
}

///|
/// Pure Goal transition table. Success and cancellation are competing terminal
/// compare-and-set decisions: neither terminal state accepts another trigger.
pub fn transition_goal_lifecycle(
  current : GoalLifecycle,
  trigger : GoalTransition,
) -> Result[GoalLifecycle, @types.ChoirError] {
  match (current, trigger) {
    (GoalActive(_), ObserveGoalCondition(condition)) =>
      Ok(GoalActive(condition))
    (GoalActive(_), RequestGoalCancellation(cutoff)) =>
      Ok(GoalCanceling(cutoff))
    (GoalActive(GoalRunning), CommitGoalSuccess(finalization_id)) =>
      Ok(GoalSucceeded(finalization_id))
    (GoalCanceling(_), CommitGoalCancellation(summary_id)) =>
      Ok(GoalCanceled(summary_id))
    (GoalActive(_), CommitGoalSuccess(_)) =>
      Err(
        invalid_transition("Goal", "success requires GoalActive(GoalRunning)"),
      )
    (GoalActive(_), CommitGoalCancellation(_)) =>
      Err(invalid_transition("Goal", "cancellation has no durable cutoff"))
    (GoalCanceling(_), _) =>
      Err(invalid_transition("Goal", "only cancellation may be committed"))
    (GoalSucceeded(_), _) | (GoalCanceled(_), _) =>
      Err(invalid_transition("Goal", "terminal decision already committed"))
  }
}

///|
pub fn transition_goal(
  goal : Goal,
  trigger : GoalTransition,
) -> Result[Goal, @types.ChoirError] {
  match transition_goal_lifecycle(goal.lifecycle, trigger) {
    Ok(lifecycle) => Ok({ ..goal, lifecycle, })
    Err(error) => Err(error)
  }
}

///|
fn candidate_matches(actual : CandidateId, expected : CandidateId) -> Bool {
  actual == expected
}

///|
/// Pure Part transition table. A missing verification or audit is intentionally
/// absent from this table: gates inspect state; scheduler code must explicitly
/// schedule the producer Take.
pub fn transition_part_lifecycle(
  current : PartLifecycle,
  trigger : PartTransition,
) -> Result[PartLifecycle, @types.ChoirError] {
  match (current, trigger) {
    (PartPending, MarkPartReady) => Ok(PartReady)
    (PartReady, StartPartTake(take_id)) => Ok(PartExecuting(take_id))
    (PartExecuting(active_take_id), RetryPartTake(failed_take_id)) =>
      if active_take_id == failed_take_id {
        Ok(PartReady)
      } else {
        Err(invalid_transition("Part", "retry Take is not the active Take"))
      }
    (PartExecuting(active_take_id), RecordPartCandidate(take_id, candidate_id)) =>
      if active_take_id == take_id {
        Ok(PartCandidate(candidate_id))
      } else {
        Err(invalid_transition("Part", "candidate Take is not the active Take"))
      }
    (PartCandidate(actual), RecordPartVerification(expected, receipt_set_digest)
    ) =>
      if candidate_matches(actual, expected) {
        Ok(PartVerified(actual, receipt_set_digest))
      } else {
        Err(invalid_transition("Part", "verification subject is stale"))
      }
    (
      PartVerified(actual, receipt_set_digest),
      RecordPartAudit(expected, receipt_id),
    ) =>
      if candidate_matches(actual, expected) {
        Ok(PartAudited(actual, receipt_set_digest, receipt_id))
      } else {
        Err(invalid_transition("Part", "audit subject is stale"))
      }
    (
      PartAudited(actual, receipt_set_digest, receipt_id),
      BeginPartPromotion(expected),
    ) =>
      if candidate_matches(actual, expected) {
        Ok(PartPromoting(actual, receipt_set_digest, receipt_id))
      } else {
        Err(invalid_transition("Part", "promotion subject is stale"))
      }
    (PartPromoting(actual, _, _), RecordPartIntegration(expected, receipt_id)) =>
      if candidate_matches(actual, expected) {
        Ok(PartIntegrated(receipt_id))
      } else {
        Err(invalid_transition("Part", "integration subject is stale"))
      }
    (PartPending, BlockPart(reason))
    | (PartReady, BlockPart(reason))
    | (PartExecuting(_), BlockPart(reason))
    | (PartCandidate(_), BlockPart(reason))
    | (PartVerified(_, _), BlockPart(reason))
    | (PartAudited(_, _, _), BlockPart(reason))
    | (PartPromoting(_, _, _), BlockPart(reason)) => Ok(PartBlocked(reason))
    (PartPending, CancelPartNotRun)
    | (PartReady, CancelPartNotRun)
    | (PartExecuting(_), CancelPartNotRun)
    | (PartBlocked(_), CancelPartNotRun) => Ok(PartCanceledNotRun)
    (PartIntegrated(_), _) | (PartCanceledNotRun, _) =>
      Err(invalid_transition("Part", "terminal state already committed"))
    (PartBlocked(_), _) =>
      Err(
        invalid_transition(
          "Part", "blocked Part requires explicit policy action",
        ),
      )
    _ =>
      Err(invalid_transition("Part", "trigger is not legal from current state"))
  }
}

///|
pub fn transition_part(
  part : GoalPart,
  trigger : PartTransition,
) -> Result[GoalPart, @types.ChoirError] {
  match transition_part_lifecycle(part.lifecycle, trigger) {
    Ok(lifecycle) => Ok({ ..part, lifecycle, })
    Err(error) => Err(error)
  }
}

///|
fn require_take_fence(
  take : Take,
  supplied : FencingEpoch,
) -> Result[Unit, @types.ChoirError] {
  match take.fencing_epoch {
    Some(active) if active == supplied => Ok(())
    Some(_) => Err(invalid_transition("Take", "stale fencing epoch"))
    None => Err(invalid_transition("Take", "Take has no active lease"))
  }
}

///|
/// Pure Take transition table. Lease expiry is deliberately not a success
/// transition. Callers must record an explicit terminal uncertainty or admit a
/// fresh Take under retry policy.
pub fn transition_take(
  take : Take,
  trigger : TakeTransition,
) -> Result[Take, @types.ChoirError] {
  match (take.lifecycle, trigger) {
    (TakePlanned, LeaseTake(epoch)) =>
      Ok({ ..take, fencing_epoch: Some(epoch), lifecycle: TakeLeased })
    (TakeLeased, StartTake(epoch)) =>
      match require_take_fence(take, epoch) {
        Ok(_) => Ok({ ..take, lifecycle: TakeRunning })
        Err(error) => Err(error)
      }
    (TakeRunning, RecordTakeResult(epoch, result_digest)) =>
      match require_take_fence(take, epoch) {
        Ok(_) => Ok({ ..take, lifecycle: TakeResultRecorded(result_digest) })
        Err(error) => Err(error)
      }
    (TakeLeased, FinishTake(epoch, TakeCanceled)) =>
      match require_take_fence(take, epoch) {
        Ok(_) => Ok({ ..take, lifecycle: TakeTerminal(TakeCanceled) })
        Err(error) => Err(error)
      }
    (TakeRunning, FinishTake(epoch, disposition))
    | (TakeResultRecorded(_), FinishTake(epoch, disposition)) =>
      match require_take_fence(take, epoch) {
        Ok(_) => Ok({ ..take, lifecycle: TakeTerminal(disposition) })
        Err(error) => Err(error)
      }
    (TakeTerminal(_), _) =>
      Err(invalid_transition("Take", "terminal disposition already committed"))
    _ =>
      Err(invalid_transition("Take", "trigger is not legal from current state"))
  }
}
