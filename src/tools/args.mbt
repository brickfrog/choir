///|
struct TaskFile {
  id : String
  title : String
  status : @types.TaskStatus
  assignee : String
  notes : String
} derive(Debug, Eq)

///|
pub(all) struct FilePrArgs {
  branch : String
  parent_branch : String?
  tracked_agent_id : String
  title : String?
  body : String?
  /// Optional context posted as `@copilot review: …` on the PR when review is requested.
  review_context : String?
} derive(Debug, Eq)

///|
pub(all) struct TrackPrArgs {
  pr_number : Int
  agent_id : String
  branch : String
  parent_branch : String
  pr_url : String
} derive(Debug, Eq)

///|
pub(all) struct ForkWaveArgs {
  count : Int
  tasks : Array[String]
  has_per_leaf_tasks : Bool
  parent_branch : String
  caller_id : String
  slug_prefix : String
  agent_type : @types.AgentType
  /// Spawned child role: Dev (default) or TL (sub-team-lead).
  child_role : @types.Role
  parent_session_id : String?
  /// Appended to each leaf task so children can pass it to `file_pr` / Copilot review.
  review_context : String?
} derive(Debug, Eq)

///|
pub(all) struct SpawnGeminiArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
  parent_session_id : String?
} derive(Debug, Eq)

///|
pub(all) struct RescueLeafArgs {
  task : String
  caller_id : String
  from_agent_id : String
  new_slug : String
  agent_type : @types.AgentType
  parent_session_id : String?
} derive(Debug, Eq)

///|
struct LeafSpawnArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
} derive(Debug, Eq)

///|
pub(all) struct WorkerSpawnArgs {
  task : String
  caller_id : String
  slug : String
  agent_type : @types.AgentType
} derive(Debug, Eq)

///|
pub(all) struct RemoteSpawnArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
  ssh_target : String
  repo_url : String
  tcp_addr : String
  parent_session_id : String?
} derive(Debug, Eq)

///|
struct TaskCreateArgs {
  id : String
  title : String
  status : @types.TaskStatus
  assignee : String
  notes : String
} derive(Debug, Eq)

///|
struct TaskUpdateArgs {
  id : String
  status : @types.TaskStatus?
  assignee : String?
  notes : String?
} derive(Debug, Eq)

///|
struct RegisterArgs {
  agent_id : String
  role : @types.Role
  agent_type : @types.AgentType
  parent : String?
  terminal_target : @types.LocalTarget?
  workspace : String
  branch : String
  spawn_depth : Int
} derive(Debug, Eq)

///|
struct KvKeyArgs {
  key : String
} derive(Debug, Eq)

///|
struct KvSetArgs {
  key : String
  value : String
} derive(Debug, Eq)

///|
struct MutexAcquireArgs {
  name : String
  agent_id : String
  ttl_sec : Int64
} derive(Debug, Eq)

///|
struct MutexNameArgs {
  name : String
} derive(Debug, Eq)

///|
struct MutexReleaseArgs {
  name : String
  agent_id : String
} derive(Debug, Eq)

///|
pub(all) struct MergePrArgs {
  pr_number : Int
  parent_branch : String
  caller_id : String
  force : Bool
} derive(Debug, Eq)

///|
struct ResolveReviewThreadArgs {
  thread_id : String
  caller_id : String
} derive(Debug, Eq)

///|
pub(all) struct CallerMessageArgs {
  caller_id : String
  message : String
  status : @types.Status
} derive(Debug, Eq)

///|
struct SendMessageArgs {
  target_id : String
  sender_id : String
  message : String
  status : @types.Status
} derive(Debug, Eq)

///|
pub(all) struct ShutdownArgs {
  caller_id : String?
} derive(Debug, Eq)

///|
pub(all) struct KillAgentArgs {
  agent_id : String
  reason : String
} derive(Debug, Eq)

///|
pub(all) struct AgentListArgs {
  parent_id : String?
  include_inactive : Bool
} derive(Debug, Eq)

///|
pub(all) struct CancelWaveArgs {
  force : Bool
} derive(Debug, Eq)

///|
struct IdArgs {
  id : String
} derive(Debug, Eq)

///|
struct SessionNameArgs {
  name : String
} derive(Debug, Eq)

///|
pub(all) struct ReplyArgs {
  id : String
  payload : String
  cancel : Bool
} derive(Debug, Eq)

///|
pub impl Show for TaskFile with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for FilePrArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TrackPrArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ForkWaveArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SpawnGeminiArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for RescueLeafArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for LeafSpawnArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for WorkerSpawnArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for RemoteSpawnArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TaskCreateArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TaskUpdateArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for RegisterArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for KvKeyArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for KvSetArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MutexAcquireArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MutexNameArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MutexReleaseArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MergePrArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ResolveReviewThreadArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for CallerMessageArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SendMessageArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ShutdownArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for KillAgentArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for AgentListArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for CancelWaveArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for IdArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SessionNameArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ReplyArgs with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
