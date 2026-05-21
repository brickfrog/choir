///|
async fn server_delivery_test_sleep(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
async fn ServerState::capture_audit_on_file_pr_report_test(
  self : ServerState,
  agent_id : String,
  report : @tools.AuditOnFilePrReport,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> Unit {
  self.capture_audit_on_file_pr_report(
    agent_id,
    report,
    runner~,
    capture~,
    sleep_fn=server_delivery_test_sleep,
  )
}

///|
async fn ServerState::replay_pending_outbox_with_test(
  self : ServerState,
  now : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  self.replay_pending_outbox_with(
    now,
    runner~,
    sleep_fn=server_delivery_test_sleep,
  )
}

///|
async fn ServerState::refresh_pr_with_test(
  self : ServerState,
  pr_number : Int,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
    @poller.Mergeable,
    @poller.MergeStateStatus,
    Int64?,
  ),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
) -> Unit {
  self.refresh_pr_with(
    pr_number,
    now,
    timeout,
    poll,
    runner~,
    capture~,
    automerge_capture~,
    sleep_fn=server_delivery_test_sleep,
  )
}

///|
async fn ServerState::process_poller_tick_with_test(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
    @poller.Mergeable,
    @poller.MergeStateStatus,
    Int64?,
  ),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  git_pull_capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
  audit_receipt_exists? : (String) -> Bool = @exec.path_entry_exists,
  audit_receipt_read? : (String) -> String = @exec.read_file,
  git_state_capture? : async (
    String,
    async (@workspace.Command) -> (Int, String),
  ) -> ParentWorktreeGitState? = async fn(
    _project_dir : String,
    _capture : async (@workspace.Command) -> (Int, String),
  ) {
    @async.sleep(0)
    None
  },
  git_pull_runner? : async (String, async (@workspace.Command) -> (Int, String)) -> Bool = async fn(
    _project_dir : String,
    _capture : async (@workspace.Command) -> (Int, String),
  ) {
    @async.sleep(0)
    false
  },
) -> Unit {
  self.process_poller_tick_with(
    now,
    timeout,
    poll,
    runner~,
    capture~,
    automerge_capture~,
    git_pull_capture~,
    hook_capture~,
    audit_receipt_exists~,
    audit_receipt_read~,
    git_state_capture~,
    git_pull_runner~,
    sleep_fn=server_delivery_test_sleep,
  )
}
