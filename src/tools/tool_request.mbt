///|
pub(all) enum ToolRequest {
  Register(RegisterArgs)
  ForkWave(ForkWaveArgs)
  ForkSession(SessionNameArgs)
  FilePr(FilePrArgs)
  MergePr(MergePrArgs)
  TrackPr(TrackPrArgs)
  NotifyParent(CallerMessageArgs)
  SendMessage(SendMessageArgs)
  Reply(ReplyArgs)
  Shutdown(ShutdownArgs)
  KvGet(KvKeyArgs)
  KvSet(KvSetArgs)
  KvDelete(KvKeyArgs)
  KvList
  MutexAcquire(MutexAcquireArgs)
  MutexRelease(MutexReleaseArgs)
  MutexStatus(MutexNameArgs)
  TaskList
  TaskGet(IdArgs)
  TaskCreate(TaskCreateArgs)
  TaskUpdate(TaskUpdateArgs)
  SpawnGemini(SpawnGeminiArgs)
  RescueLeaf(RescueLeafArgs)
  SpawnRemote(RemoteSpawnArgs)
  SpawnWorker(WorkerSpawnArgs)
  KillAgent(KillAgentArgs)
  AgentList(AgentListArgs)
  CancelWave(CancelWaveArgs)
  ResolveReviewThread(ResolveReviewThreadArgs)
} derive(Show, Eq)

///|
pub fn ToolRequest::tool_name(self : ToolRequest) -> String {
  match self {
    Register(_) => "register"
    ForkWave(_) => "fork_wave"
    ForkSession(_) => "fork_session"
    FilePr(_) => "file_pr"
    MergePr(_) => "merge_pr"
    TrackPr(_) => "track_pr"
    NotifyParent(_) => "notify_parent"
    SendMessage(_) => "send_message"
    Reply(_) => "reply"
    Shutdown(_) => "shutdown"
    KvGet(_) => "kv_get"
    KvSet(_) => "kv_set"
    KvDelete(_) => "kv_delete"
    KvList => "kv_list"
    MutexAcquire(_) => "mutex_acquire"
    MutexRelease(_) => "mutex_release"
    MutexStatus(_) => "mutex_status"
    TaskList => "task_list"
    TaskGet(_) => "task_get"
    TaskCreate(_) => "task_create"
    TaskUpdate(_) => "task_update"
    SpawnGemini(_) => "spawn_gemini"
    RescueLeaf(_) => "rescue_leaf"
    SpawnRemote(_) => "spawn_remote"
    SpawnWorker(_) => "spawn_worker"
    KillAgent(_) => "kill_agent"
    AgentList(_) => "agent_list"
    CancelWave(_) => "cancel_wave"
    ResolveReviewThread(_) => "resolve_review_thread"
  }
}
