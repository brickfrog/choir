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
  merge : async (
    String,
    String,
    @workflow.PullRequestIntent,
    @workflow.PullRequestReceipt,
  ) -> @workflow.PullRequestMergeDispatchObservation
  /// Strip the forge's authority to merge the exact pull request: disable
  /// automatic merge, then close it. Both effects are idempotent and bound to
  /// the receipted pull request number; the result is never trusted, so
  /// cancellation always reconciles with a fresh lookup.
  neutralize : async (
    String,
    String,
    @workflow.PullRequestIntent,
    @workflow.PullRequestReceipt,
  ) -> Unit
}

///|
let native_github_timeout_ms : Int = 30000

///|
let native_github_output_limit_bytes : Int = 4 * 1024 * 1024

///|
let native_pull_request_page_limit : Int = 5

///|
let native_pull_request_page_size : Int = 100

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
fn native_gh_environment(getenv : (String) -> String?) -> Map[String, String] {
  let environment : Map[String, String] = {
    "PATH": "/usr/bin:/bin",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "GH_PROMPT_DISABLED": "1",
    "GH_PAGER": "cat",
    "PAGER": "cat",
    "GIT_TERMINAL_PROMPT": "0",
  }
  let inherited = [
    "HOME", "GH_CONFIG_DIR", "GH_HOST", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
  ]
  for name in inherited {
    match getenv(name) {
      Some(value) if value != "" && !value.contains("\u{00}") =>
        environment[name] = value
      _ => ()
    }
  }
  environment
}

///|
async fn native_gh_capture(
  repository_root : String,
  arguments : Array[String],
) -> Result[@process_host.NativeBoundedProcessOutcome, @types.ChoirError] {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(native_pull_request_error("GitHub CLI input pipe failed"))
  }
  stdin_write.close()
  @process_host.capture_bounded_process(
    "/usr/bin/gh",
    arguments,
    native_gh_environment(@sys.getenv),
    stdin_read,
    repository_root,
    native_github_timeout_ms,
    native_github_output_limit_bytes,
    fn() { false },
  )
}

///|
test "GitHub CLI environment retains only explicit host inputs" {
  let environment = native_gh_environment(fn(name) {
    match name {
      "HOME" => Some("/home/provider")
      "GH_TOKEN" => Some("secret")
      "HTTPS_PROXY" => Some("https://proxy.invalid")
      "SHELL" => Some("/bin/host-shell")
      _ => None
    }
  })
  assert_eq(environment["PATH"], "/usr/bin:/bin")
  assert_eq(environment["HOME"], "/home/provider")
  assert_eq(environment["GH_TOKEN"], "secret")
  assert_eq(environment["HTTPS_PROXY"], "https://proxy.invalid")
  assert_false(environment.contains("SHELL"))
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
/// GitHub reports draft state as `draft` on the REST resource.
fn native_pull_request_draft(fields : Map[String, Json]) -> Bool {
  match fields.get("draft") {
    Some(True) => return true
    Some(False) => return false
    _ => ()
  }
  match fields.get("isDraft") {
    Some(True) => true
    _ => false
  }
}

///|
fn native_pull_request_auto_merge_enabled(fields : Map[String, Json]) -> Bool {
  match fields.get("auto_merge") {
    Some(Object(_)) => return true
    _ => ()
  }
  match fields.get("autoMergeRequest") {
    Some(Object(_)) => true
    _ => false
  }
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
    draft: native_pull_request_draft(fields),
    auto_merge_enabled: native_pull_request_auto_merge_enabled(fields),
    marker_state: if body.contains(intent.identity_marker.0) {
      @workflow.PullRequestMarkerState::PullRequestMarkerExact
    } else {
      @workflow.PullRequestMarkerState::PullRequestMarkerMissing
    },
    title_digest: @storage.artifact_digest(@utf8.encode(title)),
    body_digest: @storage.artifact_digest(@utf8.encode(body)),
  })
}

///|
fn native_pull_request_snapshot_is_exact(
  snapshot : @workflow.RemotePullRequestSnapshot,
  intent : @workflow.PullRequestIntent,
) -> Bool {
  snapshot.provider_repository_id == intent.canonical_repository_id &&
  snapshot.head_repository_id == intent.head_repository_id &&
  snapshot.head_ref == intent.head_ref &&
  snapshot.base_repository_id == intent.base_repository_id &&
  snapshot.base_ref == intent.base_ref &&
  snapshot.observed_head_oid == intent.expected_head_oid &&
  snapshot.marker_state ==
  @workflow.PullRequestMarkerState::PullRequestMarkerExact &&
  snapshot.title_digest ==
  @storage.artifact_digest(@utf8.encode(intent.document.title)) &&
  snapshot.body_digest ==
  @storage.artifact_digest(@utf8.encode(intent.document.body))
}

///|
fn native_pull_request_snapshot_is_related(
  snapshot : @workflow.RemotePullRequestSnapshot,
  intent : @workflow.PullRequestIntent,
) -> Bool {
  snapshot.marker_state ==
  @workflow.PullRequestMarkerState::PullRequestMarkerExact ||
  (
    snapshot.head_repository_id == intent.head_repository_id &&
    snapshot.head_ref == intent.head_ref &&
    snapshot.base_repository_id == intent.base_repository_id &&
    snapshot.base_ref == intent.base_ref
  )
}

///|
priv struct NativePullRequestLookupAccumulator {
  mut exact : @workflow.RemotePullRequestSnapshot?
  mut possible : @workflow.RemotePullRequestSnapshot?
  mut ambiguous : Bool
}

///|
fn native_pull_request_lookup_accumulator() -> NativePullRequestLookupAccumulator {
  { exact: None, possible: None, ambiguous: false }
}

///|
fn native_pull_request_accumulate_snapshot(
  accumulator : NativePullRequestLookupAccumulator,
  snapshot : @workflow.RemotePullRequestSnapshot,
  intent : @workflow.PullRequestIntent,
) -> Unit {
  if native_pull_request_snapshot_is_exact(snapshot, intent) {
    if accumulator.exact is Some(_) || accumulator.possible is Some(_) {
      accumulator.ambiguous = true
    } else {
      accumulator.exact = Some(snapshot)
    }
  } else if native_pull_request_snapshot_is_related(snapshot, intent) {
    if accumulator.exact is Some(_) || accumulator.possible is Some(_) {
      accumulator.ambiguous = true
    } else {
      accumulator.possible = Some(snapshot)
    }
  }
}

///|
fn native_pull_request_lookup_accumulator_observation(
  accumulator : NativePullRequestLookupAccumulator,
) -> @workflow.PullRequestLookupObservation {
  if accumulator.ambiguous {
    return @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
  }
  match accumulator.exact {
    Some(snapshot) =>
      return @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        snapshot,
      )
    None => ()
  }
  match accumulator.possible {
    Some(snapshot) =>
      @workflow.PullRequestLookupObservation::PullRequestPossibleExistingMatch(
        snapshot,
      )
    None => @workflow.PullRequestLookupObservation::PullRequestNoMatch
  }
}

///|
fn parse_native_pull_request_page(
  output : String,
  repository_name : String,
  intent : @workflow.PullRequestIntent,
  accumulator : NativePullRequestLookupAccumulator,
) -> Int? {
  let json = @json.parse(output) catch { _ => return None }
  guard json is Array(items) && items.length() <= native_pull_request_page_size else {
    return None
  }
  for item in items {
    guard item is Object(fields) else { return None }
    match native_rest_pull_request_snapshot(fields, repository_name, intent) {
      Some(snapshot) =>
        native_pull_request_accumulate_snapshot(accumulator, snapshot, intent)
      None => return None
    }
  }
  Some(items.length())
}

///|
fn native_graphql_pull_request_snapshot(
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
  guard fields.get("headRepository") is Some(Object(head_repository)) else {
    return None
  }
  let head_repository_name = match head_repository.get("nameWithOwner") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let title = match fields.get("title") {
    Some(String(value)) => value
    _ => return None
  }
  let body = match fields.get("body") {
    Some(String(value)) => value
    _ => return None
  }
  let state = match fields.get("mergedAt") {
    Some(String(value)) if value != "" =>
      @workflow.RemotePullRequestState::RemotePullRequestMerged
    _ =>
      match fields.get("state") {
        Some(String("OPEN")) =>
          @workflow.RemotePullRequestState::RemotePullRequestOpen
        Some(String("CLOSED")) =>
          @workflow.RemotePullRequestState::RemotePullRequestClosed
        Some(String("MERGED")) =>
          @workflow.RemotePullRequestState::RemotePullRequestMerged
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
    draft: native_pull_request_draft(fields),
    auto_merge_enabled: native_pull_request_auto_merge_enabled(fields),
    marker_state: if body.contains(intent.identity_marker.0) {
      @workflow.PullRequestMarkerState::PullRequestMarkerExact
    } else {
      @workflow.PullRequestMarkerState::PullRequestMarkerMissing
    },
    title_digest: @storage.artifact_digest(@utf8.encode(title)),
    body_digest: @storage.artifact_digest(@utf8.encode(body)),
  })
}

///|
fn parse_native_direct_pull_request_lookup(
  output : String,
  repository_name : String,
  intent : @workflow.PullRequestIntent,
  stored_id : @workflow.RemotePullRequestId,
) -> @workflow.PullRequestLookupObservation {
  let json = @json.parse(output) catch {
    _ =>
      return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
  }
  guard json is Object(root) &&
    root.get("data") is Some(Object(data)) &&
    data.get("node") is Some(Object(fields)) &&
    native_graphql_pull_request_snapshot(fields, repository_name, intent)
    is Some(snapshot) else {
    return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
  }
  if snapshot.remote_id == stored_id {
    @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(snapshot)
  } else {
    @workflow.PullRequestLookupObservation::PullRequestPossibleExistingMatch(
      snapshot,
    )
  }
}

///|
async fn native_pull_request_lookup(
  repository_root : String,
  repository_name : String,
  intent : @workflow.PullRequestIntent,
  capture : async (String, Array[String]) -> Result[
    @process_host.NativeBoundedProcessOutcome,
    @types.ChoirError,
  ],
) -> @workflow.PullRequestLookupObservation {
  match intent.canonical_remote_pull_request_id {
    Some(stored_id) => {
      let outcome = capture(repository_root, [
        "api",
        "graphql",
        "-f",
        "query=query($id:ID!){node(id:$id){... on PullRequest{id number url state mergedAt headRefName headRefOid headRepository{nameWithOwner} baseRefName title body isDraft autoMergeRequest{enabledAt}}}}",
        "-f",
        "id=" + stored_id.0,
      ])
      match outcome {
        Ok(@process_host.NativeProcessCompleted(0, output)) =>
          parse_native_direct_pull_request_lookup(
            output, repository_name, intent, stored_id,
          )
        _ => @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      }
    }
    None => {
      guard pull_request_short_ref(intent.head_ref) is Some(head) &&
        pull_request_short_ref(intent.base_ref) is Some(base) else {
        return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      }
      let repository_parts = repository_name.split("/").to_array()
      if repository_parts.length() != 2 || repository_parts[0] == "" {
        return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
      }
      let accumulator = native_pull_request_lookup_accumulator()
      let mut page = 1
      while page <= native_pull_request_page_limit {
        let outcome = capture(repository_root, [
          "api",
          "--method",
          "GET",
          "repos/" + repository_name + "/pulls",
          "-f",
          "state=all",
          "-f",
          "head=" + repository_parts[0].to_owned() + ":" + head,
          "-f",
          "base=" + base,
          "-f",
          "per_page=" + native_pull_request_page_size.to_string(),
          "-f",
          "page=" + page.to_string(),
        ])
        let output = match outcome {
          Ok(@process_host.NativeProcessCompleted(0, value)) => value
          _ =>
            return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
        }
        let count = match
          parse_native_pull_request_page(
            output, repository_name, intent, accumulator,
          ) {
          Some(value) => value
          None =>
            return @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
        }
        if accumulator.ambiguous {
          return @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
        }
        if count < native_pull_request_page_size {
          return native_pull_request_lookup_accumulator_observation(accumulator)
        }
        page = page + 1
      }
      @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
    }
  }
}

///|
fn native_pull_request_create_arguments(
  repository_name : String,
  base : String,
  head : String,
  document : @workflow.PullRequestDocument,
) -> Array[String] {
  let arguments = [
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
  ]
  if document.draft {
    arguments.push("--draft")
  }
  arguments
}

///|
fn native_pull_request_merge_arguments(
  repository_name : String,
  number : @workflow.PullRequestNumber,
  expected_head_oid : @control.GitOid,
  title : String,
  merge_method : @types.PullRequestMergeMethod,
) -> Array[String] {
  let arguments = [
    "pr",
    "merge",
    number.0.to_string(),
    "--repo",
    repository_name,
    "--auto",
    "--match-head-commit",
    expected_head_oid.0,
  ]
  match merge_method {
    @types.PullRequestMergeMethod::PullRequestSquashMerge => {
      arguments.push("--squash")
      arguments.push("--subject")
      arguments.push(title)
    }
    @types.PullRequestMergeMethod::PullRequestRebaseMerge =>
      arguments.push("--rebase")
    @types.PullRequestMergeMethod::PullRequestMergeCommit => {
      arguments.push("--merge")
      arguments.push("--subject")
      arguments.push(title)
    }
  }
  arguments
}

///|
fn native_pull_request_disable_auto_merge_arguments(
  repository_name : String,
  number : @workflow.PullRequestNumber,
) -> Array[String] {
  [
    "pr",
    "merge",
    number.0.to_string(),
    "--repo",
    repository_name,
    "--disable-auto",
  ]
}

///|
fn native_pull_request_close_arguments(
  repository_name : String,
  number : @workflow.PullRequestNumber,
) -> Array[String] {
  ["pr", "close", number.0.to_string(), "--repo", repository_name]
}

///|
test "native neutralization disables automatic merge before closing" {
  assert_eq(
    native_pull_request_disable_auto_merge_arguments(
      "brickfrog/choir",
      @workflow.PullRequestNumber(7),
    ),
    ["pr", "merge", "7", "--repo", "brickfrog/choir", "--disable-auto"],
  )
  assert_eq(
    native_pull_request_close_arguments(
      "brickfrog/choir",
      @workflow.PullRequestNumber(7),
    ),
    ["pr", "close", "7", "--repo", "brickfrog/choir"],
  )
}

///|
test "native automatic merge pins head and preserves semantic squash title" {
  let expected_head_oid = @control.GitOid(
    "0123456789012345678901234567890123456789",
  )
  let title = "fix: merge the exact candidate"
  assert_eq(
    native_pull_request_merge_arguments(
      "brickfrog/choir",
      @workflow.PullRequestNumber(7),
      expected_head_oid,
      title,
      @types.PullRequestMergeMethod::PullRequestSquashMerge,
    ),
    [
      "pr",
      "merge",
      "7",
      "--repo",
      "brickfrog/choir",
      "--auto",
      "--match-head-commit",
      expected_head_oid.0,
      "--squash",
      "--subject",
      title,
    ],
  )
}

///|
test "native PR create arguments include draft only when requested" {
  let ready = native_pull_request_create_arguments(
    "brickfrog/choir",
    "main",
    "choir/goals/example",
    { title: "fix: ready", body: "Ready for review.", draft: false },
  )
  assert_eq(ready, [
    "pr", "create", "--repo", "brickfrog/choir", "--base", "main", "--head", "choir/goals/example",
    "--title", "fix: ready", "--body", "Ready for review.",
  ])
  let draft = native_pull_request_create_arguments(
    "brickfrog/choir",
    "main",
    "choir/goals/example",
    { title: "fix: draft", body: "Preliminary review.", draft: true },
  )
  assert_eq(draft[ready.length():], ["--draft"])
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
      match captured {
        @process_host.NativeProcessCompleted(0, output) =>
          match native_pull_request_repository_name(output) {
            Some(value) => Ok(value)
            None =>
              Err(native_pull_request_error("repository identity is invalid"))
          }
        _ => Err(native_pull_request_error("repository lookup failed"))
      }
    },
    lookup: async fn(repository_root, repository_name, intent) {
      native_pull_request_lookup(
        repository_root, repository_name, intent, native_gh_capture,
      )
    },
    create: async fn(repository_root, repository_name, intent, document) {
      guard pull_request_short_ref(intent.head_ref) is Some(head) &&
        pull_request_short_ref(intent.base_ref) is Some(base) else {
        return
      }
      // The durable state is changed to CreateMayHaveBeenIssued before this
      // call. This function puts at most one request on the wire and its output
      // is never trusted; reconciliation always performs a fresh lookup.
      let arguments = native_pull_request_create_arguments(
        repository_name, base, head, document,
      )
      ignore(native_gh_capture(repository_root, arguments))
    },
    merge: async fn(repository_root, repository_name, intent, receipt) {
      let captured = match
        native_gh_capture(
          repository_root,
          native_pull_request_merge_arguments(
            repository_name,
            receipt.number,
            intent.expected_head_oid,
            intent.document.title,
            intent.delivery_policy.merge_method,
          ),
        ) {
        Ok(value) => value
        Err(_) =>
          return @workflow.PullRequestMergeDispatchObservation::PullRequestMergeDispatchUncertain
      }
      match captured {
        @process_host.NativeProcessCompleted(0, _) =>
          @workflow.PullRequestMergeDispatchObservation::PullRequestMergeDispatchAccepted
        @process_host.NativeProcessCompleted(_, output) =>
          @workflow.PullRequestMergeDispatchObservation::PullRequestMergeDispatchRejected(
            @storage.artifact_digest(@utf8.encode(output)),
          )
        _ =>
          @workflow.PullRequestMergeDispatchObservation::PullRequestMergeDispatchUncertain
      }
    },
    neutralize: async fn(repository_root, repository_name, _, receipt) {
      // Disabling automatic merge first is what makes the close safe: closing
      // alone would leave a queued merge to fire if the PR were reopened.
      ignore(
        native_gh_capture(
          repository_root,
          native_pull_request_disable_auto_merge_arguments(
            repository_name,
            receipt.number,
          ),
        ),
      )
      ignore(
        native_gh_capture(
          repository_root,
          native_pull_request_close_arguments(repository_name, receipt.number),
        ),
      )
    },
  }
}

///|
pub fn synthetic_pull_request_forge_adapters() -> NativePullRequestForgeAdapters {
  let created = Ref(false)
  let neutralized = Ref(false)
  {
    resolve_repository: _ => Ok("choir/synthetic"),
    lookup: (_, _, intent) => {
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
        state: if neutralized.val {
          @workflow.RemotePullRequestState::RemotePullRequestClosed
        } else {
          @workflow.RemotePullRequestState::RemotePullRequestOpen
        },
        draft: intent.document.draft,
        auto_merge_enabled: !neutralized.val &&
        (
          intent.merge_state ==
          @workflow.PullRequestMergeState::PullRequestMergeMayHaveBeenIssued ||
          intent.merge_state ==
          @workflow.PullRequestMergeState::PullRequestMergeEnabled
        ),
        marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
        title_digest: @storage.artifact_digest(
          @utf8.encode(intent.document.title),
        ),
        body_digest: @storage.artifact_digest(
          @utf8.encode(intent.document.body),
        ),
      })
    },
    create: (_, _, _, _) => created.val = true,
    merge: (_, _, _, _) => {
      @workflow.PullRequestMergeDispatchObservation::PullRequestMergeDispatchAccepted
    },
    neutralize: (_, _, _, _) => neutralized.val = true,
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
fn native_goal_pull_request_document(
  proposed : @workflow.PullRequestDocument?,
  marker : @workflow.PullRequestIdentityMarker,
) -> Result[@workflow.PullRequestDocument, @types.ChoirError] {
  guard proposed is Some(document) else {
    return Err(
      native_pull_request_error("publishable Goal has no pull request document"),
    )
  }
  Ok({
    title: document.title,
    body: document.body + "\n\n" + marker.0,
    draft: document.draft,
  })
}

///|
test "native final PR preserves Conductor prose and adds only its marker" {
  let marker = @workflow.PullRequestIdentityMarker(
    "<!-- choir-final-pr:exact -->",
  )
  let document = native_goal_pull_request_document(
    Some({
      title: "docs: add first-Goal walkthrough",
      body: "Explains the workflow and its verification.",
      draft: false,
    }),
    marker,
  ).unwrap()
  assert_eq(document.title, "docs: add first-Goal walkthrough")
  assert_eq(
    document.body,
    "Explains the workflow and its verification.\n\n" + marker.0,
  )
  assert_false(document.body.contains("goal-contract-digest"))
  assert_false(document.body.contains("evidence-manifest-digest"))
  assert_true(native_goal_pull_request_document(None, marker) is Err(_))
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
pub async fn advance_native_goal_pull_request_with_adapters(
  project_dir : String,
  goal_id : @control.GoalId,
  forge : NativePullRequestForgeAdapters,
  delivery_policy? : @types.PullRequestDeliveryPolicy = {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  },
  fault? : @workflow.GoalPullRequestFaultPoint? = None,
) -> Result[@workflow.GoalPullRequestTickOutcome, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let repository_adapters = @storage_host.local_part_workflow_repository_adapters()
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
  if execution.completion_mode != @workflow.GoalCompletionMode::GoalPublishable {
    return Err(native_pull_request_error("Goal is not publishable"))
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
  let mut dispatch_merge = false
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
        let document = match
          native_goal_pull_request_document(
            execution.pull_request_document,
            marker,
          ) {
          Ok(value) => value
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
            delivery_policy~,
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
              (forge.create)(
                git.root,
                repository_name,
                stored.record.intent,
                stored.record.intent.document,
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
            match stored.record.intent.merge_state {
              @workflow.PullRequestMergeState::PullRequestMergeNotRequested
              | @workflow.PullRequestMergeState::PullRequestMergeEnabled =>
                return Ok(
                  @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
                )
              @workflow.PullRequestMergeState::PullRequestMergeRejected(digest) =>
                return Ok(
                  @workflow.GoalPullRequestTickOutcome::GoalPullRequestDeliveryFailed(
                    digest,
                  ),
                )
              @workflow.PullRequestMergeState::PullRequestMergePlanned => {
                let authorized = match
                  @workflow.authorize_goal_pull_request_merge(
                    stored.record,
                    (forge.lookup)(
                      git.root,
                      repository_name,
                      stored.record.intent,
                    ),
                  ) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                }
                if authorized == stored.record {
                  return Ok(
                    @workflow.GoalPullRequestTickOutcome::GoalPullRequestPending,
                  )
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
              }
              @workflow.PullRequestMergeState::PullRequestMergeAuthorized => {
                let issued = match
                  @workflow.mark_goal_pull_request_merge_may_have_been_issued(
                    stored.record,
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
                dispatch_merge = persisted.1
              }
              @workflow.PullRequestMergeState::PullRequestMergeMayHaveBeenIssued => {
                if dispatch_merge {
                  guard stored.record.receipt is Some(receipt) else {
                    return Err(
                      native_pull_request_error(
                        "automatic merge receipt is absent",
                      ),
                    )
                  }
                  let observed = (forge.merge)(
                    git.root,
                    repository_name,
                    stored.record.intent,
                    receipt,
                  )
                  dispatch_merge = false
                  let recorded = match
                    @workflow.record_goal_pull_request_merge_dispatch(
                      stored.record,
                      observed,
                    ) {
                    Ok(value) => value
                    Err(error) => return Err(error)
                  }
                  if recorded != stored.record {
                    let persisted = match
                      persist_native_goal_pull_request_record(
                        repository,
                        repository_adapters,
                        execution,
                        recorded,
                        Some(stored.state_record.version),
                      ) {
                      Ok(value) => value
                      Err(error) => return Err(error)
                    }
                    current = persisted.0
                    continue
                  }
                }
                let reconciled = match
                  @workflow.reconcile_goal_pull_request_merge(
                    stored.record,
                    (forge.lookup)(
                      git.root,
                      repository_name,
                      stored.record.intent,
                    ),
                  ) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                }
                if reconciled == stored.record {
                  return Ok(
                    @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain,
                  )
                }
                let persisted = match
                  persist_native_goal_pull_request_record(
                    repository,
                    repository_adapters,
                    execution,
                    reconciled,
                    Some(stored.state_record.version),
                  ) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                }
                current = persisted.0
                if reconciled.intent.merge_state ==
                  @workflow.PullRequestMergeState::PullRequestMergeAuthorized {
                  return Ok(
                    @workflow.GoalPullRequestTickOutcome::GoalPullRequestPending,
                  )
                }
              }
            }
          @workflow.PullRequestIntentState::PullRequestNeedsInput(_) =>
            match stored.record.intent.merge_state {
              @workflow.PullRequestMergeState::PullRequestMergeRejected(digest) =>
                return Ok(
                  @workflow.GoalPullRequestTickOutcome::GoalPullRequestDeliveryFailed(
                    digest,
                  ),
                )
              _ =>
                return Ok(
                  @workflow.GoalPullRequestTickOutcome::GoalPullRequestNeedsUserInput,
                )
            }
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
fn native_pull_request_test_intent() -> @workflow.PullRequestIntent {
  {
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
    document: {
      title: "docs: explain Goal workflow",
      body: "Explains the Goal workflow.\n\n<!-- choir-final-pr:fixture -->",
      draft: false,
    },
    identity_marker: @workflow.PullRequestIdentityMarker(
      "<!-- choir-final-pr:fixture -->",
    ),
    idempotency_key: "pr-fixture",
    canonical_remote_pull_request_id: None,
    state: @workflow.PullRequestIntentState::PullRequestPlanned,
    delivery_policy: {
      mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
      merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
    },
    merge_state: @workflow.PullRequestMergeState::PullRequestMergeNotRequested,
    cancellation_state: @workflow.PullRequestCancellationState::PullRequestCancellationNotRequested,
  }
}

///|
fn native_pull_request_test_snapshot_json(
  title : String,
  body : String,
  number? : Int = 7,
  head? : String = "choir/goals/fixture",
) -> String {
  {
    "node_id": ("PR_" + number.to_string()).to_json(),
    "number": number.to_json(),
    "html_url": ("https://example.test/pull/" + number.to_string()).to_json(),
    "state": "open".to_json(),
    "head": {
      "ref": head.to_json(),
      "sha": "0123456789012345678901234567890123456789".to_json(),
      "repo": { "full_name": "choir/choir".to_json() }.to_json(),
    }.to_json(),
    "base": { "ref": "main".to_json() }.to_json(),
    "title": title.to_json(),
    "body": body.to_json(),
  }
  .to_json()
  .stringify()
}

///|
fn native_pull_request_test_graphql_response(
  intent : @workflow.PullRequestIntent,
) -> String {
  {
    "data": {
      "node": {
        "id": "PR_7".to_json(),
        "number": (7 : Int).to_json(),
        "url": "https://example.test/pull/7".to_json(),
        "state": "OPEN".to_json(),
        "headRefName": "choir/goals/fixture".to_json(),
        "headRefOid": intent.expected_head_oid.0.to_json(),
        "headRepository": { "nameWithOwner": "choir/choir".to_json() }.to_json(),
        "baseRefName": "main".to_json(),
        "title": intent.document.title.to_json(),
        "body": intent.document.body.to_json(),
        "isDraft": (false : Bool).to_json(),
      }.to_json(),
    }.to_json(),
  }
  .to_json()
  .stringify()
}

///|
test "GitHub lookup parser requires exact identity and detects ambiguity" {
  let intent = native_pull_request_test_intent()
  let exact = native_pull_request_test_snapshot_json(
    intent.document.title,
    intent.document.body,
  )
  let accumulator = native_pull_request_lookup_accumulator()
  assert_eq(
    parse_native_pull_request_page(
      "[" + exact + "]",
      "choir/choir",
      intent,
      accumulator,
    ),
    Some(1),
  )
  assert_true(
    native_pull_request_lookup_accumulator_observation(accumulator)
    is @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(_),
  )
  let possible_accumulator = native_pull_request_lookup_accumulator()
  let possible = native_pull_request_test_snapshot_json(
    "edited title",
    intent.document.body,
  )
  assert_eq(
    parse_native_pull_request_page(
      "[" + possible + "]",
      "choir/choir",
      intent,
      possible_accumulator,
    ),
    Some(1),
  )
  assert_true(
    native_pull_request_lookup_accumulator_observation(possible_accumulator)
    is @workflow.PullRequestLookupObservation::PullRequestPossibleExistingMatch(
      _
    ),
  )
  let duplicate_accumulator = native_pull_request_lookup_accumulator()
  assert_eq(
    parse_native_pull_request_page(
      "[" + exact + "," + exact + "]",
      "choir/choir",
      intent,
      duplicate_accumulator,
    ),
    Some(2),
  )
  assert_true(duplicate_accumulator.ambiguous)
  assert_eq(
    parse_native_pull_request_page(
      "not-json", "choir/choir", intent, accumulator,
    ),
    None,
  )
}

///|
async test "GitHub lookup uses one direct request for a stored node ID" {
  let base = native_pull_request_test_intent()
  let stored_id = @workflow.RemotePullRequestId("PR_7")
  let intent = { ..base, canonical_remote_pull_request_id: Some(stored_id) }
  let arguments : Array[Array[String]] = []
  let observation = native_pull_request_lookup(
    "/unused",
    "choir/choir",
    intent,
    async fn(_, args) {
      @async.sleep(0)
      arguments.push(args)
      Ok(
        @process_host.NativeProcessCompleted(
          0,
          native_pull_request_test_graphql_response(intent),
        ),
      )
    },
  )
  assert_true(
    observation
    is @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(_),
  )
  assert_eq(arguments.length(), 1)
  assert_eq(arguments[0][0:4], [
    "api", "graphql", "-f", "query=query($id:ID!){node(id:$id){... on PullRequest{id number url state mergedAt headRefName headRefOid headRepository{nameWithOwner} baseRefName title body isDraft autoMergeRequest{enabledAt}}}}",
  ])
  assert_eq(arguments[0][4:], ["-f", "id=PR_7"])
}

///|
async test "GitHub lookup filters exact refs and stops on a short page" {
  let intent = native_pull_request_test_intent()
  let arguments : Array[Array[String]] = []
  let observation = native_pull_request_lookup(
    "/unused",
    "choir/choir",
    intent,
    async fn(_, args) {
      @async.sleep(0)
      arguments.push(args)
      Ok(
        @process_host.NativeProcessCompleted(
          0,
          "[" +
          native_pull_request_test_snapshot_json(
            intent.document.title,
            intent.document.body,
          ) +
          "]",
        ),
      )
    },
  )
  assert_true(
    observation
    is @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(_),
  )
  assert_eq(arguments.length(), 1)
  assert_true(arguments[0].contains("head=choir:choir/goals/fixture"))
  assert_true(arguments[0].contains("base=main"))
  assert_true(arguments[0].contains("per_page=100"))
  assert_true(arguments[0].contains("page=1"))
}

///|
async test "GitHub lookup treats five full pages as uncertain" {
  let intent = native_pull_request_test_intent()
  let full_page_items : Array[String] = []
  for index = 0; index < native_pull_request_page_size; index = index + 1 {
    full_page_items.push(
      native_pull_request_test_snapshot_json(
        "unrelated " + index.to_string(),
        "unrelated",
        number=1000 + index,
        head="other/" + index.to_string(),
      ),
    )
  }
  let full_page = "[" + full_page_items.join(",") + "]"
  let mut calls = 0
  let observation = native_pull_request_lookup(
    "/unused",
    "choir/choir",
    intent,
    async fn(_, _) {
      @async.sleep(0)
      calls = calls + 1
      Ok(@process_host.NativeProcessCompleted(0, full_page))
    },
  )
  assert_eq(calls, 5)
  assert_eq(
    observation,
    @workflow.PullRequestLookupObservation::PullRequestLookupUncertain,
  )
}

///|
async test "GitHub lookup maps bounded failures to uncertainty" {
  let intent = native_pull_request_test_intent()
  let timed_out = native_pull_request_lookup("/unused", "choir/choir", intent, async fn(
    _,
    _,
  ) {
    @async.sleep(0)
    Ok(@process_host.NativeProcessTimedOut("bounded tail"))
  })
  assert_eq(
    timed_out,
    @workflow.PullRequestLookupObservation::PullRequestLookupUncertain,
  )
  let exceeded = native_pull_request_lookup("/unused", "choir/choir", intent, async fn(
    _,
    _,
  ) {
    @async.sleep(0)
    Ok(@process_host.NativeProcessOutputExceeded("bounded tail"))
  })
  assert_eq(
    exceeded,
    @workflow.PullRequestLookupObservation::PullRequestLookupUncertain,
  )
  assert_eq(native_github_timeout_ms, 30000)
  assert_eq(native_github_output_limit_bytes, 4194304)
}

///|
