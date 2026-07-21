///|
pub(all) struct NativePullRequestForgeAdapters {
  resolve_repository : async (String) -> Result[String, @types.ChoirError]
  lookup : async (String, String, @workflow.PullRequestIntent) -> @workflow.PullRequestLookupObservation
  create : async (
    String,
    String,
    @workflow.PullRequestIntent,
    @workflow.PullRequestDocument,
  ) -> Unit
}

///|
fn native_pull_request_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("native Goal pull request: " + detail)
}

///|
fn pull_request_short_ref(reference : @workflow.GitRefName) -> String? {
  if reference.0.has_prefix("refs/heads/") &&
    reference.0.length() > "refs/heads/".length() {
    Some(reference.0["refs/heads/".length():].to_owned())
  } else {
    None
  }
}

///|
async fn native_gh_capture(
  repository_root : String,
  arguments : Array[String],
) -> Result[NativeGitCapture, @types.ChoirError] {
  let environment : Map[String, String] = {
    "GH_PROMPT_DISABLED": "1",
    "GH_PAGER": "cat",
    "PAGER": "cat",
    "GIT_TERMINAL_PROMPT": "0",
  }
  let captured = @process.collect_output_merged(
    "/usr/bin/timeout",
    ["30s", "/usr/bin/gh"] + arguments,
    extra_env=environment,
    inherit_env=true,
    cwd=repository_root,
  ) catch {
    _ => return Err(native_pull_request_error("GitHub CLI process failed"))
  }
  let output = captured.1.text() catch {
    _ => return Err(native_pull_request_error("GitHub CLI output is not UTF-8"))
  }
  Ok({ exit_code: captured.0, output })
}

///|
fn native_pull_request_repository_name(output : String) -> String? {
  let json = @json.parse(output) catch { _ => return None }
  guard json is Object(fields) else { return None }
  match fields.get("nameWithOwner") {
    Some(String(value)) if value != "" && !value.contains("\u{00}") =>
      Some(value)
    _ => None
  }
}

///|
fn native_pull_request_head_repository(fields : Map[String, Json]) -> String? {
  guard fields.get("headRepository") is Some(Object(repository)) else {
    return None
  }
  match repository.get("nameWithOwner") {
    Some(String(value)) if value != "" && !value.contains("\u{00}") =>
      Some(value)
    _ => None
  }
}

///|
fn native_pull_request_remote_state(
  fields : Map[String, Json],
) -> @workflow.RemotePullRequestState? {
  match fields.get("mergedAt") {
    Some(String(value)) if value.trim().to_owned() != "" =>
      return Some(@workflow.RemotePullRequestState::RemotePullRequestMerged)
    _ => ()
  }
  match fields.get("state") {
    Some(String("OPEN")) =>
      Some(@workflow.RemotePullRequestState::RemotePullRequestOpen)
    Some(String("CLOSED")) =>
      Some(@workflow.RemotePullRequestState::RemotePullRequestClosed)
    Some(String("MERGED")) =>
      Some(@workflow.RemotePullRequestState::RemotePullRequestMerged)
    _ => None
  }
}

///|
fn native_pull_request_snapshot(
  fields : Map[String, Json],
  repository_name : String,
  intent : @workflow.PullRequestIntent,
) -> @workflow.RemotePullRequestSnapshot? {
  let remote_id = match fields.get("id") {
    Some(String(value)) if value != "" => @workflow.RemotePullRequestId(value)
    _ => return None
  }
  let number = match fields.get("number") {
    Some(Number(value, ..)) if value.to_int() > 0 =>
      @workflow.PullRequestNumber(value.to_int())
    _ => return None
  }
  let url = match fields.get("url") {
    Some(String(value)) if value != "" => @workflow.PullRequestUrl(value)
    _ => return None
  }
  let head_name = match fields.get("headRefName") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let base_name = match fields.get("baseRefName") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let head_oid = match fields.get("headRefOid") {
    Some(String(value)) if value != "" => @control.GitOid(value)
    _ => return None
  }
  let head_repository_name = match native_pull_request_head_repository(fields) {
    Some(value) => value
    None => return None
  }
  let title = match fields.get("title") {
    Some(String(value)) => value
    _ => return None
  }
  let body = match fields.get("body") {
    Some(String(value)) => value
    _ => return None
  }
  let state = match native_pull_request_remote_state(fields) {
    Some(value) => value
    None => return None
  }
  let head_repository_id = if head_repository_name == repository_name {
    intent.head_repository_id
  } else {
    @workflow.RemoteRepositoryId("github:" + head_repository_name)
  }
  Some({
    remote_id,
    number,
    url,
    provider_repository_id: intent.canonical_repository_id,
    head_repository_id,
    head_ref: @workflow.GitRefName("refs/heads/" + head_name),
    base_repository_id: intent.base_repository_id,
    base_ref: @workflow.GitRefName("refs/heads/" + base_name),
    observed_head_oid: head_oid,
    state,
    marker_state: if body.contains(intent.identity_marker.0) {
      @workflow.PullRequestMarkerState::PullRequestMarkerExact
    } else {
      @workflow.PullRequestMarkerState::PullRequestMarkerMissing
    },
    title_digest: @storage.artifact_digest(@utf8.encode(title)),
    body_digest: @storage.artifact_digest(@utf8.encode(body)),
    goal_contract_link_present: body.contains(
      @storage.digest_text(intent.goal_contract_digest),
    ),
    evidence_manifest_link_present: body.contains(
      @storage.digest_text(intent.evidence_manifest_digest),
    ),
  })
}

///|
fn native_rest_pull_request_snapshot(
  fields : Map[String, Json],
  repository_name : String,
  intent : @workflow.PullRequestIntent,
) -> @workflow.RemotePullRequestSnapshot? {
  let remote_id = match fields.get("node_id") {
    Some(String(value)) if value != "" => @workflow.RemotePullRequestId(value)
    _ => return None
  }
  let number = match fields.get("number") {
    Some(Number(value, ..)) if value.to_int() > 0 =>
      @workflow.PullRequestNumber(value.to_int())
    _ => return None
  }
  let url = match fields.get("html_url") {
    Some(String(value)) if value != "" => @workflow.PullRequestUrl(value)
    _ => return None
  }
  guard fields.get("head") is Some(Object(head)) &&
    fields.get("base") is Some(Object(base)) else {
    return None
  }
  let head_name = match head.get("ref") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let head_oid = match head.get("sha") {
    Some(String(value)) if value != "" => @control.GitOid(value)
    _ => return None
  }
  guard head.get("repo") is Some(Object(head_repository)) else { return None }
  let head_repository_name = match head_repository.get("full_name") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let base_name = match base.get("ref") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let title = match fields.get("title") {
    Some(String(value)) => value
    _ => return None
  }
  let body = match fields.get("body") {
    Some(String(value)) => value
    Some(Null) => ""
    _ => return None
  }
  let state = match fields.get("merged_at") {
    Some(String(value)) if value.trim().to_owned() != "" =>
      @workflow.RemotePullRequestState::RemotePullRequestMerged
    _ =>
      match fields.get("state") {
        Some(String("open")) =>
          @workflow.RemotePullRequestState::RemotePullRequestOpen
        Some(String("closed")) =>
          @workflow.RemotePullRequestState::RemotePullRequestClosed
        _ => return None
      }
  }
  let head_repository_id = if head_repository_name == repository_name {
    intent.head_repository_id
  } else {
    @workflow.RemoteRepositoryId("github:" + head_repository_name)
  }
  Some({
    remote_id,
    number,
    url,
    provider_repository_id: intent.canonical_repository_id,
    head_repository_id,
    head_ref: @workflow.GitRefName("refs/heads/" + head_name),
    base_repository_id: intent.base_repository_id,
    base_ref: @workflow.GitRefName("refs/heads/" + base_name),
    observed_head_oid: head_oid,
    state,
    marker_state: if body.contains(intent.identity_marker.0) {
      @workflow.PullRequestMarkerState::PullRequestMarkerExact
    } else {
      @workflow.PullRequestMarkerState::PullRequestMarkerMissing
    },
    title_digest: @storage.artifact_digest(@utf8.encode(title)),
    body_digest: @storage.artifact_digest(@utf8.encode(body)),
    goal_contract_link_present: body.contains(
      @storage.digest_text(intent.goal_contract_digest),
    ),
    evidence_manifest_link_present: body.contains(
      @storage.digest_text(intent.evidence_manifest_digest),
    ),
  })
}

///|
fn parse_native_pull_request_lookup(
  output : String,
  repository_name : String,
  intent : @workflow.PullRequestIntent,
) -> @workflow.PullRequestLookupObservation {
  let json = @json.parse(output) catch {
    _ =>
      return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
  }
  guard json is Array(items) else {
    return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
  }
  let snapshots : Array[@workflow.RemotePullRequestSnapshot] = []
  for item in items {
    guard item is Object(fields) else {
      return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
    }
    match native_pull_request_snapshot(fields, repository_name, intent) {
      Some(value) => snapshots.push(value)
      None =>
        return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
    }
  }
  classify_native_pull_request_snapshots(snapshots, intent)
}

///|
fn classify_native_pull_request_snapshots(
  snapshots : Array[@workflow.RemotePullRequestSnapshot],
  intent : @workflow.PullRequestIntent,
) -> @workflow.PullRequestLookupObservation {
  match intent.canonical_remote_pull_request_id {
    Some(stored_id) => {
      let matches = snapshots.filter(fn(snapshot) {
        snapshot.remote_id == stored_id
      })
      if matches.length() == 1 {
        return @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
          matches[0],
        )
      }
      if matches.length() > 1 {
        return @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
      }
    }
    None => ()
  }
  let marker_matches = snapshots.filter(fn(snapshot) {
    snapshot.marker_state ==
    @workflow.PullRequestMarkerState::PullRequestMarkerExact
  })
  if marker_matches.length() == 1 {
    return @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
      marker_matches[0],
    )
  }
  if marker_matches.length() > 1 {
    return @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
  }
  let possible = snapshots.filter(fn(snapshot) {
    snapshot.head_repository_id == intent.head_repository_id &&
    snapshot.head_ref == intent.head_ref &&
    snapshot.base_repository_id == intent.base_repository_id &&
    snapshot.base_ref == intent.base_ref &&
    snapshot.observed_head_oid == intent.expected_head_oid
  })
  match possible {
    [] => @workflow.PullRequestLookupObservation::PullRequestNoMatch
    [snapshot] =>
      @workflow.PullRequestLookupObservation::PullRequestPossibleExistingMatch(
        snapshot,
      )
    _ =>
      @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
  }
}

///|
fn parse_native_paginated_pull_request_lookup(
  output : String,
  repository_name : String,
  intent : @workflow.PullRequestIntent,
) -> @workflow.PullRequestLookupObservation {
  let json = @json.parse(output) catch {
    _ =>
      return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
  }
  guard json is Array(pages) else {
    return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
  }
  let snapshots : Array[@workflow.RemotePullRequestSnapshot] = []
  for page in pages {
    guard page is Array(items) else {
      return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
    }
    for item in items {
      guard item is Object(fields) else {
        return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      }
      match native_rest_pull_request_snapshot(fields, repository_name, intent) {
        Some(value) => snapshots.push(value)
        None =>
          return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      }
    }
  }
  classify_native_pull_request_snapshots(snapshots, intent)
}

///|
pub fn native_pull_request_forge_adapters() -> NativePullRequestForgeAdapters {
  {
    resolve_repository: async fn(repository_root) {
      let captured = match
        native_gh_capture(repository_root, [
          "repo", "view", "--json", "nameWithOwner",
        ]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if captured.exit_code != 0 {
        return Err(native_pull_request_error("repository lookup failed"))
      }
      match native_pull_request_repository_name(captured.output) {
        Some(value) => Ok(value)
        None => Err(native_pull_request_error("repository identity is invalid"))
      }
    },
    lookup: async fn(repository_root, repository_name, intent) {
      let captured = match
        native_gh_capture(repository_root, [
          "api",
          "--paginate",
          "--slurp",
          "repos/" + repository_name + "/pulls?state=all&per_page=100",
        ]) {
        Ok(value) => value
        Err(_) =>
          return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      }
      if captured.exit_code != 0 {
        @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      } else {
        parse_native_paginated_pull_request_lookup(
          captured.output,
          repository_name,
          intent,
        )
      }
    },
    create: async fn(repository_root, repository_name, intent, document) {
      guard pull_request_short_ref(intent.head_ref) is Some(head) &&
        pull_request_short_ref(intent.base_ref) is Some(base) else {
        return
      }
      // The durable state is changed to CreateMayHaveBeenIssued before this
      // call. This function puts at most one request on the wire and its output
      // is never trusted; reconciliation always performs a fresh lookup.
      ignore(
        native_gh_capture(repository_root, [
          "pr",
          "create",
          "--repo",
          repository_name,
          "--base",
          base,
          "--head",
          head,
          "--title",
          document.title,
          "--body",
          document.body,
        ]),
      )
    },
  }
}

///|
pub fn synthetic_pull_request_forge_adapters() -> NativePullRequestForgeAdapters {
  let created = Ref(false)
  {
    resolve_repository: async fn(_) { Ok("choir/synthetic") },
    lookup: async fn(_, _, intent) {
      if !created.val && intent.canonical_remote_pull_request_id is None {
        return @workflow.PullRequestLookupObservation::PullRequestNoMatch
      }
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        remote_id: @workflow.RemotePullRequestId(
          "PR_synthetic_" + intent.goal_id.0,
        ),
        number: @workflow.PullRequestNumber(1),
        url: @workflow.PullRequestUrl("https://example.invalid/choir/pull/1"),
        provider_repository_id: intent.canonical_repository_id,
        head_repository_id: intent.head_repository_id,
        head_ref: intent.head_ref,
        base_repository_id: intent.base_repository_id,
        base_ref: intent.base_ref,
        observed_head_oid: intent.expected_head_oid,
        state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
        marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
        title_digest: @storage.artifact_digest(
          @utf8.encode("feat: complete Choir Goal"),
        ),
        body_digest: @storage.artifact_digest(
          @utf8.encode(intent.identity_marker.0),
        ),
        goal_contract_link_present: true,
        evidence_manifest_link_present: true,
      })
    },
    create: async fn(_, _, _, _) { created.val = true },
  }
}

///|
fn native_pull_request_transaction_completed(
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
fn persist_native_goal_pull_request_record(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  record : @workflow.GoalPullRequestRecord,
  expected_store_version : Int?,
  fault_point? : @storage.StateStoreFaultPoint? = None,
) -> Result[(@workflow.StoredGoalPullRequestRecord?, Bool), @types.ChoirError] {
  let receipt = match
    @workflow.persist_goal_pull_request_record(
      repository,
      repository_adapters,
      {
        record,
        expected_store_version,
        goal_precondition: @workflow.goal_execution_state_precondition(
          execution,
        ),
        fault_point,
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.outcome {
    @workflow.GoalPullRequestPersistenceOutcome::GoalPullRequestGoalPreconditionConflict =>
      Ok((None, false))
    @workflow.GoalPullRequestPersistenceOutcome::GoalPullRequestPersistenceCompleted(
      outcome
    ) => {
      let stored = match
        @workflow.load_goal_pull_request_record(
          repository,
          repository_adapters,
          execution.goal.id,
        ) {
        Ok(Some(value)) => value
        Ok(None) =>
          return Err(native_pull_request_error("PR record disappeared"))
        Err(error) => return Err(error)
      }
      if stored.record == record &&
        (
          native_pull_request_transaction_completed(outcome) ||
          outcome ==
          @storage.StateTransactionOutcome::StateTransactionVersionConflict
        ) {
        Ok(
          (
            Some(stored),
            outcome ==
            @storage.StateTransactionOutcome::StateTransactionCommitted,
          ),
        )
      } else {
        Err(native_pull_request_error("PR persistence conflicted"))
      }
    }
  }
}

///|
fn adopt_native_pull_request_document(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
  document : @workflow.PullRequestDocument,
) -> Result[@control.Digest, @types.ChoirError] {
  let content = @workflow.pull_request_document_bytes(document)
  let digest = @storage.artifact_digest(content)
  let receipt = match
    (repository_adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactPullRequestDocument(
        goal_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if receipt.digest == digest && receipt.byte_length == content.length() {
    Ok(digest)
  } else {
    Err(native_pull_request_error("PR document artifact receipt is false"))
  }
}

///|
fn load_native_pull_request_document(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  digest : @control.Digest,
) -> Result[@workflow.PullRequestDocument, @types.ChoirError] {
  let content = match
    (repository_adapters.artifacts.read)(repository.artifact_store, {
      digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != digest {
    return Err(native_pull_request_error("PR document digest disagrees"))
  }
  @workflow.decode_pull_request_document(content)
}

///|
pub async fn advance_native_goal_pull_request_with_adapters(
  project_dir : String,
  goal_id : @control.GoalId,
  forge : NativePullRequestForgeAdapters,
  fault? : @workflow.GoalPullRequestFaultPoint? = None,
) -> Result[@workflow.GoalPullRequestTickOutcome, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let repository_adapters = local_part_workflow_repository_adapters()
  match
    @workflow.initialize_part_workflow_repository(
      repository, repository_adapters,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let execution = match
    @workflow.load_goal_execution_record(
      repository, repository_adapters, goal_id,
    ) {
    Ok(Some(value)) => value.record
    Ok(None) => return Err(native_pull_request_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  if execution.state != @workflow.GoalExecutionState::GoalExecutionAssured {
    return Err(native_pull_request_error("Goal is not assured"))
  }
  let assurance = match
    @workflow.load_goal_assurance_record(
      repository, repository_adapters, goal_id,
    ) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_pull_request_error("Goal assurance is absent"))
    Err(error) => return Err(error)
  }
  let publication = match
    @workflow.load_goal_publication_record(
      repository, repository_adapters, goal_id,
    ) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_pull_request_error("Goal publication is absent"))
    Err(error) => return Err(error)
  }
  guard publication.receipt is Some(publication_receipt) else {
    return Err(native_pull_request_error("Goal publication is not receipted"))
  }
  let git = match discover_native_goal_repository(project_dir, execution) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let remote_head = native_remote_branch_observation(git, publication.intent)
  if remote_head !=
    @workflow.RemoteBranchObservation::RemoteBranchAt(
      publication_receipt.published_oid,
    ) {
    return Err(native_pull_request_error("published remote head is not exact"))
  }
  let repository_name = match (forge.resolve_repository)(git.root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base_repository_id = publication.intent.canonical_repository_id
  let mut current = match
    @workflow.load_goal_pull_request_record(
      repository, repository_adapters, goal_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut dispatch_create = false
  let mut cycles = 0
  while cycles < 10 {
    cycles = cycles + 1
    match current {
      None => {
        let marker = match
          @workflow.goal_pull_request_identity_marker(
            execution, publication, base_repository_id,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let document : @workflow.PullRequestDocument = {
          title: "feat: complete Choir Goal",
          body: "## Summary\n\nCompletes Goal `" +
          goal_id.0 +
          "` from its sealed, verified, and independently audited branch.\n\nGoal contract: `" +
          @storage.digest_text(execution.goal.contract_digest) +
          "`\nEvidence manifest: `" +
          @storage.digest_text(
            publication.goal_verification_evidence_manifest_digest,
          ) +
          "`\n\n" +
          marker.0,
        }
        match
          adopt_native_pull_request_document(
            repository, repository_adapters, goal_id, document,
          ) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        let planned = match
          @workflow.initialize_goal_pull_request(
            execution,
            assurance,
            publication,
            @workflow.PullRequestProvider::GitHubPullRequestProvider,
            base_repository_id,
            document,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let persisted = match
          persist_native_goal_pull_request_record(
            repository,
            repository_adapters,
            execution,
            planned,
            None,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        current = persisted.0
        if fault ==
          Some(
            @workflow.GoalPullRequestFaultPoint::PullRequestAfterIntentBeforeLookup,
          ) {
          return Err(native_pull_request_error("injected pull request fault"))
        }
      }
      Some(stored) =>
        match stored.record.intent.state {
          @workflow.PullRequestIntentState::PullRequestPlanned => {
            let lookup = (forge.lookup)(
              git.root,
              repository_name,
              stored.record.intent,
            )
            if lookup ==
              @workflow.PullRequestLookupObservation::PullRequestNoMatch &&
              fault ==
              Some(
                @workflow.GoalPullRequestFaultPoint::PullRequestAfterEmptyLookupBeforeAuthorized,
              ) {
              return Err(
                native_pull_request_error("injected pull request fault"),
              )
            }
            let authorized = match
              @workflow.authorize_goal_pull_request(
                stored.record,
                execution,
                assurance,
                publication,
                publication_receipt.published_oid,
                lookup,
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let persisted = match
              persist_native_goal_pull_request_record(
                repository,
                repository_adapters,
                execution,
                authorized,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = persisted.0
            if authorized.intent.state ==
              @workflow.PullRequestIntentState::PullRequestAuthorized &&
              fault ==
              Some(
                @workflow.GoalPullRequestFaultPoint::PullRequestAfterAuthorizedBeforeCreateMayHaveBeenIssued,
              ) {
              return Err(
                native_pull_request_error("injected pull request fault"),
              )
            }
          }
          @workflow.PullRequestIntentState::PullRequestAuthorized => {
            let issued = match
              @workflow.mark_goal_pull_request_create_may_have_been_issued(
                stored.record,
                execution,
                assurance,
                publication,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let persisted = match
              persist_native_goal_pull_request_record(
                repository,
                repository_adapters,
                execution,
                issued,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = persisted.0
            dispatch_create = persisted.1
            if issued.intent.state ==
              @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued &&
              fault ==
              Some(
                @workflow.GoalPullRequestFaultPoint::PullRequestAfterCreateMayHaveBeenIssuedBeforeDispatch,
              ) {
              return Err(
                native_pull_request_error("injected pull request fault"),
              )
            }
          }
          @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued
          | @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain => {
            if dispatch_create &&
              stored.record.intent.state ==
              @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued {
              let document = match
                load_native_pull_request_document(
                  repository,
                  repository_adapters,
                  stored.record.intent.title_and_body_artifact_digest,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              (forge.create)(
                git.root,
                repository_name,
                stored.record.intent,
                document,
              )
              dispatch_create = false
              if fault ==
                Some(
                  @workflow.GoalPullRequestFaultPoint::PullRequestAfterRemoteCreateBeforeResponse,
                ) {
                return Err(
                  native_pull_request_error("injected pull request fault"),
                )
              }
            }
            let reconciled = match
              @workflow.reconcile_goal_pull_request_after_create(
                stored.record,
                (forge.lookup)(git.root, repository_name, stored.record.intent),
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if reconciled == stored.record {
              return Ok(
                @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain,
              )
            }
            if reconciled.intent.state ==
              @workflow.PullRequestIntentState::PullRequestReceipted &&
              fault ==
              Some(
                @workflow.GoalPullRequestFaultPoint::PullRequestAfterResponseBeforeReceipt,
              ) {
              return Err(
                native_pull_request_error("injected pull request fault"),
              )
            }
            let persisted = match
              persist_native_goal_pull_request_record(
                repository,
                repository_adapters,
                execution,
                reconciled,
                Some(stored.state_record.version),
                fault_point=if reconciled.intent.state ==
                  @workflow.PullRequestIntentState::PullRequestReceipted &&
                  fault ==
                  Some(
                    @workflow.GoalPullRequestFaultPoint::PullRequestDuringReceiptTransaction,
                  ) {
                  Some(@storage.StateStoreFaultPoint::StateAfterCommitBeforeAck)
                } else {
                  None
                },
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = persisted.0
            if reconciled.intent.state ==
              @workflow.PullRequestIntentState::PullRequestReceipted &&
              fault ==
              Some(
                @workflow.GoalPullRequestFaultPoint::PullRequestDuringReceiptTransaction,
              ) {
              return Err(
                native_pull_request_error("injected pull request fault"),
              )
            }
          }
          @workflow.PullRequestIntentState::PullRequestReceipted =>
            return Ok(
              @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
            )
          @workflow.PullRequestIntentState::PullRequestNeedsInput(_) =>
            return Ok(
              @workflow.GoalPullRequestTickOutcome::GoalPullRequestNeedsUserInput,
            )
          @workflow.PullRequestIntentState::PullRequestAbandonedByCancellation =>
            return Ok(
              @workflow.GoalPullRequestTickOutcome::GoalPullRequestPending,
            )
        }
    }
  } nobreak {
    Err(native_pull_request_error("PR reconciliation exceeded its cycle bound"))
  }
}

///|
pub async fn advance_native_goal_pull_request(
  project_dir : String,
  goal_id : @control.GoalId,
) -> Result[@workflow.GoalPullRequestTickOutcome, @types.ChoirError] {
  advance_native_goal_pull_request_with_adapters(
    project_dir,
    goal_id,
    native_pull_request_forge_adapters(),
  )
}

///|
test "GitHub lookup parser distinguishes identity, possible match, and ambiguity" {
  let intent : @workflow.PullRequestIntent = {
    id: @workflow.PullRequestIntentId("pr-intent-fixture"),
    goal_id: @control.GoalId("goal-fixture"),
    provider: @workflow.PullRequestProvider::GitHubPullRequestProvider,
    canonical_repository_id: @workflow.RemoteRepositoryId("remote-fixture"),
    head_repository_id: @workflow.RemoteRepositoryId("remote-fixture"),
    head_ref: @workflow.GitRefName("refs/heads/choir/goals/fixture"),
    base_repository_id: @workflow.RemoteRepositoryId("remote-fixture"),
    base_ref: @workflow.GitRefName("refs/heads/main"),
    expected_head_oid: @control.GitOid(
      "0123456789012345678901234567890123456789",
    ),
    goal_contract_digest: @control.Digest("sha256:contract"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-fixture"),
    goal_branch_seal_digest: @control.Digest("sha256:fixture"),
    combined_audit_receipt_id: @control.ReceiptId("audit-fixture"),
    evidence_manifest_digest: @control.Digest("sha256:evidence"),
    title_and_body_artifact_digest: @control.Digest("sha256:document"),
    identity_marker: @workflow.PullRequestIdentityMarker(
      "<!-- choir-final-pr:fixture -->",
    ),
    idempotency_key: "pr-fixture",
    canonical_remote_pull_request_id: None,
    state: @workflow.PullRequestIntentState::PullRequestPlanned,
  }
  let exact =
    #|[{"id":"PR_1","number":7,"url":"https://example.test/pull/7","state":"OPEN","mergedAt":null,"headRefName":"choir/goals/fixture","headRefOid":"0123456789012345678901234567890123456789","headRepository":{"nameWithOwner":"choir/choir"},"baseRefName":"main","title":"Goal","body":"evidence\n<!-- choir-final-pr:fixture -->"}]
  assert_true(
    parse_native_pull_request_lookup(exact, "choir/choir", intent)
    is @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(_),
  )
  let possible = exact.replace_all(
    old="<!-- choir-final-pr:fixture -->",
    new="no marker",
  )
  assert_true(
    parse_native_pull_request_lookup(possible, "choir/choir", intent)
    is @workflow.PullRequestLookupObservation::PullRequestPossibleExistingMatch(
      _
    ),
  )
  let duplicate = (exact[0:exact.length() - 1] + "," + exact[1:]).to_owned()
  assert_eq(
    parse_native_pull_request_lookup(duplicate, "choir/choir", intent),
    @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches,
  )
  assert_eq(
    parse_native_pull_request_lookup("not-json", "choir/choir", intent),
    @workflow.PullRequestLookupObservation::PullRequestLookupUncertain,
  )
  let paginated =
    #|[[{"node_id":"PR_1","number":7,"html_url":"https://example.test/pull/7","state":"open","merged_at":null,"head":{"ref":"choir/goals/fixture","sha":"0123456789012345678901234567890123456789","repo":{"full_name":"choir/choir"}},"base":{"ref":"main"},"title":"Goal","body":"evidence\n<!-- choir-final-pr:fixture -->"}],[]]
  assert_true(
    parse_native_paginated_pull_request_lookup(paginated, "choir/choir", intent)
    is @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(_),
  )
}

///|
fn pull_request_fault_snapshot(
  intent : @workflow.PullRequestIntent,
  document : @workflow.PullRequestDocument,
) -> @workflow.RemotePullRequestSnapshot {
  {
    remote_id: @workflow.RemotePullRequestId("PR_fault_" + intent.goal_id.0),
    number: @workflow.PullRequestNumber(1),
    url: @workflow.PullRequestUrl("https://example.invalid/choir/pull/1"),
    provider_repository_id: intent.canonical_repository_id,
    head_repository_id: intent.head_repository_id,
    head_ref: intent.head_ref,
    base_repository_id: intent.base_repository_id,
    base_ref: intent.base_ref,
    observed_head_oid: intent.expected_head_oid,
    state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
    marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
    title_digest: @storage.artifact_digest(@utf8.encode(document.title)),
    body_digest: @storage.artifact_digest(@utf8.encode(document.body)),
    goal_contract_link_present: true,
    evidence_manifest_link_present: true,
  }
}

///|
pub(all) struct NativePullRequestFaultObservation {
  fault : @workflow.GoalPullRequestFaultPoint
  interrupted_state : @workflow.PullRequestIntentState
  create_count : Int
  completion_expected : Bool
  expected_outcome_observed : Bool
  duplicate_free : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePullRequestFaultConformanceReport {
  observations : Array[NativePullRequestFaultObservation]
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
async fn prove_pull_request_fault_recovery(
  label : String,
  fault : @workflow.GoalPullRequestFaultPoint,
  expected_state : @workflow.PullRequestIntentState,
  create_expected : Bool,
  completion_expected : Bool,
) -> NativePullRequestFaultObservation {
  let fixture = prove_publication_fault_recovery(
    "pull-request-" + label,
    @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
    @workflow.BranchPublicationState::BranchPublicationPlanned,
    false,
  )
  let root = fixture.0
  let remote = fixture.1
  let goal_id = fixture.2
  let created = Ref(0)
  let remote_pull_request : Ref[@workflow.RemotePullRequestSnapshot?] = Ref(
    None,
  )
  let forge : NativePullRequestForgeAdapters = {
    resolve_repository: async fn(_) { Ok("choir/fault-fixture") },
    lookup: async fn(_, _, _) {
      match remote_pull_request.val {
        Some(snapshot) =>
          @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
            snapshot,
          )
        None => @workflow.PullRequestLookupObservation::PullRequestNoMatch
      }
    },
    create: async fn(_, _, intent, document) {
      created.val = created.val + 1
      remote_pull_request.val = Some(
        pull_request_fault_snapshot(intent, document),
      )
    },
  }
  assert_true(
    advance_native_goal_pull_request_with_adapters(
      root,
      goal_id,
      forge,
      fault=Some(fault),
    )
    is Err(_),
  )
  let repository = native_goal_repository(root)
  let adapters = local_part_workflow_repository_adapters()
  let interrupted = @workflow.load_goal_pull_request_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  assert_eq(interrupted.intent.state, expected_state)
  assert_eq(created.val > 0, create_expected)
  let recovered = advance_native_goal_pull_request_with_adapters(
    root, goal_id, forge,
  ).unwrap()
  let durable = @workflow.load_goal_pull_request_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  if completion_expected {
    assert_eq(
      recovered,
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
    )
    assert_eq(
      durable.intent.state,
      @workflow.PullRequestIntentState::PullRequestReceipted,
    )
    assert_true(durable.receipt is Some(_))
    assert_eq(created.val, 1)
    assert_eq(
      advance_native_goal_pull_request_with_adapters(root, goal_id, forge).unwrap(),
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
    )
    assert_eq(created.val, 1)
  } else {
    assert_eq(
      recovered,
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain,
    )
    assert_eq(
      durable.intent.state,
      @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain,
    )
    assert_true(durable.receipt is None)
    assert_eq(created.val, 0)
  }
  assert_eq(
    @workflow.load_goal_execution_record(repository, adapters, goal_id)
    .unwrap()
    .unwrap().record.state,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  )
  let observation = {
    fault,
    interrupted_state: interrupted.intent.state,
    create_count: created.val,
    completion_expected,
    expected_outcome_observed: if completion_expected {
      recovered == @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete &&
      durable.intent.state ==
      @workflow.PullRequestIntentState::PullRequestReceipted &&
      durable.receipt is Some(_)
    } else {
      recovered ==
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain &&
      durable.intent.state ==
      @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain &&
      durable.receipt is None
    },
    duplicate_free: created.val <= 1,
  }
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
  observation
}

///|
pub async fn run_native_pull_request_fault_conformance(
) -> NativePullRequestFaultConformanceReport {
  let observations : Array[NativePullRequestFaultObservation] = []
  let cases : Array[
    (
      String,
      @workflow.GoalPullRequestFaultPoint,
      @workflow.PullRequestIntentState,
      Bool,
      Bool,
    )
  ] = [
    (
      "after-intent",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterIntentBeforeLookup,
      @workflow.PullRequestIntentState::PullRequestPlanned,
      false,
      true,
    ),
    (
      "after-empty-lookup",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterEmptyLookupBeforeAuthorized,
      @workflow.PullRequestIntentState::PullRequestPlanned,
      false,
      true,
    ),
    (
      "after-authorization",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterAuthorizedBeforeCreateMayHaveBeenIssued,
      @workflow.PullRequestIntentState::PullRequestAuthorized,
      false,
      true,
    ),
    (
      "before-dispatch",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterCreateMayHaveBeenIssuedBeforeDispatch,
      @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
      false,
      false,
    ),
    (
      "after-create",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterRemoteCreateBeforeResponse,
      @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
      true,
      true,
    ),
    (
      "after-response",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterResponseBeforeReceipt,
      @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
      true,
      true,
    ),
    (
      "during-receipt",
      @workflow.GoalPullRequestFaultPoint::PullRequestDuringReceiptTransaction,
      @workflow.PullRequestIntentState::PullRequestReceipted,
      true,
      true,
    ),
  ]
  for config in cases {
    observations.push(
      prove_pull_request_fault_recovery(
        config.0,
        config.1,
        config.2,
        config.3,
        config.4,
      ),
    )
  }
  {
    observations,
    passed: observations.length() == cases.length() &&
    observations.all(fn(observation) {
      observation.expected_outcome_observed && observation.duplicate_free
    }),
  }
}

///|
async test "real exec integration: final PR creation recovers without duplicate dispatch" {
  let report = run_native_pull_request_fault_conformance()
  assert_true(report.passed)
  assert_eq(report.observations.length(), 7)
}
