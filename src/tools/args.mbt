///|
struct TaskFile {
  id : String
  title : String
  status : String
  assignee : String
  notes : String
} derive(Show, Eq)

///|
struct FilePrArgs {
  branch : String
  parent_branch : String?
  tracked_agent_id : String
  title : String?
  body : String?
} derive(Show, Eq)

///|
struct TrackPrArgs {
  pr_number : Int
  agent_id : String
  branch : String
  parent_branch : String
  pr_url : String
} derive(Show, Eq)

///|
struct ForkWaveArgs {
  count : Int
  tasks : Array[String]
  has_per_leaf_tasks : Bool
  parent_branch : String
  caller_id : String
  slug_prefix : String
  agent_type : @types.AgentType
  parent_session_id : String?
} derive(Show, Eq)

///|
struct SpawnGeminiArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
  parent_session_id : String?
} derive(Show, Eq)

///|
struct LeafSpawnArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
} derive(Show, Eq)

///|
struct WorkerSpawnArgs {
  task : String
  caller_id : String
  slug : String
  agent_type : @types.AgentType
} derive(Show, Eq)

///|
struct RemoteSpawnArgs {
  task : String
  caller_id : String
  slug : String
  parent_branch : String
  ssh_target : String
  repo_url : String
  tcp_addr : String
  parent_session_id : String?
} derive(Show, Eq)

///|
struct TaskCreateArgs {
  id : String
  title : String
  status : String
  assignee : String
  notes : String
} derive(Show, Eq)

///|
struct TaskUpdateArgs {
  id : String
  status : String?
  assignee : String?
  notes : String?
} derive(Show, Eq)

///|
struct RegisterArgs {
  agent_id : String
  role : @types.Role
  agent_type : @types.AgentType
  parent : String?
  terminal_target : @types.LocalTarget?
  workspace : String
  branch : String
} derive(Show, Eq)

///|
struct KvKeyArgs {
  key : String
} derive(Show, Eq)

///|
struct KvSetArgs {
  key : String
  value : String
} derive(Show, Eq)

///|
struct MutexAcquireArgs {
  name : String
  agent_id : String
  ttl_sec : Int64
} derive(Show, Eq)

///|
struct MutexNameArgs {
  name : String
} derive(Show, Eq)

///|
struct MutexReleaseArgs {
  name : String
  agent_id : String
} derive(Show, Eq)

///|
struct MergePrArgs {
  pr_number : Int
  parent_branch : String
  caller_id : String
} derive(Show, Eq)

///|
struct CallerMessageArgs {
  caller_id : String
  message : String
  status : String
} derive(Show, Eq)

///|
struct SendMessageArgs {
  target_id : String
  sender_id : String
  message : String
  status : String
} derive(Show, Eq)

///|
struct ShutdownArgs {
  caller_id : String?
} derive(Show, Eq)

///|
struct IdArgs {
  id : String
} derive(Show, Eq)

///|
struct SessionNameArgs {
  name : String
} derive(Show, Eq)

///|
pub(all) struct ReplyArgs {
  id : String
  payload : String
  cancel : Bool
} derive(Show, Eq)
