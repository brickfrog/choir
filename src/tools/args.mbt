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
pub(all) struct TddIntentArgs {
  caller_id : String
  intent : String
  test_command : String?
  artifact_path : String?
} derive(Debug, Eq)

///|
pub(all) struct TddRedCheckArgs {
  caller_id : String
  exit_code : Int
} derive(Debug, Eq)

///|
pub(all) struct TddGreenCheckArgs {
  caller_id : String
  exit_code : Int
  next_phase : @types.LeafTddPhase?
} derive(Debug, Eq)

///|
pub(all) struct ForkWaveScaffoldCommit {
  message : String
  paths : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct ForkWaveArgs {
  count : Int
  tasks : Array[String]
  task_contracts : Array[@types.TaskContract]
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
  /// Per-wave automerge override. `None` means "use the global config default".
  automerge : Bool?
  /// Per-wave review-mode override. `None` means "use the global config default".
  review_mode : @types.ReviewMode?
  /// Per-wave merge-strategy override. `None` means "use the global config default".
  merge_strategy : @types.MergeStrategy?
  /// Agent IDs the wave depends on. When non-empty the wave is queued as a
  /// pending wave (`pending-wave--<id>`) and only spawned after every named
  /// dep reaches `Dev(Done(Merged))`. See `pending_wave.mbt`.
  depends_on : Array[String]
  /// Optional scaffold commit applied on the parent branch before spawning leaves.
  scaffold_commit : ForkWaveScaffoldCommit?
} derive(Debug, Eq)

///|
pub(all) struct SpawnGeminiArgs {
  task : String
  task_contract : @types.TaskContract
  caller_id : String
  slug : String
  parent_branch : String
  parent_session_id : String?
} derive(Debug, Eq)

///|
pub(all) enum WorkerKind {
  Research
  Review
} derive(Debug, Eq)

///|
pub impl Show for WorkerKind with fn output(self, logger) -> Unit {
  match self {
    Research => logger.write_string("research")
    Review => logger.write_string("review")
  }
}

///|
struct LeafSpawnArgs {
  task : String
  task_contract : @types.TaskContract
  caller_id : String
  slug : String
  parent_branch : String
} derive(Debug, Eq)

///|
pub(all) struct WorkerSpawnArgs {
  task : String
  task_contract : @types.TaskContract
  caller_id : String
  slug : String
  agent_type : @types.AgentType
  worker_kind : WorkerKind
  parent_branch : String?
  isolation : @types.IsolationMode?
} derive(Debug, Eq)

///|
pub(all) struct RemoteSpawnArgs {
  task : String
  task_contract : @types.TaskContract
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
  agent_type_explicit : Bool
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
pub(all) struct GoalSetArgs {
  input : String
  verify : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct GoalStatusArgs {
  evaluate : Bool
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
  review_mode : @types.ReviewMode?
} derive(Debug, Eq)

///|
pub(all) struct ResolveReviewThreadArgs {
  thread_id : String
  caller_id : String
} derive(Debug, Eq)

///|
pub(all) struct ResolveMyReviewThreadsArgs {
  caller_id : String
  pr_number : Int?
} derive(Debug, Eq)

///|
pub(all) struct RequestReviewArgs {
  pr_number : Int
  reviewer : String
} derive(Debug, Eq)

///|
pub(all) struct CallerMessageArgs {
  caller_id : String
  message : String
  status : @types.Status
} derive(Debug, Eq)

///|
pub(all) struct ReportUsageArgs {
  caller_id : String
  tokens_in : Int
  tokens_out : Int
  elapsed_s : Int
  cost_usd : Double?
} derive(Debug, Eq)

///|
pub(all) struct WaveStateArgs {
  caller_id : String
} derive(Debug, Eq)

///|
pub(all) struct StatusBarStateArgs {
  unit : Unit
} derive(Debug, Eq)

///|
pub(all) struct CrystallizeSpecArgs {
  caller_id : String
  feature_slug : String
} derive(Debug, Eq)

///|
pub(all) struct WriteAuditReceiptArgs {
  caller_id : String
  sha : String
  tree_sha : String
  branch : String
  findings_count : Int
  findings : String
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
pub(all) struct SuspendArgs {
  agent_id : String
  reason : String
} derive(Debug, Eq)

///|
pub(all) struct ResumeArgs {
  agent_id : String
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
