//|

///|
/// What a provider surface reported about its own allowance when a dispatch
/// failed. This is an observation, not a verdict: whether it means the surface
/// must be deferred, and until when, is
/// `@control.classify_provider_availability`'s decision.
///
/// Both supported protocols report the reset as an absolute epoch-second
/// instant — Claude Code's `system/api_error` frame carries
/// `error.rate_limits.resets_at` from the `anthropic-ratelimit-unified-reset`
/// header, and the Codex app-server's `account/rateLimits/updated` carries
/// `rateLimits.primary.resetsAt` — which is the same unit Choir's clock reads
/// in, so neither needs converting.
pub(all) struct ProviderAllowanceObservation {
  /// When the surface said its window resets.
  reset_at : Int64?
  /// How long the surface asked the caller to wait.
  retry_after_seconds : Int64?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Orchestrator error types (suberror for `raise` / `try?` interop).
suberror ChoirError {
  AgentNotFound(String)
  ToolNotFound(String)
  PermissionDenied(String, String)
  /// An authority rejection that reports as `permission_denied` but carries a
  /// custom explanatory message (e.g. the single-writer gate's kill-to-take-over
  /// / terminal-fence wording). Same taxonomy as `PermissionDenied`, with an
  /// informative detail instead of the fixed `role X cannot call Y` rendering.
  PermissionDeniedDetail(String)
  PolicyBlocked(String)
  ProviderProtocolViolation(String)
  EventIngestionOverflow(String)
  ProviderProcessLost(String, ProviderAllowanceObservation?)
  /// A JSON-RPC peer rejected a request. The numeric code is retained rather
  /// than flattened into prose so a caller deciding whether the rejection is
  /// recoverable has something typed to look at.
  ProviderRpcError(Int, String)
  ValidationError(String)
  Timeout(String)
  OperationCanceled(String)
  WorkspaceError(String)
  TransportError(String)
  GitError(String)
  ConfigError(String)
  CommandPreparationMissingRequiredArtifact(String)
  CommandPreparationStaleBinding
  CommandPreparationSizeLimitExceeded(Int, Int)
  CommandPreparationDigestMismatch
  CommandPreparationUnsupportedTemplate
}

///|
pub fn ChoirError::to_wire_string(self : ChoirError) -> String {
  match self {
    AgentNotFound(_) => "agent_not_found"
    ToolNotFound(_) => "tool_not_found"
    PermissionDenied(_, _) => "permission_denied"
    PermissionDeniedDetail(_) => "permission_denied"
    PolicyBlocked(_) => "policy_blocked"
    ProviderProtocolViolation(_) => "provider_protocol_violation"
    EventIngestionOverflow(_) => "event_ingestion_overflow"
    ProviderProcessLost(_, _) => "provider_process_lost"
    ProviderRpcError(_, _) => "provider_rpc_error"
    ValidationError(_) => "validation_error"
    Timeout(_) => "timeout"
    OperationCanceled(_) => "canceled"
    WorkspaceError(_) => "workspace_error"
    TransportError(_) => "transport_error"
    GitError(_) => "git_error"
    ConfigError(_) => "config_error"
    CommandPreparationMissingRequiredArtifact(_) =>
      "command_preparation_blocked"
    CommandPreparationStaleBinding => "command_preparation_blocked"
    CommandPreparationSizeLimitExceeded(_, _) => "command_preparation_blocked"
    CommandPreparationDigestMismatch => "command_preparation_blocked"
    CommandPreparationUnsupportedTemplate => "command_preparation_blocked"
  }
}

///|
pub fn ChoirError::message(self : ChoirError) -> String {
  match self {
    AgentNotFound(id) => "agent not found: " + id
    ToolNotFound(name) => "tool not found: " + name
    PermissionDenied(role, tool) => "role " + role + " cannot call " + tool
    PermissionDeniedDetail(msg) => msg
    PolicyBlocked(msg) => "policy blocked: " + msg
    ProviderProtocolViolation(msg) => "provider protocol violation: " + msg
    EventIngestionOverflow(msg) => "event ingestion overflow: " + msg
    ProviderProcessLost(msg, _) => "provider process lost: " + msg
    ProviderRpcError(code, msg) =>
      "provider rpc error " + code.to_string() + ": " + msg
    ValidationError(msg) => "validation error: " + msg
    Timeout(msg) => "timeout error: " + msg
    OperationCanceled(msg) => "canceled: " + msg
    WorkspaceError(msg) => "workspace error: " + msg
    TransportError(msg) => "transport error: " + msg
    GitError(msg) => "git error: " + msg
    ConfigError(msg) => "config error: " + msg
    CommandPreparationMissingRequiredArtifact(digest) =>
      "command preparation blocked: missing required artifact " + digest
    CommandPreparationStaleBinding =>
      "command preparation blocked: stale binding"
    CommandPreparationSizeLimitExceeded(actual, limit) =>
      "command preparation blocked: size limit exceeded (" +
      actual.to_string() +
      " > " +
      limit.to_string() +
      ")"
    CommandPreparationDigestMismatch =>
      "command preparation blocked: digest mismatch"
    CommandPreparationUnsupportedTemplate =>
      "command preparation blocked: unsupported template"
  }
}

///|
pub impl Show for ChoirError with fn output(self, logger) -> Unit {
  self.message().output(logger)
}

///|
/// Factories for use outside this package (`suberror` constructors are package-private).
pub fn ChoirError::agent_not_found(id : String) -> ChoirError {
  AgentNotFound(id)
}

///|
pub fn ChoirError::tool_not_found(name : String) -> ChoirError {
  ToolNotFound(name)
}

///|
pub fn ChoirError::permission_denied(
  role : String,
  tool : String,
) -> ChoirError {
  PermissionDenied(role, tool)
}

///|
/// Authority rejection reported as `permission_denied` but carrying a custom
/// explanatory message (single-writer gate kill-to-take-over / terminal fence).
pub fn ChoirError::permission_denied_detail(detail : String) -> ChoirError {
  PermissionDeniedDetail(detail)
}

///|
pub fn ChoirError::policy_blocked(msg : String) -> ChoirError {
  PolicyBlocked(msg)
}

///|
pub fn ChoirError::provider_protocol_violation(msg : String) -> ChoirError {
  ProviderProtocolViolation(msg)
}

///|
pub fn ChoirError::event_ingestion_overflow(msg : String) -> ChoirError {
  EventIngestionOverflow(msg)
}

///|
/// A provider dispatch was lost. `allowance` carries what the surface itself
/// reported about its allowance, when it reported anything; classification of
/// that observation belongs to the control plane, not here.
pub fn ChoirError::provider_process_lost(
  msg : String,
  allowance? : ProviderAllowanceObservation? = None,
) -> ChoirError {
  ProviderProcessLost(msg, allowance)
}

///|
pub fn ChoirError::validation_error(msg : String) -> ChoirError {
  ValidationError(msg)
}

///|
pub fn ChoirError::timeout(msg : String) -> ChoirError {
  Timeout(msg)
}

///|
pub fn ChoirError::canceled(msg : String) -> ChoirError {
  OperationCanceled(msg)
}

///|
pub fn ChoirError::validation_detail_or_message(self : ChoirError) -> String {
  match self {
    ValidationError(msg) => msg
    Timeout(msg) => msg
    OperationCanceled(msg) => msg
    PermissionDeniedDetail(msg) => msg
    _ => self.message()
  }
}

///|
pub fn ChoirError::config_detail(self : ChoirError) -> String? {
  match self {
    ConfigError(msg) => Some(msg)
    _ => None
  }
}

///|
pub fn ChoirError::workspace_error(msg : String) -> ChoirError {
  WorkspaceError(msg)
}

///|
pub fn ChoirError::transport_error(msg : String) -> ChoirError {
  TransportError(msg)
}

///|
pub fn ChoirError::git_error(msg : String) -> ChoirError {
  GitError(msg)
}

///|
pub fn ChoirError::config_error(msg : String) -> ChoirError {
  ConfigError(msg)
}

///|
pub fn ChoirError::command_preparation_missing_required_artifact(
  digest : String,
) -> ChoirError {
  CommandPreparationMissingRequiredArtifact(digest)
}

///|
pub fn ChoirError::command_preparation_stale_binding() -> ChoirError {
  CommandPreparationStaleBinding
}

///|
pub fn ChoirError::command_preparation_size_limit_exceeded(
  actual_bytes : Int,
  limit_bytes : Int,
) -> ChoirError {
  CommandPreparationSizeLimitExceeded(actual_bytes, limit_bytes)
}

///|
pub fn ChoirError::command_preparation_digest_mismatch() -> ChoirError {
  CommandPreparationDigestMismatch
}

///|
pub fn ChoirError::command_preparation_unsupported_template() -> ChoirError {
  CommandPreparationUnsupportedTemplate
}

///|
pub fn ChoirError::is_command_preparation_blocked(self : ChoirError) -> Bool {
  match self {
    CommandPreparationMissingRequiredArtifact(_)
    | CommandPreparationStaleBinding
    | CommandPreparationSizeLimitExceeded(_, _)
    | CommandPreparationDigestMismatch
    | CommandPreparationUnsupportedTemplate => true
    _ => false
  }
}

///|
pub fn ChoirError::is_tool_not_found(self : ChoirError) -> Bool {
  match self {
    ToolNotFound(_) => true
    _ => false
  }
}

///|
pub fn ChoirError::is_timeout(self : ChoirError) -> Bool {
  match self {
    Timeout(_) => true
    _ => false
  }
}

///|
pub fn ChoirError::is_provider_protocol_violation(self : ChoirError) -> Bool {
  match self {
    ProviderProtocolViolation(_) => true
    _ => false
  }
}

///|
pub fn ChoirError::is_event_ingestion_overflow(self : ChoirError) -> Bool {
  match self {
    EventIngestionOverflow(_) => true
    _ => false
  }
}

///|
pub fn ChoirError::provider_rpc_error(code : Int, msg : String) -> ChoirError {
  ProviderRpcError(code, msg)
}

///|
/// The JSON-RPC code and message a peer rejected the request with, if it was a
/// rejection at all.
pub fn ChoirError::provider_rpc_rejection(self : ChoirError) -> (Int, String)? {
  match self {
    ProviderRpcError(code, msg) => Some((code, msg))
    _ => None
  }
}

///|
/// Typed predicates for the classifications control flow branches on.
///
/// Without these, callers compared `to_wire_string()` to a literal, which put
/// the wire vocabulary in the middle of cancellation and validation decisions:
/// renaming a tag would silently change what a Part does on cancel instead of
/// failing to compile.
pub fn ChoirError::is_canceled(self : ChoirError) -> Bool {
  self is OperationCanceled(_)
}

///|
pub fn ChoirError::is_validation_error(self : ChoirError) -> Bool {
  self is ValidationError(_)
}

///|
pub fn ChoirError::is_transport_error(self : ChoirError) -> Bool {
  self is TransportError(_)
}

///|
pub fn ChoirError::is_provider_process_lost(self : ChoirError) -> Bool {
  match self {
    ProviderProcessLost(_, _) => true
    _ => false
  }
}

///|
/// What the surface reported about its own allowance, if it reported anything.
/// Absent means Choir observed nothing, never that the allowance is intact.
pub fn ChoirError::provider_allowance_observation(
  self : ChoirError,
) -> ProviderAllowanceObservation? {
  match self {
    ProviderProcessLost(_, allowance) => allowance
    _ => None
  }
}
