///|
enum NativeGoalPublicationRemoteIdentity {
  NativeGoalPublicationRemoteAvailable(@workflow.RemoteRepositoryId)
  NativeGoalPublicationRemoteUnavailable
} derive(Debug, Eq)

///|
fn native_goal_remote_git_environment(
  environment : Map[String, String],
  getenv? : (String) -> String? = @sys.getenv,
) -> Map[String, String] {
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_ATTR_NOSYSTEM"] = "1"
  environment["XDG_CONFIG_HOME"] = "/nonexistent"
  environment["GIT_TERMINAL_PROMPT"] = "0"
  match getenv("HOME") {
    Some(value) if value != "" && !value.contains("\u{00}") =>
      environment["HOME"] = value
    _ => ()
  }
  match getenv("SSH_AUTH_SOCK") {
    Some(value) if value != "" && !value.contains("\u{00}") =>
      environment["SSH_AUTH_SOCK"] = value
    _ => ()
  }
  environment
}

///|
priv enum NativeGoalRemoteGitCapture {
  NativeGoalRemoteGitCompleted(Int, String)
  NativeGoalRemoteGitInterrupted(String)
  NativeGoalRemoteGitTimedOut(String)
  NativeGoalRemoteGitOutputExceeded(String)
}

///|
let native_goal_remote_git_output_limit_bytes : Int = 1024 * 1024

///|
let native_goal_remote_probe_timeout_ms : Int = 30000

///|
let native_goal_remote_push_timeout_ms : Int = 300000

///|
async fn capture_native_goal_remote_git_with_timeout(
  repository_root : String,
  arguments : Array[String],
  timeout_ms : Int,
) -> Result[NativeGoalRemoteGitCapture, @types.ChoirError] {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_goal_execution_error("remote Git input pipe failed"))
  }
  stdin_write.close()
  let captured = match
    @process_host.capture_bounded_process(
      "/usr/bin/git",
      arguments,
      native_goal_remote_git_environment(
        @git_host.native_git_environment(false),
      ),
      stdin_read,
      repository_root,
      timeout_ms,
      native_goal_remote_git_output_limit_bytes,
      fn() { false },
    ) {
    Ok(value) => value
    Err(_) =>
      return Err(native_goal_execution_error("remote Git process failed"))
  }
  Ok(
    match captured {
      @process_host.NativeProcessCompleted(code, output) =>
        NativeGoalRemoteGitCompleted(code, output)
      @process_host.NativeProcessInterrupted(detail) =>
        NativeGoalRemoteGitInterrupted(detail)
      @process_host.NativeProcessTimedOut(detail) =>
        NativeGoalRemoteGitTimedOut(detail)
      @process_host.NativeProcessOutputExceeded(detail) =>
        NativeGoalRemoteGitOutputExceeded(detail)
    },
  )
}

///|
async fn capture_native_goal_remote_probe(
  repository_root : String,
  arguments : Array[String],
) -> Result[NativeGoalRemoteGitCapture, @types.ChoirError] {
  capture_native_goal_remote_git_with_timeout(
    repository_root, arguments, native_goal_remote_probe_timeout_ms,
  )
}

///|
async fn capture_native_goal_remote_push(
  repository_root : String,
  arguments : Array[String],
) -> Result[NativeGoalRemoteGitCapture, @types.ChoirError] {
  capture_native_goal_remote_git_with_timeout(
    repository_root, arguments, native_goal_remote_push_timeout_ms,
  )
}

///|
test "remote Git carries only explicit SSH authentication inputs" {
  let environment = native_goal_remote_git_environment(
    {
      "PATH": "/usr/bin:/bin",
      "HOME": "/nonexistent",
      "LC_ALL": "C",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_TERMINAL_PROMPT": "0",
    },
    getenv=fn(name) {
      match name {
        "HOME" => Some("/home/provider")
        "SSH_AUTH_SOCK" => Some("/run/user/1000/ssh-agent.socket")
        "GIT_SSH_COMMAND" => Some("untrusted ssh wrapper")
        _ => None
      }
    },
  )
  assert_eq(environment["PATH"], "/usr/bin:/bin")
  assert_eq(environment["HOME"], "/home/provider")
  assert_eq(environment["SSH_AUTH_SOCK"], "/run/user/1000/ssh-agent.socket")
  assert_eq(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
  assert_eq(environment["GIT_CONFIG_NOSYSTEM"], "1")
  assert_eq(environment["GIT_ATTR_NOSYSTEM"], "1")
  assert_eq(environment["XDG_CONFIG_HOME"], "/nonexistent")
  assert_eq(environment["GIT_TERMINAL_PROMPT"], "0")
  assert_false(environment.contains("GIT_SSH_COMMAND"))
}

///|
test "remote Git remains sterile when SSH inputs are unavailable" {
  let environment = native_goal_remote_git_environment(
    {
      "PATH": "/usr/bin:/bin",
      "HOME": "/nonexistent",
      "LC_ALL": "C",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_TERMINAL_PROMPT": "0",
    },
    getenv=fn(name) {
      match name {
        "HOME" => Some("")
        "SSH_AUTH_SOCK" => Some("/tmp/agent\u{00}ignored")
        _ => None
      }
    },
  )
  assert_eq(environment["HOME"], "/nonexistent")
  assert_false(environment.contains("SSH_AUTH_SOCK"))
}

///|
priv enum NativeRemoteBranchProbeFailureKind {
  RemoteProbeProcessFailure
  RemoteProbeExitFailure
  RemoteProbeInterrupted
  RemoteProbeTimedOut
  RemoteProbeOutputExceeded
  RemoteProbeMalformedOutput
  RemoteProbeAmbiguousOutput
} derive(Debug, Eq, ToJson)

///|
priv struct NativeRemoteBranchProbe {
  observation : @workflow.RemoteBranchObservation
  failure_kind : NativeRemoteBranchProbeFailureKind?
  exit_code : Int?
  detail : String
  attempts : Int
}

///|
fn native_remote_branch_probe_to_json(probe : NativeRemoteBranchProbe) -> Json {
  {
    "observation": probe.observation.to_json(),
    "failure_kind": probe.failure_kind.to_json(),
    "exit_code": probe.exit_code.to_json(),
    "detail": probe.detail.to_json(),
    "attempts": probe.attempts.to_json(),
  }.to_json()
}

///|
fn native_remote_branch_probe_detail(value : String) -> String {
  // Git quotes the remote it failed against, and a token-in-URL remote carries
  // the credential into this text. It is persisted to disk and surfaced in
  // diagnostics, so the credential is removed before either happens.
  let trimmed = @control.redact_url_credentials(value.trim().to_owned())
  let bytes = @utf8.encode(trimmed)
  if bytes.length() <= 4096 {
    trimmed
  } else {
    @utf8.decode_lossy(bytes[:4096]) + "\n[truncated]"
  }
}

///|
fn native_goal_publication_probe_path(
  project_dir : String,
  goal_id : @control.GoalId,
) -> String {
  let digest = @storage.digest_text(
    @storage.artifact_digest(
      @utf8.encode("choir.publication-observation.v1\u{00}" + goal_id.0),
    ),
  )
  project_dir + "/.choir/state/observations/publication/" + digest + ".json"
}

///|
fn persist_native_remote_branch_probe_diagnostic(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
  probe : NativeRemoteBranchProbe,
) -> Unit {
  let path = native_goal_publication_probe_path(repository.root, intent.goal_id)
  if probe.observation
    is @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain {
    let parent = repository.root + "/.choir/state/observations/publication"
    if !@sys.create_dir_all(parent) ||
      !@sys.write_file_atomic(
        path,
        native_remote_branch_probe_to_json(probe).stringify(indent=2) + "\n",
      ) {
      @sys.write_stderr(
        "choir publication: failed to persist remote observation diagnostic\n",
      )
    }
  } else if @sys.path_entry_exists(path) {
    ignore(@sys.delete_file_sync(path))
  }
}

///|
pub fn native_goal_publication_probe_diagnostic(
  project_dir : String,
  goal_id : @control.GoalId,
) -> Json? {
  let path = native_goal_publication_probe_path(project_dir, goal_id)
  if !@sys.path_entry_exists(path) {
    return None
  }
  Some(@json.parse(@sys.read_file(path))) catch {
    _ => None
  }
}

///|
async fn native_goal_publication_remote_identity(
  repository : NativeGoalRepositoryIdentity,
  remote_name : @workflow.RemoteName,
) -> Result[NativeGoalPublicationRemoteIdentity, @types.ChoirError] {
  let captured = match
    capture_native_goal_git(repository.root, [
      "remote",
      "get-url",
      remote_name.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let url = captured.output.trim().to_owned()
  if captured.exit_code != 0 || url == "" || url.contains("\u{00}") {
    return Ok(NativeGoalPublicationRemoteUnavailable)
  }
  Ok(
    NativeGoalPublicationRemoteAvailable(
      @workflow.RemoteRepositoryId(
        "sha256:" +
        @storage.digest_text(
          @storage.artifact_digest(
            @utf8.encode("choir.remote-repository.v1\u{00}" + url),
          ),
        ),
      ),
    ),
  )
}

///|
async fn native_remote_branch_probe_once(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
  capture : async (String, Array[String]) -> Result[
    NativeGoalRemoteGitCapture,
    @types.ChoirError,
  ],
) -> NativeRemoteBranchProbe {
  let captured_outcome = match
    capture(repository.root, [
      "ls-remote",
      "--refs",
      intent.remote_name.0,
      intent.remote_head_ref.0,
    ]) {
    Ok(value) => value
    Err(error) =>
      return {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeProcessFailure),
        exit_code: None,
        detail: native_remote_branch_probe_detail(error.message()),
        attempts: 1,
      }
  }
  let (exit_code, output) = match captured_outcome {
    NativeGoalRemoteGitCompleted(exit_code, output) => (exit_code, output)
    NativeGoalRemoteGitInterrupted(detail) =>
      return {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeInterrupted),
        exit_code: None,
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      }
    NativeGoalRemoteGitTimedOut(detail) =>
      return {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeTimedOut),
        exit_code: None,
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      }
    NativeGoalRemoteGitOutputExceeded(detail) =>
      return {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeOutputExceeded),
        exit_code: None,
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      }
  }
  if exit_code != 0 {
    return {
      observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
      failure_kind: Some(RemoteProbeExitFailure),
      exit_code: Some(exit_code),
      detail: native_remote_branch_probe_detail(output),
      attempts: 1,
    }
  }
  let observed : Array[@control.GitOid] = []
  for raw in output.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let fields = line.split("\t").to_array()
    if fields.length() != 2 || fields[1] != intent.remote_head_ref.0 {
      return {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeMalformedOutput),
        exit_code: Some(exit_code),
        detail: native_remote_branch_probe_detail(output),
        attempts: 1,
      }
    }
    let oid = fields[0].trim().to_owned()
    if oid.length() != intent.sealed_head_oid.0.length() {
      return {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeMalformedOutput),
        exit_code: Some(exit_code),
        detail: native_remote_branch_probe_detail(output),
        attempts: 1,
      }
    }
    observed.push(@control.GitOid(oid))
  }
  match observed {
    [] =>
      {
        observation: @workflow.RemoteBranchObservation::RemoteBranchAbsent,
        failure_kind: None,
        exit_code: Some(exit_code),
        detail: "",
        attempts: 1,
      }
    [oid] =>
      {
        observation: @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
        failure_kind: None,
        exit_code: Some(exit_code),
        detail: "",
        attempts: 1,
      }
    _ =>
      {
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeAmbiguousOutput),
        exit_code: Some(exit_code),
        detail: native_remote_branch_probe_detail(output),
        attempts: 1,
      }
  }
}

///|
async fn native_remote_branch_probe(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
  capture : async (String, Array[String]) -> Result[
    NativeGoalRemoteGitCapture,
    @types.ChoirError,
  ],
  wait? : async (Int) -> Unit = async fn(milliseconds) {
    @async.sleep(milliseconds)
  },
  persist? : (
    NativeGoalRepositoryIdentity,
    @workflow.BranchPublicationIntent,
    NativeRemoteBranchProbe,
  ) -> Unit = persist_native_remote_branch_probe_diagnostic,
) -> NativeRemoteBranchProbe {
  let mut probe = native_remote_branch_probe_once(repository, intent, capture)
  while probe.observation
        is @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain &&
        probe.attempts < 3 {
    wait(if probe.attempts == 1 { 500 } else { 1500 })
    let next = native_remote_branch_probe_once(repository, intent, capture)
    probe = { ..next, attempts: probe.attempts + 1 }
  }
  persist(repository, intent, probe)
  probe
}

///|
async fn native_remote_branch_observation(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
) -> @workflow.RemoteBranchObservation {
  native_remote_branch_probe(
    repository, intent, capture_native_goal_remote_probe,
  ).observation
}

///|
async test "publication preflight retries read-only observation with backoff" {
  let intent : @workflow.BranchPublicationIntent = {
    id: @workflow.BranchPublicationIntentId("probe-test"),
    goal_id: @control.GoalId("goal-probe-test"),
    canonical_repository_id: @workflow.RemoteRepositoryId("remote-test"),
    remote_name: @workflow.RemoteName("origin"),
    remote_head_ref: @workflow.GitRefName("refs/heads/choir/goals/probe-test"),
    expected_prior_remote_oid: None,
    sealed_head_oid: @control.GitOid("1111111111111111111111111111111111111111"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-probe-test"),
    goal_branch_seal_digest: @control.Digest("seal-digest"),
    idempotency_key: "probe-test",
    state: @workflow.BranchPublicationState::BranchPublicationPlanned,
  }
  let repository : NativeGoalRepositoryIdentity = {
    root: "/unused",
    git_directory: "/unused/.git",
    object_directory: "/unused/.git/objects",
  }
  let mut calls = 0
  let waits : Array[Int] = []
  let probe = native_remote_branch_probe(
    repository,
    intent,
    async fn(_, _) {
      @async.sleep(0)
      calls = calls + 1
      if calls < 3 {
        Ok(
          NativeGoalRemoteGitCompleted(
            128, "ssh: Could not resolve hostname github.com",
          ),
        )
      } else {
        Ok(NativeGoalRemoteGitCompleted(0, ""))
      }
    },
    wait=async fn(milliseconds) {
      @async.sleep(0)
      waits.push(milliseconds)
    },
    persist=fn(_, _, _) { () },
  )
  assert_eq(calls, 3)
  assert_eq(waits, [500, 1500])
  assert_eq(probe.attempts, 3)
  assert_eq(
    probe.observation,
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
  )
  assert_eq(probe.failure_kind, None)
}

///|
async test "publication preflight retains final failure diagnostics" {
  let intent : @workflow.BranchPublicationIntent = {
    id: @workflow.BranchPublicationIntentId("probe-failure-test"),
    goal_id: @control.GoalId("goal-probe-failure-test"),
    canonical_repository_id: @workflow.RemoteRepositoryId("remote-test"),
    remote_name: @workflow.RemoteName("origin"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/probe-failure-test",
    ),
    expected_prior_remote_oid: None,
    sealed_head_oid: @control.GitOid("2222222222222222222222222222222222222222"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-probe-failure-test"),
    goal_branch_seal_digest: @control.Digest("seal-digest"),
    idempotency_key: "probe-failure-test",
    state: @workflow.BranchPublicationState::BranchPublicationPlanned,
  }
  let repository : NativeGoalRepositoryIdentity = {
    root: "/unused",
    git_directory: "/unused/.git",
    object_directory: "/unused/.git/objects",
  }
  let probe = native_remote_branch_probe(
    repository,
    intent,
    async fn(_, _) {
      @async.sleep(0)
      Ok(NativeGoalRemoteGitCompleted(128, "Permission denied (publickey)."))
    },
    wait=async fn(_) { @async.sleep(0) },
    persist=fn(_, _, _) { () },
  )
  assert_eq(probe.attempts, 3)
  assert_eq(probe.failure_kind, Some(RemoteProbeExitFailure))
  assert_eq(probe.exit_code, Some(128))
  assert_true(probe.detail.contains("Permission denied"))
  assert_eq(
    probe.observation,
    @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
  )
}

///|
async test "publication preflight types bounded process failures" {
  let intent : @workflow.BranchPublicationIntent = {
    id: @workflow.BranchPublicationIntentId("probe-bounds-test"),
    goal_id: @control.GoalId("goal-probe-bounds-test"),
    canonical_repository_id: @workflow.RemoteRepositoryId("remote-test"),
    remote_name: @workflow.RemoteName("origin"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/probe-bounds-test",
    ),
    expected_prior_remote_oid: None,
    sealed_head_oid: @control.GitOid("3333333333333333333333333333333333333333"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-probe-bounds-test"),
    goal_branch_seal_digest: @control.Digest("seal-digest"),
    idempotency_key: "probe-bounds-test",
    state: @workflow.BranchPublicationState::BranchPublicationPlanned,
  }
  let repository : NativeGoalRepositoryIdentity = {
    root: "/unused",
    git_directory: "/unused/.git",
    object_directory: "/unused/.git/objects",
  }
  let timed_out = native_remote_branch_probe_once(repository, intent, async fn(
    _,
    _,
  ) {
    @async.sleep(0)
    Ok(NativeGoalRemoteGitTimedOut("https://secret@github.com/x/y"))
  })
  assert_eq(timed_out.failure_kind, Some(RemoteProbeTimedOut))
  assert_false(timed_out.detail.contains("secret"))
  let exceeded = native_remote_branch_probe_once(repository, intent, async fn(
    _,
    _,
  ) {
    @async.sleep(0)
    Ok(NativeGoalRemoteGitOutputExceeded("bounded tail"))
  })
  assert_eq(exceeded.failure_kind, Some(RemoteProbeOutputExceeded))
  let interrupted = native_remote_branch_probe_once(repository, intent, async fn(
    _,
    _,
  ) {
    @async.sleep(0)
    Ok(NativeGoalRemoteGitInterrupted("bounded tail"))
  })
  assert_eq(interrupted.failure_kind, Some(RemoteProbeInterrupted))
  assert_eq(native_goal_remote_git_output_limit_bytes, 1048576)
  assert_eq(native_goal_remote_probe_timeout_ms, 30000)
  assert_eq(native_goal_remote_push_timeout_ms, 300000)
}

///|
test "publication push failures retain mutation uncertainty" {
  assert_true(
    native_goal_publication_push_probe(
      Ok(NativeGoalRemoteGitCompleted(0, "ok")),
    )
    is None,
  )
  guard native_goal_publication_push_probe(
      Ok(NativeGoalRemoteGitCompleted(1, "rejected")),
    )
    is Some(rejected) else {
    fail("nonzero push was treated as successful")
  }
  assert_eq(rejected.failure_kind, Some(RemoteProbeExitFailure))
  guard native_goal_publication_push_probe(
      Ok(NativeGoalRemoteGitTimedOut("timed out")),
    )
    is Some(timed_out) else {
    fail("timed-out push was treated as successful")
  }
  assert_eq(timed_out.failure_kind, Some(RemoteProbeTimedOut))
  guard native_goal_publication_push_probe(
      Ok(NativeGoalRemoteGitOutputExceeded("too much")),
    )
    is Some(exceeded) else {
    fail("oversized push was treated as successful")
  }
  assert_eq(exceeded.failure_kind, Some(RemoteProbeOutputExceeded))
}

///|
async fn native_publication_prior_is_ancestor(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
  observation : @workflow.RemoteBranchObservation,
) -> Bool {
  guard observation is @workflow.RemoteBranchObservation::RemoteBranchAt(oid) &&
    intent.expected_prior_remote_oid == Some(oid) else {
    return false
  }
  match
    capture_native_goal_git(repository.root, [
      "merge-base",
      "--is-ancestor",
      oid.0,
      intent.sealed_head_oid.0,
    ]) {
    Ok(value) => value.exit_code == 0
    Err(_) => false
  }
}

///|
async fn publish_native_goal_ref(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
) -> Result[NativeGoalRemoteGitCapture, @types.ChoirError] {
  let expected_remote = match intent.expected_prior_remote_oid {
    Some(oid) => oid.0
    None => ""
  }
  let lease = "--force-with-lease=" +
    intent.remote_head_ref.0 +
    ":" +
    expected_remote
  // The exact prior OID is part of the remote mutation, closing the race
  // between preflight observation and push. Authorization separately proves
  // ancestry, so the lease never authorizes a non-fast-forward transition.
  capture_native_goal_remote_push(repository.root, [
    "-c",
    "core.hooksPath=/dev/null",
    "push",
    "--porcelain",
    "--no-verify",
    lease,
    intent.remote_name.0,
    intent.sealed_head_oid.0 + ":" + intent.remote_head_ref.0,
  ])
}

///|
fn native_goal_publication_push_probe(
  outcome : Result[NativeGoalRemoteGitCapture, @types.ChoirError],
) -> NativeRemoteBranchProbe? {
  match outcome {
    Ok(NativeGoalRemoteGitCompleted(0, _)) => None
    Ok(NativeGoalRemoteGitCompleted(code, detail)) =>
      Some({
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeExitFailure),
        exit_code: Some(code),
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      })
    Ok(NativeGoalRemoteGitInterrupted(detail)) =>
      Some({
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeInterrupted),
        exit_code: None,
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      })
    Ok(NativeGoalRemoteGitTimedOut(detail)) =>
      Some({
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeTimedOut),
        exit_code: None,
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      })
    Ok(NativeGoalRemoteGitOutputExceeded(detail)) =>
      Some({
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeOutputExceeded),
        exit_code: None,
        detail: native_remote_branch_probe_detail(detail),
        attempts: 1,
      })
    Err(error) =>
      Some({
        observation: @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
        failure_kind: Some(RemoteProbeProcessFailure),
        exit_code: None,
        detail: native_remote_branch_probe_detail(error.message()),
        attempts: 1,
      })
  }
}

///|
async fn native_goal_publication_observe_push(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
  outcome : Result[NativeGoalRemoteGitCapture, @types.ChoirError],
) -> @workflow.RemoteBranchObservation {
  match native_goal_publication_push_probe(outcome) {
    None => native_remote_branch_observation(repository, intent)
    Some(probe) => {
      persist_native_remote_branch_probe_diagnostic(repository, intent, probe)
      probe.observation
    }
  }
}

///|
fn native_goal_publication_transaction_completed(
  outcome : @storage.StateTransactionOutcome,
) -> Bool {
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost => true
    _ => false
  }
}

///|
fn persist_native_goal_publication_record(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  record : @workflow.GoalPublicationRecord,
  expected_store_version : Int?,
  fault_point? : @storage.StateStoreFaultPoint? = None,
) -> Result[@workflow.StoredGoalPublicationRecord?, @types.ChoirError] {
  let receipt = match
    @workflow.persist_goal_publication_record(repository, adapters, {
      record,
      expected_store_version,
      goal_precondition: @workflow.goal_execution_state_precondition(execution),
      fault_point,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.outcome {
    @workflow.GoalPublicationPersistenceOutcome::GoalPublicationGoalPreconditionConflict =>
      Ok(None)
    @workflow.GoalPublicationPersistenceOutcome::GoalPublicationPersistenceCompleted(
      outcome
    ) => {
      let observed = match
        @workflow.load_goal_publication_record(
          repository,
          adapters,
          execution.goal.id,
        ) {
        Ok(Some(value)) => value
        Ok(None) =>
          return Err(
            native_goal_execution_error("Goal publication record disappeared"),
          )
        Err(error) => return Err(error)
      }
      if observed.record == record &&
        (
          native_goal_publication_transaction_completed(outcome) ||
          outcome ==
          @storage.StateTransactionOutcome::StateTransactionVersionConflict
        ) {
        Ok(Some(observed))
      } else {
        Err(
          native_goal_execution_error("Goal publication persistence conflicted"),
        )
      }
    }
  }
}

///|
pub async fn advance_native_goal_publication(
  project_dir : String,
  goal_id : @control.GoalId,
  fault? : @workflow.GoalPublicationFaultPoint? = None,
) -> Result[@workflow.GoalPublicationTickOutcome, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let execution = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_goal_execution_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  if execution.state != @workflow.GoalExecutionState::GoalExecutionAssured {
    return Err(native_goal_execution_error("Goal is not assured"))
  }
  let assurance = match
    @workflow.load_goal_assurance_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_goal_execution_error("Goal assurance is absent"))
    Err(error) => return Err(error)
  }
  let git = match discover_native_goal_repository(project_dir, execution) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let local_identity = match native_goal_ref_identity(git, execution.goal_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard assurance.seal is Some(seal) else {
    return Err(native_goal_execution_error("Goal seal is absent"))
  }
  if local_identity.0 != seal.head_oid || local_identity.1 != seal.tree_oid {
    return Err(native_goal_execution_error("sealed Goal ref diverged"))
  }
  let remote_name = @workflow.RemoteName("origin")
  let remote_repository_id = match
    native_goal_publication_remote_identity(git, remote_name) {
    Ok(NativeGoalPublicationRemoteAvailable(value)) => value
    Ok(NativeGoalPublicationRemoteUnavailable) =>
      return Ok(
        @workflow.GoalPublicationTickOutcome::GoalPublicationRemoteUnavailable,
      )
    Err(error) => return Err(error)
  }
  let mut current = match
    @workflow.load_goal_publication_record(repository, adapters, goal_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut cycles = 0
  while cycles < 8 {
    cycles = cycles + 1
    match current {
      None => {
        let planned = match
          @workflow.initialize_goal_publication(
            execution,
            assurance,
            remote_repository_id,
            remote_name,
            execution.goal_ref,
            None,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        current = match
          persist_native_goal_publication_record(
            repository,
            adapters,
            execution,
            planned,
            None,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if fault ==
          Some(
            @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
          ) {
          return Err(native_goal_execution_error("injected publication fault"))
        }
      }
      Some(stored) =>
        match stored.record.intent.state {
          @workflow.BranchPublicationState::BranchPublicationPlanned
          | @workflow.BranchPublicationState::BranchPublicationPreflightUncertain => {
            let observation = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let authorized = match
              @workflow.authorize_goal_publication(
                stored.record,
                execution,
                assurance,
                local_identity.0,
                observation,
                native_publication_prior_is_ancestor(
                  git,
                  stored.record.intent,
                  observation,
                ),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if authorized == stored.record {
              return Ok(
                @workflow.GoalPublicationTickOutcome::GoalPublicationRecoveryUncertain,
              )
            }
            current = match
              persist_native_goal_publication_record(
                repository,
                adapters,
                execution,
                authorized,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if authorized.intent.state ==
              @workflow.BranchPublicationState::BranchPublicationPreflightUncertain {
              return Ok(
                @workflow.GoalPublicationTickOutcome::GoalPublicationPending,
              )
            }
            if authorized.intent.state ==
              @workflow.BranchPublicationState::BranchPublicationAuthorized &&
              fault ==
              Some(
                @workflow.GoalPublicationFaultPoint::PublicationAfterAuthorizedBeforeRemoteUpdate,
              ) {
              return Err(
                native_goal_execution_error("injected publication fault"),
              )
            }
          }
          @workflow.BranchPublicationState::BranchPublicationAuthorized => {
            let before = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let (after, origin, prior, mutated) = match before {
              @workflow.RemoteBranchObservation::RemoteBranchAt(oid) if oid ==
                stored.record.intent.sealed_head_oid =>
                (
                  before,
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                  Some(oid),
                  false,
                )
              @workflow.RemoteBranchObservation::RemoteBranchAbsent => {
                let push = publish_native_goal_ref(git, stored.record.intent)
                if fault ==
                  Some(
                    @workflow.GoalPublicationFaultPoint::PublicationAfterRemoteUpdateBeforeResponse,
                  ) {
                  return Err(
                    native_goal_execution_error("injected publication fault"),
                  )
                }
                (
                  native_goal_publication_observe_push(
                    git,
                    stored.record.intent,
                    push,
                  ),
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
                  None,
                  true,
                )
              }
              @workflow.RemoteBranchObservation::RemoteBranchAt(oid) if stored.record.intent.expected_prior_remote_oid ==
                Some(oid) => {
                let push = publish_native_goal_ref(git, stored.record.intent)
                if fault ==
                  Some(
                    @workflow.GoalPublicationFaultPoint::PublicationAfterRemoteUpdateBeforeResponse,
                  ) {
                  return Err(
                    native_goal_execution_error("injected publication fault"),
                  )
                }
                (
                  native_goal_publication_observe_push(
                    git,
                    stored.record.intent,
                    push,
                  ),
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
                  Some(oid),
                  true,
                )
              }
              _ =>
                (
                  before,
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                  None,
                  false,
                )
            }
            if mutated &&
              fault ==
              Some(
                @workflow.GoalPublicationFaultPoint::PublicationAfterResponseBeforeReceipt,
              ) {
              return Err(
                native_goal_execution_error("injected publication fault"),
              )
            }
            let observed = match
              @workflow.record_goal_publication_observation(
                stored.record,
                after,
                origin,
                prior,
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_publication_record(
                repository,
                adapters,
                execution,
                observed,
                Some(stored.state_record.version),
                fault_point=if observed.intent.state ==
                  @workflow.BranchPublicationState::BranchPublicationReceipted &&
                  fault ==
                  Some(
                    @workflow.GoalPublicationFaultPoint::PublicationDuringReceiptTransaction,
                  ) {
                  Some(@storage.StateStoreFaultPoint::StateAfterCommitBeforeAck)
                } else {
                  None
                },
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if observed.intent.state ==
              @workflow.BranchPublicationState::BranchPublicationReceipted &&
              fault ==
              Some(
                @workflow.GoalPublicationFaultPoint::PublicationDuringReceiptTransaction,
              ) {
              return Err(
                native_goal_execution_error("injected publication fault"),
              )
            }
          }
          @workflow.BranchPublicationState::BranchPublicationReceipted =>
            return Ok(
              @workflow.GoalPublicationTickOutcome::GoalPublicationComplete,
            )
          @workflow.BranchPublicationState::BranchPublicationDrift =>
            return Ok(
              @workflow.GoalPublicationTickOutcome::GoalPublicationDrifted,
            )
          @workflow.BranchPublicationState::BranchPublicationMutationUncertain => {
            let observation = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let reconciled = match
              @workflow.record_goal_publication_observation(
                stored.record,
                observation,
                @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                None,
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if reconciled == stored.record {
              return Ok(
                @workflow.GoalPublicationTickOutcome::GoalPublicationRecoveryUncertain,
              )
            }
            current = match
              persist_native_goal_publication_record(
                repository,
                adapters,
                execution,
                reconciled,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
          }
          @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation =>
            return Ok(
              @workflow.GoalPublicationTickOutcome::GoalPublicationPending,
            )
        }
    }
  } nobreak {
    Err(
      native_goal_execution_error("Goal publication exceeded its cycle bound"),
    )
  }
}

///|
async test "real exec integration: native Goal publication creates, adopts, and refuses remote drift" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-publication-" + @sys.get_pid().to_string()
  let remote = root + "-remote.git"
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
  if !@sys.create_dir_all(root) || !@sys.create_dir_all(remote) {
    fail("failed to create publication test roots")
  }
  let local_git = async fn(
    arguments : Array[String],
  ) -> @git_integration.NativeGitCapture {
    match capture_native_goal_git(root, arguments) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
  }
  let remote_git = @process.collect_output_merged(
    "/usr/bin/git",
    ["init", "--bare", "-q", remote],
    inherit_env=false,
  ) catch {
    _ => fail("failed to initialize bare remote")
  }
  if remote_git.0 != 0 || local_git(["init", "-q"]).exit_code != 0 {
    fail("failed to initialize publication repositories")
  }
  let tree = local_git(["hash-object", "-w", "-t", "tree", "/dev/null"])
  let base = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-m",
    "publication base",
  ])
  let middle = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-p",
    base.output.trim().to_owned(),
    "-m",
    "publication middle",
  ])
  let commit = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-p",
    middle.output.trim().to_owned(),
    "-m",
    "publication",
  ])
  if tree.exit_code != 0 ||
    base.exit_code != 0 ||
    middle.exit_code != 0 ||
    commit.exit_code != 0 {
    fail("failed to create publication commit")
  }
  let base_oid = @control.GitOid(base.output.trim().to_owned())
  let middle_oid = @control.GitOid(middle.output.trim().to_owned())
  let oid = @control.GitOid(commit.output.trim().to_owned())
  let repository : NativeGoalRepositoryIdentity = {
    root,
    git_directory: root + "/.git",
    object_directory: root + "/.git/objects",
  }
  guard native_goal_publication_remote_identity(
      repository,
      @workflow.RemoteName("origin"),
    )
    is Ok(NativeGoalPublicationRemoteUnavailable) else {
    fail("absent publication remote was not reported")
  }
  if local_git(["remote", "add", "origin", remote]).exit_code != 0 {
    fail("failed to add publication remote")
  }
  guard native_goal_publication_remote_identity(
      repository,
      @workflow.RemoteName("origin"),
    )
    is Ok(NativeGoalPublicationRemoteAvailable(_)) else {
    fail("publication remote identity remained unavailable")
  }
  let intent : @workflow.BranchPublicationIntent = {
    id: @workflow.BranchPublicationIntentId("publication-test"),
    goal_id: @control.GoalId("goal-publication-test"),
    canonical_repository_id: @workflow.RemoteRepositoryId("remote-test"),
    remote_name: @workflow.RemoteName("origin"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-test",
    ),
    expected_prior_remote_oid: None,
    sealed_head_oid: oid,
    goal_branch_seal_id: @control.GoalBranchSealId("seal-publication-test"),
    goal_branch_seal_digest: @control.Digest("seal-digest"),
    idempotency_key: "publication-test",
    state: @workflow.BranchPublicationState::BranchPublicationAuthorized,
  }
  let create_race_intent : @workflow.BranchPublicationIntent = {
    ..intent,
    id: @workflow.BranchPublicationIntentId("publication-create-race"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-create-race",
    ),
    idempotency_key: "publication-create-race",
  }
  let create_race = local_git([
    "push",
    "origin",
    middle_oid.0 + ":" + create_race_intent.remote_head_ref.0,
  ])
  if create_race.exit_code != 0 {
    fail("failed to install concurrent publication creation")
  }
  ignore(publish_native_goal_ref(repository, create_race_intent))
  assert_eq(
    native_remote_branch_observation(repository, create_race_intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(middle_oid),
  )
  let exact_update_intent : @workflow.BranchPublicationIntent = {
    ..intent,
    id: @workflow.BranchPublicationIntentId("publication-exact-update"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-exact-update",
    ),
    expected_prior_remote_oid: Some(base_oid),
    idempotency_key: "publication-exact-update",
  }
  let exact_prior = local_git([
    "push",
    "origin",
    base_oid.0 + ":" + exact_update_intent.remote_head_ref.0,
  ])
  if exact_prior.exit_code != 0 {
    fail("failed to install exact publication prior")
  }
  ignore(publish_native_goal_ref(repository, exact_update_intent))
  assert_eq(
    native_remote_branch_observation(repository, exact_update_intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
  )
  let update_race_intent : @workflow.BranchPublicationIntent = {
    ..intent,
    id: @workflow.BranchPublicationIntentId("publication-update-race"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-update-race",
    ),
    expected_prior_remote_oid: Some(base_oid),
    idempotency_key: "publication-update-race",
  }
  let raced_prior = local_git([
    "push",
    "origin",
    middle_oid.0 + ":" + update_race_intent.remote_head_ref.0,
  ])
  if raced_prior.exit_code != 0 {
    fail("failed to install concurrent publication update")
  }
  ignore(publish_native_goal_ref(repository, update_race_intent))
  assert_eq(
    native_remote_branch_observation(repository, update_race_intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(middle_oid),
  )
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
  )
  ignore(publish_native_goal_ref(repository, intent))
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
  )
  ignore(publish_native_goal_ref(repository, intent))
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
  )
  let other = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-m",
    "other",
  ])
  let drift = local_git([
    "push",
    "--force",
    "origin",
    other.output.trim().to_owned() + ":" + intent.remote_head_ref.0,
  ])
  if other.exit_code != 0 || drift.exit_code != 0 {
    fail("failed to install remote drift")
  }
  ignore(publish_native_goal_ref(repository, intent))
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(
      @control.GitOid(other.output.trim().to_owned()),
    ),
  )
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
}

///|
