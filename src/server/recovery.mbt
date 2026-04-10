///|
pub fn make_recovery_provider() -> @runtime.RecoveryProvider {
  @runtime.make_shell_recovery_provider(@exec.capture_stdout_with_cwd)
}

///|
pub async fn recover_state(
  state : ServerState,
  session : String,
  input : @runtime.RecoveryReconcileInput,
) -> Unit {
  let plan = @runtime.plan_recovery(session, input)

  for action in plan.actions {
    match action {
      @runtime.RecoveryAction::RegisterAgent(agent, alive) =>
        state.apply_recovered_agent(agent, alive)
      @runtime.RecoveryAction::RestorePRTracking(tracked) =>
        state.restore_recovered_pr_tracking(tracked)
      @runtime.RecoveryAction::TrackNewPR(
        pr_number~,
        agent_id~,
        branch~,
        parent_branch~,
        pr_url~,
        review~,
        review_bodies~,
        sha~,
        ci_rollup~,
        copilot_issue_comment_seen~,
        created_at~
      ) =>
        state.track_recovered_pr(
          pr_number, agent_id, branch, parent_branch, pr_url, created_at, review,
          review_bodies, sha, ci_rollup, copilot_issue_comment_seen,
        )
      @runtime.RecoveryAction::SyncLifecycle(agent_id~, pr~, review~) =>
        state.sync_recovered_pr_lifecycle(agent_id, pr, review)
      @runtime.RecoveryAction::FinalizeMergedAgent(
        agent_id~,
        pr_number~,
        branch~,
        parent_branch~,
        pr_url~
      ) =>
        state.reconcile_external_merge_with_runner(
          agent_id, pr_number, branch, parent_branch, pr_url, @exec.run_sequence,
        )
      @runtime.RecoveryAction::FinalizeOfflineAgent(agent_id~) =>
        state.finalize_recovered_offline_agent(agent_id)
    }
  }

  state.persist_recovered_poller_state()
}
