///|
async fn server_delivery_test_sleep(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
fn server_delivery_test_command_name(cmd : @workspace.Command) -> String {
  let mut text = cmd.program
  for arg in cmd.args {
    text = text + " " + arg
  }
  text
}

///|
async fn server_delivery_test_runner(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let command = if cmds.length() == 0 {
    "run_sequence []"
  } else {
    server_delivery_test_command_name(cmds[0])
  }
  abort(@exec.hermetic_exec_violation_message(command))
}

///|
async fn server_delivery_test_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  abort(
    @exec.hermetic_exec_violation_message(
      server_delivery_test_command_name(cmd),
    ),
  )
}

///|
async fn server_delivery_test_hook_capture(
  _hook_path : String,
  _stdin_body : String,
  _cwd : String?,
) -> (Int, String) {
  @async.sleep(0)
  (0, "")
}

///|
fn server_delivery_test_path_entry_exists(_path : String) -> Bool {
  false
}

///|
fn server_delivery_test_read_file(_path : String) -> String {
  ""
}

///|
async fn ServerState::replay_pending_outbox_with_test(
  self : ServerState,
  now : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = server_delivery_test_runner,
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
  runner? : async (Array[@workspace.Command]) -> Array[Int] = server_delivery_test_runner,
  capture? : async (@workspace.Command) -> (Int, String) = server_delivery_test_capture,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = server_delivery_test_capture,
  hook_capture? : async (String, String, String?) -> (Int, String) = server_delivery_test_hook_capture,
) -> Unit {
  self.refresh_pr_with(
    pr_number,
    now,
    timeout,
    poll,
    hook_capture,
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
  runner? : async (Array[@workspace.Command]) -> Array[Int] = server_delivery_test_runner,
  capture? : async (@workspace.Command) -> (Int, String) = server_delivery_test_capture,
  automerge_capture? : async (@workspace.Command) -> (Int, String) = server_delivery_test_capture,
  git_pull_capture? : async (@workspace.Command) -> (Int, String) = server_delivery_test_capture,
  hook_capture? : async (String, String, String?) -> (Int, String) = server_delivery_test_hook_capture,
  audit_receipt_exists? : (String) -> Bool = server_delivery_test_path_entry_exists,
  audit_receipt_read? : (String) -> String = server_delivery_test_read_file,
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
