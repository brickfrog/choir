///|
fn test_take(epoch? : Int64 = 1L) -> @control.Take {
  {
    id: @control.TakeId("take-1"),
    goal_id: @control.GoalId("goal-1"),
    purpose: @control.TakePurpose::Implementation(
      @control.PartId("part-1"),
      @control.RevisionId("contract-1"),
    ),
    ordinal: 1,
    fencing_epoch: Some(@control.FencingEpoch(epoch)),
    lifecycle: @control.TakeLifecycle::TakeLeased,
  }
}

///|
test "Goal success and cancellation have one terminal winner" {
  let active = @control.GoalLifecycle::GoalActive(
    @control.GoalActiveCondition::GoalRunning,
  )
  let success = @control.transition_goal_lifecycle(
    active,
    @control.GoalTransition::CommitGoalSuccess(
      @control.FinalizationId("final-1"),
    ),
  )
  match success {
    Ok(@control.GoalLifecycle::GoalSucceeded(@control.FinalizationId(id))) => {
      assert_eq(id, "final-1")
      match
        @control.transition_goal_lifecycle(
          @control.GoalLifecycle::GoalSucceeded(@control.FinalizationId(id)),
          @control.GoalTransition::RequestGoalCancellation(
            @control.EventSequence(12L),
          ),
        ) {
        Err(error) => assert_true(error.message().contains("terminal decision"))
        Ok(_) => fail("terminal Goal accepted cancellation")
      }
    }
    Ok(_) => fail("Goal committed the wrong terminal state")
    Err(error) => fail(error.message())
  }
}

///|
test "Goal cannot succeed from a non-running active condition" {
  match
    @control.transition_goal_lifecycle(
      @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalNeedsInput,
      ),
      @control.GoalTransition::CommitGoalSuccess(
        @control.FinalizationId("final-1"),
      ),
    ) {
    Err(error) =>
      assert_true(error.message().contains("GoalActive(GoalRunning)"))
    Ok(_) => fail("NeedsInput Goal succeeded")
  }
}

///|
test "Goal cancellation requires cutoff then summary" {
  let active = @control.GoalLifecycle::GoalActive(
    @control.GoalActiveCondition::GoalRecoveryUncertain,
  )
  let canceling = @control.transition_goal_lifecycle(
    active,
    @control.GoalTransition::RequestGoalCancellation(
      @control.EventSequence(42L),
    ),
  )
  match canceling {
    Ok(state) =>
      match
        @control.transition_goal_lifecycle(
          state,
          @control.GoalTransition::CommitGoalCancellation(
            @control.CancellationSummaryId("cancel-1"),
          ),
        ) {
        Ok(
          @control.GoalLifecycle::GoalCanceled(
            @control.CancellationSummaryId(id)
          )
        ) => assert_eq(id, "cancel-1")
        Ok(_) => fail("Goal committed the wrong cancellation state")
        Err(error) => fail(error.message())
      }
    Err(error) => fail(error.message())
  }
}

///|
test "Part cannot skip passive verification and audit gates" {
  let candidate = @control.CandidateId("candidate-1")
  match
    @control.transition_part_lifecycle(
      @control.PartLifecycle::PartCandidate(candidate),
      @control.PartTransition::BeginPartPromotion(candidate),
    ) {
    Err(error) => assert_true(error.message().contains("not legal"))
    Ok(_) => fail("candidate skipped verification and audit")
  }
  match
    @control.transition_part_lifecycle(
      @control.PartLifecycle::PartVerified(
        candidate,
        @control.Digest("verification-set"),
      ),
      @control.PartTransition::BeginPartPromotion(candidate),
    ) {
    Err(error) => assert_true(error.message().contains("not legal"))
    Ok(_) => fail("verified candidate skipped audit")
  }
}

///|
test "Part progression binds verification audit and promotion to one candidate" {
  let candidate = @control.CandidateId("candidate-1")
  let stale = @control.CandidateId("candidate-old")
  match
    @control.transition_part_lifecycle(
      @control.PartLifecycle::PartCandidate(candidate),
      @control.PartTransition::RecordPartVerification(
        stale,
        @control.Digest("verification-set"),
      ),
    ) {
    Err(error) => assert_true(error.message().contains("stale"))
    Ok(_) => fail("stale verification advanced Part")
  }
  let verified = @control.transition_part_lifecycle(
    @control.PartLifecycle::PartCandidate(candidate),
    @control.PartTransition::RecordPartVerification(
      candidate,
      @control.Digest("verification-set"),
    ),
  )
  match verified {
    Ok(state) => {
      let audited = @control.transition_part_lifecycle(
        state,
        @control.PartTransition::RecordPartAudit(
          candidate,
          @control.ReceiptId("audit-receipt"),
        ),
      )
      match audited {
        Ok(state) =>
          match
            @control.transition_part_lifecycle(
              state,
              @control.PartTransition::BeginPartPromotion(candidate),
            ) {
            Ok(
              @control.PartLifecycle::PartPromoting(
                @control.CandidateId(id),
                @control.Digest(verification_digest),
                @control.ReceiptId(audit_receipt_id)
              )
            ) => {
              assert_eq(id, "candidate-1")
              assert_eq(verification_digest, "verification-set")
              assert_eq(audit_receipt_id, "audit-receipt")
            }
            Ok(_) => fail("Part committed the wrong promotion state")
            Err(error) => fail(error.message())
          }
        Err(error) => fail(error.message())
      }
    }
    Err(error) => fail(error.message())
  }
}

///|
test "Take transitions reject stale fencing epochs" {
  match
    @control.transition_take(
      test_take(),
      @control.TakeTransition::StartTake(@control.FencingEpoch(2L)),
    ) {
    Err(error) => assert_true(error.message().contains("stale fencing epoch"))
    Ok(_) => fail("stale fencing epoch started Take")
  }
}

///|
test "Take records one result and one terminal disposition" {
  let epoch = @control.FencingEpoch(1L)
  let running = match
    @control.transition_take(
      test_take(),
      @control.TakeTransition::StartTake(epoch),
    ) {
    Ok(take) => take
    Err(error) => fail(error.message())
  }
  let recorded = match
    @control.transition_take(
      running,
      @control.TakeTransition::RecordTakeResult(
        epoch,
        @control.Digest("result-digest"),
      ),
    ) {
    Ok(take) => take
    Err(error) => fail(error.message())
  }
  let terminal = match
    @control.transition_take(
      recorded,
      @control.TakeTransition::FinishTake(
        epoch,
        @control.TakeTerminalDisposition::TakeSucceeded,
      ),
    ) {
    Ok(take) => take
    Err(error) => fail(error.message())
  }
  match terminal.lifecycle {
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeSucceeded
    ) => ()
    _ => fail("Take committed the wrong terminal disposition")
  }
  match
    @control.transition_take(
      terminal,
      @control.TakeTransition::FinishTake(
        epoch,
        @control.TakeTerminalDisposition::TakeInterrupted,
      ),
    ) {
    Err(error) => assert_true(error.message().contains("already committed"))
    Ok(_) => fail("terminal Take accepted a second disposition")
  }
}
