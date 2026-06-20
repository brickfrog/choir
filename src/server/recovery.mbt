///|
pub fn make_recovery_provider() -> @runtime.RecoveryProvider {
  @runtime.make_shell_recovery_provider(@exec.capture_stdout_with_cwd, agent_process_alive=async fn(
    project_dir,
    agent_id,
  ) {
    @async.sleep(0)
    @exec.agent_recorded_process_alive(project_dir, agent_id)
  })
}

///|
/// Hermetic RecoveryProvider for tests: every closure is a no-op stub that
/// returns empty/None without forking a subprocess. Use this instead of
/// `make_recovery_provider()` in tests so the suite never spawns real
/// `gh pr list`, `git ls-remote`, or `zellij list-sessions` against the host
/// environment. Production code (server boot, /reload) keeps the shell-backed
/// provider; only tests opt into the hermetic flavor.
pub fn make_hermetic_recovery_provider() -> @runtime.RecoveryProvider {
  {
    zellij_live: async fn(_dir, _session) {
      @async.sleep(0)
      { tabs: [], panes: [] }
    },
    agent_process_alive: async fn(_dir, _workspace) {
      @async.sleep(0)
      false
    },
    open_prs: async fn(_dir) {
      @async.sleep(0)
      []
    },
    find_prs_by_head: async fn(_dir, _branch) {
      @async.sleep(0)
      []
    },
    find_prs_by_head_any: async fn(_dir, _branch) {
      @async.sleep(0)
      []
    },
    find_pr_by_number: async fn(_dir, _pr_number) {
      @async.sleep(0)
      None
    },
    list_agent_containers: async fn(_dir) {
      @async.sleep(0)
      []
    },
    list_agents_in_container: async fn(_dir, _container) {
      @async.sleep(0)
      []
    },
    read_agent_config: async fn(_dir, _container, _slug) {
      @async.sleep(0)
      ""
    },
    get_agent_relative_workspace: fn(_container, _slug) { "" },
    list_lifecycle_ids: async fn(_dir) {
      @async.sleep(0)
      []
    },
    read_lifecycle_content: async fn(_dir, _id) {
      @async.sleep(0)
      ""
    },
    read_poller_state: async fn(_dir) {
      @async.sleep(0)
      []
    },
    write_poller_state: async fn(_dir, _tracked) { @async.sleep(0) },
    gh_poll_pr: async fn(_pr, _skip) {
      @async.sleep(0)
      (
        false,
        @poller.ReviewState::None_,
        "",
        @poller.CiRollupStatus::Unknown,
        "",
        false,
        false,
        @poller.Mergeable::Unknown,
        @poller.MergeStateStatus::Unknown,
        None,
      )
    },
  }
}

///|
pub async fn recover_state(
  state : ServerState,
  session : String,
  input : @runtime.RecoveryReconcileInput,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = async fn(cmds) {
    @async.sleep(0)
    let codes : Array[Int] = []
    for _ in cmds {
      codes.push(0)
    }
    codes
  },
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
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
          agent_id,
          pr_number,
          branch,
          parent_branch,
          pr_url,
          @exec.run_sequence,
          notify_parent=false,
        )
      @runtime.RecoveryAction::FinalizeOfflineAgent(agent_id~) =>
        state.finalize_recovered_offline_agent(agent_id)
      @runtime.RecoveryAction::ReapStaleLifecycle(agent_id~) => {
        state.interpret_teardown_effects(
          [ClearRuntimeTracking(agent_id)],
          runner,
          kill_pgid~,
        )
        if @phase.delete_lifecycle(state.config.project_dir, agent_id) {
          @moontrace.debug("reaped stale lifecycle", fields=[
            @moontrace.field("agent_id", agent_id),
          ])
        } else {
          @moontrace.warn(
            "reap stale lifecycle failed: delete_lifecycle returned false",
            fields=[@moontrace.field("agent_id", agent_id)],
          )
        }
      }
    }
  }

  state.persist_recovered_poller_state()
}
