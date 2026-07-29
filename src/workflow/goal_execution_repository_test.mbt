///|
test "Goal execution states have an exhaustive schedulability projection" {
  let schedulable = @storage.StateRecordScheduleClass::StateRecordSchedulable
  let terminal = @storage.StateRecordScheduleClass::StateRecordNotSchedulable
  for
    state in [
      @workflow.GoalExecutionState::GoalExecutionQueued,
      @workflow.GoalExecutionState::GoalExecutionRunning,
      @workflow.GoalExecutionState::GoalExecutionAssuring,
      @workflow.GoalExecutionState::GoalExecutionAssured,
      @workflow.GoalExecutionState::GoalExecutionBlocked,
      @workflow.GoalExecutionState::GoalExecutionCanceling,
    ] {
    assert_eq(@workflow.goal_execution_schedule_class(state), schedulable)
  }
  for
    state in [
      @workflow.GoalExecutionState::GoalExecutionPaused,
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
      @workflow.GoalExecutionState::GoalExecutionCanceled,
    ] {
    assert_eq(@workflow.goal_execution_schedule_class(state), terminal)
  }
}
